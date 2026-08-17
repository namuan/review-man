import Foundation
import os

/// Signpost and duration helpers used by the Phase 1 performance baseline.
///
/// Signposts are visible in Instruments without adding a second timing system
/// to the UI. Duration logs are opt-in because logging from a hot path would
/// distort the measurement being collected.
public enum PerformanceLog {
    public static let subsystem = "com.prreview.app"
    public static let log = OSLog(subsystem: subsystem, category: "performance")

    @discardableResult
    public static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    public static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    /// Times a synchronous phase while keeping the operation's normal result
    /// and error behavior. Set `logDuration` only for coarse phases; the log
    /// itself must not be part of per-line or per-frame measurements.
    public static func measure<T>(
        name: StaticString,
        label: String,
        logDuration: Bool = false,
        _ operation: () throws -> T
    ) rethrows -> T {
        let signpostID = begin(name)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            end(name, id: signpostID)
            if logDuration {
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                let milliseconds = Double(elapsed) / 1_000_000
                let formatted = String(format: "%.2f", milliseconds)
                AppLog.info("perf", "\(label) elapsedMs=\(formatted)")
            }
        }
        return try operation()
    }
}
