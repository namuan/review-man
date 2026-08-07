import XCTest
import SwiftUI
import PRReviewKit
@testable import PRReviewDesktop

/// Caching semantics for the rendered diff line cache: hits return the cached
/// value, the key space covers everything the visual depends on, and the LRU
/// is bounded (O(1) promote/evict so it stays fast at load-test scale).
final class DiffLineCacheTests: XCTestCase {

    private func line(_ kind: DiffLine.Kind, content: String, newLine: Int? = 1, emphasis: Range<Int>? = nil) -> DiffLine {
        DiffLine(kind: kind, content: content, oldLine: 1, newLine: newLine, emphasis: emphasis)
    }

    func testHitReturnsSameRenderedValue() {
        let cache = DiffLineCache()
        let l = line(.added, content: "let x = compute(y, flag: true)  // note")
        let a = cache.attributedString(for: l, language: Highlighter.language(for: "a.swift"), palette: SemanticTheme.light, isDark: false, highContrast: false)
        let b = cache.attributedString(for: l, language: Highlighter.language(for: "a.swift"), palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(a, b)
        XCTAssertEqual(cache.entryCount, 1)
    }

    func testKeyDistinguishesContentLanguageAndTheme() {
        let cache = DiffLineCache()
        let content = "let payload = decode(data)"
        let swift = Highlighter.language(for: "a.swift")
        let py = Highlighter.language(for: "b.py")
        let l = line(.context, content: content)
        let swiftLight = cache.attributedString(for: l, language: swift, palette: SemanticTheme.light, isDark: false, highContrast: false)
        let pyLight = cache.attributedString(for: l, language: py, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertNotEqual(swiftLight, pyLight, "language must be part of the key")
        XCTAssertEqual(cache.entryCount, 2)

        let dark = cache.attributedString(for: l, language: swift, palette: SemanticTheme.dark, isDark: true, highContrast: false)
        XCTAssertNotEqual(swiftLight, dark, "theme must be part of the key")
        XCTAssertEqual(cache.entryCount, 3)

        let emphasized = line(.added, content: content, emphasis: 4..<10)
        let emph = cache.attributedString(for: emphasized, language: swift, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertNotEqual(swiftLight, emph, "word emphasis must be part of the key")
        XCTAssertEqual(cache.entryCount, 4)
    }

    func testCacheIsBounded() {
        let cache = DiffLineCache(maxEntries: 2, maxRetainedCharacters: 1_000_000)
        let l1 = line(.added, content: "first line content")
        let l2 = line(.removed, content: "second line content")
        let l3 = line(.context, content: "third line content")
        let lang = Highlighter.language(for: "a.swift")
        _ = cache.attributedString(for: l1, language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: l2, language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
        // l1 was most recently... l2 inserted after l1 → l1 is LRU; inserting l3 evicts l1.
        _ = cache.attributedString(for: l3, language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
        // Touching l2 makes it MRU, so l3 becomes LRU.
        _ = cache.attributedString(for: l2, language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: l1, language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
    }

    func testRetainedCharactersBoundEvicts() {
        // Small char budget: two long lines evict each other.
        let cache = DiffLineCache(maxEntries: 100, maxRetainedCharacters: 100)
        let long1 = String(repeating: "a", count: 80)
        let long2 = String(repeating: "b", count: 80)
        let lang = Highlighter.language(for: "a.swift")
        _ = cache.attributedString(for: line(.added, content: long1), language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: line(.added, content: long2), language: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 1, "80 + 80 chars exceeds the 100-char budget")
    }
}
