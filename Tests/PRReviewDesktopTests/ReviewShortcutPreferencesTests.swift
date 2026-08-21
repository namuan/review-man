import XCTest
@testable import PRReviewDesktop

@MainActor
final class ReviewShortcutPreferencesTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        let name = "prr-shortcuts-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    func testDefaultsMatchTheExistingCommands() {
        let preferences = ReviewShortcutPreferences(defaults: makeSuite())

        XCTAssertEqual(
            preferences.shortcut(for: .toggleDiffLayout),
            ReviewShortcut(key: "d", modifiers: [.command, .control, .option])
        )
        XCTAssertEqual(
            preferences.shortcut(for: .toggleSidebar),
            ReviewShortcut(key: "s", modifiers: [.command, .control])
        )
    }

    func testSelectionPersistsAcrossInstances() {
        let defaults = makeSuite()
        let shortcut = ReviewShortcut(key: "l", modifiers: [.command, .option])
        let preferences = ReviewShortcutPreferences(defaults: defaults)

        XCTAssertTrue(preferences.set(shortcut, for: .toggleDiffLayout))

        let restored = ReviewShortcutPreferences(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .toggleDiffLayout), shortcut)
    }

    func testDuplicateShortcutIsRejected() {
        let preferences = ReviewShortcutPreferences(defaults: makeSuite())
        let sidebarShortcut = preferences.shortcut(for: .toggleSidebar)

        XCTAssertFalse(preferences.set(sidebarShortcut, for: .toggleDiffLayout))
        XCTAssertEqual(
            preferences.shortcut(for: .toggleDiffLayout),
            ReviewShortcut(key: "d", modifiers: [.command, .control, .option])
        )
    }

    func testRestoreDefaultsClearsCustomValues() {
        let defaults = makeSuite()
        let preferences = ReviewShortcutPreferences(defaults: defaults)
        XCTAssertTrue(preferences.set(ReviewShortcut(key: "l", modifiers: [.command, .option]), for: .toggleDiffLayout))

        preferences.restoreDefaults()

        XCTAssertEqual(
            preferences.shortcut(for: .toggleDiffLayout),
            ReviewShortcut(key: "d", modifiers: [.command, .control, .option])
        )
        XCTAssertEqual(
            ReviewShortcutPreferences(defaults: defaults).shortcut(for: .toggleDiffLayout),
            ReviewShortcut(key: "d", modifiers: [.command, .control, .option])
        )
    }
}
