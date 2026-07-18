//
//  CalendarSyncManager.swift
//  TimeGrow
//

import Combine
import EventKit
import FirebaseAuth
import Foundation
import UIKit

/// One-way mirror of TimeGrow sessions into a dedicated Apple Calendar. Firestore remains the
/// source of truth: changes made to calendar events aren't imported back into TimeGrow.
@MainActor
final class CalendarSyncManager: ObservableObject {
    static let shared = CalendarSyncManager()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var statusMessage: String?

    private let eventStore = EKEventStore()
    private let defaults = UserDefaults.standard
    private let enabledKey = "calendarSync.enabled"
    private let calendarIDKey = "calendarSync.calendarID"
    private let ownsCalendarKey = "calendarSync.ownsCalendar"
    private let eventIDsKeyPrefix = "calendarSync.eventIDs."
    private let eventTitleFormatVersionKey = "calendarSync.eventTitleFormatVersion"
    private let eventTitleFormatVersion = 2
    private var latestSessions: [TaskTimeSession] = []
    private var latestUserID: String?
    private var runningSessionTimer: Timer?
    private var isMigratingEventTitles = false

    private init() {
        isEnabled = defaults.bool(forKey: enabledKey)
    }

    /// Enables the mirror only after the user grants the required Calendar permission. A full
    /// snapshot is used here so Timeline history outside the app's 30-day listener cache is
    /// exported as well.
    func setEnabled(_ enabled: Bool, taskService: TaskService) {
        if !enabled {
            disable()
            return
        }

        Task { @MainActor in
            guard taskService.currentUser != nil else {
                statusMessage = LanguageManager.localized("Sign in before syncing sessions to Calendar.")
                return
            }

            do {
                guard try await eventStore.requestFullAccessToEvents() else {
                    statusMessage = LanguageManager.localized("Calendar access wasn't granted.")
                    return
                }
            } catch {
                statusMessage = String(format: LanguageManager.localized("Couldn't access Calendar: %@"), error.localizedDescription)
                return
            }

            guard calendarForTimeGrowEvents() != nil else { return }
            isEnabled = true
            defaults.set(true, forKey: enabledKey)
            statusMessage = nil
            await synchronizeAll(using: taskService)
        }
    }

    /// Called from the Firestore session listener. It only upserts the observed 30-day cache;
    /// deletion reconciliation is performed from a full fetch when the user enables the feature.
    func observeSessions(_ sessions: [TaskTimeSession], userID: String?, taskService: TaskService) {
        latestSessions = sessions
        latestUserID = userID
        guard isEnabled, let userID else { return }
        synchronize(sessions, userID: userID, removeMissingEvents: false)
        updateRunningSessionTimer()

        // Update titles of older Timeline events too, not only the 30-day listener cache.
        // Version 1 used the "TimeGrow ·" prefix; version 2 contains only the task name.
        guard defaults.integer(forKey: eventTitleFormatVersionKey) < eventTitleFormatVersion,
              !isMigratingEventTitles else { return }
        isMigratingEventTitles = true
        Task { @MainActor [weak self, weak taskService] in
            guard let self, let taskService else { return }
            await self.synchronizeAll(using: taskService)
            self.isMigratingEventTitles = false
        }
    }

    func synchronizeAll(using taskService: TaskService) async {
        guard isEnabled, let userID = taskService.currentUser?.uid else { return }
        do {
            let sessions = try await taskService.fetchAllSessionsForCalendarSync()
            latestSessions = sessions
            latestUserID = userID
            synchronize(sessions, userID: userID, removeMissingEvents: true)
            defaults.set(eventTitleFormatVersion, forKey: eventTitleFormatVersionKey)
            updateRunningSessionTimer()
        } catch {
            // Do not reconcile deletions with a partial cache: a transient Firestore failure must
            // never erase older Timeline events from Calendar.
            statusMessage = String(format: LanguageManager.localized("Couldn't load Timeline history: %@"), error.localizedDescription)
            DiagnosticsLog.log("calendar", "Failed to fetch full session history: \(error.localizedDescription)")
        }
    }

    func removeSession(_ sessionID: String, userID: String?) {
        guard isEnabled, let userID else { return }
        var eventIDs = eventIDs(for: userID)
        guard let eventID = eventIDs[sessionID] else { return }

        if let event = eventStore.event(withIdentifier: eventID) {
            do {
                try eventStore.remove(event, span: .thisEvent, commit: true)
            } catch {
                DiagnosticsLog.log("calendar", "Failed to remove event for session \(sessionID): \(error.localizedDescription)")
                return
            }
        }
        eventIDs.removeValue(forKey: sessionID)
        save(eventIDs: eventIDs, for: userID)
    }

