import XCTest
@testable import PRReviewKit

final class ScreenDumpTests: XCTestCase {

    func testDemoFrameContainsExpectedContent() {
        let model = DemoData.makeDemoModel()
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("PR #482"), "frame should show PR number")
        XCTAssertTrue(dump.contains("Add terminal UI skeleton"), "frame should show PR title")
        XCTAssertTrue(dump.contains("Sources/PRReview/App.swift"), "file list should show the app file")
        XCTAssertTrue(dump.contains("README.md"), "file list should show README")
        XCTAssertTrue(dump.contains("maintainer-jane"), "thread author should be visible")
        XCTAssertTrue(dump.contains("Terminal.swift"), "diff pane should show current file path")
    }

    func testFileSelectionSwitchesDiff() {
        let model = DemoData.makeDemoModel()
        // select the Terminal.swift file (index 1)
        model.selectedFile = 1
        model.cursorRow = 0
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("import Darwin"))
        XCTAssertTrue(dump.contains("enable raw mode"))
    }

    func testDraftShowsInFrame() {
        let model = DemoData.makeDemoModel()
        model.drafts = [DraftComment(
            path: "Sources/PRReview/App.swift", line: 9, side: "RIGHT", body: "Should this be lazy?"
        )]
        model.rebuildRows()
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("Should this be lazy?"))
        XCTAssertTrue(dump.contains("draft"))
    }

    func testEditorOverlayRenders() {
        let model = DemoData.makeDemoModel()
        model.mode = .edit
        model.editorTarget = .newDraft(
            path: "Sources/PRReview/App.swift", line: 9, side: "RIGHT",
            startLine: nil, startSide: nil
        )
        model.editor = TextEditor(text: "a comment")
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("Comment on Sources/PRReview/App.swift:9"))
        XCTAssertTrue(dump.contains("a comment"))
    }

    func testComposerOverlayRenders() {
        let model = DemoData.makeDemoModel()
        model.mode = .compose
        model.drafts = [DraftComment(path: "x", line: 1, side: "RIGHT", body: "draft body")]
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("Submit review"))
        XCTAssertTrue(dump.contains("Approve"))
        XCTAssertTrue(dump.contains("draft body"))
    }

    func testHelpOverlayRenders() {
        let model = DemoData.makeDemoModel()
        model.mode = .help
        let screen = Screen(width: 100, height: 36)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("Key bindings"))
        XCTAssertTrue(dump.contains("submit review"))
    }
}
