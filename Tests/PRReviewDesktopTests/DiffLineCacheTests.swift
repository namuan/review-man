import XCTest
import SwiftUI
import PRReviewKit
@testable import PRReviewDesktop

/// Caching semantics for the rendered diff line cache: hits return the cached
/// value, the key space covers everything the visual depends on, the LRU is
/// bounded (O(1) promote/evict so it stays fast at load-test scale), and the
/// cache itself must be fully released when dropped (no retain cycle).
final class DiffLineCacheTests: XCTestCase {

    private func line(_ kind: DiffLine.Kind, content: String, newLine: Int? = 1, emphasis: Range<Int>? = nil) -> DiffLine {
        DiffLine(kind: kind, content: content, oldLine: 1, newLine: newLine, emphasis: emphasis)
    }

    private func swiftID() -> Int? {
        Highlighter.languageID(for: "a.swift")
    }

    func testHitReturnsSameRenderedValue() {
        let cache = DiffLineCache()
        let l = line(.added, content: "let x = compute(y, flag: true)  // note")
        let a = cache.attributedString(for: l, languageID: swiftID(), palette: SemanticTheme.light, isDark: false, highContrast: false)
        let b = cache.attributedString(for: l, languageID: swiftID(), palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(a, b)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(cache.missCount, 1)
    }

    func testKeyDistinguishesContentLanguageAndTheme() {
        let cache = DiffLineCache()
        let content = "let payload = decode(data)"
        let swift = Highlighter.languageID(for: "a.swift")
        let py = Highlighter.languageID(for: "b.py")
        let l = line(.context, content: content)
        let swiftLight = cache.attributedString(for: l, languageID: swift, palette: SemanticTheme.light, isDark: false, highContrast: false)
        let pyLight = cache.attributedString(for: l, languageID: py, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertNotEqual(swiftLight, pyLight, "language must be part of the key")
        XCTAssertEqual(cache.entryCount, 2)

        let dark = cache.attributedString(for: l, languageID: swift, palette: SemanticTheme.dark, isDark: true, highContrast: false)
        XCTAssertNotEqual(swiftLight, dark, "theme must be part of the key")
        XCTAssertEqual(cache.entryCount, 3)

        let emphasized = line(.added, content: content, emphasis: 4..<10)
        let emph = cache.attributedString(for: emphasized, languageID: swift, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertNotEqual(swiftLight, emph, "word emphasis must be part of the key")
        XCTAssertEqual(cache.entryCount, 4)
    }

    func testCacheIsBounded() {
        let cache = DiffLineCache(maxEntries: 2, maxRetainedCharacters: 1_000_000)
        let l1 = line(.added, content: "first line content")
        let l2 = line(.removed, content: "second line content")
        let l3 = line(.context, content: "third line content")
        let lang = swiftID()
        _ = cache.attributedString(for: l1, languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: l2, languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
        // l1 was most recently... l2 inserted after l1 → l1 is LRU; inserting l3 evicts l1.
        _ = cache.attributedString(for: l3, languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(cache.evictionCount, 1)
        // Touching l2 makes it MRU, so l3 becomes LRU.
        _ = cache.attributedString(for: l2, languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: l1, languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 2)
    }

    func testRetainedCharactersBoundEvicts() {
        // Small char budget: two long lines evict each other.
        let cache = DiffLineCache(maxEntries: 100, maxRetainedCharacters: 100)
        let long1 = String(repeating: "a", count: 80)
        let long2 = String(repeating: "b", count: 80)
        let lang = swiftID()
        _ = cache.attributedString(for: line(.added, content: long1), languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        _ = cache.attributedString(for: line(.added, content: long2), languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false)
        XCTAssertEqual(cache.entryCount, 1, "80 + 80 chars exceeds the 100-char budget")
    }

    /// The intrusive LRU links nodes to each other; the back-link must be weak
    /// so dropping the cache releases every node (no retain ring). Without the
    /// weak back-link, `weakRef` below stays non-nil.
    func testCacheDeallocatesWhenReleased() {
        weak var weakRef: DiffLineCache?
        autoreleasepool {
            let cache = DiffLineCache()
            let lang = swiftID()
            for i in 0..<100 {
                _ = cache.attributedString(
                    for: line(.added, content: "line \(i) with some content"),
                    languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false
                )
            }
            weakRef = cache
        }
        // Flush autorelease pools so the only strong reference (the local) is gone.
        var drained = 0
        while weakRef != nil && drained < 20 {
            drained += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(weakRef, "cache must deallocate when released (no retain cycle)")
    }

    func testRemoveAllReleasesEntries() {
        let cache = DiffLineCache()
        let lang = swiftID()
        for i in 0..<10 {
            _ = cache.attributedString(
                for: line(.added, content: "content \(i)"),
                languageID: lang, palette: SemanticTheme.light, isDark: false, highContrast: false
            )
        }
        XCTAssertEqual(cache.entryCount, 10)
        cache.removeAll()
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.retainedCharacterCount, 0)
    }
}