    private func disable() {
        guard isEnabled else { return }
        let userID = latestUserID

        if let userID {
            removeAllEvents(for: userID)
        }

        if defaults.bool(forKey: ownsCalendarKey),
           let calendarID = defaults.string(forKey: calendarIDKey),
           let calendar = eventStore.calendar(withIdentifier: calendarID) {
            do {
                try eventStore.removeCalendar(calendar, commit: true)
            } catch {
                DiagnosticsLog.log("calendar", "Failed to remove TimeGrow calendar: \(error.localizedDescription)")
            }
        }

        defaults.set(false, forKey: enabledKey)
        defaults.removeObject(forKey: calendarIDKey)
        defaults.removeObject(forKey: ownsCalendarKey)
        isEnabled = false
        statusMessage = nil
        runningSessionTimer?.invalidate()
        runningSessionTimer = nil
    }

    private func synchronize(_ sessions: [TaskTimeSession], userID: String, removeMissingEvents: Bool) {
        guard let calendar = calendarForTimeGrowEvents() else { return }
        var eventIDs = eventIDs(for: userID)
        let sessionIDs = Set(sessions.compactMap(\.id))

        for session in sessions {
            guard let sessionID = session.id else { continue }
            let event = eventIDs[sessionID].flatMap(eventStore.event(withIdentifier:)) ?? EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = session.taskName
            event.startDate = session.startedAt
            event.endDate = max(session.endedAt ?? Date(), session.startedAt.addingTimeInterval(1))
            event.isAllDay = false
            event.notes = eventNotes(for: session)
            event.url = URL(string: "timegrow://calendar-session?sessionID=\(sessionID)")

            do {
                try eventStore.save(event, span: .thisEvent, commit: true)
                if let eventID = event.eventIdentifier {
                    eventIDs[sessionID] = eventID
                }
            } catch {
                DiagnosticsLog.log("calendar", "Failed to save event for session \(sessionID): \(error.localizedDescription)")
            }
        }

        if removeMissingEvents {
            let staleEvents = eventIDs.filter { !sessionIDs.contains($0.key) }
            for (sessionID, eventID) in staleEvents {
                if let event = eventStore.event(withIdentifier: eventID) {
                    try? eventStore.remove(event, span: .thisEvent, commit: true)
                }
                eventIDs.removeValue(forKey: sessionID)
            }
        }

        save(eventIDs: eventIDs, for: userID)
    }

    private func calendarForTimeGrowEvents() -> EKCalendar? {
        if let calendarID = defaults.string(forKey: calendarIDKey),
           let calendar = eventStore.calendar(withIdentifier: calendarID),
           calendar.allowsContentModifications {
            return calendar
        }

        let source = eventStore.defaultCalendarForNewEvents?.source
            ?? eventStore.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local })
        if let source {
            let calendar = EKCalendar(for: .event, eventStore: eventStore)
            calendar.title = "TimeGrow"
            calendar.cgColor = UIColor.systemGreen.cgColor
            calendar.source = source
            do {
                try eventStore.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: calendarIDKey)
                defaults.set(true, forKey: ownsCalendarKey)
                return calendar
            } catch {
                DiagnosticsLog.log("calendar", "Failed to create TimeGrow calendar: \(error.localizedDescription)")
            }
        }

        // Some managed calendar accounts don't permit adding a new calendar. In that case, use
        // the person's default writable calendar while retaining event IDs so only TimeGrow
        // events are ever touched.
        if let calendar = eventStore.defaultCalendarForNewEvents, calendar.allowsContentModifications {
            defaults.set(calendar.calendarIdentifier, forKey: calendarIDKey)
            defaults.set(false, forKey: ownsCalendarKey)
            return calendar
        }

        statusMessage = LanguageManager.localized("No writable Apple Calendar is available on this device.")
        DiagnosticsLog.log("calendar", "No writable calendar available")
        return nil
    }

    private func eventNotes(for session: TaskTimeSession) -> String {
        var lines = ["Tracked with TimeGrow"]
        if let notes = session.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append(notes)
        }
        return lines.joined(separator: "\n\n")
    }

    private func eventIDs(for userID: String) -> [String: String] {
        defaults.dictionary(forKey: eventIDsKeyPrefix + userID) as? [String: String] ?? [:]
    }

    private func save(eventIDs: [String: String], for userID: String) {
        defaults.set(eventIDs, forKey: eventIDsKeyPrefix + userID)
    }

    private func removeAllEvents(for userID: String) {
        let eventIDs = eventIDs(for: userID)
        for eventID in eventIDs.values {
            if let event = eventStore.event(withIdentifier: eventID) {
                try? eventStore.remove(event, span: .thisEvent, commit: true)
            }
        }
        defaults.removeObject(forKey: eventIDsKeyPrefix + userID)
    }

    private func updateRunningSessionTimer() {
        let hasRunningSession = latestSessions.contains { $0.endedAt == nil }
        if hasRunningSession, runningSessionTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let userID = self.latestUserID else { return }
                    self.synchronize(self.latestSessions, userID: userID, removeMissingEvents: false)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            runningSessionTimer = timer
        } else if !hasRunningSession {
            runningSessionTimer?.invalidate()
            runningSessionTimer = nil
        }
    }
}
