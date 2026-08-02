import XCTest
@testable import PRReviewKit

final class TextUtilTests: XCTestCase {

    func testDisplayWidthASCII() {
        XCTAssertEqual(displayWidth(of: "abc"), 3)
        XCTAssertEqual(displayWidth(of: "a"), 1)
    }

    func testDisplayWidthCJK() {
        XCTAssertEqual(displayWidth(of: "代"), 2)
        XCTAssertEqual(displayWidth(of: "a代"), 3)
    }

    func testTruncate() {
        XCTAssertEqual(truncateToWidth("hello world", 100), "hello world")
        XCTAssertEqual(displayWidth(of: truncateToWidth("hello world", 8)), 8)
        XCTAssertTrue(truncateToWidth("hello world", 8).hasSuffix("…"))
    }

    func testPad() {
        XCTAssertEqual(displayWidth(of: padToWidth("ab", 4)), 4)
        XCTAssertEqual(padToWidth("ab", 4), "ab  ")
        XCTAssertEqual(displayWidth(of: padToWidth("long", 3)), 3)
    }

    func testExpandTabs() {
        XCTAssertEqual(expandTabs("a\tb"), "a   b")
        XCTAssertEqual(expandTabs("ab\tc"), "ab  c")
        XCTAssertEqual(expandTabs("\tx", from: 0), "    x")
    }

    func testWrap() {
        let lines = wrapText("one two three four five", width: 10)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { displayWidth(of: $0) <= 10 })
        // newlines are respected
        let multi = wrapText("line1\nline2 words", width: 100)
        XCTAssertEqual(multi.count, 2)
        XCTAssertEqual(multi[0], "line1")
    }

    func testTimeAgo() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        XCTAssertFalse(timeAgo(oneHourAgo).isEmpty)
    }

    func testParseGHDate() {
        let d = parseGHDate("2026-07-30T10:12:00Z")
        XCTAssertNotNil(d)
        let withFraction = parseGHDate("2026-07-30T10:12:00.123Z")
        XCTAssertNotNil(withFraction)
        XCTAssertNil(parseGHDate("garbage"))
    }
}
