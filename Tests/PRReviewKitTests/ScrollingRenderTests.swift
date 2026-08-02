import XCTest
@testable import PRReviewKit

final class ScrollingRenderTests: XCTestCase {

    /// Builds a model with a single file of `lineCount` context lines.
    private func tallModel(lineCount: Int) -> AppModel {
        var lines: [String] = [
            "diff --git a/tall.txt b/tall.txt",
            "--- a/tall.txt",
            "+++ b/tall.txt",
            "@@ -1,\(lineCount) +1,\(lineCount) @@",
        ]
        for i in 1...lineCount {
            lines.append(" marker-line-\(i)")
        }
        let model = AppModel()
        model.files = DiffParser.parse(lines.joined(separator: "\n"))
        model.rebuildRows()
        return model
    }

    func testScrolledRenderingShowsLastRows() {
        let model = tallModel(lineCount: 150)
        let rows = model.fileRows
        XCTAssertEqual(rows.count, 151) // 1 hunk header + 150 lines

        // Scroll so the window is full and the cursor sits on the last row.
        let m = AppLayout.metrics(screenW: 100, screenH: 30)
        let visibleH = m.diffH - 1
        model.cursorRow = rows.count - 1
        model.scrollRow = max(0, rows.count - visibleH)

        let screen = Screen(width: 100, height: 30)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("marker-line-150"), "last line should be rendered when scrolled down")
        XCTAssertTrue(dump.contains("marker-line-145"), "lines near the bottom should be visible too")
    }

    func testScrolledRenderingShowsMiddleRows() {
        let model = tallModel(lineCount: 200)
        let rows = model.fileRows
        // Scroll to a middle band and select a row there.
        model.cursorRow = 100
        model.scrollRow = 90
        let screen = Screen(width: 100, height: 30)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("marker-line-100"))
        XCTAssertFalse(dump.contains("marker-line-150"), "rows far below the viewport must not render")
        XCTAssertFalse(dump.contains("marker-line-40"), "rows far above the viewport must not render")
    }

    func testGOnTallFileKeepsPaneFilled() {
        let model = tallModel(lineCount: 400)
        let m = AppLayout.metrics(screenW: 100, screenH: 24)
        let visibleH = m.diffH - 1
        model.cursorRow = model.fileRows.count - 1
        model.scrollRow = max(0, model.fileRows.count - visibleH)
        let screen = Screen(width: 100, height: 24)
        AppView.render(model: model, into: screen)
        let dump = screen.debugDump()
        XCTAssertTrue(dump.contains("marker-line-400"))
        XCTAssertTrue(dump.contains("marker-line-390"))
    }

    func testExpiredMessageDoesNotLeaveStaleText() {
        let model = DemoData.makeDemoModel()
        model.setMessage("temporary notice", duration: 1)
        // First frame: message visible.
        let s1 = Screen(width: 100, height: 30)
        AppView.render(model: model, into: s1)
        XCTAssertTrue(s1.debugDump().contains("temporary notice"))
        // Message expires; second frame must not contain it.
        model.messageUntil = Date().addingTimeInterval(-1)
        model.message = nil
        let s2 = Screen(width: 100, height: 30)
        AppView.render(model: model, into: s2)
        XCTAssertFalse(s2.debugDump().contains("temporary notice"))
    }
}
