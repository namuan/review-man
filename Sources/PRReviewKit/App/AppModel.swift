import Foundation

public enum FocusPane {
    case files
    case diff
}

public enum Mode {
    case normal
    case help
    case search
    case edit
    case compose
    case prBody
    case visual
    case confirmQuit
    case confirmDeleteDraft
}

public enum EditTarget {
    case newDraft(path: String, line: Int, side: String, startLine: Int?, startSide: String?)
    case editDraft(UUID)
    case reply(threadID: String, commentID: Int)
    case composerBody
}

public struct Message {
    public let text: String
    public let isError: Bool
}

public enum ReviewEvent: Int, CaseIterable {
    case comment = 0
    case approve = 1
    case requestChanges = 2

    public var apiValue: String {
        switch self {
        case .comment: return "COMMENT"
        case .approve: return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        }
    }

    public var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }
}

/// The most recent local-persistence failure, retained beyond the timed
/// message banner so a window close can warn about it later.
public struct PersistenceFailure {
    public let operation: String
    public let message: String

    public init(operation: String, message: String) {
        self.operation = operation
        self.message = message
    }
}

/// Single source of truth for the app state.
public final class AppModel {

    // Data
    public var endpoint: PREndpoint?
    public var isDemo = false
    public var pr: PRInfo?
    public var headOID = ""
    public var files: [DiffFile] = []
    public var threads: [PRThread] = []
    public var drafts: [DraftComment] = []
    public var rows: [[Row]] = []
    public var loaded = false

    // Navigation
    public var selectedFile = 0
    public var cursorRow = 0
    public var scrollRow = 0
    public var hScroll = 0
    public var fileScroll = 0
    public var focus: FocusPane = .files
    public var mode: Mode = .normal
    public var filter = ""
    public var visualStartRow: Int?

    // Editor
    public var editor = TextEditor()
    public var editorTarget: EditTarget?

    // Composer
    public var composerEvent: ReviewEvent = .comment
    public var composerBody = ""
    public var composerError: String?

    // Misc state
    public var message: Message?
    public var messageUntil: Date?
    public var viewed: Set<String> = []
    public var expandedThreads: Set<String> = []
    public var outdatedExpanded = false
    public var helpScroll = 0
    public var prBodyScroll = 0
    public var loading = false
    public var dirty = true
    public var shouldQuit = false
    /// Cleared on every successful persistence operation; set on failure. Used
    /// for the close-warning contract and persisted across message expiry.
    public var persistenceFailure: PersistenceFailure?

    private let tokenCache = SyntaxTokenCache()

    /// Cached syntax tokens for a diff line, keyed by language AND content
    /// (bounded LRU). Identical content in different languages never shares
    /// tokens.
    public func tokens(for content: String, path: String) -> [CodeToken] {
        tokenCache.tokens(for: content, language: Highlighter.language(for: path))
    }

    public init() {}

    // MARK: - Derived state

    public var currentFileIndex: Int {
        guard !files.isEmpty else { return 0 }
        return min(max(0, selectedFile), files.count - 1)
    }

    public var currentFile: DiffFile? {
        files.isEmpty ? nil : files[currentFileIndex]
    }

    public var fileRows: [Row] {
        rows.isEmpty ? [] : rows[currentFileIndex]
    }

    public func filteredFileIndices() -> [Int] {
        let f = filter.lowercased()
        guard !f.isEmpty else { return Array(files.indices) }
        return files.indices.filter { idx in
            let file = files[idx]
            return file.path.lowercased().contains(f)
                || file.status.letter.lowercased() == f
        }
    }

    public func rebuildRows() {
        var newRows: [[Row]] = []
        for file in files {
            newRows.append(RowBuilder.build(
                file: file,
                threads: threads,
                drafts: drafts,
                outdatedExpanded: outdatedExpanded
            ))
        }
        // Orphaned drafts whose path vanished from the diff are surfaced on the
        // last file so they stay visible and deletable.
        if !files.isEmpty, let last = newRows.indices.last {
            let knownPaths = Set(files.map { $0.path })
            let pathless = drafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
            if !pathless.isEmpty {
                if !newRows[last].contains(.orphanedHeader) {
                    newRows[last].append(.orphanedHeader)
                }
                newRows[last].append(contentsOf: pathless.map { .draft(draftID: $0.id) })
            }
        }
        rows = newRows
        clampCursor()
    }

    public func clampCursor() {
        let count = fileRows.count
        cursorRow = min(max(0, cursorRow), max(0, count - 1))
        if count == 0 { scrollRow = 0 } else {
            scrollRow = min(max(0, scrollRow), max(0, count - 1))
        }
        visualStartRow = visualStartRow.map { min(max(0, $0), max(0, count - 1)) }
    }

    public func thread(byID id: String) -> PRThread? {
        threads.first { $0.id == id }
    }

    public func draft(byID id: UUID) -> DraftComment? {
        drafts.first { $0.id == id }
    }

    /// (hunk, line) under the cursor, if the cursor is on a diff line.
    public func cursorLineInfo() -> (hunk: DiffHunk, line: DiffLine)? {
        guard let row = row(at: cursorRow) else { return nil }
        guard case .line(let h, let l) = row else { return nil }
        guard let file = currentFile, h < file.hunks.count, l < file.hunks[h].lines.count else {
            return nil
        }
        return (file.hunks[h], file.hunks[h].lines[l])
    }

    public func row(at index: Int) -> Row? {
        let r = fileRows
        return (index >= 0 && index < r.count) ? r[index] : nil
    }

    public func currentHunkIndex() -> Int? {
        var found: Int?
        for i in 0...cursorRow {
            if case .hunkHeader(let h) = row(at: i) { found = h }
        }
        return found
    }

    public func setMessage(_ text: String, isError: Bool = false, duration: TimeInterval = 6) {
        message = Message(text: text, isError: isError)
        messageUntil = Date().addingTimeInterval(duration)
        dirty = true
    }

    public func threadCount(forPath path: String) -> Int {
        threads.filter { $0.path == path && !$0.isOutdated }.count
            + drafts.filter { $0.path == path }.count
    }

    public var reviewDecisionLabel: String? {
        guard let d = pr?.reviewDecision else { return nil }
        switch d {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "REVIEW_REQUIRED": return "review required"
        default: return d.lowercased()
        }
    }

    public var stateLabel: String {
        guard let pr else { return "" }
        switch pr.state {
        case "OPEN": return pr.isDraft ? "DRAFT" : "OPEN"
        case "MERGED": return "MERGED"
        default: return "CLOSED"
        }
    }
}
