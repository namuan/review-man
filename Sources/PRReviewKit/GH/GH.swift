import Foundation

public enum GitHubError: Error, CustomStringConvertible {
    /// gh CLI is not installed or not authenticated.
    case ghUnavailable(String)
    /// A user-selected gh executable is no longer usable.
    case staleSelectedExecutable(String)
    /// A gh subprocess exited non-zero.
    case commandFailed(command: String, stderr: String)
    /// gh ran but returned a GraphQL/API error payload.
    case api(String)
    /// Response could not be decoded.
    case parse(String)
    /// The process timed out.
    case timeout(String)

    public var description: String {
        switch self {
        case .ghUnavailable(let s):
            return s
        case .staleSelectedExecutable(let s):
            return s
        case .commandFailed(let cmd, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed: \(cmd)" + (trimmed.isEmpty ? "" : "\n\(trimmed)")
        case .api(let s):
            return "GitHub API error: \(s)"
        case .parse(let s):
            return "Parse error: \(s)"
        case .timeout(let s):
            return "Timed out: \(s)"
        }
    }
}

/// A completed `gh` invocation: raw stdout plus bounded stderr text.
public enum GH {

    public struct Result {
        public let data: Data
        public let stderr: String
    }

    public static let defaultTimeout: TimeInterval = 120
}

/// Asynchronous command execution seam. The production implementation spawns
/// the resolved `gh` executable, supports cancellation (which terminates the
/// child), enforces a timeout, writes output to private temporary files, and
/// removes them on every path. Tests inject a scripted fake.
public protocol CommandRunning {
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> GH.Result
}

/// Default production command runner: resolves one absolute `gh` executable
/// path (cached per runner) and executes every command against it.
public struct SystemCommandRunner: CommandRunning {

    private let resolver: GitHubExecutableResolving
    private let temporaryDirectory: URL

    public init(
        resolver: GitHubExecutableResolving = GitHubExecutableResolver(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.resolver = resolver
        self.temporaryDirectory = temporaryDirectory
    }

    public func run(_ arguments: [String], timeout: TimeInterval = GH.defaultTimeout) async throws -> GH.Result {
        let executable = try resolver.resolveExecutable()
        return try await CommandProcess.run(
            executableURL: executable,
            arguments: arguments,
            timeout: timeout,
            directory: temporaryDirectory
        )
    }
}
