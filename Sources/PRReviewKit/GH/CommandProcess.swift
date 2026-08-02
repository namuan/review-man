import Foundation

// MARK: - gh executable resolution

/// Resolves the absolute path of the `gh` executable once per runner lifetime.
public protocol GitHubExecutableResolving {
    func resolveExecutable() throws -> URL
}

/// Where a resolved executable was found.
public enum GitHubExecutableSource: Equatable, Sendable {
    case selected
    case inheritedPath
    case appleSiliconHomebrew
    case intelHomebrew
    case macPorts
}

/// A resolved `gh` plus its discovery source (for dependency-status UI).
public struct GitHubExecutableInfo: Equatable, Sendable {
    public let url: URL
    public let source: GitHubExecutableSource

    public init(url: URL, source: GitHubExecutableSource) {
        self.url = url
        self.source = source
    }
}

/// Optional inspection surface for resolvers that can report metadata.
public protocol GitHubExecutableInspecting {
    func resolveExecutableInfo() throws -> GitHubExecutableInfo
}

/// Resolves `gh` from (in order): a user-selected override, the inherited
/// `PATH`, Apple Silicon Homebrew, Intel Homebrew, and MacPorts. The first
/// executable candidate is cached for the runner lifetime (single-flight);
/// `invalidateCache()` forces a rescan (Re-check, preference changes).
public final class GitHubExecutableResolver: GitHubExecutableResolving, GitHubExecutableInspecting {

    /// Fixed fallback locations probed after the inherited PATH.
    public static let fallbackDirectories: [(source: GitHubExecutableSource, path: String)] = [
        (.appleSiliconHomebrew, "/opt/homebrew/bin"),
        (.intelHomebrew, "/usr/local/bin"),
        (.macPorts, "/opt/local/bin"),
    ]

    private let lock = NSLock()
    private var cached: GitHubExecutableInfo?
    private let path: String
    private let overrideURL: URL?
    private let fallbacks: [(source: GitHubExecutableSource, path: String)]

    public init(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        overrideURL: URL? = nil,
        fallbacks: [(source: GitHubExecutableSource, path: String)] = GitHubExecutableResolver.fallbackDirectories
    ) {
        self.path = path
        self.overrideURL = overrideURL
        self.fallbacks = fallbacks
    }

    public func resolveExecutable() throws -> URL {
        try resolveExecutableInfo().url
    }

    public func resolveExecutableInfo() throws -> GitHubExecutableInfo {
        // A user-selected override is re-verified on every resolve: a stale
        // selection must fail loudly rather than silently switching to
        // another `gh` (which would use a different account/configuration).
        if let overrideURL {
            let fm = FileManager.default
            guard fm.isExecutableFile(atPath: overrideURL.path) else {
                throw GitHubError.staleSelectedExecutable(
                    "The selected `gh` executable is no longer usable: \(overrideURL.path)\n"
                    + "Locate a valid GitHub CLI or clear the selection."
                )
            }
            let info = GitHubExecutableInfo(url: overrideURL.resolvingSymlinksInPath(), source: .selected)
            lock.lock()
            cached = info
            lock.unlock()
            return info
        }

        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // The scan runs while holding the lock, so concurrent first resolves
        // are single-flight: only one scans, and the rest hit the cache.
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let fm = FileManager.default

        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: dir)
                .appendingPathComponent("gh")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: candidate.path) else { continue }
            let info = GitHubExecutableInfo(url: candidate, source: .inheritedPath)
            cached = info
            return info
        }
        for fallback in fallbacks {
            let candidate = URL(fileURLWithPath: fallback.path)
                .appendingPathComponent("gh")
                .resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: candidate.path) else { continue }
            let info = GitHubExecutableInfo(url: candidate, source: fallback.source)
            cached = info
            return info
        }
        throw GitHubError.ghUnavailable(
            "The `gh` GitHub CLI is required but was not found.\n"
            + "Install it with:  brew install gh\n"
            + "Then authenticate with:  gh auth login"
        )
    }

    /// Forces the next resolution to rescan (after a preference change or a
    /// failed `--version`).
    public func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

// MARK: - Secure temporary files

/// Creates private (0600) temporary files. Payload, stdout, and stderr files
/// are all created through here so no intermediate file ever carries default
/// permissions, and callers are responsible for removing every created URL on
/// every completion path.
public enum SecureTemporaryFile {

    @discardableResult
    public static func make(
        prefix: String,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw GitHubError.commandFailed(
                command: prefix,
                stderr: "could not create a private temporary file"
            )
        }
        return url
    }
}

// MARK: - Async process execution

/// Runs one child process with Swift Concurrency semantics: the caller can be
/// cancelled (which terminates the child), a timeout terminates the child,
/// output is captured in secure temporary files, and files are removed on
/// every completion path.
final class CommandProcess {

