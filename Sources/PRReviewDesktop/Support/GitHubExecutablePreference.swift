import Foundation

/// Persists the user-selected `gh` executable override. Only the normalized
/// absolute path is stored (never contents, credentials, or bookmarks).
public final class GitHubExecutablePreference {

    public static let key = "PRReview.gitHubExecutableOverridePath"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedExecutableURL: URL? {
        guard let path = defaults.string(forKey: Self.key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Persists a validated executable selection (must exist and be
    /// executable). Returns false when the path is not a usable executable.
    @discardableResult
    public func setSelectedExecutableURL(_ url: URL) -> Bool {
        let normalized = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: normalized.path) else { return false }
        defaults.set(normalized.path, forKey: Self.key)
        return true
    }

    public func clearSelectedExecutableURL() {
        defaults.removeObject(forKey: Self.key)
    }
}
