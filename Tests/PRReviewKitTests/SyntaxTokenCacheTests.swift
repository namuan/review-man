import XCTest
@testable import PRReviewKit

final class SyntaxTokenCacheTests: XCTestCase {

    private var swift: Language? { Highlighter.language(for: "a.swift") }
    private var go: Language? { Highlighter.language(for: "a.go") }

    /// Identical content in different languages must produce different tokens
    /// (the content-only cache bug) and be stored separately. "let" is a Swift
    /// keyword but not a Go keyword, so the token output differs.
    func testSeparatesContentByLanguage() {
        let cache = SyntaxTokenCache()
        let content = "let value = 42"

        let swiftTokens = cache.tokens(for: content, language: swift)
        let goTokens = cache.tokens(for: content, language: go)

        XCTAssertNotEqual(swiftTokens, goTokens, "different languages must not share tokens")
        XCTAssertEqual(cache.entryCount, 2)
        // Same language + content returns the identical cached array.
        let again = cache.tokens(for: content, language: swift)
        XCTAssertEqual(again, swiftTokens)
        XCTAssertEqual(cache.entryCount, 2)
    }

    /// Cache hits are returned without recomputation and refresh recency.
    func testHitRefreshesRecencyAndEvictsLRU() {
        let cache = SyntaxTokenCache(maxEntries: 3, maxRetainedCharacters: 1_000_000)
        let a = cache.tokens(for: "alpha", language: swift)
        _ = cache.tokens(for: "beta", language: swift)
        _ = cache.tokens(for: "gamma", language: swift)

        // Touch "alpha" (now most recent), then add "delta" → "beta" evicted.
        XCTAssertEqual(cache.tokens(for: "alpha", language: swift), a)
        _ = cache.tokens(for: "delta", language: swift)

        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertNotNil(cache.entry(for: "alpha", language: swift))
        XCTAssertNil(cache.entry(for: "beta", language: swift))
    }

    /// The retained-character bound is enforced and eviction frees capacity.
    func testCharacterBudgetIsEnforced() {
        let cache = SyntaxTokenCache(maxEntries: 100, maxRetainedCharacters: 20)
        _ = cache.tokens(for: String(repeating: "x", count: 12), language: swift)   // 12 chars
        _ = cache.tokens(for: String(repeating: "y", count: 12), language: swift)   // 12 → evicts first
        XCTAssertLessThanOrEqual(cache.retainedCharacterCount, 20)
        XCTAssertEqual(cache.entryCount, 1)
    }

    /// Cache behavior is thread-safe under concurrent access (no crash, bounded).
    func testConcurrentAccessIsSafe() {
        let cache = SyntaxTokenCache()
        let contents = (0..<200).map { "func f\($0)() -> Int { return \($0) }" }
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let lang = i % 2 == 0 ? swift : go
            _ = cache.tokens(for: contents[i], language: lang)
        }
        XCTAssertLessThanOrEqual(cache.entryCount, 200)
        XCTAssertLessThanOrEqual(cache.retainedCharacterCount, cache.maxRetainedCharacters)
    }
}