    /// The single terminal outcome of a run.
    private enum Outcome {
        case success(GH.Result)
        case failure(Error)
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        directory: URL
    ) async throws -> GH.Result {
        let coordinator = Coordinator(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            directory: directory
        )
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.install(continuation)
                coordinator.start()
            }
        }, onCancel: {
            coordinator.cancel()
        })
    }

    /// Lock-protected single-finish state machine. Timeout, cancellation, the
    /// process termination handler, and launch all race; the lock guarantees
    /// exactly one terminal outcome.
    private final class Coordinator {

        private let lock = NSLock()
        private let executableURL: URL
        private let arguments: [String]
        private let timeout: TimeInterval
        private let directory: URL

        private var continuation: CheckedContinuation<GH.Result, Error>?
        private var process: Process?
        private var outHandle: FileHandle?
        private var errHandle: FileHandle?
        private var outURL: URL?
        private var errURL: URL?
        private var timeoutTask: Task<Void, Never>?
        private var ended = false
        private var cancelRequested = false
        private var timedOut = false

        init(
            executableURL: URL,
            arguments: [String],
            timeout: TimeInterval,
            directory: URL
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.timeout = timeout
            self.directory = directory
        }

        func install(_ continuation: CheckedContinuation<GH.Result, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        /// Cancellation signal from `withTaskCancellationHandler`. Terminates
        /// the child if it is already running; if it has not launched yet,
        /// `start()` observes `cancelRequested` and terminates immediately
        /// after launching.
        func cancel() {
            lock.lock()
            cancelRequested = true
            let proc = process
            lock.unlock()
            proc?.terminate()
        }

        func start() {
            lock.lock()
            let out: URL
            let err: URL
            do {
                out = try SecureTemporaryFile.make(prefix: "prr-out", in: directory)
                err = try SecureTemporaryFile.make(prefix: "prr-err", in: directory)
                outURL = out
                errURL = err
                let outHandle = try FileHandle(forWritingTo: out)
                let errHandle = try FileHandle(forWritingTo: err)
                self.outHandle = outHandle
                self.errHandle = errHandle

                let proc = Process()
                proc.executableURL = executableURL
                proc.arguments = arguments
                proc.standardOutput = outHandle
                proc.standardError = errHandle
                proc.terminationHandler = { [weak self] _ in
                    self?.processFinished()
                }
                try proc.run()
                process = proc

                if cancelRequested {
                    proc.terminate()
                } else if timeout > 0 {
                    let t = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            self?.timedOutTrigger()
                        } catch {
                            // Cancelled (the run finished first): do nothing.
                        }
                    }
                    timeoutTask = t
                }
                lock.unlock()
            } catch {
                lock.unlock()
                finish(.failure(error))
            }
        }

        private func timedOutTrigger() {
            lock.lock()
            guard !ended else {
                lock.unlock()
                return
            }
            timedOut = true
            let proc = process
            lock.unlock()
            proc?.terminate()
        }

        private func processFinished() {
            // Called on the process termination thread.
            lock.lock()
            guard !ended else {
                lock.unlock()
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil

            let fm = FileManager.default
            try? outHandle?.close()
            try? errHandle?.close()
            outHandle = nil
            errHandle = nil

            let data = (outURL).flatMap { fm.contents(atPath: $0.path) } ?? Data()
            let errText = (errURL).flatMap { fm.contents(atPath: $0.path) }
                .map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
            if let outURL { try? fm.removeItem(at: outURL) }
            if let errURL { try? fm.removeItem(at: errURL) }
            self.outURL = nil
            self.errURL = nil

            let status = process?.terminationStatus ?? -1
            let outcome: Outcome
            if cancelRequested {
                outcome = .failure(CancellationError())
            } else if timedOut {
                outcome = .failure(GitHubError.timeout(CommandProcess.label(for: arguments)))
            } else if status != 0 {
                outcome = .failure(GitHubError.commandFailed(
                    command: CommandProcess.label(for: arguments),
                    stderr: errText
                ))
            } else {
                outcome = .success(GH.Result(data: data, stderr: errText))
            }
            ended = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume(with: Self.result(from: outcome))
        }

        private func finish(_ outcome: Outcome) {
            lock.lock()
            guard !ended else {
                lock.unlock()
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            let fm = FileManager.default
            try? outHandle?.close()
            try? errHandle?.close()
            outHandle = nil
            errHandle = nil
            if let outURL { try? fm.removeItem(at: outURL) }
            if let errURL { try? fm.removeItem(at: errURL) }
            self.outURL = nil
            self.errURL = nil
            ended = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume(with: Self.result(from: outcome))
        }

        private static func result(from outcome: Outcome) -> Result<GH.Result, Error> {
            switch outcome {
            case .success(let r): return .success(r)
            case .failure(let e): return .failure(e)
            }
        }
    }

    /// Sanitized diagnostic label: reveals only the `gh` subcommand, never
    /// arguments that could carry credentials, secrets, or GraphQL variables.
    static func label(for arguments: [String]) -> String {
        let subcommand = arguments.first ?? "cli"
        return "gh \(subcommand)"
    }
}
