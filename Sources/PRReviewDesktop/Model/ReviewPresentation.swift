import Foundation
import PRReviewKit

/// Path-based selection for the desktop UI. Files are identified by path (not
/// index) so a reload retains the selected path when it still exists.
public struct ReviewSelection: Equatable {
    public var filePath: String?
    public var rowID: DiffRowID?

    public init(filePath: String? = nil, rowID: DiffRowID? = nil) {
        self.filePath = filePath
        self.rowID = rowID
    }
}

/// Typed, stable identity for one diff display row, derived from file, hunk,
/// side, and line anchors (never a transient array offset).
public enum DiffRowID: Hashable {
    case hunk(file: String, hunk: Int, oldStart: Int, newStart: Int)
    case line(file: String, hunk: Int, kind: DiffLine.Kind, old: Int?, new: Int?)
    case thread(id: String)
    case draft(id: UUID)
    case outdatedHeader(file: String)
    case orphanedHeader(file: String)
    case empty(file: String)
}

/// One row in the diff display: the core `Row` plus its file path and stable ID.
public struct DiffDisplayRow: Identifiable, Equatable {
    public let id: DiffRowID
    public let filePath: String
    public let row: Row

    public init(id: DiffRowID, filePath: String, row: Row) {
        self.id = id
        self.filePath = filePath
        self.row = row
    }
}

/// Top-level load state of a review session window.
public enum PresentationState: Equatable {
    case welcome
    case loading(reference: String)
    case loaded
    case empty
    case failed(message: String)

    public static func == (lhs: PresentationState, rhs: PresentationState) -> Bool {
        switch (lhs, rhs) {
        case (.welcome, .welcome): return true
        case (.loading(let a), .loading(let b)): return a == b
        case (.loaded, .loaded): return true
        case (.empty, .empty): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// One row of the file sidebar.
public struct FileSidebarItem: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let statusLetter: String
    /// Additions/deletions are nil when the patch is unavailable (too-large).
    public let additions: Int?
    public let deletions: Int?
    public let isBinary: Bool
    public let tooLarge: Bool
    public let threadCount: Int
    public let isViewed: Bool
}

/// Immutable data snapshot for a loaded review window. All values are copied
/// so SwiftUI can diff cleanly; rows are built once per load.
public struct ReviewPresentation {
    public let endpoint: PREndpoint?
    public let pr: PRInfo?
    public let files: [DiffFile]
    public let threads: [PRThread]
    public let drafts: [DraftComment]
    public let viewed: Set<String>
    /// RowBuilder rows per file path (display order is authoritative).
    public let rowsByFile: [String: [Row]]
    /// RowBuilder rows for files that vanished from the diff (pathless orphans).
    public let pathlessOrphanIDs: [UUID]
    public let sidebarItems: [FileSidebarItem]

    public init(
        endpoint: PREndpoint?,
        pr: PRInfo?,
        files: [DiffFile],
        threads: [PRThread],
        drafts: [DraftComment],
        viewed: Set<String>
    ) {
        self.endpoint = endpoint
        self.pr = pr
        self.files = files
        self.threads = threads
        self.drafts = drafts
        self.viewed = viewed

        var rows: [String: [Row]] = [:]
        var orphans: [UUID] = []
        let knownPaths = Set(files.map { $0.path })
        for file in files {
            // outdatedExpanded: true renders outdated thread cards inline under
            // their header (read-only display of every thread).
            rows[file.path] = RowBuilder.build(
                file: file, threads: threads, drafts: drafts, outdatedExpanded: true
            )
        }
        // Pathless orphans surface on the last file so they stay visible and
        // deletable even when their path vanished from the diff.
        let pathless = drafts.filter { $0.isOrphaned && !knownPaths.contains($0.path) }
        if !pathless.isEmpty, let lastPath = files.last?.path, var lastRows = rows[lastPath] {
            if !lastRows.contains(.orphanedHeader) {
                lastRows.append(.orphanedHeader)
            }
            lastRows.append(contentsOf: pathless.map { .draft(draftID: $0.id) })
            rows[lastPath] = lastRows
            orphans = pathless.map(\.id)
        }
        self.pathlessOrphanIDs = orphans
        self.rowsByFile = rows

        self.sidebarItems = files.map { file in
            let threadCount = threads.filter { $0.path == file.path && !$0.isOutdated }.count
                + drafts.filter { $0.path == file.path }.count
            let countsAvailable = !file.tooLarge && !file.isBinary
            return FileSidebarItem(
                path: file.path,
                oldPath: file.oldPath,
                statusLetter: file.status.letter,
                additions: countsAvailable ? file.additions : nil,
                deletions: countsAvailable ? file.deletions : nil,
                isBinary: file.isBinary,
                tooLarge: file.tooLarge,
                threadCount: threadCount,
                isViewed: viewed.contains(file.path)
            )
        }
    }

    public func rows(for path: String) -> [Row] {
        rowsByFile[path] ?? []
    }

    /// Maps a file's core rows to display rows with stable, anchor-derived IDs.
    public func diffRows(for file: DiffFile) -> [DiffDisplayRow] {
        let path = file.path
        return rows(for: path).map { row in
            let id: DiffRowID
            switch row {
            case .hunkHeader(let hunkIndex):
                let hunk = file.hunks[hunkIndex]
                id = .hunk(file: path, hunk: hunkIndex, oldStart: hunk.oldStart, newStart: hunk.newStart)
            case .line(let hunkIndex, let lineIndex):
                let line = file.hunks[hunkIndex].lines[lineIndex]
                id = .line(file: path, hunk: hunkIndex, kind: line.kind, old: line.oldLine, new: line.newLine)
            case .thread(let threadID):
                id = .thread(id: threadID)
            case .draft(let draftID):
                id = .draft(id: draftID)
            case .outdatedHeader:
                id = .outdatedHeader(file: path)
            case .orphanedHeader:
                id = .orphanedHeader(file: path)
            case .empty:
                id = .empty(file: path)
            }
            return DiffDisplayRow(id: id, filePath: path, row: row)
        }
    }
}
