//
//  TaskReportDetailView.swift
//  TimeGrow
//

import Charts
import SwiftUI

private struct SessionDayGroup: Identifiable {
    let id: Date
    let day: Date
    let sessions: [TaskTimeSession]
}

private struct TaskChartBucket: Identifiable {
    let id: String
    let axisID: String
    let labelDate: Date
    let seconds: TimeInterval
}

private enum TaskReportChartStyle: String, CaseIterable, Identifiable {
    case bars
    case line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: "Bars"
        case .line: "Line"
        }
    }

    var systemImage: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .line: "chart.xyaxis.line"
        }
    }
}

struct TaskReportDetailView: View {
    @EnvironmentObject private var taskService: TaskService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let task: TGTask

    @State private var period: ReportPeriod
    @State private var referenceDate: Date
    @State private var sessions: [TaskTimeSession] = []
    @State private var isLoading = false
    @State private var isShowingDatePicker = false
    @State private var shareItem: IdentifiableURL?
    @State private var chartStyle: TaskReportChartStyle = .bars
    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration

    private let calendar = Calendar.current

    init(task: TGTask, initialPeriod: ReportPeriod, initialReferenceDate: Date) {
        self.task = task
        _period = State(initialValue: initialPeriod)
        _referenceDate = State(initialValue: initialReferenceDate)
    }

    private var range: (start: Date, end: Date) {
        ReportDateMath.range(for: period, containing: referenceDate, calendar: calendar)
    }

    private var fetchRange: (start: Date, end: Date) {
        period == .day
            ? ReportDateMath.range(for: .month, containing: referenceDate, calendar: calendar)
            : range
    }

    private var chartPeriod: ReportPeriod {
        period == .day ? .month : period
    }

