import Foundation

/// Bounded, thread-safe LRU cache for syntax tokens, keyed by the canonical
/// language AND the complete line content. A content-only key (the old bug)
/// returns the wrong highlighting when identical text appears in files of
/// different languages. Demand-driven: entries are created only for lines the
/// UI actually renders.
public final class SyntaxTokenCache {

    public struct Key: Hashable {
        public let language: Language?
        public let content: String
        public init(language: Language?, content: String) {
            self.language = language
            self.content = content
        }
    }

    private let lock = NSLock()
    private var entries: [Key: [CodeToken]] = [:]
    private var lruOrder: [Key] = []
    private var retainedCharacters = 0

    public let maxEntries: Int
    public let maxRetainedCharacters: Int

    public init(maxEntries: Int = 2048, maxRetainedCharacters: Int = 1_000_000) {
        self.maxEntries = maxEntries
        self.maxRetainedCharacters = maxRetainedCharacters
    }

    /// Returns cached tokens for the (language, content) pair, computing and
    /// caching them on a miss. A hit refreshes LRU recency.
    public func tokens(for content: String, language: Language?) -> [CodeToken] {
        let key = Key(language: language, content: content)
        lock.lock()
        if let hit = entries[key] {
            if let idx = lruOrder.firstIndex(of: key) {
                lruOrder.remove(at: idx)
                lruOrder.append(key)
            }
            lock.unlock()
            return hit
        }
        lock.unlock()

        let tokens = Highlighter.tokenize(content, language)

        lock.lock()
        // Re-check under the lock (another thread may have inserted it).
        if let existing = entries[key] {
            lock.unlock()
            return existing
        }
        entries[key] = tokens
        lruOrder.append(key)
        retainedCharacters += key.content.count
        while (entries.count > maxEntries || retainedCharacters > maxRetainedCharacters),
              !lruOrder.isEmpty {
            let oldest = lruOrder.removeFirst()
            if entries.removeValue(forKey: oldest) != nil {
                retainedCharacters -= oldest.content.count
            }
        }
        lock.unlock()
        return tokens
    }

    // MARK: - Diagnostics (internal, for tests)

    func entry(for content: String, language: Language?) -> [CodeToken]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(language: language, content: content)]
    }

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
        entries.removeAll()
        lruOrder.removeAll()
        retainedCharacters = 0
        lock.unlock()
    }
}
