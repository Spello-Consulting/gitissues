//
//  PerfTimer.swift
//  GitIssues
//
//  Issue #109 — performance instrumentation.
//

import Foundation

/// Lightweight wall-clock timer used to log how long network calls, merges and view-model work
/// take. All output is prefixed with `[PERF]` so it can be found with `grep PERF` in the log file
/// (Settings → Log level must be at least "Information"; "Debug" also shows the fast samples).
///
/// ```swift
/// let timer = PerfTimer()
/// await work()
/// PerfTimer.log("fetchIssuePages", timer, "pages=\(pages)")
/// ```
nonisolated struct PerfTimer {
    private let start = ContinuousClock.now

    /// Milliseconds elapsed since the timer was created.
    var elapsedMs: Double {
        let d = ContinuousClock.now - start
        let comps = d.components
        return Double(comps.seconds) * 1_000 + Double(comps.attoseconds) / 1e15
    }

    /// Milliseconds as a fixed one-decimal string, e.g. `"1234.5"`.
    var elapsedString: String { Self.format(elapsedMs) }

    static func format(_ ms: Double) -> String { String(format: "%.1f", ms) }

    /// Logs `[PERF] <label> <ms>ms <detail>`.
    ///
    /// - Parameters:
    ///   - slowAfterMs: When non-nil, samples faster than this are logged at debug level instead
    ///     of info, so very frequent measurements (e.g. per-render work) don't flood the log.
    static func log(_ label: String, _ timer: PerfTimer, _ detail: String = "", slowAfterMs: Double? = nil) {
        let ms = timer.elapsedMs
        let message = "[PERF] \(label) \(format(ms))ms" + (detail.isEmpty ? "" : " \(detail)")
        if let slowAfterMs, ms < slowAfterMs {
            AppLogger.shared.debug(message)
        } else {
            AppLogger.shared.info(message)
        }
    }
}
