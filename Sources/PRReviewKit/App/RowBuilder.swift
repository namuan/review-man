import Foundation

/// One visible row in the diff pane for the current file.
public enum Row: Equatable {
    case hunkHeader(hunkIndex: Int)
    case line(hunkIndex: Int, lineIndex: Int)
    case thread(threadID: String)
    case draft(draftID: UUID)
    case outdatedHeader
    case empty
}

/// Builds the ordered list of visible rows for a file: hunks and lines in diff
/// order, with comment threads and drafts attached right after the line they
/// anchor to (old line numbers for LEFT, new for RIGHT).
public enum RowBuilder {

    public static func build(
        file: DiffFile,
        threads: [PRThread],
        drafts: [DraftComment],
        outdatedExpanded: Bool
    ) -> [Row] {
        var rows: [Row] = []

        let fileThreads = threads
            .filter { $0.path == file.path }
            .sorted { ($0.line ?? $0.originalLine ?? Int.max, $0.lastCommentAt) <
                      ($1.line ?? $1.originalLine ?? Int.max, $1.lastCommentAt) }
        let fileDrafts = drafts
            .filter { $0.path == file.path }
            .sorted { ($0.line, $0.createdAt) < ($1.line, $1.createdAt) }

        let outdated = fileThreads.filter { $0.isOutdated }
        let active = fileThreads.filter { !$0.isOutdated }

        if !outdated.isEmpty {
            rows.append(.outdatedHeader)
            if outdatedExpanded {
                for t in outdated { rows.append(.thread(threadID: t.id)) }
            }
        }

        var attached = Set<String>()

        if file.hunks.isEmpty {
            rows.append(.empty)
        } else {
            for (hi, hunk) in file.hunks.enumerated() {
                rows.append(.hunkHeader(hunkIndex: hi))
                for (li, line) in hunk.lines.enumerated() {
                    rows.append(.line(hunkIndex: hi, lineIndex: li))
                    for t in active {
                        guard let anchor = threadAnchor(t) else { continue }
                        let matches: Bool
                        if t.side == "LEFT" {
                            matches = anchor == line.oldLine
                        } else {
                            matches = anchor == line.newLine
                        }
                        if matches {
                            rows.append(.thread(threadID: t.id))
                            attached.insert(t.id)
                        }
                    }
                    for d in fileDrafts {
                        let matches: Bool
                        if d.side == "LEFT" {
                            matches = d.line == line.oldLine
                        } else {
                            matches = d.line == line.newLine
                        }
                        if matches {
                            rows.append(.draft(draftID: d.id))
                            attached.insert(d.id.uuidString)
                        }
                    }
                }
            }
        }

        // Unanchored (e.g. the diff no longer contains the line): append at end.
        for t in active where !attached.contains(t.id) {
            rows.append(.thread(threadID: t.id))
        }
        for d in fileDrafts where !attached.contains(d.id.uuidString) {
            rows.append(.draft(draftID: d.id))
        }
        return rows
    }

    /// The diff line number a thread anchors to, on its own side.
    public static func threadAnchor(_ t: PRThread) -> Int? {
        if t.isOutdated { return t.originalLine }
        if t.side == "LEFT" { return t.originalLine ?? t.line }
        return t.line ?? t.originalLine
    }
}
