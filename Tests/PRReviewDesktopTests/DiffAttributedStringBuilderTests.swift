import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class DiffAttributedStringBuilderTests: XCTestCase {

    /// Syntax foregrounds and word-change backgrounds apply without one
    /// overwriting the other.
    func testSyntaxAndWordBackgroundCoexist() {
        let line = DiffLine(
            kind: .added,
            content: "let value = compute(42)",
            oldLine: nil,
            newLine: 2,
            emphasis: 4..<9   // "value"
        )
        let tokens = Highlighter.tokenize(line.content, Highlighter.language(for: "a.swift"))
        let text = DiffAttributedStringBuilder.build(line: line, tokens: tokens, palette: SemanticTheme.light)

        var hasKeyword = false
        var hasWordBackground = false
        for run in text.runs {
            if run.foregroundColor != nil, run.foregroundColor != SemanticTheme.light.addedForeground {
                hasKeyword = true
            }
            if run.backgroundColor == SemanticTheme.light.wordAddedBackground {
                hasWordBackground = true
            }
        }
        XCTAssertTrue(hasKeyword, "syntax foreground must survive")
        XCTAssertTrue(hasWordBackground, "word-change background must survive")
        XCTAssertEqual(String(text.characters), line.content, "content must be unchanged")
    }

    /// Unicode, emoji, and combining characters never crash the builder; the
    /// full content survives with the base color.
    func testUnicodeAndCombiningCharactersAreSafe() {
        let content = "let café = \"🎉\" + e\u{0301}  // comment"
        let line = DiffLine(kind: .context, content: content, oldLine: 1, newLine: 1, emphasis: 4..<8)
        let tokens = Highlighter.tokenize(content, Highlighter.language(for: "a.swift"))

        let text = DiffAttributedStringBuilder.build(line: line, tokens: tokens, palette: SemanticTheme.light)
        XCTAssertEqual(String(text.characters), content)
    }

    /// Out-of-bounds token and emphasis ranges are ignored, not fatal.
    func testInvalidRangesAreIgnored() {
        let line = DiffLine(kind: .added, content: "abc", oldLine: nil, newLine: 1, emphasis: 2..<99)
        let badTokens = [
            CodeToken(range: -3..<1, kind: .keyword),
            CodeToken(range: 50..<60, kind: .string),
        ]
        let text = DiffAttributedStringBuilder.build(line: line, tokens: badTokens, palette: SemanticTheme.light)
        XCTAssertEqual(String(text.characters), "abc")
        XCTAssertEqual(text.foregroundColor, SemanticTheme.light.addedForeground)
    }

    /// Gutter text pads old/new columns to the file's digit width.
    func testGutterTextPadding() {
        let added = DiffLine(kind: .added, content: "x", oldLine: nil, newLine: 42)
        XCTAssertEqual(DiffAttributedStringBuilder.gutterText(for: added, digits: 4), "       42 +")
        let removed = DiffLine(kind: .removed, content: "x", oldLine: 7, newLine: nil)
        XCTAssertEqual(DiffAttributedStringBuilder.gutterText(for: removed, digits: 4), "   7      -")
    }
}
