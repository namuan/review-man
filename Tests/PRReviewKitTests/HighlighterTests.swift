import XCTest
@testable import PRReviewKit

final class HighlighterTests: XCTestCase {

    func testSwiftKeywordsStringsAndComments() {
        let lang = Highlighter.language(for: "file.swift")
        XCTAssertNotNil(lang)
        let line = "func foo(x: String) -> Int { let s = \"hi\"; return 42 } // done"
        let tokens = Highlighter.tokenize(line, lang)
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && line[$0.range] == "func" })
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && line[$0.range] == "return" })
        XCTAssertTrue(tokens.contains { $0.kind == .type && line[$0.range] == "String" })
        XCTAssertTrue(tokens.contains { $0.kind == .type && line[$0.range] == "Int" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && line[$0.range] == "42" })
        XCTAssertTrue(tokens.contains { $0.kind == .comment })
        XCTAssertTrue(tokens.contains { $0.kind == .string })
    }

    func testPythonCommentIsNotDirective() {
        let lang = Highlighter.language(for: "script.py")
        let tokens = Highlighter.tokenize("# import this", lang)
        XCTAssertTrue(tokens.contains { $0.kind == .comment })
    }

    func testPythonDecoratorsAdvancePastAtPrefix() {
        let lang = Highlighter.language(for: "script.py")
        XCTAssertTrue(Highlighter.tokenize("@staticmethod", lang).isEmpty)
    }

    func testJSONLiterals() {
        let lang = Highlighter.language(for: "data.json")
        let line = "{\"key\": true, \"num\": 12.5}"
        let tokens = Highlighter.tokenize(line, lang)
        XCTAssertTrue(tokens.contains { $0.kind == .string })
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && line[$0.range] == "true" })
        XCTAssertTrue(tokens.contains { $0.kind == .number })
    }

    func testBlockComment() {
        let lang = Highlighter.language(for: "a.c")
        let line = "/* block */ int x = 1;"
        let tokens = Highlighter.tokenize(line, lang)
        XCTAssertTrue(tokens.contains { $0.kind == .comment && line[$0.range] == "/* block */" })
    }

    func testNoLanguageReturnsNoTokens() {
        XCTAssertTrue(Highlighter.tokenize("whatever", nil).isEmpty)
    }

    func testStringWithCommentLikeContent() {
        let lang = Highlighter.language(for: "a.swift")
        let line = "let url = \"https://example.com/x\" // real comment"
        let tokens = Highlighter.tokenize(line, lang)
        // The URL must be part of a string token, not a comment token.
        let commentTokens = tokens.filter { $0.kind == .comment }
        XCTAssertEqual(commentTokens.count, 1)
        XCTAssertEqual(line[commentTokens[0].range], "// real comment")
    }
}

private extension String {
    subscript(_ range: Range<Int>) -> String {
        let chars = Array(self)
        guard range.lowerBound >= 0, range.upperBound <= chars.count else { return "" }
        return String(chars[range])
    }
}
