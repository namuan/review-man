import Foundation

/// Parses a GitHub API timestamp, tolerating optional fractional seconds.
public func parseGHDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
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
