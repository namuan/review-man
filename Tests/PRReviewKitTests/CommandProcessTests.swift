import XCTest
@testable import PRReviewKit

/// A resolver that always returns a fixed executable URL (test double).
private struct FixedResolver: GitHubExecutableResolving {
    let url: URL
    func resolveExecutable() throws -> URL { url }
}

final class CommandProcessTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func contents(of dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: - Cancellation

    func testCancellationTerminatesChildAndCleansUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemCommandRunner(
            resolver: FixedResolver(url: URL(fileURLWithPath: "/bin/sleep")),
            temporaryDirectory: dir
        )

        let task = Task { try await runner.run(["30"], timeout: 60) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(contents(of: dir).isEmpty, "temporary files must be removed on cancellation")
    }

    // MARK: - Timeout

    func testTimeoutTerminatesChildAndCleansUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemCommandRunner(
            resolver: FixedResolver(url: URL(fileURLWithPath: "/bin/sleep")),
            temporaryDirectory: dir
        )

        do {
            _ = try await runner.run(["30"], timeout: 0.3)
            XCTFail("expected timeout")
        } catch let error as GitHubError {
            guard case .timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(contents(of: dir).isEmpty, "temporary files must be removed on timeout")
    }

    // MARK: - Success and cleanup

    func testSuccessfulCommandReturnsOutputAndCleansUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemCommandRunner(
            resolver: FixedResolver(url: URL(fileURLWithPath: "/bin/echo")),
            temporaryDirectory: dir
        )

        let result = try await runner.run(["hello world"], timeout: 5)
        XCTAssertEqual(String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
        XCTAssertTrue(contents(of: dir).isEmpty, "temporary files must be removed on success")
    }

    // MARK: - Secure files

    func testSecureTemporaryFileHasPrivatePermissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try SecureTemporaryFile.make(prefix: "prr-test", in: dir)
        defer { try? FileManager.default.removeItem(at: url) }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testPayloadTempFileHasPrivatePermissions() throws {
        let path = try PayloadBuilder.writeJSONToTemp(["a": 1])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    // MARK: - Diagnostics

    func testDiagnosticLabelHidesVariablesAndBodies() {
        // GraphQL variables, cursors, and query text must never leak into
        // diagnostic labels.
        XCTAssertEqual(
            CommandProcess.label(for: ["api", "graphql", "-f", "query=secret", "-F", "token=abc123"]),
            "gh api"
        )
        XCTAssertEqual(CommandProcess.label(for: []), "gh cli")
        XCTAssertEqual(CommandProcess.label(for: ["pr", "view"]), "gh pr")
    }

    // MARK: - Resolver caching

    func testResolverCachesSingleAbsoluteExecutable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ghURL = bin.appendingPathComponent("gh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: ghURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghURL.path)

        let resolver = GitHubExecutableResolver(path: bin.path)
        let first = try resolver.resolveExecutable()
        // Delete the executable: a cached resolver must not re-probe the FS.
        try FileManager.default.removeItem(at: ghURL)
        let second = try resolver.resolveExecutable()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ghURL.resolvingSymlinksInPath())
    }

    func testLaunchFailureCleansUpTempFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemCommandRunner(
            resolver: FixedResolver(url: URL(fileURLWithPath: "/nonexistent/prr-missing-gh")),
            temporaryDirectory: dir
        )

        do {
            _ = try await runner.run(["x"], timeout: 5)
            XCTFail("expected a launch failure")
        } catch {
            // Any launch/exec error is expected.
        }
        XCTAssertTrue(contents(of: dir).isEmpty, "temporary files must be removed on launch failure")
    }

    func testResolverThrowsActionableErrorWhenMissing() {
        let resolver = GitHubExecutableResolver(path: "/nonexistent-dir", fallbacks: [])
        XCTAssertThrowsError(try resolver.resolveExecutable()) { error in
            guard case GitHubError.ghUnavailable(let message) = error else {
                return XCTFail("expected ghUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("brew install gh"))
        }
    }
}
