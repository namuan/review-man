import XCTest
@testable import PRReviewKit

// MARK: - Resolver ordering and override

final class ResolverPhase8Tests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutable(in dir: URL, name: String = "gh") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\necho gh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testOverrideTakesPrecedenceOverPathAndFallbacks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let override = try makeExecutable(in: dir, name: "custom-gh")
        let pathDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: pathDir) }
        let pathGH = try makeExecutable(in: pathDir)

        let resolver = GitHubExecutableResolver(
            path: pathDir.path,
            overrideURL: override,
            fallbacks: []
        )
        let info = try resolver.resolveExecutableInfo()
        XCTAssertEqual(info.url.path, override.resolvingSymlinksInPath().path)
        XCTAssertEqual(info.source, .selected)
        XCTAssertNotEqual(info.url.path, pathGH.path)
    }

    func testPathPrecedesHomebrewFallbacks() throws {
        let pathDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: pathDir) }
        let pathGH = try makeExecutable(in: pathDir)
        let homebrewDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: homebrewDir) }
        let homebrewGH = try makeExecutable(in: homebrewDir)

        let resolver = GitHubExecutableResolver(
            path: pathDir.path,
            fallbacks: [(.appleSiliconHomebrew, homebrewDir.path)]
        )
        let info = try resolver.resolveExecutableInfo()
        XCTAssertEqual(info.url.path, pathGH.path)
        XCTAssertEqual(info.source, .inheritedPath)
    }

    func testHomebrewFallbackUsedWhenPathMisses() throws {
        let homebrewDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: homebrewDir) }
        let homebrewGH = try makeExecutable(in: homebrewDir)

        let resolver = GitHubExecutableResolver(
            path: "/nonexistent-path",
            fallbacks: [(.appleSiliconHomebrew, homebrewDir.path)]
        )
        let info = try resolver.resolveExecutableInfo()
        XCTAssertEqual(info.url.path, homebrewGH.path)
        XCTAssertEqual(info.source, .appleSiliconHomebrew)
    }

    func testStaleOverrideFailsWithActionableError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let override = try makeExecutable(in: dir)
        let resolver = GitHubExecutableResolver(path: "/nonexistent", overrideURL: override, fallbacks: [])
        _ = try resolver.resolveExecutable()
        // Delete the override; resolution must now fail (not silently fall
        // back to another gh).
        try FileManager.default.removeItem(at: override)
        XCTAssertThrowsError(try resolver.resolveExecutable())
    }

    func testInvalidateCacheForcesRescan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghURL = try makeExecutable(in: dir)
        let resolver = GitHubExecutableResolver(path: dir.path, fallbacks: [])
        XCTAssertNotNil(try? resolver.resolveExecutable())

        // After invalidation the cached success is dropped (the scan still
        // finds gh, but the cache path is exercised).
        resolver.invalidateCache()
        XCTAssertNotNil(try? resolver.resolveExecutable())
    }
}

// MARK: - Health checker classification (scripted runner)

private final class ScriptedDependencyRunner: CommandRunning {
    enum Step {
        case result(GH.Result)
        case error(Error)
    }
    var steps: [Step] = []
    private(set) var calls: [[String]] = []

    func run(_ args: [String], timeout: TimeInterval) async throws -> GH.Result {
        calls.append(args)
        guard !steps.isEmpty else { return GH.Result(data: Data(), stderr: "") }
        switch steps.removeFirst() {
        case .result(let r): return r
        case .error(let e): throw e
        }
    }
}

private final class FixedExecutableResolver: GitHubExecutableResolving & GitHubExecutableInspecting {
    let info: GitHubExecutableInfo
    var error: Error?
    init(info: GitHubExecutableInfo) { self.info = info }
    func resolveExecutable() throws -> URL {
        if let error { throw error }
        return info.url
    }
    func resolveExecutableInfo() throws -> GitHubExecutableInfo {
        if let error { throw error }
        return info
    }
}

final class DependencyHealthTests: XCTestCase {

    private let info = GitHubExecutableInfo(url: URL(fileURLWithPath: "/opt/homebrew/bin/gh"), source: .appleSiliconHomebrew)

    private func versionResult(_ version: String = "gh version 2.88.1 (2026-03-12)") -> GH.Result {
        GH.Result(data: Data(version.utf8), stderr: "")
    }

    func testReadyStatusWithAccountAndScope() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(versionResult()),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in to github.com account octocat")),
            .result(GH.Result(data: Data(#"{"login":"octocat"}"#.utf8), stderr: "X-OAuth-Scopes: repo, workflow\nHTTP/2 200")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.account, "octocat")
        XCTAssertEqual(status.version, "2.88.1")
        XCTAssertTrue(status.scopeNote?.contains("repo") ?? false)
        // Command order: version → auth status → api user.
        XCTAssertEqual(runner.calls[0], ["--version"])
        XCTAssertEqual(runner.calls[1], ["auth", "status", "--hostname", "github.com", "--active"])
        XCTAssertEqual(runner.calls[2], ["api", "user", "--include"])
        // No shell is ever invoked.
        XCTAssertFalse(runner.calls.joined().contains { $0.contains("sh") || $0.contains("bash") || $0.contains("env") })
    }

    func testMissingResolver() async {
        let resolver = FixedExecutableResolver(info: info)
        resolver.error = GitHubError.ghUnavailable("missing")
        let status = await GitHubDependencyChecker(
            runner: ScriptedDependencyRunner(), resolver: resolver
        ).check()
        XCTAssertEqual(status.state, .missing)
        XCTAssertTrue(status.message?.contains("brew install gh") ?? false)
    }

    func testUnauthenticated() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(versionResult()),
            .error(GitHubError.commandFailed(command: "gh auth", stderr: "not logged in")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .unauthenticated)
    }

    func testExpiredOrRevokedOnAPI401() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(versionResult()),
            .result(GH.Result(data: Data(), stderr: "ok")),
            .error(GitHubError.commandFailed(command: "gh api", stderr: "HTTP 401: Bad credentials")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .expiredOrRevoked)
    }

