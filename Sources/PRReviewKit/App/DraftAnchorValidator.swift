import Foundation

/// Precomputed per-diff lookup tables so draft revalidation (and anything else
/// that needs "is this (side, line) present?") is O(1) per query instead of
/// rescanning hunks/lines. Built once per fetched diff; all query methods are
/// pure dictionary lookups.
public struct DiffAnchorIndex {

    public let fileIndexByPath: [String: Int]
    /// fileIndex → oldLine → hunkIndex (removed lines are LEFT-commentable).
    private let oldLineToHunk: [[Int: Int]]
    /// fileIndex → newLine → hunkIndex (added/context lines are RIGHT-commentable).
    private let newLineToHunk: [[Int: Int]]

    public init(files: [DiffFile]) {
        var fileIndex: [String: Int] = [:]
        fileIndex.reserveCapacity(files.count)
        for (i, f) in files.enumerated() { fileIndex[f.path] = i }

        var oldMaps: [[Int: Int]] = []
        var newMaps: [[Int: Int]] = []
        oldMaps.reserveCapacity(files.count)
        newMaps.reserveCapacity(files.count)
        for file in files {
            var oldMap: [Int: Int] = [:]
            var newMap: [Int: Int] = [:]
            for (hi, hunk) in file.hunks.enumerated() {
                for line in hunk.lines {
                    switch line.kind {
                    case .removed:
                        if let old = line.oldLine { oldMap[old] = hi }
                    case .added, .context:
                        if let new = line.newLine { newMap[new] = hi }
                    }
                }
            }
            oldMaps.append(oldMap)
            newMaps.append(newMap)
        }

        self.fileIndexByPath = fileIndex
        self.oldLineToHunk = oldMaps
        self.newLineToHunk = newMaps
    }

    /// The hunk containing an old (removed) line, if any.
    public func hunkIndex(oldLine: Int, fileIndex: Int) -> Int? {
        guard fileIndex >= 0, fileIndex < oldLineToHunk.count else { return nil }
        return oldLineToHunk[fileIndex][oldLine]
    }

    /// The hunk containing a new (added/context) line, if any.
    public func hunkIndex(newLine: Int, fileIndex: Int) -> Int? {
        guard fileIndex >= 0, fileIndex < newLineToHunk.count else { return nil }
        return newLineToHunk[fileIndex][newLine]
    }
}

/// Validates that a draft's anchor exists in a fetched diff, mirroring the
/// line-side rules used when creating comments (added/context lines are
/// RIGHT-commentable, removed lines are LEFT-commentable).
///
/// Multi-line ranges are valid only when both endpoints are commentable on the
/// same side, are in the same hunk, and are ordered (`startLine <= line`),
/// matching GitHub's multi-line comment requirements.
public struct DraftAnchorValidator {

    private let files: [DiffFile]
    private let index: DiffAnchorIndex

    public init(files: [DiffFile]) {
        self.files = files
        // O(total lines) once; every `isValid` query is then O(1).
        self.index = DiffAnchorIndex(files: files)
    }

    /// Recomputes orphan status for every draft against the given files:
    /// anchors that are valid again clear the flag (automatic reattachment),
    /// invalid anchors are marked orphaned. Idempotent.
    public static func revalidated(_ drafts: [DraftComment], against files: [DiffFile]) -> [DraftComment] {
        let validator = DraftAnchorValidator(files: files)
        return drafts.map { draft in
            var copy = draft
            copy.isOrphaned = !validator.isValid(copy)
            return copy
        }
    }

    public func isValid(_ draft: DraftComment) -> Bool {
        guard let fileIndex = index.fileIndexByPath[draft.path] else {
            return false
        }
        let line = draft.line
        let startLine = draft.startLine
        switch draft.side {
        case "LEFT":
            guard index.hunkIndex(oldLine: line, fileIndex: fileIndex) != nil else { return false }
            if let start = startLine {
                guard draft.startSide == "LEFT", start <= line else { return false }
                guard let startHunk = index.hunkIndex(oldLine: start, fileIndex: fileIndex),
                      startHunk == index.hunkIndex(oldLine: line, fileIndex: fileIndex) else {
                    return false
                }
            }
            return true
        case "RIGHT":
            guard index.hunkIndex(newLine: line, fileIndex: fileIndex) != nil else { return false }
            if let start = startLine {
                guard draft.startSide == "RIGHT", start <= line else { return false }
                guard let startHunk = index.hunkIndex(newLine: start, fileIndex: fileIndex),
                      startHunk == index.hunkIndex(newLine: line, fileIndex: fileIndex) else {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }
}
