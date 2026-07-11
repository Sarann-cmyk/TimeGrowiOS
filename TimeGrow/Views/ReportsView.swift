//
//  ReportsView.swift
//  TimeGrow
//

import SwiftUI

private struct ReportTaskEntry: Identifiable {
    let id: String
    let title: String
    let color: Color
    let colorHex: String
    let seconds: TimeInterval
}

private struct ReportChartSegment: Identifiable {
    let id: String
    let color: Color
    let seconds: TimeInterval
}

private struct ReportChartColumn: Identifiable {
    let id: TimeInterval
    let date: Date
    let totalSeconds: TimeInterval
    let segments: [ReportChartSegment]
}

private struct ReportSessionGroup: Identifiable {
    let id: TimeInterval
    let date: Date
    let sessions: [TaskTimeSession]
}

private struct ReportTimelineSegment: Identifiable {
    let id: String
    let startRatio: CGFloat
    let endRatio: CGFloat
    let color: Color
}

private struct ReportChartScale {
    let maxSeconds: TimeInterval
    let tickSeconds: [TimeInterval]

    static func automatic(for columns: [ReportChartColumn], tickCount: Int = 3) -> ReportChartScale {
        let peak = columns.map(\.totalSeconds).max() ?? 0
        guard peak > 0 else {
            return ReportChartScale(maxSeconds: 3600, tickSeconds: [3600, 0])
        }
        let maxSeconds = niceUpperBound(peak * 1.12)
        let step = niceTickStep(minStep: maxSeconds / Double(max(1, tickCount - 1)))
        var ticks: [TimeInterval] = []
        var value = ceil(maxSeconds / step) * step
        while value >= 0 {
            ticks.append(value)
            value -= step
        }
        if ticks.last != 0 {
            ticks.append(0)
        }
        return ReportChartScale(maxSeconds: ticks.first ?? maxSeconds, tickSeconds: ticks)
    }

    func yAxisLabel(for seconds: TimeInterval) -> String {
        if seconds <= 0 { return "0" }
        let hours = seconds / 3600
        if abs(hours.rounded() - hours) < 0.001 {
            return "\(Int(hours.rounded()))"
        }
        return String(format: "%.1f", hours)
    }

    private static func niceTickStep(minStep: TimeInterval) -> TimeInterval {
        let hours = minStep / 3600
        let candidates: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 36, 48, 72, 96]
        return (candidates.first { $0 >= hours } ?? ceil(hours)) * 3600
    }

    private static func niceUpperBound(_ seconds: TimeInterval) -> TimeInterval {
        let hours = seconds / 3600
        let candidates: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 18, 20, 24, 28, 32, 36, 48, 72, 96]
        return (candidates.first { $0 >= hours } ?? ceil(hours)) * 3600
    }
}

struct ReportsView: View {
    @EnvironmentObject private var taskService: TaskService
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @Environment(\.locale) private var locale

    @State private var period: ReportPeriod = .week
    @State private var referenceDate = Date()
    @State private var sessions: [TaskTimeSession] = []
    @State private var loadedRangeKey: String?
    @State private var isShowingDatePicker = false
    @State private var shareItem: IdentifiableURL?
    @State private var selectedTask: TGTask?
    @State private var editingSession: TaskTimeSession?
    @State private var sessionPendingDeletion: TaskTimeSession?
    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration

    private let calendar = Calendar.current

    /// Lets a report row for a task that was later deleted still open the
    /// detail screen, so its leftover sessions can be found and removed.
    private static func orphanedTask(for entry: ReportTaskEntry) -> TGTask {
        let now = Date()
        return TGTask(
            id: entry.id,
            name: entry.title,
            colorHex: entry.colorHex,
            createdAt: now,
            updatedAt: now,
            timerStartedAt: nil,
            activeSessionID: nil,
            timerOwnerDeviceID: nil,
            timerOwnerPlatform: nil,
            timerOwnerDeviceName: nil,
            timerOwnerLastAliveAt: nil,
            timerOwnerIsActive: nil
        )
    }

    private var range: (start: Date, end: Date) {
        ReportDateMath.range(for: period, containing: referenceDate, calendar: calendar)
    }

    private var hasLiveSession: Bool {
        displaySessions.contains { $0.endedAt == nil }
    }

