import XCTest
@testable import PRReviewKit

final class TextEditorTests: XCTestCase {

    func testInitialText() {
        let e = TextEditor(text: "hello\nworld")
        XCTAssertEqual(e.lines, ["hello", "world"])
        XCTAssertEqual(e.text, "hello\nworld")
        XCTAssertEqual(e.row, 1)
        XCTAssertEqual(e.col, 5)
    }

    func testInsertNewlineBackspace() {
        var e = TextEditor()
        for c in "hello" { e.handle(.char(c)) }
        e.handle(.enter)
        for c in "world" { e.handle(.char(c)) }
        XCTAssertEqual(e.text, "hello\nworld")
        e.handle(.up)
        e.handle(.end)
        e.handle(.backspace)
        XCTAssertEqual(e.lines[0], "hell")
        e.handle(.backspace)
        XCTAssertEqual(e.lines[0], "hel")
    }

    func testBackspaceMergesLines() {
        var e = TextEditor(text: "ab\ncd")
        e.handle(.home) // row 1 (last line), col 0
        e.handle(.backspace) // merge "cd" onto "ab"
        XCTAssertEqual(e.lines, ["abcd"])
        XCTAssertEqual(e.row, 0)
        XCTAssertEqual(e.col, 2)
    }

    func testDeleteForwardMergesLines() {
        var e = TextEditor(text: "ab\ncd")
        e.handle(.up)  // row 0
        e.handle(.end) // col 2
        e.handle(.delete) // merge "cd" into line 0
        XCTAssertEqual(e.lines, ["abcd"])
    }

    func testHomeEndAndArrows() {
        var e = TextEditor(text: "hello")
        e.handle(.end)
        XCTAssertEqual(e.col, 5)
        e.handle(.left)
        XCTAssertEqual(e.col, 4)
        e.handle(.home)
        XCTAssertEqual(e.col, 0)
        e.handle(.char("X"))
        XCTAssertEqual(e.lines[0], "Xhello")
    }

    func testPaste() {
        var e = TextEditor()
        e.handle(.paste("multi\nline\ntext"))
        XCTAssertEqual(e.lines, ["multi", "line", "text"])
    }

    func testKillToEndAndLine() {
        var e = TextEditor(text: "hello world")
        e.handle(.home)
        e.handle(.ctrl("k"))
        XCTAssertEqual(e.lines[0], "")
        var e2 = TextEditor(text: "hello")
        e2.handle(.ctrl("a"))
        e2.handle(.ctrl("k"))
        XCTAssertEqual(e2.lines[0], "")
    }

    func testClampColOnMove() {
        var e = TextEditor(text: "a\nbbbb")
        e.handle(.up)
        XCTAssertEqual(e.col, 1)
        e.handle(.up)
        XCTAssertEqual(e.col, 1)
    }
}