    private var hasLiveSession: Bool {
        sessions.contains { $0.endedAt == nil }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if hasLiveSession {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        content(at: context.date)
                    }
                } else {
                    content(at: Date())
                }
            }

            if !isCurrentPeriod {
                VStack {
                    Spacer()
                    goToTodayButton
                        .padding(.bottom, 24)
                }
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
        .preferredColorScheme(.dark)
    }

    private var rangeKey: String {
        "\(period.rawValue)-\(range.start.timeIntervalSince1970)"
    }

    private func content(at date: Date) -> some View {
        let sortedSessions = sessions
            .filter { overlapSeconds($0, start: range.start, end: range.end, now: date) > 0 }
            .filter { sessionListDuration($0, at: date) >= TimeInterval(sessionListMinimumDuration) }
            .sorted { $0.startedAt > $1.startedAt }
        let groups = dayGroups(sortedSessions, at: date)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar
                periodPickerStrip

                VStack(alignment: .leading, spacing: 20) {
                    statsRow(at: date)
                }
                .padding(.horizontal, 16)

                taskChart(at: date)
                    .padding(.horizontal, 8)

                Text("Sessions")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .padding(.top, 4)
                    .padding(.horizontal, 8)

                if groups.isEmpty {
                    placeholderCard("No sessions")
                        .padding(.horizontal, 8)
                } else {
                    ForEach(groups) { group in
                        sessionDayGroup(group, at: date)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await load()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentPurple)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.tabBarBackground))
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)

            periodPicker

            iconButton("calendar") { isShowingDatePicker = true }
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
                .foregroundStyle(Color.accentPurple)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.tabBarBackground))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(ReportPeriod.allCases) { candidate in
                Button {
                    guard period != candidate else { return }
                    Haptics.selection()
                    period = candidate
                    referenceDate = normalizedReferenceDate(for: candidate, date: Date())
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .semibold))
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
                Haptics.selection()
                referenceDate = normalized
            }
        } label: {
            Text(periodStripLabel(for: normalized, selected: selected))
                .font(.system(size: period == .year ? 20 : 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? task.color : .secondary)
                .padding(.horizontal, selected ? 14 : 10)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(task.color.opacity(0.22))
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

    // MARK: - Period navigator

    private var periodNavigator: some View {
        HStack(spacing: 8) {
            navigatorPill(text: ReportDateMath.neighborLabel(period, referenceDate: referenceDate, offset: -1, calendar: calendar), isEnabled: true) { step(-1) }

            Text(ReportDateMath.periodLabel(period, referenceDate: referenceDate, calendar: calendar))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(task.color))

            navigatorPill(text: ReportDateMath.neighborLabel(period, referenceDate: referenceDate, offset: 1, calendar: calendar), isEnabled: !isCurrentPeriod) { step(1) }
        }
    }

    private func navigatorPill(text: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var goToTodayButton: some View {
        Button {
            Haptics.impact(.light)
            referenceDate = Date()
        } label: {
            Text("Go To Today")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.tabBarBackground))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        referenceDate = ReportDateMath.step(period, referenceDate: referenceDate, delta: delta, calendar: calendar)
    }

    private var isCurrentPeriod: Bool {
        ReportDateMath.isCurrentPeriod(period, referenceDate: referenceDate, calendar: calendar)
    }

    private func normalizedReferenceDate(for period: ReportPeriod, date: Date) -> Date {
        ReportDateMath.range(for: period, containing: date, calendar: calendar).start
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    private func daySectionHeader(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale)).uppercased()
    }

    // MARK: - Stats

    private func statsRow(at date: Date) -> some View {
        let total = totalSeconds(at: date)
        let divisor = ReportDateMath.averageDivisor(for: period, referenceDate: referenceDate, calendar: calendar)
        let average = total / Double(divisor)
        return HStack(alignment: .top, spacing: 0) {
            statColumn(title: "Time Tracked", value: ReportDateMath.formatDuration(total))
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 10) {
                statColumn(title: period.averageLabel, value: ReportDateMath.formatDuration(average))
                chartStylePicker
            }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func statColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }

    private func totalSeconds(at date: Date) -> TimeInterval {
        let bounds = range
        return sessions.reduce(0) { total, session in
            total + overlapSeconds(session, start: bounds.start, end: bounds.end, now: date)
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

    // MARK: - Chart

    private var chartStylePicker: some View {
        HStack(spacing: 4) {
            ForEach(TaskReportChartStyle.allCases) { style in
                Button {
                    guard chartStyle != style else { return }
                    Haptics.selection()
                    chartStyle = style
                } label: {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chartStyle == style ? .white : .secondary)
                        .frame(width: 30, height: 24)
                        .background {
                            if chartStyle == style {
                                Capsule().fill(task.color.opacity(0.42))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.tabBarBackground))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    @ViewBuilder
    private func taskChart(at date: Date) -> some View {
        switch chartStyle {
        case .bars:
            barChart(at: date)
        case .line:
            lineChart(at: date)
        }
    }

    private func barChart(at date: Date) -> some View {
        let data = chartBuckets(at: date)
        let axisLabels = Dictionary(uniqueKeysWithValues: data.map { ($0.axisID, $0.labelDate) })
        return Chart(data) { bucket in
            BarMark(
                x: .value("Period", bucket.axisID),
                y: .value("Hours", bucket.seconds / 3600)
            )
            .foregroundStyle(task.color)
            .cornerRadius(3)
            .annotation(position: .top) {
                if shouldShowBarDurationAnnotations, bucket.seconds > 0 {
                    Text(ReportDateMath.formatDuration(bucket.seconds))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 220)
        .taskReportChartAxes(xAxisValues: visibleXAxisIDs(for: data)) { axisID in
            if let labelDate = axisLabels[axisID] {
                xAxisLabelView(for: labelDate)
            }
        }
    }

    private func lineChart(at date: Date) -> some View {
        let data = chartBuckets(at: date)
        let axisLabels = Dictionary(uniqueKeysWithValues: data.map { ($0.axisID, $0.labelDate) })
        return Chart(data) { bucket in
            AreaMark(
                x: .value("Period", bucket.axisID),
                y: .value("Hours", bucket.seconds / 3600)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [task.color.opacity(0.45), task.color.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Period", bucket.axisID),
                y: .value("Hours", bucket.seconds / 3600)
            )
            .foregroundStyle(task.color)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 220)
        .taskReportChartAxes(xAxisValues: visibleXAxisIDs(for: data)) { axisID in
            if let labelDate = axisLabels[axisID] {
                xAxisLabelView(for: labelDate)
            }
        }
    }

    private func chartBuckets(at date: Date) -> [TaskChartBucket] {
        ReportDateMath.buckets(for: chartPeriod, referenceDate: referenceDate, calendar: calendar, sessions: sessions, at: date)
            .enumerated()
            .map { index, bucket in
                let axisID = "\(chartPeriod.rawValue)-\(index)"
                return TaskChartBucket(id: axisID, axisID: axisID, labelDate: bucket.date, seconds: bucket.seconds)
        }
    }

    private var shouldShowBarDurationAnnotations: Bool {
        period == .week || period == .year
    }

    private func visibleXAxisIDs(for buckets: [TaskChartBucket]) -> [String] {
        switch chartPeriod {
        case .day:
            return buckets.filter { calendar.component(.hour, from: $0.labelDate).isMultiple(of: 3) }.map(\.axisID)
        case .week:
            return buckets.map(\.axisID)
        case .month:
            return buckets.filter { calendar.component(.day, from: $0.labelDate).isMultiple(of: 2) == false }.map(\.axisID)
        case .year:
            return buckets.map(\.axisID)
        }
    }

    @ViewBuilder
    private func xAxisLabelView(for date: Date) -> some View {
        switch chartPeriod {
        case .day:
            Text(ReportFormatters.hour.string(from: date))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
        case .week:
            VStack(spacing: 2) {
                Text(ReportFormatters.weekday.string(from: date).uppercased())
                Text(ReportFormatters.day.string(from: date))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.45))
        case .month:
            Text(ReportFormatters.day.string(from: date))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
        case .year:
            Text(ReportFormatters.monthShort.string(from: date))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    // MARK: - Sessions

    private func dayGroups(_ sortedSessions: [TaskTimeSession], at date: Date) -> [SessionDayGroup] {
        let grouped = Dictionary(grouping: sortedSessions) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            SessionDayGroup(id: day, day: day, sessions: grouped[day]?.sorted { $0.startedAt > $1.startedAt } ?? [])
        }
    }

    private func sessionDayGroup(_ group: SessionDayGroup, at date: Date) -> some View {
        let dayTotal = group.sessions.reduce(0) { $0 + $1.duration(at: date) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(daySectionHeader(group.day))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ReportDateMath.formatDuration(dayTotal))
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

    private func sessionRow(_ session: TaskTimeSession, at date: Date) -> some View {
        let end = session.endedAt ?? date
        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                Text(ReportFormatters.time.string(from: session.startedAt))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
                Text(ReportFormatters.time.string(from: end))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15, design: .monospaced))
            .frame(width: 48)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(task.color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(task.color)
                Text("No notes")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(ReportDateMath.formatDuration(session.duration(at: date)))
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .monospacedDigit()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func placeholderCard(_ text: String) -> some View {
        reportCard {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
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
        isLoading = true
        defer { isLoading = false }
        do {
            let taskID = task.id
            let bounds = fetchRange
            sessions = try await taskService.fetchSessions(from: bounds.start, to: bounds.end)
                .filter { $0.taskID == taskID }
        } catch {
            print("Failed to load task report sessions: \(error.localizedDescription)")
            sessions = []
        }
    }

    private func deleteSession(_ session: TaskTimeSession) {
        Haptics.impact(.medium)
        sessions.removeAll { $0.id == session.id }
        taskService.deleteSession(session)
    }

    private func writeShareFile(at date: Date) -> IdentifiableURL? {
        let total = totalSeconds(at: date)
        let divisor = ReportDateMath.averageDivisor(for: period, referenceDate: referenceDate, calendar: calendar)
        var text = "TimeGrow — \(task.name) — \(ReportDateMath.periodLabel(period, referenceDate: referenceDate, calendar: calendar))\n\n"
        text += "Time Tracked: \(ReportDateMath.formatDuration(total))\n"
        text += "\(period.averageLabel): \(ReportDateMath.formatDuration(total / Double(divisor)))\n"

        let fileNameFormatter = DateFormatter()
        fileNameFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "TimeGrow-\(task.name)-\(fileNameFormatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return IdentifiableURL(url: url)
        } catch {
            print("Failed to write task report export: \(error.localizedDescription)")
            return nil
        }
    }
}

private extension View {
    func taskReportChartAxes<AxisLabel: View>(
        xAxisValues: [String],
        @ViewBuilder xAxisLabel: @escaping (String) -> AxisLabel
    ) -> some View {
        chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick(stroke: StrokeStyle(lineWidth: 0))
                    .foregroundStyle(.clear)
                AxisValueLabel(collisionResolution: .disabled) {
                    if let axisID = value.as(String.self) {
                        xAxisLabel(axisID)
                    }
                }
            }
        }
    }
}

#Preview {
    TaskReportDetailView(
        task: TGTask(
            id: "preview",
            name: "Prayer",
            colorHex: "#E5484D",
            createdAt: .now,
            updatedAt: .now,
            timerStartedAt: nil,
            activeSessionID: nil,
            timerOwnerDeviceID: nil,
            timerOwnerPlatform: nil,
            timerOwnerDeviceName: nil,
            timerOwnerLastAliveAt: nil,
            timerOwnerIsActive: nil,
            autoTrackLastUsageAt: nil,
            autoTrackLiveUntil: nil,
            autoTrackActiveSessionID: nil,
            autoTrackSessionStartedAt: nil
        ),
        initialPeriod: .year,
        initialReferenceDate: .now
    )
    .environmentObject(TaskService())
}
