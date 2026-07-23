//
//  DiagnosticsLog.swift
//  TimeGrow
//

import Foundation
import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Persistent, exportable diagnostic log for tracking down intermittent
/// timer start/stop issues (manual + auto-tracking) over real usage time.
/// Lives in the shared App Group container so it survives app restarts
/// and can be combined with AutoTrackingExtension's debug events on export.
enum DiagnosticsLog {
    private static let logFileName = "diagnostics.log"
    private static let debugEventsKey = "autoTracking.debugEvents"
    private static let creditedSecondsKeyPrefix = "autoTracking.creditedSecondsToday."
    private static let unaccountedSecondsKeyPrefix = "autoTracking.unaccountedSecondsToday."
    private static let maxStoredCharacters = 400_000
    private static let queue = DispatchQueue(label: "TimeGrow.DiagnosticsLog")

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: autoTrackingAppGroupID)?
            .appendingPathComponent(logFileName)
    }

    static func log(_ tag: String, _ message: String) {
        let line = "\(Self.timestampFormatter.string(from: Date())) [\(tag)] \(message)"
        print(line)
        queue.async {
            append(line + "\n")
        }
    }

    static func exportText() -> String {
        var result = "TimeGrow diagnostics export — \(Self.timestampFormatter.string(from: Date()))\n\n"
        if let url = fileURL, let content = try? String(contentsOf: url, encoding: .utf8) {
            result += content
        } else {
            result += "(no app log entries yet)\n"
        }

        if let sharedDefaults = UserDefaults(suiteName: autoTrackingAppGroupID),
           let events = sharedDefaults.array(forKey: debugEventsKey) as? [[String: Any]], !events.isEmpty {
            result += "\n--- AutoTrackingExtension events ---\n"
            for event in events {
                let name = event["name"] as? String ?? "?"
                let taskID = event["taskID"] as? String ?? "?"
                let timestamp = (event["occurredAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let timestampText = timestamp.map { Self.timestampFormatter.string(from: $0) } ?? "?"
                result += "\(timestampText) [extension] \(name) task=\(taskID)\n"
            }
        }

        result += autoTrackTotalsSummary()
        return result
    }

    /// Reads the running daily counters `AutoTrackingExtension` maintains per task — exact
    /// credited usage versus wall-clock time that produced no credit at all (real pauses or
    /// delayed/dropped DeviceActivity callbacks) — so a discrepancy against iOS Screen Time can
    /// be sized directly from the export instead of by diffing raw event timestamps by hand.
    private static func autoTrackTotalsSummary() -> String {
        guard let sharedDefaults = UserDefaults(suiteName: autoTrackingAppGroupID) else { return "" }
        let creditedKeys = sharedDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(creditedSecondsKeyPrefix) }
        guard !creditedKeys.isEmpty else { return "" }

        var summary = "\n--- Auto-track totals today (per task) ---\n"
        for creditedKey in creditedKeys.sorted() {
            let taskID = String(creditedKey.dropFirst(creditedSecondsKeyPrefix.count))
            let credited = sharedDefaults.double(forKey: creditedKey)
            let unaccounted = sharedDefaults.double(forKey: "\(unaccountedSecondsKeyPrefix)\(taskID)")
            summary += "task=\(taskID) credited=\(formatDuration(credited)) unaccounted~=\(formatDuration(unaccounted))\n"
        }
        return summary
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
    }

    static func writeExportFile() -> URL? {
        let fileNameFormatter = DateFormatter()
        fileNameFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "TimeGrow-diagnostics-\(fileNameFormatter.string(from: Date())).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Failed to write diagnostics export: \(error.localizedDescription)")
            return nil
        }
    }

    static func clearAll() {
        queue.async {
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        UserDefaults(suiteName: autoTrackingAppGroupID)?.removeObject(forKey: debugEventsKey)
    }

    private static func append(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }

        trimIfNeeded(url: url)
    }

    private static func trimIfNeeded(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > maxStoredCharacters * 2,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let trimmed = String(content.suffix(maxStoredCharacters))
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
