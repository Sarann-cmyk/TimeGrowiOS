//
//  TimeGrowApp.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI
import FirebaseCore
import UIKit
import UserNotifications

/// Handles regular (non-ActivityKit) remote notifications: registers this device for silent
/// background-wake pushes and runs the supplied handler when one arrives. Push-to-start alone
/// proved unreliable on-device (ActivityKit acknowledges the push but doesn't always materialize
/// the activity); a `content-available` push wakes the app so it can call the already-proven
/// local `LiveActivityManager.reconcile()` path instead.
class AppDelegate: NSObject, UIApplicationDelegate {
    private var latestRemoteNotificationToken: String?
    /// A single timer write can legitimately produce several APNs wake packets (for example an
    /// old packet arriving alongside the current task update). Fetching Firestore and reconciling
    /// ActivityKit once per packet puts that work on the main actor in a burst and visibly stalls
    /// the Tasks tab. Keep every system completion handler, but coalesce the actual work.
    private var pendingBackgroundFetchCompletions: [(UIBackgroundFetchResult) -> Void] = []
    private var isHandlingBackgroundNotification = false
    var remoteNotificationTokenHandler: ((String) -> Void)? {
        didSet {
            if let latestRemoteNotificationToken {
                remoteNotificationTokenHandler?(latestRemoteNotificationToken)
            }
        }
    }
    var backgroundNotificationHandler: ((@escaping () -> Void) -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Remote Live Activity starts contain an alert. Ask once on first launch so that alert
        // can light the Lock Screen and play its sound instead of relying on the user to find
        // TimeGrow in Settings after installation.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                DiagnosticsLog.log("push", "Notification authorization request failed: \(error.localizedDescription)")
            } else {
                DiagnosticsLog.log("push", "Notification authorization granted=\(granted)")
            }
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        DiagnosticsLog.log("push", "Registered for remote notifications, device token=\(hexToken)")
        latestRemoteNotificationToken = hexToken
        remoteNotificationTokenHandler?(hexToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagnosticsLog.log("push", "Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        DiagnosticsLog.log("push", "Received remote notification: \(userInfo)")
        guard let handler = backgroundNotificationHandler else {
            DiagnosticsLog.log("push", "No backgroundNotificationHandler set, ignoring")
            completionHandler(.noData)
            return
        }
        pendingBackgroundFetchCompletions.append(completionHandler)
        guard !isHandlingBackgroundNotification else {
            DiagnosticsLog.log("push", "Coalesced duplicate background reconciliation wake")
            return
        }

        isHandlingBackgroundNotification = true
        var didFinish = false
        let finish: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                guard let self else {
                    completionHandler(.newData)
                    return
                }
                let completions = self.pendingBackgroundFetchCompletions
                self.pendingBackgroundFetchCompletions.removeAll()
                self.isHandlingBackgroundNotification = false
                completions.forEach { $0(.newData) }
            }
        }
        handler(finish)

        // A server fetch can be suspended by iOS when the background execution lease expires.
        // Never let one such fetch permanently swallow all later stop-wake notifications.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !didFinish else { return }
            DiagnosticsLog.log("push", "Background reconciliation timed out; releasing queued wakes")
            finish()
        }
    }
}

