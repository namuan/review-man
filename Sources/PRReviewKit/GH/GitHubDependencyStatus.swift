import Foundation

/// Actionable health of the `gh` dependency for the desktop app.
public struct GitHubDependencyStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case checking
        case ready
        case missing
        case unusable
        case unauthenticated
        case expiredOrRevoked
        case underScoped
        case unknownFailure
    }

    public let state: State
    public let executableURL: URL?
    public let source: GitHubExecutableSource?
    public let version: String?
    public let account: String?
    public let scopeNote: String?
    /// Bounded, user-safe diagnostic message.
    public let message: String?

    public init(
        state: State,
        executableURL: URL? = nil,
        source: GitHubExecutableSource? = nil,
        version: String? = nil,
        account: String? = nil,
        scopeNote: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.executableURL = executableURL
        self.source = source
        self.version = version
        self.account = account
        self.scopeNote = scopeNote
        self.message = message
    }
}

/// Runs the direct, shell-free `gh` health checks: version, auth status, and a
/// minimal authenticated API request. Only definitive evidence is classified;
/// fine-grained tokens without classic OAuth scope headers are NOT rejected.
public struct GitHubDependencyChecker {

    public let runner: CommandRunning
    public let resolver: GitHubExecutableResolving & GitHubExecutableInspecting

    public init(
        runner: CommandRunning,
        resolver: GitHubExecutableResolving & GitHubExecutableInspecting
    ) {
        self.runner = runner
        self.resolver = resolver
    }

    public func check() async -> GitHubDependencyStatus {
        let info: GitHubExecutableInfo
        do {
            info = try resolver.resolveExecutableInfo()
        } catch let error as GitHubError {
            switch error {
            case .staleSelectedExecutable:
                return GitHubDependencyStatus(
                    state: .unusable,
                    message: "The selected `gh` executable is no longer usable. Locate a valid GitHub CLI or clear the selection."
                )
            default:
                return GitHubDependencyStatus(
                    state: .missing,
                    message: "The GitHub CLI was not found. Install it with `brew install gh`, then authenticate with `gh auth login`."
                )
            }
        } catch {
            return GitHubDependencyStatus(
                state: .missing,
                message: "The GitHub CLI was not found. Install it with `brew install gh`, then authenticate with `gh auth login`."
            )
        }

        // 1. gh --version
        let versionResult: GH.Result
        do {
            versionResult = try await runner.run(["--version"], timeout: 30)
        } catch is CancellationError {
            return GitHubDependencyStatus(state: .checking, executableURL: info.url, source: info.source)
        } catch {
            return GitHubDependencyStatus(
                state: .unusable,
                executableURL: info.url,
                source: info.source,
                message: "The detected `gh` could not run. Locate a valid GitHub CLI or clear the selection."
            )
        }
        let versionLine = String(data: versionResult.data, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)
        let version = versionLine.flatMap { parseVersion($0) }

        // 2. gh auth status --hostname github.com --active
        let authResult: GH.Result
        do {
            authResult = try await runner.run(
                ["auth", "status", "--hostname", "github.com", "--active"], timeout: 30
            )
        } catch is CancellationError {
            return GitHubDependencyStatus(state: .checking, executableURL: info.url, source: info.source)
        } catch {
            return classifyAuthFailure(info: info, version: version, error: error)
        }
        if authResult.data.isEmpty && authResult.stderr.isEmpty {
            return GitHubDependencyStatus(
                state: .unknownFailure, executableURL: info.url, source: info.source, version: version,
                message: "`gh auth status` produced no output."
            )
        }

        // 3. Minimal authenticated API request: decode only the login.
        let apiResult: GH.Result
        do {
            apiResult = try await runner.run(["api", "user", "--include"], timeout: 30)
        } catch is CancellationError {
            return GitHubDependencyStatus(state: .checking, executableURL: info.url, source: info.source)
        } catch {
            return classifyApiFailure(info: info, version: version, error: error)
        }

        guard let account = parseLogin(from: apiResult.data) else {
            return GitHubDependencyStatus(
                state: .unknownFailure, executableURL: info.url, source: info.source, version: version,
                message: "The authenticated API request returned an unexpected response."
            )
        }
        let scopeAssessment = scopeAssessment(apiResult: apiResult)
        let state: GitHubDependencyStatus.State
        switch scopeAssessment {
        case .underScoped: state = .underScoped
        case .ready: state = .ready
        }
        return GitHubDependencyStatus(
            state: state, executableURL: info.url, source: info.source,
            version: version, account: account,
            scopeNote: scopeAssessment.note
        )
    }

    // MARK: - Classification

