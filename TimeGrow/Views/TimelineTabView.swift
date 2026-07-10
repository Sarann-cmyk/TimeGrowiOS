//
//  TimelineTabView.swift
//  TimeGrow
//

import SwiftUI

struct TimelineTabView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case day, week

        var id: String { rawValue }
        var title: String { self == .day ? "Day" : "Week" }
    }

    @EnvironmentObject private var taskService: TaskService
    @Environment(\.locale) private var locale

    @State private var scope: Scope = .week
    @State private var selectedDate = Date()
    @State private var sessions: [TaskTimeSession] = []
    @State private var loadedDayKey: String?
    @State private var appearID = UUID()
    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 64
    private let leadingLabelWidth: CGFloat = 46

    private var dayBounds: (start: Date, end: Date) {
        let start = calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (start, end)
    }

    private var dayKey: String { String(dayBounds.start.timeIntervalSince1970) }

    private var hasLiveSession: Bool { sessions.contains { $0.endedAt == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            weekStrip
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider().background(Color.white.opacity(0.08))

            Group {
                if hasLiveSession {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
                        timelineScroll(at: context.date)
                    }
                } else {
                    timelineScroll(at: Date())
                }
            }
        }
        .background(Color.black)
        .task(id: dayKey) {
            await load()
        }
        .onAppear {
            // Every time Timeline becomes visible — including switching back from another
            // tab — it should jump to today and scroll near the current time, not wherever
            // the user last left it.
            selectedDate = Date()
            appearID = UUID()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timeline")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            scopePicker
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var subtitle: String {
        selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale))
    }

    private var scopePicker: some View {
        HStack(spacing: 6) {
            ForEach(Scope.allCases) { candidate in
                Button {
                    guard scope != candidate else { return }
                    Haptics.selection()
                    scope = candidate
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scope == candidate ? .white : .secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            Capsule().fill(scope == candidate ? Color.accentPurple : Color.white.opacity(0.08))
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Week strip

    private var weekDates: [Date] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(weekDates, id: \.timeIntervalSince1970) { date in
                weekStripDay(date)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
    }

    private func weekStripDay(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        return Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.2)) { selectedDate = date }
        } label: {
            VStack(spacing: 6) {
                Text(date.formatted(.dateTime.weekday(.narrow).locale(locale)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(String(calendar.component(.day, from: date)))
                    .font(.system(size: 17, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background {
                        if selected {
                            Circle().fill(Color.accentPurple)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline

    private func timelineScroll(at date: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid

                    sessionBlocks(at: date)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if calendar.isDate(selectedDate, inSameDayAs: date) {
                        currentTimeLine(at: date)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToRelevantTime(proxy: proxy, at: date)
            }
            .onChange(of: dayKey) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
            .onChange(of: appearID) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: leadingLabelWidth, alignment: .trailing)
                        .offset(y: -6)

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .id("hour-\(hour)")
            }

            // Closing "00:00" line for the next day, so the timeline ends naturally at the
            // bottom of the grid instead of trailing off into empty space after 23:00.
            HStack(alignment: .top, spacing: 8) {
                Text(hourLabel(24))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: leadingLabelWidth, alignment: .trailing)
                    .offset(y: -6)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            .frame(height: 1, alignment: .top)
        }
    }

    private struct PositionedSession: Identifiable {
        let session: TaskTimeSession
        let y: CGFloat
        let height: CGFloat
        let laneIndex: Int
        let laneCount: Int
        var id: String {
            session.id ?? "\(session.taskID)-\(session.startedAt.timeIntervalSince1970)"
        }
    }

    private func sessionBlocks(at date: Date) -> some View {
        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - leadingLabelWidth - 8)
            ZStack(alignment: .topLeading) {
                ForEach(positionedSessions(at: date, totalHeight: geo.size.height)) { positioned in
                    let laneWidth = availableWidth / CGFloat(positioned.laneCount)
                    let laneGap: CGFloat = positioned.laneCount > 1 ? 3 : 0

                    sessionBlock(positioned.session, at: date, compact: positioned.laneCount > 1 || positioned.height < 34)
                        .frame(width: max(0, laneWidth - laneGap), height: positioned.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: leadingLabelWidth + 8 + laneWidth * CGFloat(positioned.laneIndex), y: positioned.y)
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    /// Groups sessions that overlap in time into clusters, then greedily assigns each a lane
    /// (like Apple/Google Calendar's side-by-side columns) so overlapping sessions never stack
    /// on top of each other unreadably. Sessions with no overlap keep the full row width.
    private func positionedSessions(at date: Date, totalHeight: CGFloat) -> [PositionedSession] {
        // When looking at today, no block may cross the red current-time line — a session
        // that just started or just ended must stop exactly at "now", not reach into the future.
        let nowMinutes: CGFloat? = calendar.isDate(selectedDate, inSameDayAs: date)
            ? CGFloat(min(max(date.timeIntervalSince(dayBounds.start), 0), dayBounds.end.timeIntervalSince(dayBounds.start)) / 60)
            : nil

        let intervals = daySessions(at: date).map { session -> (session: TaskTimeSession, start: CGFloat, end: CGFloat) in
            let start = max(session.startedAt, dayBounds.start)
            let end = min(session.endedAt ?? date, dayBounds.end)
            let startMinutes = CGFloat(start.timeIntervalSince(dayBounds.start) / 60)
            let trueEndMinutes = CGFloat(end.timeIntervalSince(dayBounds.start) / 60)
            let endMinutes = nowMinutes.map { min(trueEndMinutes, max(startMinutes, $0)) } ?? trueEndMinutes
            return (session, startMinutes, endMinutes)
        }
        .sorted { $0.start < $1.start }

        var result: [PositionedSession] = []
        var clusterStartIndex = 0
        var clusterMaxEnd: CGFloat = -.infinity
        let minPixelHeight: CGFloat = 16

        func flushCluster(upTo index: Int) {
            guard clusterStartIndex < index else { return }
            var laneEnds: [CGFloat] = []
            var laneOf: [Int: Int] = [:]
            for i in clusterStartIndex..<index {
                let item = intervals[i]
                if let lane = laneEnds.firstIndex(where: { $0 <= item.start }) {
                    laneEnds[lane] = item.end
                    laneOf[i] = lane
                } else {
                    laneEnds.append(item.end)
                    laneOf[i] = laneEnds.count - 1
                }
            }
            let laneCount = laneEnds.count
            for i in clusterStartIndex..<index {
                let item = intervals[i]
                var y = totalHeight * (item.start / 1440)
                var height = totalHeight * ((item.end - item.start) / 1440)
                if height < minPixelHeight {
                    height = minPixelHeight
                    // Reaching the minimum readable size would normally stretch the block
                    // downward past its real end. If that end is pinned to "now", grow the
                    // block upward instead so it still can't cross the current-time line.
                    if let nowMinutes, item.end >= nowMinutes - 0.01 {
                        let nowY = totalHeight * (nowMinutes / 1440)
                        y = min(y, nowY - height)
                    }
                }
                result.append(PositionedSession(session: item.session, y: y, height: height, laneIndex: laneOf[i] ?? 0, laneCount: laneCount))
            }
        }

        for (index, item) in intervals.enumerated() {
            if item.start >= clusterMaxEnd {
                flushCluster(upTo: index)
                clusterStartIndex = index
                clusterMaxEnd = item.end
            } else {
                clusterMaxEnd = max(clusterMaxEnd, item.end)
            }
        }
        flushCluster(upTo: intervals.count)

        return result
    }

    private func sessionBlock(_ session: TaskTimeSession, at date: Date, compact: Bool) -> some View {
        let end = session.endedAt ?? date
        return VStack(alignment: .leading, spacing: 2) {
            Text(session.taskName)
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !compact {
                Text("\(clockText(session.startedAt)) – \(clockText(end))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(session.color.opacity(session.endedAt == nil ? 0.45 : 0.32))
                Rectangle()
                    .fill(session.color)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func currentTimeLine(at date: Date) -> some View {
        let totalHeight = hourHeight * 24
        let minutes = date.timeIntervalSince(dayBounds.start) / 60
        let y = totalHeight * CGFloat(minutes / 1440)

        return HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.leading, leadingLabelWidth - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: y - 4)
    }

    private func scrollToRelevantTime(proxy: ScrollViewProxy, at date: Date) {
        let hour: Int
        if calendar.isDate(selectedDate, inSameDayAs: date) {
            hour = max(0, calendar.component(.hour, from: date) - 2)
        } else if let first = daySessions(at: date).first {
            hour = max(0, calendar.component(.hour, from: first.startedAt) - 1)
        } else {
            hour = 6
        }
        withAnimation(.none) {
            proxy.scrollTo("hour-\(hour)", anchor: .top)
        }
    }

    // MARK: - Data

    private func daySessions(at date: Date) -> [TaskTimeSession] {
        (loadedDayKey == dayKey ? sessions : cachedSessionsForCurrentDay())
            .filter { session in
                let end = session.endedAt ?? date
                guard end > dayBounds.start && session.startedAt < dayBounds.end else { return false }
                let overlapStart = max(session.startedAt, dayBounds.start)
                let overlapEnd = min(end, dayBounds.end)
                let duration = max(0, overlapEnd.timeIntervalSince(overlapStart))
                return duration >= TimeInterval(sessionListMinimumDuration)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func cachedSessionsForCurrentDay() -> [TaskTimeSession] {
        guard canUseObservedSessionCache else { return [] }
        return taskService.sessions
    }

    private var canUseObservedSessionCache: Bool {
        let observedCutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return dayBounds.start >= observedCutoff
    }

    private func load() async {
        let requestedKey = dayKey
        do {
            let fetched = try await taskService.fetchSessions(from: dayBounds.start, to: dayBounds.end)
            guard requestedKey == dayKey else { return }
            sessions = fetched
            loadedDayKey = requestedKey
        } catch {
            print("Failed to load timeline sessions: \(error.localizedDescription)")
            if requestedKey == dayKey {
                loadedDayKey = nil
            }
        }
    }

    // MARK: - Formatting

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour % 24)
    }

    private func clockText(_ date: Date) -> String {
        ReportFormatters.time.string(from: date)
    }
}

#Preview {
    TimelineTabView()
        .environmentObject(TaskService())
        .preferredColorScheme(.dark)
}