@main
struct TimeGrowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var taskService: TaskService
    @StateObject private var autoTrackingStore = AutoTrackingStore()
    @StateObject private var accentColorManager = AccentColorManager()
    @StateObject private var languageManager = LanguageManager()
    @StateObject private var calendarSyncManager = CalendarSyncManager.shared
    @State private var pendingLiveActivityToggleTaskID: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        HangDetector.start()
        LiveActivityManager.shared.startObservingActivityEnablement()
        LiveActivityManager.shared.startObservingPushToStartTokens()
        _taskService = StateObject(wrappedValue: TaskService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(taskService)
                .environmentObject(autoTrackingStore)
                .environmentObject(accentColorManager)
                .environmentObject(languageManager)
                .environmentObject(calendarSyncManager)
                .environment(\.locale, languageManager.locale)
                .onAppear {
                    DiagnosticsLog.log(
                        "language",
                        "App root appeared current=\(languageManager.current.rawValue) appliedLocale=\(languageManager.locale.identifier) persisted=\(UserDefaults.standard.string(forKey: LanguageManager.storageKey) ?? "nil")"
                    )
                    taskService.start()
                    autoTrackingStore.refreshMonitoring(for: taskService.tasks)
                    processPendingAutoTrackEvents()
                    Task {
                        await taskService.reconcileServerAutoTrackEvents()
                        await taskService.reconcileServerLiveActivityDiagnostics()
                    }
                    LiveActivityManager.shared.pushTokenHandler = { taskID, token in
                        taskService.updateLiveActivityPushToken(taskID: taskID, token: token)
                    }
                    LiveActivityManager.shared.pushToStartTokenHandler = { token in
                        taskService.updateActivityPushToStartToken(token)
                    }
                    LiveActivityManager.shared.startObservingActivityUpdates()
                    delegate.remoteNotificationTokenHandler = { token in
                        taskService.updateAPNsDeviceToken(token)
                    }
                    delegate.backgroundNotificationHandler = { done in
                        taskService.fetchTasksOnce { tasks in
                            guard let tasks else {
                                DiagnosticsLog.log(
                                    "push",
                                    "Background reconciliation skipped: server task fetch unavailable"
                                )
                                done()
                                return
                            }
                            LiveActivityManager.shared.reconcile(tasks: tasks)
                            done()
                        }
                    }
                    taskService.fetchTasksOnce { tasks in
                        LiveActivityManager.shared.reconcile(tasks: tasks ?? taskService.tasks)
                    }
                }
                .onChange(of: languageManager.current) { oldLanguage, newLanguage in
                    DiagnosticsLog.log(
                        "language",
                        "App root observed change old=\(oldLanguage.rawValue) new=\(newLanguage.rawValue) appliedLocale=\(languageManager.locale.identifier)"
                    )
                }
                .onChange(of: scenePhase) { _, newPhase in
                    taskService.handleScenePhase(newPhase)
                    if newPhase == .active {
                        autoTrackingStore.refreshAuthorizationStatus()
                        autoTrackingStore.refreshMonitoring(for: taskService.tasks)
                        processPendingAutoTrackEvents()
                        Task {
                            await taskService.reconcileServerAutoTrackEvents()
                            await taskService.reconcileServerLiveActivityDiagnostics()
                        }
                        // A remotely push-started Live Activity can exist even when the app did
                        // not receive enough background time to upload its per-activity token.
                        // In that case the server cannot send an addressable ActivityKit `end`.
                        // When the user returns to the app, fetch authoritative task state and
                        // end any such orphan immediately instead of waiting for a listener
                        // callback that may contain no visible task change.
                        taskService.fetchTasksOnce { tasks in
                            LiveActivityManager.shared.reconcile(tasks: tasks ?? taskService.tasks)
                        }
                    }
                }
                .onChange(of: taskService.tasks) { _, tasks in
                    autoTrackingStore.refreshMonitoring(for: tasks)
                    if let pendingTaskID = pendingLiveActivityToggleTaskID,
                       tasks.contains(where: { $0.id == pendingTaskID }) {
                        pendingLiveActivityToggleTaskID = nil
                        taskService.toggleTrackingFromLiveActivity(taskID: pendingTaskID)
                    }
                }
                .onOpenURL { url in
                    handleLiveActivityURL(url)
                }
        }
    }

    private func processPendingAutoTrackEvents() {
        let events = autoTrackingStore.drainPendingEvents()
        taskService.processPendingAutoTrackEvents(events)
    }

    private func handleLiveActivityURL(_ url: URL) {
        guard url.scheme == "timegrow",
              url.host == "toggle-live-activity",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let taskID = components.queryItems?.first(where: { $0.name == "taskID" })?.value,
              !taskID.isEmpty else {
            return
        }
        if taskService.tasks.contains(where: { $0.id == taskID }) {
            taskService.toggleTrackingFromLiveActivity(taskID: taskID)
        } else {
            // When the app was terminated, the URL can arrive before Firestore's first listener
            // snapshot. Preserve this one user action until that snapshot contains the task.
            pendingLiveActivityToggleTaskID = taskID
        }
    }
}
