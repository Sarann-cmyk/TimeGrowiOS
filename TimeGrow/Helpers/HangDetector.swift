//
//  HangDetector.swift
//  TimeGrow
//

import Foundation

/// Watches the main thread's run loop from a background thread and logs it via `DiagnosticsLog`
/// whenever it stops responding for longer than `hangThreshold` — so intermittent freezes users
/// report can be correlated with whatever else was logged right before them.
enum HangDetector {
    private static let pingInterval: TimeInterval = 0.5
    private static let hangThreshold: TimeInterval = 1.5
    /// Backgrounding suspends the process entirely, so the next ping after a resume can be
    /// minutes or hours late. That's not a real hang — just skip logging it.
    private static let maxPlausibleHang: TimeInterval = 30
    private static var isRunning = false

    static func start() {
        guard !isRunning, !isDebuggerAttached() else { return }
        isRunning = true

        let thread = Thread { monitorLoop() }
        thread.name = "TimeGrow.HangDetector"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func monitorLoop() {
        while true {
            let semaphore = DispatchSemaphore(value: 0)
            let pingedAt = Date()
            DispatchQueue.main.async { semaphore.signal() }

            if semaphore.wait(timeout: .now() + hangThreshold) == .timedOut {
                semaphore.wait()
                let elapsed = Date().timeIntervalSince(pingedAt)
                if elapsed <= maxPlausibleHang {
                    DiagnosticsLog.log("hang", String(format: "Main thread unresponsive for %.2fs", elapsed))
                }
            }

            Thread.sleep(forTimeInterval: pingInterval)
        }
    }

    /// Breakpoints and `po` evaluation stall the main thread the same way a real hang does —
    /// without this check every Xcode debug session would spam false "hang" entries.
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