    private var displaySessions: [TaskTimeSession] {
        // Prefer the live, always-up-to-date Firestore listener cache whenever the range is
        // recent enough for it to cover — otherwise an edit or delete only shows up after
        // navigating away and back, since the one-time fetch below never refreshes itself.
        guard canUseObservedSessionCache else {
            return loadedRangeKey == rangeKey ? sessions : []
        }
        return taskService.sessions
    }

    var body: some View {
        Group {
            if hasLiveSession {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: Date())
            }
        }
        .task(id: rangeKey) {
            await load()
        }
        .sheet(isPresented: $isShowingDatePicker) {
            datePickerSheet
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .fullScreenCover(item: $selectedTask) { task in
            TaskReportDetailView(task: task, initialPeriod: period, initialReferenceDate: referenceDate)
                .environmentObject(taskService)
        }
        .sheet(item: $editingSession) { session in
            SessionEditView(session: session)
                .environmentObject(taskService)
                .environmentObject(accentColorManager)
        }
        .alert("Delete Session?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let session = sessionPendingDeletion {
                    taskService.deleteSession(session)
                }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var rangeKey: String {
        "\(period.rawValue)-\(range.start.timeIntervalSince1970)"
    }

    private func content(at date: Date) -> some View {
        let reportSessions = displaySessions.filter { sessionListDuration($0, at: date) >= TimeInterval(sessionListMinimumDuration) }
        let entries = taskEntries(reportSessions, at: date)
        let columns = chartColumns(reportSessions, at: date)
        let scale = ReportChartScale.automatic(for: columns)
        let sessionGroups = groupedSessions(reportSessions, at: date)
        let timelineSegments = activityTimelineSegments(reportSessions, at: date)
        let total = entries.reduce(0) { $0 + $1.seconds }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar(at: date)
                periodPickerStrip

                VStack(alignment: .leading, spacing: 14) {
                    summarySection(total: total)
                }
                .padding(.horizontal, 16)

                if period == .day {
                    ReportsActivityTimelineView(
                        segments: timelineSegments,
                        range: range,
                        period: period,
                        locale: locale,
                        calendar: calendar
                    )
                    .padding(.horizontal, 16)
                }

                if period != .day {
                    ReportsStackedBarChart(
                        columns: columns,
                        scale: scale,
                        period: period,
                        locale: locale,
                        calendar: calendar
                    )
                    .padding(.horizontal, period == .year ? 16 : 8)
                }

                VStack(alignment: .leading, spacing: 20) {
                    tasksSection(entries: entries, total: total)

                    if period == .day || period == .week {
                        sessionsSection(groups: sessionGroups, at: date)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .background(Color.black)
        .scrollIndicators(.hidden)
        .refreshable {
            await load()
        }
    }

    // MARK: - Top

    private func topBar(at date: Date) -> some View {
        HStack(spacing: 10) {
            iconButton("calendar") { isShowingDatePicker = true }

            HStack(spacing: 4) {
                ForEach(ReportPeriod.allCases) { candidate in
                    Button {
                        guard period != candidate else { return }
                        Haptics.selection()
                        period = candidate
                        referenceDate = normalizedReferenceDate(for: candidate, date: Date())
                    } label: {
                        Text(candidate.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(period == candidate ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background {
                                if period == candidate {
                                    Capsule().fill(Color.white.opacity(0.14))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.tabBarBackground))
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))

            iconButton("square.and.arrow.up") {
                shareItem = writeShareFile(at: date)
            }
        }
        .padding(.horizontal, 16)
    }

    private func iconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accentColorManager.color)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.tabBarBackground))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var periodPickerStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: period == .week ? 8 : 12) {
                    ForEach(periodStripDates, id: \.timeIntervalSince1970) { date in
                        periodStripButton(for: date)
                            .id(date.timeIntervalSince1970)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                proxy.scrollTo(normalizedReferenceDate(for: period, date: referenceDate).timeIntervalSince1970, anchor: .center)
            }
            .onChange(of: referenceDate) { _, _ in
                proxy.scrollTo(normalizedReferenceDate(for: period, date: referenceDate).timeIntervalSince1970, anchor: .center)
            }
        }
    }

    private func periodStripButton(for date: Date) -> some View {
        let normalized = normalizedReferenceDate(for: period, date: date)
        let selected = calendar.isDate(normalized, inSameDayAs: normalizedReferenceDate(for: period, date: referenceDate))
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                referenceDate = normalized
            }
        } label: {
            Text(periodStripLabel(for: normalized, selected: selected))
                .font(.system(size: period == .year ? 20 : 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? accentColorManager.color : .secondary)
                .padding(.horizontal, selected ? 14 : 10)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColorManager.color.opacity(0.22))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var periodStripDates: [Date] {
        let base = normalizedReferenceDate(for: period, date: referenceDate)
        let component: Calendar.Component
        let bounds: ClosedRange<Int>
        switch period {
        case .day:
            component = .day
            bounds = -8...8
        case .week:
            component = .weekOfYear
            bounds = -8...8
        case .month:
            component = .month
            bounds = -12...12
        case .year:
            component = .year
            bounds = -5...5
        }
        return bounds.compactMap { calendar.date(byAdding: component, value: $0, to: base) }
    }

    private func periodStripLabel(for date: Date, selected: Bool) -> String {
        switch period {
        case .day:
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        case .week:
            let week = calendar.component(.weekOfYear, from: date)
            guard selected else { return "Week \(week)" }
            let end = calendar.date(byAdding: .day, value: 6, to: date) ?? date
            return "Week \(week) (\(shortDate(date)) - \(shortDate(end)))"
        case .month:
            return date.formatted(.dateTime.month(.wide).year().locale(locale))
        case .year:
            return String(calendar.component(.year, from: date))
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("", selection: $referenceDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .navigationTitle("Select Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingDatePicker = false }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    // MARK: - Summary

    private func summarySection(total: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 0) {
            summaryMetric(title: "Time Tracked", value: durationText(total))
                .frame(maxWidth: .infinity, alignment: .leading)

            summaryMetric(
                title: period == .year ? "Monthly Avg." : "Daily Avg.",
                value: durationText(averageSeconds(total: total))
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    private func averageSeconds(total: TimeInterval) -> TimeInterval {
        let divisor = ReportDateMath.averageDivisor(for: period, referenceDate: referenceDate, calendar: calendar)
        return total / Double(divisor)
    }

    // MARK: - Sections

    private func tasksSection(entries: [ReportTaskEntry], total: TimeInterval) -> some View {
        let usedEntries = entries.filter { $0.seconds > 0 }
        return VStack(alignment: .leading, spacing: 16) {
            Text("BY TASKS")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            reportCard {
                if usedEntries.isEmpty {
                    Text("No time tracked")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(usedEntries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            Haptics.impact(.light)
                            selectedTask = taskService.tasks.first { $0.id == entry.id } ?? Self.orphanedTask(for: entry)
                        } label: {
                            taskRow(entry: entry, total: total)
                        }
                        .buttonStyle(.plain)

                        if index < usedEntries.count - 1 {
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private func taskRow(entry: ReportTaskEntry, total: TimeInterval) -> some View {
        let percent = total > 0 ? Int((entry.seconds / total * 100).rounded()) : 0
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(entry.color)
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                usageScaleRow(color: entry.color, percent: percent)
            }

            Spacer(minLength: 8)

            Text(durationText(entry.seconds))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func usageScaleRow(color: Color, percent: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 6) {
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geo.size.width * CGFloat(percent) / 100), height: 5)
                Text("\(percent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
    }

    private func sessionsSection(groups: [ReportSessionGroup], at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SESSIONS")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            if groups.isEmpty {
                reportCard {
                    Text("No sessions")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(daySectionHeader(group.date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(durationText(group.sessions.reduce(0) { $0 + $1.duration(at: date) }))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        reportCard {
                            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                                sessionRow(session, at: date)
                                if index < group.sessions.count - 1 {
                                    Divider().background(Color.white.opacity(0.08))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: TaskTimeSession, at date: Date) -> some View {
        let end = session.endedAt ?? date
        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                Text(clockText(session.startedAt))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
                Text(clockText(end))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15, design: .monospaced))
            .frame(width: 48)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(session.color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.taskName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(session.color)
                Text(session.notes?.isEmpty == false ? session.notes! : "No notes")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(durationText(session.duration(at: date)))
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.impact(.light)
            editingSession = session
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                Haptics.impact(.medium)
                sessionPendingDeletion = session
            }
        )
    }

    private func reportCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
    }

    // MARK: - Data

    private func load() async {
        let requestedRangeKey = rangeKey
        do {
            let fetched = try await taskService.fetchSessions(from: range.start, to: range.end)
            guard requestedRangeKey == rangeKey else { return }
            sessions = fetched
            loadedRangeKey = requestedRangeKey
        } catch {
            print("Failed to load report sessions: \(error.localizedDescription)")
            if requestedRangeKey == rangeKey {
                loadedRangeKey = nil
            }
        }
    }

    private var canUseObservedSessionCache: Bool {
        let observedCutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return range.start >= observedCutoff
    }

    private func taskEntries(_ sourceSessions: [TaskTimeSession], at date: Date) -> [ReportTaskEntry] {
        var totals: [String: (title: String, color: Color, colorHex: String, seconds: TimeInterval)] = [:]

        for session in sourceSessions {
            let duration = overlapSeconds(session, start: range.start, end: range.end, now: date)
            guard duration > 0 else { continue }
            var entry = totals[session.taskID] ?? (session.taskName, session.color, session.colorHex, 0)
            entry.seconds += duration
            totals[session.taskID] = entry
        }

        return totals
            .map { ReportTaskEntry(id: $0.key, title: $0.value.title, color: $0.value.color, colorHex: $0.value.colorHex, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }

    private func chartColumns(_ sourceSessions: [TaskTimeSession], at date: Date) -> [ReportChartColumn] {
        switch period {
        case .day:
            return []
        case .week:
            return bucketColumns(sourceSessions, component: .day, count: 7, start: range.start, now: date)
        case .month:
            let count = calendar.range(of: .day, in: .month, for: referenceDate)?.count ?? 30
            return bucketColumns(sourceSessions, component: .day, count: count, start: range.start, now: date)
        case .year:
            return bucketColumns(sourceSessions, component: .month, count: 12, start: range.start, now: date)
        }
    }

    private func bucketColumns(_ sourceSessions: [TaskTimeSession], component: Calendar.Component, count: Int, start: Date, now: Date) -> [ReportChartColumn] {
        (0..<count).compactMap { offset in
            guard let bucketStart = calendar.date(byAdding: component, value: offset, to: start),
                  let bucketEnd = calendar.date(byAdding: component, value: 1, to: bucketStart) else { return nil }

            var totals: [String: (color: Color, seconds: TimeInterval)] = [:]
            for session in sourceSessions {
                let seconds = overlapSeconds(session, start: bucketStart, end: bucketEnd, now: now)
                guard seconds > 0 else { continue }
                var entry = totals[session.taskID] ?? (session.color, 0)
                entry.seconds += seconds
                totals[session.taskID] = entry
            }

            let segments = totals
                .map { ReportChartSegment(id: $0.key, color: $0.value.color, seconds: $0.value.seconds) }
                .sorted { $0.seconds < $1.seconds }
            let total = segments.reduce(0) { $0 + $1.seconds }
            return ReportChartColumn(id: bucketStart.timeIntervalSince1970, date: bucketStart, totalSeconds: total, segments: segments)
        }
    }

    private func groupedSessions(_ sourceSessions: [TaskTimeSession], at date: Date) -> [ReportSessionGroup] {
        let scoped = sourceSessions
            .filter { overlapSeconds($0, start: range.start, end: range.end, now: date) > 0 }
            .sorted { $0.startedAt > $1.startedAt }
        let grouped = Dictionary(grouping: scoped) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            ReportSessionGroup(
                id: day.timeIntervalSince1970,
                date: day,
                sessions: grouped[day]?.sorted { $0.startedAt > $1.startedAt } ?? []
            )
        }
    }

    private func activityTimelineSegments(_ sourceSessions: [TaskTimeSession], at date: Date) -> [ReportTimelineSegment] {
        let rangeDuration = max(1, range.end.timeIntervalSince(range.start))
        return sourceSessions
            .sorted { $0.startedAt < $1.startedAt }
            .compactMap { session in
                let sessionEnd = session.endedAt ?? date
                let start = max(session.startedAt, range.start)
                let end = min(sessionEnd, range.end)
                guard end > start else { return nil }
                let startRatio = CGFloat(start.timeIntervalSince(range.start) / rangeDuration)
                let endRatio = CGFloat(end.timeIntervalSince(range.start) / rangeDuration)
                let id = session.id ?? "\(session.taskID)-\(session.startedAt.timeIntervalSince1970)-\(sessionEnd.timeIntervalSince1970)"
                return ReportTimelineSegment(
                    id: id,
                    startRatio: min(max(startRatio, 0), 1),
                    endRatio: min(max(endRatio, 0), 1),
                    color: session.color
                )
            }
    }

    private func overlapSeconds(_ session: TaskTimeSession, start: Date, end: Date, now: Date) -> TimeInterval {
        let sessionEnd = session.endedAt ?? now
        let overlapStart = max(session.startedAt, start)
        let overlapEnd = min(sessionEnd, end)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    private func sessionListDuration(_ session: TaskTimeSession, at date: Date) -> TimeInterval {
        overlapSeconds(session, start: range.start, end: range.end, now: date)
    }

    // MARK: - Formatting

    private func normalizedReferenceDate(for period: ReportPeriod, date: Date) -> Date {
        ReportDateMath.range(for: period, containing: date, calendar: calendar).start
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    private func daySectionHeader(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale)).uppercased()
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func writeShareFile(at date: Date) -> IdentifiableURL? {
        let entries = taskEntries(displaySessions, at: date)
        let total = entries.reduce(0) { $0 + $1.seconds }
        var text = "TimeGrow - \(ReportDateMath.periodLabel(period, referenceDate: referenceDate, calendar: calendar))\n\n"
        text += "Time Tracked: \(durationText(total))\n"
        text += "\(period.averageLabel): \(durationText(averageSeconds(total: total)))\n\n"
        text += "By tasks:\n"
        if entries.isEmpty {
            text += "  (no time tracked)\n"
        } else {
            for entry in entries {
                text += "  \(entry.title): \(durationText(entry.seconds))\n"
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TimeGrow-report-\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return IdentifiableURL(url: url)
        } catch {
            print("Failed to write report export: \(error.localizedDescription)")
            return nil
        }
    }
}

private struct ReportsActivityTimelineView: View {
    let segments: [ReportTimelineSegment]
    let range: (start: Date, end: Date)
    let period: ReportPeriod
    let locale: Locale
    let calendar: Calendar

    private var axisDates: [Date] {
        switch period {
        case .day:
            return strideDates(component: .hour, step: 6, count: 5)
        case .week:
            return strideDates(component: .day, step: 2, count: 4)
        case .month:
            let days = calendar.range(of: .day, in: .month, for: range.start)?.count ?? 30
            return [0, max(0, days / 2), max(0, days - 1)].compactMap {
                calendar.date(byAdding: .day, value: $0, to: range.start)
            }
        case .year:
            return [0, 3, 6, 9, 12].compactMap {
                calendar.date(byAdding: .month, value: $0, to: range.start)
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 10)

                    ForEach(segments) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: segmentWidth(segment, totalWidth: geo.size.width), height: 10)
                            .offset(x: segment.startRatio * geo.size.width)
                    }
                }
                .frame(height: 18)
            }
            .frame(height: 18)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(axisDates, id: \.timeIntervalSince1970) { date in
                        Text(axisLabel(for: date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: xPosition(for: date, width: geo.size.width), y: 6)
                    }
                }
            }
            .frame(height: 14)
        }
        .opacity(segments.isEmpty ? 0.45 : 1)
    }

    private func segmentWidth(_ segment: ReportTimelineSegment, totalWidth: CGFloat) -> CGFloat {
        max(2, (segment.endRatio - segment.startRatio) * totalWidth)
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let duration = max(1, range.end.timeIntervalSince(range.start))
        let ratio = min(max(date.timeIntervalSince(range.start) / duration, 0), 1)
        return width * CGFloat(ratio)
    }

    private func strideDates(component: Calendar.Component, step: Int, count: Int) -> [Date] {
        (0..<count).compactMap {
            calendar.date(byAdding: component, value: $0 * step, to: range.start)
        }
    }

    private func axisLabel(for date: Date) -> String {
        switch period {
        case .day:
            return ReportFormatters.hour.string(from: date)
        case .week:
            return date.formatted(.dateTime.weekday(.abbreviated).locale(locale)).uppercased()
        case .month:
            return ReportFormatters.day.string(from: date)
        case .year:
            return ReportFormatters.monthShort.string(from: date)
        }
    }
}

private struct ReportsStackedBarChart: View {
    let columns: [ReportChartColumn]
    let scale: ReportChartScale
    let period: ReportPeriod
    let locale: Locale
    let calendar: Calendar

    private let chartHeight: CGFloat = 180
    private var plotAreaHeight: CGFloat { chartHeight - 20 }
    private var xAxisLabelsRowHeight: CGFloat { period == .week ? 36 : 18 }
    private var plotToLabelsGap: CGFloat { 10 }
    private var yAxisWidth: CGFloat { 22 }
    private var barWidthFraction: CGFloat {
        switch period {
        case .week: 0.52
        case .month: 0.7
        case .year: 0.55
        case .day: 0.6
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            yAxisLabels
            VStack(spacing: 0) {
                chartPlot
                    .frame(height: plotAreaHeight)
                Spacer(minLength: plotToLabelsGap)
                    .frame(height: plotToLabelsGap)
                xAxisLabels
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: plotAreaHeight + plotToLabelsGap + xAxisLabelsRowHeight)
    }

    private var yAxisLabels: some View {
        VStack {
            ForEach(scale.tickSeconds, id: \.self) { tick in
                Text(scale.yAxisLabel(for: tick))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: yAxisWidth, height: plotAreaHeight)
    }

    private var chartPlot: some View {
        GeometryReader { geo in
            let columnWidth = geo.size.width / CGFloat(max(columns.count, 1))
            ZStack(alignment: .bottom) {
                Canvas { context, size in
                    let ticks = scale.tickSeconds
                    guard ticks.count > 1 else { return }
                    let step = size.height / CGFloat(ticks.count - 1)
                    var path = Path()
                    for index in 0..<ticks.count where index < ticks.count - 1 {
                        let y = CGFloat(index) * step
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(
                        path,
                        with: .color(Color.white.opacity(0.22)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                }

                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 1)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(columns) { column in
                        chartColumn(column, width: columnWidth)
                    }
                }
            }
        }
    }

    private func chartColumn(_ column: ReportChartColumn, width: CGFloat) -> some View {
        let barWidth = max(period == .month ? 2 : 8, width * barWidthFraction)
        let height = scale.maxSeconds > 0
            ? max(column.totalSeconds > 0 ? 4 : 0, plotAreaHeight * (column.totalSeconds / scale.maxSeconds))
            : 0

        return VStack(spacing: 4) {
            if period == .week, column.totalSeconds > 0 {
                Text(durationText(column.totalSeconds))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if height > 0 {
                stackedBar(column: column, height: height)
                    .frame(width: barWidth)
            }
        }
        .frame(width: width, height: plotAreaHeight, alignment: .bottom)
    }

    private func stackedBar(column: ReportChartColumn, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(column.segments) { segment in
                let segmentHeight = column.totalSeconds > 0 ? height * (segment.seconds / column.totalSeconds) : 0
                segment.color.frame(height: max(0, segmentHeight))
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 4
            )
        )
    }

    @ViewBuilder
    private var xAxisLabels: some View {
        if period == .month {
            monthXAxisLabels
        } else {
            HStack(spacing: 0) {
                ForEach(columns) { column in
                    Group {
                        if period == .week {
                            VStack(spacing: 2) {
                                Text(column.date.formatted(.dateTime.weekday(.abbreviated).locale(locale)).uppercased())
                                Text(String(calendar.component(.day, from: column.date)))
                            }
                        } else if period == .year {
                            Text(ReportFormatters.monthShort.string(from: column.date))
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var monthXAxisLabels: some View {
        GeometryReader { geo in
            let count = max(columns.count, 1)
            let columnWidth = geo.size.width / CGFloat(count)
            let centerY = geo.size.height / 2

            ZStack(alignment: .topLeading) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    if calendar.component(.day, from: column.date).isMultiple(of: 2) == false {
                        Text(String(calendar.component(.day, from: column.date)))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: columnWidth * (CGFloat(index) + 0.5), y: centerY)
                    }
                }
            }
        }
        .frame(height: xAxisLabelsRowHeight)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
}

#Preview {
    ReportsView()
        .environmentObject(TaskService())
        .environmentObject(AccentColorManager())
        .preferredColorScheme(.dark)
}
