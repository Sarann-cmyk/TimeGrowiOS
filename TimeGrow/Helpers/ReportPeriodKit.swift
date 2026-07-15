//
//  ReportPeriodKit.swift
//  TimeGrow
//

import Foundation
import SwiftUI

enum ReportPeriod: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var averageLabel: String {
        self == .year ? "Monthly Avg." : "Daily Avg."
    }
}

struct ReportBucket: Identifiable {
    let id = UUID()
    let date: Date
    let seconds: TimeInterval
}

struct TaskBucketSegment: Identifiable {
    let id = UUID()
    let bucketDate: Date
    let taskID: String
    let color: Color
    let seconds: TimeInterval
}

enum SessionListDisplaySettings {
    static let minimumDurationKey = "reports.sessionListMinimumDurationSeconds"
    static let defaultMinimumDuration = 0
    static let minimumDurationOptions = [0, 60, 120, 300]

    static func title(for seconds: Int) -> String {
        switch seconds {
        case 0:
            return "Show all"
        case 60:
            return "1 minute"
        default:
            return "\(seconds / 60) minutes"
        }
    }

    static func description(for seconds: Int) -> String {
        seconds == 0 ? "All session records are visible." : "Hide sessions shorter than \(title(for: seconds))."
    }
}

enum WeekStartDay: Int, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .sunday: return String(localized: "Sunday")
        case .monday: return String(localized: "Monday")
        }
    }
}

enum WeekStartSettings {
    static let dayKey = "settings.weekStartDay"

    /// `Calendar.current` with `firstWeekday` overridden by the user's choice, or the
    /// locale's own default when no preference has been stored yet.
    static var calendar: Calendar {
        var calendar = Calendar.current
        let stored = UserDefaults.standard.integer(forKey: dayKey)
        if let day = WeekStartDay(rawValue: stored) {
            calendar.firstWeekday = day.rawValue
        }
        return calendar
    }

    static var selected: WeekStartDay {
        get {
            WeekStartDay(rawValue: UserDefaults.standard.integer(forKey: dayKey)) ?? WeekStartDay(rawValue: Calendar.current.firstWeekday) ?? .sunday
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: dayKey)
        }
    }
}

enum ReportFormatters {
    static let dayTitle: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "d MMMM yyyy"; return f }()
    static let shortDate: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "d MMM"; return f }()
    static let monthTitle: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "LLLL yyyy"; return f }()
    static let monthShort: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "LLL"; return f }()
    static let year: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "yyyy"; return f }()
    static let hour: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH"; return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let weekdayFull: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEEE"; return f }()
    static let monthDay: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateFormat = "MMMM d"; return f }()
}

enum ReportDateMath {
    static func range(for period: ReportPeriod, containing date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        switch period {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return (start, end)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return (start, end)
        case .month:
            let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (start, end)
        case .year:
            let start = calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
            return (start, end)
        }
    }

    static func isCurrentPeriod(_ period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> Bool {
        range(for: period, containing: Date(), calendar: calendar).start
            == range(for: period, containing: referenceDate, calendar: calendar).start
    }

    static func step(_ period: ReportPeriod, referenceDate: Date, delta: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: component(for: period), value: delta, to: referenceDate) ?? referenceDate
    }

