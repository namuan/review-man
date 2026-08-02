import Foundation
import PRReviewKit

/// Pure URL routing logic: maps incoming URLs (launcher `pr-review://` scheme
/// or plain GitHub URLs) to a PR reference string. Testable without AppKit.
public enum ReviewURLCoordinator {

    /// Returns the reference to open, or nil for unhandled URLs.
    public static func reference(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "pr-review":
            return endpoint(from: url)
        case "https", "http":
            // Only GitHub PR URLs are routed to a review window.
            guard let host = url.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" else { return nil }
            return url.absoluteString
        default:
            return nil
        }
    }

    /// Strictly validates `pr-review://open/owner/repo/number`: no query,
    /// fragment, or trailing slash; owner/repo non-empty; number positive.
    public static func endpoint(from url: URL) -> String? {
        guard url.query == nil, url.fragment == nil else { return nil }
        // URL parsing normalizes a trailing slash away; reject it explicitly.
        guard !url.absoluteString.hasSuffix("/") else { return nil }
        guard let host = url.host, host == "open" else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // The path must be exactly "/owner/repo/number" (a leading "/" then
        // three non-empty components); empty segments are rejected.
        guard parts.first == "" else { return nil }
        let segments = Array(parts.dropFirst())
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        let owner = segments[0]
        let repo = segments[1]
        guard let number = Int(segments[2]), number > 0 else { return nil }
        return "\(owner)/\(repo)#\(number)"
    }
}
