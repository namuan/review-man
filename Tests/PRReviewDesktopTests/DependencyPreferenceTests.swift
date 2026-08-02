import XCTest
import PRReviewKit
@testable import PRReviewDesktop

final class GitHubExecutablePreferenceTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        let name = "prr-pref-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func makeExecutable(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("gh")
        try Data("#!/bin/sh\necho gh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testPersistsValidatedSelectionAndClears() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-pref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = try makeExecutable(in: dir)
        let defaults = makeSuite()
        let preference = GitHubExecutablePreference(defaults: defaults)

        XCTAssertTrue(preference.setSelectedExecutableURL(executable))
        XCTAssertEqual(preference.selectedExecutableURL?.path, executable.resolvingSymlinksInPath().path)

        preference.clearSelectedExecutableURL()
        XCTAssertNil(preference.selectedExecutableURL)
    }

    func testRejectsNonExecutableSelection() {
        let defaults = makeSuite()
        let preference = GitHubExecutablePreference(defaults: defaults)
        let missing = URL(fileURLWithPath: "/nonexistent/gh")
        XCTAssertFalse(preference.setSelectedExecutableURL(missing))
        XCTAssertNil(preference.selectedExecutableURL)
    }
}