    static func periodLabel(_ period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> String {
        let bounds = range(for: period, containing: referenceDate, calendar: calendar)
        switch period {
        case .day:
            if calendar.isDateInToday(referenceDate) { return "Today" }
            return ReportFormatters.dayTitle.string(from: referenceDate)
        case .week:
            let weekNumber = calendar.component(.weekOfYear, from: referenceDate)
            let end = calendar.date(byAdding: .day, value: 6, to: bounds.start) ?? bounds.start
            return "Week \(weekNumber) (\(ReportFormatters.shortDate.string(from: bounds.start)) – \(ReportFormatters.shortDate.string(from: end)))"
        case .month:
            return ReportFormatters.monthTitle.string(from: referenceDate).capitalized
        case .year:
            return ReportFormatters.year.string(from: referenceDate)
        }
    }

    static func neighborLabel(_ period: ReportPeriod, referenceDate: Date, offset: Int, calendar: Calendar) -> String {
        guard let neighbor = neighborDate(period, referenceDate: referenceDate, offset: offset, calendar: calendar) else { return "" }
        switch period {
        case .day:
            return ReportFormatters.shortDate.string(from: neighbor)
        case .week:
            let weekNumber = calendar.component(.weekOfYear, from: neighbor)
            return "Week \(weekNumber)"
        case .month:
            return ReportFormatters.monthShort.string(from: neighbor)
        case .year:
            return ReportFormatters.year.string(from: neighbor)
        }
    }

    static func neighborDate(_ period: ReportPeriod, referenceDate: Date, offset: Int, calendar: Calendar) -> Date? {
        calendar.date(byAdding: component(for: period), value: offset, to: referenceDate)
    }

    static func elapsedDays(for period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> Int {
        let bounds = range(for: period, containing: referenceDate, calendar: calendar)
        let cappedEnd = min(bounds.end, Date())
        let seconds = max(0, cappedEnd.timeIntervalSince(bounds.start))
        return max(1, Int(ceil(seconds / 86400)))
    }

    static func elapsedMonths(for period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> Int {
        let bounds = range(for: period, containing: referenceDate, calendar: calendar)
        let cappedEnd = min(bounds.end, Date())
        guard cappedEnd > bounds.start else { return 1 }
        let months = calendar.dateComponents([.month], from: bounds.start, to: cappedEnd).month ?? 0
        return max(1, months + 1)
    }

    /// Number of period units (days for everything except `.year`, which averages by month)
    /// already elapsed — used as the divisor for the "Daily Avg."/"Monthly Avg." stat.
    static func averageDivisor(for period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> Int {
        period == .year
            ? elapsedMonths(for: period, referenceDate: referenceDate, calendar: calendar)
            : elapsedDays(for: period, referenceDate: referenceDate, calendar: calendar)
    }

    static func buckets(
        for period: ReportPeriod,
        referenceDate: Date,
        calendar: Calendar,
        sessions: [TaskTimeSession],
        at date: Date
    ) -> [ReportBucket] {
        bucketBoundaries(for: period, referenceDate: referenceDate, calendar: calendar).compactMap { bucketStart, bucketEnd in
            let seconds = sessions.reduce(0) { total, session in
                let sessionEnd = session.endedAt ?? date
                let overlapStart = max(session.startedAt, bucketStart)
                let overlapEnd = min(sessionEnd, bucketEnd)
                return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
            }
            return ReportBucket(date: bucketStart, seconds: seconds)
        }
    }

    /// Per-bucket totals broken down by task, ordered by `taskOrder` (typically task creation
    /// order) so each task occupies a consistent stack position across every bar in the chart.
    static func taskBuckets(
        for period: ReportPeriod,
        referenceDate: Date,
        calendar: Calendar,
        sessions: [TaskTimeSession],
        taskOrder: [String],
        at date: Date
    ) -> [TaskBucketSegment] {
        let orderIndex = Dictionary(uniqueKeysWithValues: taskOrder.enumerated().map { ($1, $0) })

        return bucketBoundaries(for: period, referenceDate: referenceDate, calendar: calendar).flatMap { bucketStart, bucketEnd -> [TaskBucketSegment] in
            var totals: [String: (color: Color, seconds: TimeInterval)] = [:]
            for session in sessions {
                let sessionEnd = session.endedAt ?? date
                let overlapStart = max(session.startedAt, bucketStart)
                let overlapEnd = min(sessionEnd, bucketEnd)
                let duration = max(0, overlapEnd.timeIntervalSince(overlapStart))
                guard duration > 0 else { continue }
                var entry = totals[session.taskID] ?? (session.color, 0)
                entry.seconds += duration
                totals[session.taskID] = entry
            }
            return totals
                .sorted { (orderIndex[$0.key] ?? .max, $0.key) < (orderIndex[$1.key] ?? .max, $1.key) }
                .map { taskID, value in
                    TaskBucketSegment(bucketDate: bucketStart, taskID: taskID, color: value.color, seconds: value.seconds)
                }
        }
    }

    private static func bucketBoundaries(for period: ReportPeriod, referenceDate: Date, calendar: Calendar) -> [(start: Date, end: Date)] {
        let bounds = range(for: period, containing: referenceDate, calendar: calendar)
        let bucketComponent: Calendar.Component
        let count: Int
        switch period {
        case .day:
            bucketComponent = .hour
            count = 24
        case .week:
            bucketComponent = .day
            count = 7
        case .month:
            bucketComponent = .day
            count = calendar.range(of: .day, in: .month, for: referenceDate)?.count ?? 30
        case .year:
            bucketComponent = .month
            count = 12
        }

        return (0..<count).compactMap { offset -> (start: Date, end: Date)? in
            guard let bucketStart = calendar.date(byAdding: bucketComponent, value: offset, to: bounds.start),
                  let bucketEnd = calendar.date(byAdding: bucketComponent, value: 1, to: bucketStart) else { return nil }
            return (bucketStart, bucketEnd)
        }
    }

    static func axisDesiredCount(for period: ReportPeriod) -> Int {
        switch period {
        case .day: 8
        case .week: 7
        case .month: 6
        case .year: 12
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private static func component(for period: ReportPeriod) -> Calendar.Component {
        switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}