    func testUnderScopedWhen403() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(versionResult()),
            .result(GH.Result(data: Data(), stderr: "ok")),
            .error(GitHubError.commandFailed(command: "gh api", stderr: "HTTP 403: insufficient scopes")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .underScoped)
    }

    func testMissingScopeHeaderNotTreatedAsUnderScoped() async {
        // A fine-grained token reports no classic OAuth scopes: must NOT be
        // classified as under-scoped.
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(versionResult()),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .result(GH.Result(data: Data(#"{"login":"bot"}"#.utf8), stderr: "HTTP/2 200")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.scopeNote?.contains("Not reported") ?? false)
    }
}

// MARK: - Additional classification coverage

final class DependencyHealthExtraTests: XCTestCase {

    private let info = GitHubExecutableInfo(url: URL(fileURLWithPath: "/usr/local/bin/gh"), source: .intelHomebrew)

    /// A classic token whose reported scopes lack `repo` is classified
    /// under-scoped (definitive evidence).
    func testClassicTokenWithoutRepoScopeIsUnderScoped() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(GH.Result(data: Data("gh version 2.1.0 (2024-01-01)".utf8), stderr: "")),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .result(GH.Result(data: Data(#"{"login":"u"}"#.utf8), stderr: "X-OAuth-Scopes: workflow\nHTTP/2 200")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .underScoped)
    }

    /// A successful API call with no decodable login is malformed → unknown.
    func testMalformedApiSuccessIsUnknownFailure() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(GH.Result(data: Data("gh version 2.1.0 (2024-01-01)".utf8), stderr: "")),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .result(GH.Result(data: Data("not json".utf8), stderr: "HTTP/2 200")),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .unknownFailure)
    }

    /// Diagnostics redact tokens and authorization values.
    func testDiagnosticsRedactSecrets() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(GH.Result(data: Data("gh version 2.1.0 (2024-01-01)".utf8), stderr: "")),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .error(GitHubError.commandFailed(
                command: "gh api",
                stderr: "Authorization: gho_abcdef123456\nHTTP 401: Bad credentials ghp_xYz789"
            )),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .expiredOrRevoked)
        XCTAssertFalse(status.message?.contains("gho_") ?? true)
        XCTAssertFalse(status.message?.contains("ghp_") ?? true)
    }

    /// A stale selected override maps to unusable (not missing).
    func testStaleSelectedOverrideIsUnusable() async {
        let runner = ScriptedDependencyRunner()
        let resolver = FixedExecutableResolver(info: info)
        resolver.error = GitHubError.staleSelectedExecutable("stale")
        let status = await GitHubDependencyChecker(runner: runner, resolver: resolver).check()
        XCTAssertEqual(status.state, .unusable)
    }
}



// MARK: - Header/body interleaving and exact scope matching

final class DependencyHealthHeaderTests: XCTestCase {

    private let info = GitHubExecutableInfo(url: URL(fileURLWithPath: "/usr/local/bin/gh"), source: .intelHomebrew)

    /// Headers on stdout (before the JSON body) must not break login parsing.
    func testHeadersOnStdoutDoNotBreakLoginParsing() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(GH.Result(data: Data("gh version 2.1.0 (2024-01-01)".utf8), stderr: "")),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .result(GH.Result(
                data: Data("HTTP/2 200\nX-OAuth-Scopes: repo, workflow\ncontent-type: application/json\n{\"login\":\"octocat\"}".utf8),
                stderr: ""
            )),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.account, "octocat", "headers on stdout must not break login parsing")
    }

    /// public_repo / repo:status must NOT satisfy the exact repo scope.
    func testPartialRepoScopesAreNotEnough() async {
        let runner = ScriptedDependencyRunner()
        runner.steps = [
            .result(GH.Result(data: Data("gh version 2.1.0 (2024-01-01)".utf8), stderr: "")),
            .result(GH.Result(data: Data(), stderr: "✓ Logged in")),
            .result(GH.Result(
                data: Data(#"{"login":"u"}"#.utf8),
                stderr: "X-OAuth-Scopes: public_repo, repo:status\nHTTP/2 200"
            )),
        ]
        let status = await GitHubDependencyChecker(
            runner: runner, resolver: FixedExecutableResolver(info: info)
        ).check()
        XCTAssertEqual(status.state, .underScoped, "public_repo and repo:status are not the repo scope")
    }
}
