import Foundation
import os

/// Lightweight signpost and structured timing logs for startup, OCR and translation latency.
/// Logs only durations and counts — never user text or file paths.
enum PerfLog {
    static let logger = Logger(subsystem: "com.weaveneuron.shocrot", category: "perf")
    static let signposter = OSSignposter(logger: logger)
    private static let launchUptime = ProcessInfo.processInfo.systemUptime

    static var msSinceLaunch: Double {
        (ProcessInfo.processInfo.systemUptime - launchUptime) * 1000
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}
