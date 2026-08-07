import Foundation
import SwiftUI
import PRReviewKit

/// Bounded, thread-safe LRU cache for rendered diff lines, keyed by everything
/// the rendered `AttributedString` depends on: line content, language, line
/// kind, word-diff emphasis, and the visual theme. On a hit the diff pane
/// renders from cache, so quickly switching between files in a large PR stops
/// re-tokenizing and re-attributing the viewport on every switch.
///
/// The theme is represented by (isDark, highContrast): `SemanticTheme.palette`
/// maps those two bits to exactly one palette, so they uniquely identify the
/// colors embedded in the cached value. Lines are immutable for the lifetime
/// of a loaded review, so entries stay valid until the cache evicts them.
///
/// Eviction is a classic intrusive doubly-linked list (O(1) promote + evict):
/// an LRU array + `firstIndex` would scan the whole cache on every hit, which
/// dominates at load-test scales (tens of thousands of lines).
public final class DiffLineCache {

    public struct Key: Hashable {
        public let isDark: Bool
        public let highContrast: Bool
        public let kindIndex: Int      // 0 added, 1 removed, 2 context
        public let emphasis: Range<Int>?
        /// Compact language identity (`Highlighter.languageID(for:)`) instead
        /// of the full `Language` value: hashing a small Int is dramatically
        /// cheaper than hashing keyword sets, and this key is hashed on every
        /// realized line of every file switch.
        public let languageID: Int?
        public let content: String

        public init(line: DiffLine, languageID: Int?, isDark: Bool, highContrast: Bool) {
            self.isDark = isDark
            self.highContrast = highContrast
            switch line.kind {
            case .added: self.kindIndex = 0
            case .removed: self.kindIndex = 1
            case .context: self.kindIndex = 2
            }
            self.emphasis = line.emphasis
            self.languageID = languageID
            self.content = line.content
        }
    }

    private final class Node {
        let key: Key
        var value: AttributedString
        /// Weak back-link: the forward `next` chain is the only strong path, so
        /// nodes cannot form a retain ring with the cache (or with each other)
        /// even when the cache itself is released without `removeAll()`.
        weak var prev: Node?
        var next: Node?
        init(key: Key, value: AttributedString) {
            self.key = key
            self.value = value
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Node] = [:]
    private var head: Node?   // most recently used
    private var tail: Node?   // least recently used
    private var retainedCharacters = 0

    public let maxEntries: Int
    public let maxRetainedCharacters: Int

    // MARK: - Diagnostics (for benchmarks and tests)

    /// Number of cache hits since creation (or the last `resetMetrics`).
    public private(set) var hitCount = 0
    /// Number of misses (tokenize + attribute) since creation (or the last
    /// `resetMetrics`).
    public private(set) var missCount = 0
    /// Number of entries evicted by the size/character budgets.
    public private(set) var evictionCount = 0

    public init(maxEntries: Int = 32_768, maxRetainedCharacters: Int = 4_000_000) {
        self.maxEntries = maxEntries
        self.maxRetainedCharacters = maxRetainedCharacters
    }

    /// Returns the cached rendered line, computing (tokenize + attribute) on a
    /// miss. A hit refreshes LRU recency in O(1).
    public func attributedString(
        for line: DiffLine,
        languageID: Int?,
        palette: SemanticTheme.Palette,
        isDark: Bool,
        highContrast: Bool
    ) -> AttributedString {
        let key = Key(line: line, languageID: languageID, isDark: isDark, highContrast: highContrast)
        lock.lock()
        if let node = entries[key] {
            hitCount += 1
            promote(node)
            lock.unlock()
            return node.value
        }
        missCount += 1
        lock.unlock()

        let language = languageID.flatMap { Highlighter.language(forID: $0) }
        let tokens = Highlighter.tokenize(line.content, language)
        let built = DiffAttributedStringBuilder.build(line: line, tokens: tokens, palette: palette)

        lock.lock()
        if let existing = entries[key] {
            lock.unlock()
            return existing.value
        }
        let node = Node(key: key, value: built)
        entries[key] = node
        insertAtHead(node)
        retainedCharacters += key.content.count
        while (entries.count > maxEntries || retainedCharacters > maxRetainedCharacters),
              let oldest = tail {
            removeNode(oldest)
            entries.removeValue(forKey: oldest.key)
            retainedCharacters -= oldest.key.content.count
            evictionCount += 1
        }
        lock.unlock()
        return built
    }

    // MARK: - LRU list (all calls under lock)

    private func promote(_ node: Node) {
        guard node !== head else { return }
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if node === tail { tail = prev }
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
    }

    private func insertAtHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if node === head { head = next }
        if node === tail { tail = prev }
        node.prev = nil
        node.next = nil
    }

    // MARK: - Diagnostics (internal, for tests)

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var retainedCharacterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedCharacters
    }

    func removeAll() {
        lock.lock()
        // Unlink every node explicitly (not just head/tail) so the value
        // payloads are released immediately and no node retains another.
        var node = head
        while let n = node {
            let next = n.next
            n.prev = nil
            n.next = nil
            node = next
        }
        entries.removeAll()
        head = nil
        tail = nil
        retainedCharacters = 0
        lock.unlock()
    }
}
