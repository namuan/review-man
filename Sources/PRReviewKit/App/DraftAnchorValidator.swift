import Foundation

/// Validates that a draft's anchor exists in a fetched diff, mirroring the
/// line-side rules used when creating comments (added/context lines are
/// RIGHT-commentable, removed lines are LEFT-commentable).
///
/// Multi-line ranges are valid only when both endpoints are commentable on the
/// same side, are in the same hunk, and are ordered (`startLine <= line`),
/// matching GitHub's multi-line comment requirements.
public struct DraftAnchorValidator {

    private let files: [DiffFile]

    public init(files: [DiffFile]) {
        self.files = files
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
        guard let file = files.first(where: { $0.path == draft.path }) else {
            return false
        }
        let line = draft.line
        let startLine = draft.startLine
        switch draft.side {
        case "LEFT":
            guard let hunk = hunkIndex(oldLine: line, in: file) else { return false }
            if let start = startLine {
                guard draft.startSide == "LEFT", start <= line else { return false }
                guard let startHunk = hunkIndex(oldLine: start, in: file), startHunk == hunk else {
                    return false
                }
            }
            return true
        case "RIGHT":
            guard let hunk = hunkIndex(newLine: line, in: file) else { return false }
            if let start = startLine {
                guard draft.startSide == "RIGHT", start <= line else { return false }
                guard let startHunk = hunkIndex(newLine: start, in: file), startHunk == hunk else {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    private func hunkIndex(oldLine: Int, in file: DiffFile) -> Int? {
        file.hunks.firstIndex { hunk in
            hunk.lines.contains { $0.kind == .removed && $0.oldLine == oldLine }
        }
    }

    private func hunkIndex(newLine: Int, in file: DiffFile) -> Int? {
        file.hunks.firstIndex { hunk in
            hunk.lines.contains { ($0.kind == .added || $0.kind == .context) && $0.newLine == newLine }
        }
    }
}
