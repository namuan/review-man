import Foundation

/// A commentable diff position on one side.
public struct DiffLineAnchor: Equatable {
    public let path: String
    public let side: String   // "RIGHT" or "LEFT"
    public let line: Int
    public let startLine: Int?
    public let startSide: String?

    public init(path: String, side: String, line: Int, startLine: Int? = nil, startSide: String? = nil) {
        self.path = path
        self.side = side
        self.line = line
        self.startLine = startLine
        self.startSide = startSide
    }
}

/// A normalized multi-line comment range or a precise validation failure.
public enum ValidatedDraftAnchor {
    case single(DiffLineAnchor)
    case range(DiffLineAnchor)
    case invalid(reason: String)

    public var anchor: DiffLineAnchor? {
        switch self {
        case .single(let a), .range(let a): return a
        case .invalid: return nil
        }
    }
}

/// Validates and normalizes multi-line comment ranges. Rules (Phase 6):
/// one file, one hunk, one side; endpoints must be commentable diff lines;
/// reverse selections normalize to `startLine <= line`; thread/draft cards are
/// never endpoints.
public struct DraftRangeValidator {

    public init() {}

    /// `start`/`end` are diff lines (with their file and hunk info) in display
    /// order; cards (thread/draft/header) are passed as `nil` and skipped.
    public func validate(
        start: (file: DiffFile, hunkIndex: Int, lineIndex: Int)?,
        end: (file: DiffFile, hunkIndex: Int, lineIndex: Int)?,
        ignoreCards: Bool = true
    ) -> ValidatedDraftAnchor {
        guard let start, let end else {
            return .invalid(reason: "Select two commentable lines.")
        }
        guard start.file.path == end.file.path else {
            return .invalid(reason: "A multi-line comment must stay within one file.")
        }
        guard start.hunkIndex == end.hunkIndex else {
            return .invalid(reason: "A multi-line comment must stay within one hunk.")
        }
        guard let a = anchor(of: start), let b = anchor(of: end) else {
            return .invalid(reason: "Ranges must start and end on commentable lines.")
        }
        guard a.side == b.side else {
            return .invalid(reason: "A multi-line comment must use one diff side (all added/context or all removed lines).")
        }
        // Normalize reverse selections by side-specific line number.
        let lo = min(a.line, b.line)
        let hi = max(a.line, b.line)
        let anchor = DiffLineAnchor(path: a.path, side: a.side, line: hi, startLine: lo, startSide: a.side)
        return lo == hi ? .single(DiffLineAnchor(path: a.path, side: a.side, line: hi)) : .range(anchor)
    }

    private func anchor(of line: (file: DiffFile, hunkIndex: Int, lineIndex: Int)) -> DiffLineAnchor? {
        let file = line.file
        guard line.hunkIndex < file.hunks.count else { return nil }
        let hunk = file.hunks[line.hunkIndex]
        guard line.lineIndex < hunk.lines.count else { return nil }
        let diffLine = hunk.lines[line.lineIndex]
        switch diffLine.kind {
        case .added, .context:
            guard let new = diffLine.newLine else { return nil }
            return DiffLineAnchor(path: file.path, side: "RIGHT", line: new)
        case .removed:
            guard let old = diffLine.oldLine else { return nil }
            return DiffLineAnchor(path: file.path, side: "LEFT", line: old)
        }
    }

    /// The comment side + line anchor for a single diff line.
    public static func anchor(for file: DiffFile, hunkIndex: Int, lineIndex: Int) -> DiffLineAnchor? {
        DraftRangeValidator().anchor(of: (file, hunkIndex, lineIndex))
    }
}

/// Shared review utilities (exact clipboard text, PR URL).
public enum ReviewUtilities {

    /// Exact `path:line content` text for the clipboard. RIGHT lines use the
    /// new line number, LEFT lines the old line number.
    public static func clipboardText(path: String, line: DiffLine) -> String {
        let num = line.newLine ?? line.oldLine ?? 0
        return "\(path):\(num) \(line.content)"
    }

    /// Validated PR URL for browser opening.
    public static func pullRequestURL(_ urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }
}

/// A draft mutation recorded for undo/redo.
public struct DraftMutation: Equatable {
    public let draftID: UUID
    public let before: DraftComment?
    public let after: DraftComment?

    public init(draftID: UUID, before: DraftComment?, after: DraftComment?) {
        self.draftID = draftID
        self.before = before
        self.after = after
    }
}
