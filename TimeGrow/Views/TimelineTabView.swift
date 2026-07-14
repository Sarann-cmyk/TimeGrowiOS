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
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @Environment(\.locale) private var locale

    @State private var scope: Scope = .week
    @State private var selectedDate = Date()
    @State private var sessions: [TaskTimeSession] = []
    @State private var loadedRangeKey: String?
    @State private var appearID = UUID()
    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 64
    private let leadingLabelWidth: CGFloat = 46

    private func dayBounds(for day: Date) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (start, end)
    }

    private var dayBounds: (start: Date, end: Date) { dayBounds(for: selectedDate) }

    private var weekBounds: (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return (start, end)
    }

    /// The range currently being fetched/displayed — a single day, or the whole visible week.
    private var rangeBounds: (start: Date, end: Date) { scope == .day ? dayBounds : weekBounds }

    private var rangeKey: String { "\(scope.rawValue)-\(rangeBounds.start.timeIntervalSince1970)" }

    private var hasLiveSession: Bool {
        sessions.contains { $0.endedAt == nil }
            || taskService.sessions.contains { $0.endedAt == nil }
            || activeEntry != nil
    }

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
                        content(at: context.date)
                    }
                } else {
                    content(at: Date())
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded(handleHorizontalSwipe)
            )
        }
        .background(Color.black)
        .task(id: rangeKey) {
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

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if scope == .day {
            timelineScroll(at: date)
        } else {
            weekTimelineScroll(at: date)
        }
    }

    /// Swipe left/right to step by a day (Day mode) or a week (Week mode). Only fires on a
    /// clearly horizontal drag so it doesn't fight the grid's own vertical scrolling.
    private func handleHorizontalSwipe(_ value: DragGesture.Value) {
        let horizontal = value.translation.width
        let vertical = value.translation.height
        guard abs(horizontal) > 60, abs(horizontal) > abs(vertical) * 1.5 else { return }

        let step = scope == .day ? 1 : 7
        let delta = horizontal < 0 ? step : -step
        guard let newDate = calendar.date(byAdding: .day, value: delta, to: selectedDate) else { return }

        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = newDate
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
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
                        .foregroundStyle(scope == candidate ? accentColorManager.color : Color.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(scope == candidate ? accentColorManager.color.opacity(0.22) : Color.selectedTabBackground.opacity(0.7))
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
            // Lines up the day headers with the day columns in the grid below, which are
            // pushed over by the leading hour-label gutter (e.g. "00:00"). Otherwise-empty,
            // so it doubles as a spot for the live active-tracker readout.
            activeTrackerCorner
                .frame(width: leadingLabelWidth + 8, alignment: .leading)

            ForEach(weekDates, id: \.timeIntervalSince1970) { date in
                weekStripDay(date)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private struct ActiveEntry {
        let color: Color
        let symbol: String
        let startedAt: Date
    }

    /// A manually-started timer, or an auto-tracked session that's still within its
    /// grace-period window after ending — the same two cases the Tasks list treats as "live".
    /// Auto-track never sets `timerStartedAt` on the task itself, only on the session, so
    /// this can't be answered from `task.isTimerRunning` alone.
    private var activeEntry: ActiveEntry? {
        if let task = taskService.tasks.first(where: { $0.isTimerRunning }), let startedAt = task.timerStartedAt {
            return ActiveEntry(color: task.color, symbol: task.symbol, startedAt: startedAt)
        }
        let graceCandidates = taskService.sessions.filter { session -> Bool in
            guard session.startedAutomatically == true, let endedAt = session.endedAt else { return false }
            if let stoppedAt = taskService.tasks.first(where: { $0.id == session.taskID })?.autoTrackStoppedAt,
               endedAt <= stoppedAt {
                return false
            }
            return Date().timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
        }
        guard let liveSession = graceCandidates.max(by: { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }) else {
            return nil
        }
        let symbol = String(liveSession.taskName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
        return ActiveEntry(color: liveSession.color, symbol: symbol.isEmpty ? "T" : symbol, startedAt: liveSession.startedAt)
    }

    @ViewBuilder
    private var activeTrackerCorner: some View {
        if let entry = activeEntry {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(entry.startedAt)))
                let minutes = elapsed / 60
                let secondsFraction = Double(elapsed % 60) / 60

                ZStack {
                    Circle()
                        .stroke(entry.color.opacity(0.25), lineWidth: 2.5)
                    // The ring fills clockwise over each minute, resetting as the seconds roll over.
                    Circle()
                        .trim(from: 0, to: secondsFraction)
                        .stroke(entry.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(minutes)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 35, height: 35)
            }
        } else if let lastTask = mostRecentTask {
            Text(lastTask.symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(lastTask.color)
                .frame(width: 35, height: 35)
                .background {
                    Circle().stroke(lastTask.color, lineWidth: 1.2)
                }
        } else {
            Color.clear
                .frame(width: 35, height: 35)
        }
    }

    /// The task behind the most recently started session — shown idle (just its letter) in
    /// the corner once nothing is actively tracking, instead of leaving it empty.
    private var mostRecentTask: TGTask? {
        guard let mostRecentSession = taskService.sessions.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return taskService.tasks.first { $0.id == mostRecentSession.taskID }
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
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accentColorManager.color : .white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accentColorManager.color.opacity(0.22))
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

                    sessionBlocks(bounds: dayBounds, at: date)
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
            .onChange(of: rangeKey) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
            .onChange(of: appearID) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
        }
    }

    private func weekTimelineScroll(at date: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid

                    weekSessionColumns(at: date)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToRelevantTime(proxy: proxy, at: date)
            }
            .onChange(of: rangeKey) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
            .onChange(of: appearID) { _, _ in
                scrollToRelevantTime(proxy: proxy, at: date)
            }
        }
    }

    private func weekSessionColumns(at date: Date) -> some View {
        GeometryReader { geo in
            let columnsAreaWidth = max(0, geo.size.width - leadingLabelWidth - 8)
            let columnWidth = columnsAreaWidth / 7
            ZStack(alignment: .topLeading) {
                // Vertical dividers between the 7 day columns (and a closing line on the
                // right edge), matching the existing horizontal hour gridlines.
                ForEach(0...7, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1)
                        .offset(x: leadingLabelWidth + 8 + CGFloat(index) * columnWidth)
                }

                ForEach(Array(weekDates.enumerated()), id: \.offset) { index, day in
                    weekDayColumn(
                        day: day,
                        at: date,
                        xOffset: leadingLabelWidth + 8 + CGFloat(index) * columnWidth,
                        columnWidth: columnWidth,
                        totalHeight: geo.size.height
                    )
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func weekDayColumn(day: Date, at date: Date, xOffset: CGFloat, columnWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let bounds = dayBounds(for: day)
        return ZStack(alignment: .topLeading) {
            ForEach(positionedSessions(bounds: bounds, at: date, totalHeight: totalHeight)) { positioned in
                let laneWidth = max(1, columnWidth - 4) / CGFloat(positioned.laneCount)
                let laneGap: CGFloat = positioned.laneCount > 1 ? 2 : 0

                sessionBlock(positioned.session, at: date, height: positioned.height, showsSubtitle: false)
                    .frame(width: max(0, laneWidth - laneGap), height: positioned.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: xOffset + laneWidth * CGFloat(positioned.laneIndex), y: positioned.y)
            }

            if calendar.isDate(day, inSameDayAs: date) {
                weekCurrentTimeMarker(at: date, bounds: bounds, xOffset: xOffset, columnWidth: columnWidth, totalHeight: totalHeight)
            }
        }
    }

    private func weekCurrentTimeMarker(at date: Date, bounds: (start: Date, end: Date), xOffset: CGFloat, columnWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let minutes = date.timeIntervalSince(bounds.start) / 60
        let y = totalHeight * CGFloat(minutes / 1440)
        return Rectangle()
            .fill(Color.red)
            .frame(width: max(0, columnWidth - 4), height: 1.5)
            .offset(x: xOffset, y: y)
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

    private func sessionBlocks(bounds: (start: Date, end: Date), at date: Date) -> some View {
        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - leadingLabelWidth - 8)
            ZStack(alignment: .topLeading) {
                ForEach(positionedSessions(bounds: bounds, at: date, totalHeight: geo.size.height)) { positioned in
                    let laneWidth = availableWidth / CGFloat(positioned.laneCount)
                    let laneGap: CGFloat = positioned.laneCount > 1 ? 3 : 0

                    sessionBlock(positioned.session, at: date, height: positioned.height, showsSubtitle: positioned.laneCount == 1)
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
    private func positionedSessions(bounds: (start: Date, end: Date), at date: Date, totalHeight: CGFloat) -> [PositionedSession] {
        // When looking at today, no block may cross the red current-time line — a session
        // that just started or just ended must stop exactly at "now", not reach into the future.
        let nowMinutes: CGFloat? = calendar.isDate(bounds.start, inSameDayAs: date)
            ? CGFloat(min(max(date.timeIntervalSince(bounds.start), 0), bounds.end.timeIntervalSince(bounds.start)) / 60)
            : nil

        let intervals = daySessions(for: bounds, at: date).map { session -> (session: TaskTimeSession, start: CGFloat, end: CGFloat) in
            let start = max(session.startedAt, bounds.start)
            let end = min(session.endedAt ?? date, bounds.end)
            let startMinutes = CGFloat(start.timeIntervalSince(bounds.start) / 60)
            let trueEndMinutes = CGFloat(end.timeIntervalSince(bounds.start) / 60)
            let endMinutes = nowMinutes.map { min(trueEndMinutes, max(startMinutes, $0)) } ?? trueEndMinutes
            return (session, startMinutes, endMinutes)
        }
        .sorted { $0.start < $1.start }

        var result: [PositionedSession] = []
        var clusterStartIndex = 0
        var clusterMaxEnd: CGFloat = -.infinity
        let minPixelHeight: CGFloat = 22
        // Clusters are temporally sequential by construction (a new one only starts once the
        // previous one's time range is fully behind it), so tracking the lowest point reached
        // by any earlier cluster and never drawing above it prevents overlap *across* clusters
        // too — not just between lanes inside the same cluster.
        var globalBottom: CGFloat = -.infinity

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

            // Pass 1: natural stacked position within this cluster only (lane-local), so
            // items sharing a lane never overlap each other.
            //
            // Uses each item's *true* (unpadded) end time to seed the next item's floor, not its
            // rendered height. Several very short sessions in a row each get padded up to
            // `minPixelHeight` for legibility/tappability — if that padded height fed back into
            // the next item's minimum Y, the inflation compounds indefinitely (confirmed on real
            // data: four ~1-3min sessions alone drifted later blocks by over an hour, visually
            // swallowing a genuine 67-minute gap).
            //
            // That alone still lets a single short block's *own* padding stretch its rendered
            // bottom edge past its real Reports end and into where the next lane-mate visually
            // starts, even though the next block's own Y is correctly anchored. Safeguard: cap
            // each block's padded height so it can never render past the next same-lane item's
            // true start — the block's drawn end always matches (or stops short of) the moment
            // Reports actually recorded it ending.
            var laneItemIndices: [Int: [Int]] = [:]
            for i in clusterStartIndex..<index {
                laneItemIndices[laneOf[i] ?? 0, default: []].append(i)
            }
            var yByIndex: [Int: CGFloat] = [:]
            var heightByIndex: [Int: CGFloat] = [:]
            for (_, indices) in laneItemIndices {
                var previousTrueBottom: CGFloat = -.infinity
                for (pos, i) in indices.enumerated() {
                    let item = intervals[i]
                    var y = totalHeight * (item.start / 1440)
                    if y < previousTrueBottom { y = previousTrueBottom }
                    let trueBottomY = totalHeight * (item.end / 1440)
                    var height = max(minPixelHeight, trueBottomY - y)
                    if pos + 1 < indices.count {
                        let nextItem = intervals[indices[pos + 1]]
                        let nextFloorY = max(totalHeight * (nextItem.start / 1440), trueBottomY)
                        height = min(height, max(4, nextFloorY - y))
                    }
                    yByIndex[i] = y
                    heightByIndex[i] = height
                    previousTrueBottom = trueBottomY
                }
            }
            var naiveY: [CGFloat] = []
            var naiveHeight: [CGFloat] = []
            for i in clusterStartIndex..<index {
                naiveY.append(yByIndex[i] ?? 0)
                naiveHeight.append(heightByIndex[i] ?? minPixelHeight)
            }

            // Pass 2: shift the whole cluster down if its top would land above the previous
            // cluster's lowest point.
            let clusterTop = naiveY.min() ?? 0
            let shift = max(0, globalBottom - clusterTop)

            // Mirrors the `laneBottom` fix above, one level up: tracks the cluster's true extent
            // (unpadded) so padding inside one cluster can't drift every later cluster down too.
            var trueClusterBottom: CGFloat = 0
            for (offset, i) in (clusterStartIndex..<index).enumerated() {
                let item = intervals[i]
                let lane = laneOf[i] ?? 0
                var y = naiveY[offset] + shift
                var height = naiveHeight[offset]

                // Only after the shift above: no block may cross "now" (if this is today), and
                // — regardless of which day this is — none may cross the day's own closing
                // "00:00" boundary either. This isn't limited to whichever session's *real* end
                // happens to land on "now" — the downward shift from Pass 2 (crowding several
                // short back-to-back sessions) can just as easily push an already-finished
                // block's floor-inflated position past the cap, so it applies to every block
                // unconditionally. Clamping only the height would leave a pushed-down block
                // floating below the line entirely, so the top must be pulled back up too.
                let capMinutes = nowMinutes ?? 1440
                let capY = totalHeight * (capMinutes / 1440)
                y = min(y, capY - 4)
                height = max(4, min(height, capY - y))

                trueClusterBottom = max(trueClusterBottom, totalHeight * (item.end / 1440) + shift)
                result.append(PositionedSession(session: item.session, y: y, height: height, laneIndex: lane, laneCount: laneCount))
            }
            globalBottom = max(globalBottom, trueClusterBottom)
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

    /// A block only ever shows its label at this one fixed size — never scaled down to fit.
    /// Once there isn't room for a legible label at that size, the block shows no text at
    /// all (just the colored bar) rather than shrinking it into something unreadable.
    private static let sessionLabelFontSize: CGFloat = 9
    // A 9pt line needs roughly 11pt for its own height; with 2pt of padding top and bottom
    // that's ~15pt — anything shorter than that genuinely has no room for a label.
    private static let minHeightForLabel: CGFloat = 15
    private static let minHeightForSubtitle: CGFloat = 30

    private func sessionBlock(_ session: TaskTimeSession, at date: Date, height: CGFloat, showsSubtitle: Bool) -> some View {
        let end = session.endedAt ?? date
        let showsLabel = height >= Self.minHeightForLabel
        let showsTime = showsSubtitle && height >= Self.minHeightForSubtitle

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(session.color.opacity(session.endedAt == nil ? 0.45 : 0.32))
            Rectangle()
                .fill(session.color)
                .frame(width: 3)

            if showsLabel {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.taskName)
                        .font(.system(size: Self.sessionLabelFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if showsTime {
                        Text("\(clockText(session.startedAt)) – \(clockText(end))")
                            .font(.system(size: Self.sessionLabelFontSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        } else if let first = daySessions(for: dayBounds, at: date).first {
            hour = max(0, calendar.component(.hour, from: first.startedAt) - 1)
        } else {
            hour = 6
        }
        withAnimation(.none) {
            proxy.scrollTo("hour-\(hour)", anchor: .top)
        }
    }

    // MARK: - Data

    private func daySessions(for bounds: (start: Date, end: Date), at date: Date) -> [TaskTimeSession] {
        let filtered = sessionsSource(at: date)
            .filter { session in
                let end = session.endedAt ?? date
                guard end > bounds.start && session.startedAt < bounds.end else { return false }
                let overlapStart = max(session.startedAt, bounds.start)
                let overlapEnd = min(end, bounds.end)
                let duration = max(0, overlapEnd.timeIntervalSince(overlapStart))
                return duration >= TimeInterval(sessionListMinimumDuration)
            }
            .sorted { $0.startedAt < $1.startedAt }
        return Self.mergingAdjacentAutoTrackedSessions(filtered)
    }

    /// Auto-tracking creates one real Firestore session per ~minute of usage, so a single
    /// continuous stretch of scrolling shows up as dozens of same-task records with only a few
    /// seconds between each — each one gets its own overlapping "TikTok" label in the block
    /// layout, which reads as noise rather than one activity. This is purely a *display* merge
    /// for Timeline blocks: it never touches Firestore, so Reports (which lists the real
    /// records) is unaffected.
    ///
    /// Two Firestore session records only exist as separate documents because
    /// `AutoTrackingExtension.resolveSessionStartedAt` already decided the gap between them
    /// exceeded `autoTrackingInactivityGraceSeconds` — i.e. any already-split pair represents a
    /// genuine break, not a display artifact. Because that extension also backdates a resumed
    /// session's start by `autoTrackingThresholdSeconds`, the recorded gap between two genuinely
    /// split sessions is always strictly greater than `autoTrackingInactivityGraceSeconds -
    /// autoTrackingThresholdSeconds` — using that difference as the merge cutoff means a real
    /// break (e.g. gone 4 minutes, which the grace period turns into a ~3 minute recorded gap)
    /// always stays visible, while only true sub-minute polling artifacts get merged away.
    private static func mergingAdjacentAutoTrackedSessions(_ sessions: [TaskTimeSession]) -> [TaskTimeSession] {
        let mergeCutoff = autoTrackingInactivityGraceSeconds - autoTrackingThresholdSeconds
        var merged: [TaskTimeSession] = []
        for session in sessions {
            if let last = merged.last,
               last.taskID == session.taskID,
               last.startedAutomatically == true,
               session.startedAutomatically == true,
               let lastEnd = last.endedAt,
               session.startedAt.timeIntervalSince(lastEnd) < mergeCutoff {
                var extended = last
                extended.endedAt = session.endedAt
                merged[merged.count - 1] = extended
            } else {
                merged.append(session)
            }
        }
        return merged
    }

    private func sessionsSource(at date: Date) -> [TaskTimeSession] {
        // Prefer the live, always-up-to-date Firestore listener cache whenever the range is
        // recent enough for it to cover — that's what makes new/ending sessions (like the
        // one currently running) show up immediately instead of only after the view reloads.
        // Only fall back to the one-time async fetch for ranges older than that rolling window.
        guard canUseObservedSessionCache else {
            return loadedRangeKey == rangeKey ? sessions : []
        }
        return taskService.sessions
    }

    private var canUseObservedSessionCache: Bool {
        let observedCutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return rangeBounds.start >= observedCutoff
    }

    private func load() async {
        let requestedKey = rangeKey
        do {
            let bounds = rangeBounds
            let fetched = try await taskService.fetchSessions(from: bounds.start, to: bounds.end)
            guard requestedKey == rangeKey else { return }
            sessions = fetched
            loadedRangeKey = requestedKey
        } catch {
            print("Failed to load timeline sessions: \(error.localizedDescription)")
            if requestedKey == rangeKey {
                loadedRangeKey = nil
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
        .environmentObject(AccentColorManager())
        .preferredColorScheme(.dark)
}
