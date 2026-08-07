import Foundation

/// Parses a GitHub API timestamp, tolerating optional fractional seconds.
/// The formatter is cached: `ISO8601DateFormatter` construction is expensive
/// and this is called once per comment during every fetch.
///
/// Foundation formatters are documented thread-safe since macOS 10.9, and the
/// formatter is never mutated after initialization, so the static instance is
/// safe to share across the fetch lanes and the demo generator.
private let ghDateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let ghDateFormatterStrict: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

public func parseGHDate(_ s: String) -> Date? {
    // The fractional-seconds formatter REQUIRES a fractional part, so most
    // GitHub timestamps ("2026-07-30T10:12:00Z") fall through to the strict
    // one. Both are cached — no per-call formatter construction.
    if let d = ghDateFormatter.date(from: s) { return d }
    return ghDateFormatterStrict.date(from: s)
}

/// The three review decision types, shared by the submit sheet and the core.
public enum ReviewEvent: Int, CaseIterable {
    case comment = 0
    case approve = 1
    case requestChanges = 2

    public var apiValue: String {
        switch self {
        case .comment: return "COMMENT"
        case .approve: return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        }
    }

    public var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }
}

/// The most recent local-persistence failure, retained beyond the timed
/// message banner so a window close can warn about it later.
public struct PersistenceFailure {
    public let operation: String
    public let message: String

    public init(operation: String, message: String) {
        self.operation = operation
        self.message = message
    }
}
