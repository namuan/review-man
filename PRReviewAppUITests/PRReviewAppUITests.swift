import XCTest

/// Demo-mode UI tests for the desktop app. All tests launch the real app with
/// `--demo` (or the welcome button) and use stable accessibility identifiers.
/// They require an interactive macOS session; CI without a display cannot run
/// them (recorded as manual/pending until a maintained runner exists).
final class PRReviewAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--swiftui-diff"]
        app.launch()
        return app
    }

    private func launchDefaultDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        return app
    }

    func testOpenDemoViaLaunchArgument() {
        let app = launchDefaultDemo()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["file-sidebar"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["change-canvas-pane"].exists)
    }

    func testDefaultRendererUsesAppKitSurface() {
        let app = launchDefaultDemo()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'canvas-file-'"))
            .firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        firstCard.click()
        XCTAssertTrue(app.descendants(matching: .any)["diff-pane-appkit-surface"].waitForExistence(timeout: 10))
    }

    func testOpenDemoViaWelcomeButton() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["open-demo-button"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 10))
        demoButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
    }

    func testFilterFilesInSidebar() {
        let app = launchDemo()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
        let searchField = app.textFields["sidebar-file-filter"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.click()
        searchField.typeText("README")
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-row-README.md"].waitForExistence(timeout: 5))
    }

    func testAddDraftViaToolbarComment() {
        let app = launchDemo()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
        // The canvas is the default overview. Open one file card, then click a
        // diff line (identifiers are keyed: diff-line-<path>-h<hunk>-…).
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'canvas-file-'"))
            .firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        firstCard.click()
        let firstLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'diff-line-'"))
            .firstMatch
        XCTAssertTrue(firstLine.waitForExistence(timeout: 10))
        firstLine.click()
        let commentButton = app.buttons["toolbar-comment"]
        XCTAssertTrue(commentButton.isEnabled)
        commentButton.click()
        XCTAssertTrue(app.textViews["draft-editor"].waitForExistence(timeout: 5))
    }

    func testSubmitSheetPresentsInDemoAndShowsNonSubmissionBanner() {
        let app = launchDemo()
        XCTAssertTrue(app.descendants(matching: .any)["pr-header"].waitForExistence(timeout: 10))
        app.buttons["toolbar-submit"].click()
        XCTAssertTrue(app.textViews["submit-body-editor"].waitForExistence(timeout: 5))
        app.buttons["submit-button"].click()
        // In demo mode the review is not submitted; a nonmodal banner appears.
        XCTAssertTrue(app.descendants(matching: .any)["status-banner"].waitForExistence(timeout: 5))
    }
}