    private func classifyAuthFailure(info: GitHubExecutableInfo, version: String?, error: Error) -> GitHubDependencyStatus {
        let text = "\(error)".lowercased()
        if text.contains("not logged in") || text.contains("authentication required") {
            return GitHubDependencyStatus(
                state: .unauthenticated, executableURL: info.url, source: info.source, version: version,
                message: "Not logged in to GitHub. Run `gh auth login`."
            )
        }
        if text.contains("expired") || text.contains("revoked") || text.contains("invalid token")
            || text.contains("token") && text.contains("unauthorized") {
            return GitHubDependencyStatus(
                state: .expiredOrRevoked, executableURL: info.url, source: info.source, version: version,
                message: "The GitHub credential is expired or revoked. Run `gh auth login` again."
            )
        }
        return GitHubDependencyStatus(
            state: .unauthenticated, executableURL: info.url, source: info.source, version: version,
            message: "`gh auth status` failed: \(sanitize(error))"
        )
    }

    private func classifyApiFailure(info: GitHubExecutableInfo, version: String?, error: Error) -> GitHubDependencyStatus {
        let text = "\(error)".lowercased()
        if text.contains("401") || text.contains("bad credentials") || text.contains("invalid token") {
            return GitHubDependencyStatus(
                state: .expiredOrRevoked, executableURL: info.url, source: info.source, version: version,
                message: "The GitHub credential was rejected. Run `gh auth login` again."
            )
        }
        if text.contains("403") || text.contains("forbidden") || text.contains("insufficient scopes") {
            return GitHubDependencyStatus(
                state: .underScoped, executableURL: info.url, source: info.source, version: version,
                message: "The GitHub token lacks permission. Grant `repo` scope or a fine-grained token with Pull requests read/write."
            )
        }
        return GitHubDependencyStatus(
            state: .unknownFailure, executableURL: info.url, source: info.source, version: version,
            message: "An authenticated API request failed: \(sanitize(error))"
        )
    }

    /// Scope assessment from the `--include` response headers, which gh may
    /// emit on stderr or stdout depending on version.
    private enum ScopeAssessment: Equatable {
        case ready(note: String)
        case underScoped(note: String)

        var note: String {
            switch self {
            case .ready(let note), .underScoped(let note): return note
            }
        }
    }

    private func scopeAssessment(apiResult: GH.Result) -> ScopeAssessment {
        let headers = headerText(apiResult)
        guard let scopesLine = headers.first(where: { $0.lowercased().hasPrefix("x-oauth-scopes:") }) else {
            // Fine-grained tokens / GitHub App tokens report no classic scopes.
            return .ready(note: "Not reported; repository access is checked when opening a PR.")
        }
        let scopesText = String(scopesLine.dropFirst("x-oauth-scopes:".count))
        // Exact scope matching: the full "repo" scope is required. public_repo
        // or repo:status are NOT the full repo scope.
        let scopes = scopesText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        if scopes.contains("repo") {
            return .ready(note: "Classic token with repo scope.")
        }
        return .underScoped(note: "Classic token without the full repo scope; private-repository review will fail.")
    }

    /// Collects response headers from both stderr and stdout (--include
    /// placement varies by gh version).
    private func headerText(_ apiResult: GH.Result) -> [String] {
        let stderrText = apiResult.stderr.split(separator: "\n").map(String.init)
        let stdoutText = String(data: apiResult.data, encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? []
        return stderrText + stdoutText
    }

    private func parseVersion(_ line: String) -> String? {
        // e.g. "gh version 2.88.1 (2026-03-12)"
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "gh", parts[1] == "version" else { return nil }
        return String(parts[2])
    }

    private func parseLogin(from data: Data) -> String? {
        // With --include, response headers may precede the JSON body on
        // stdout; find the JSON object and decode only that.
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let jsonStart = text.firstIndex(of: "{") else { return nil }
        let jsonBody = String(text[jsonStart...])
        guard let obj = try? JSONSerialization.jsonObject(
            with: Data(jsonBody.utf8)
        ) as? [String: Any], let login = obj["login"] as? String else {
            return nil
        }
        return login
    }

    /// Bounded diagnostic: truncates and redacts tokens, authorization
    /// headers, and credential-shaped strings.
    private func sanitize(_ error: Error) -> String {
        var text = String(String(describing: error).prefix(400))
        let tokenPatterns = ["gho_\\w+", "ghp_\\w+", "github_pat_\\w+", "(?i)authorization:\\s*\\S+"]
        for pattern in tokenPatterns {
            text = text.replacingOccurrences(
                of: pattern, with: "[redacted]", options: .regularExpression
            )
        }
        return text
    }
}
