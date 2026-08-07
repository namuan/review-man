import Foundation

/// One visible row in the diff pane for the current file.
public enum Row: Equatable {
    case hunkHeader(hunkIndex: Int)
    case line(hunkIndex: Int, lineIndex: Int)
    case thread(threadID: String)
    case draft(draftID: UUID)
    case outdatedHeader
    case orphanedHeader
    case empty
}

/// Builds the ordered list of visible rows for a file: hunks and lines in diff
/// order, with comment threads and drafts attached right after the line they
/// anchor to (old line numbers for LEFT, new for RIGHT). Orphaned drafts (their
/// anchor is absent from the diff) are collected into a dedicated section at
/// the end and are never attached to a diff line.
public enum RowBuilder {

    /// Filters the global arrays to this file, then builds (convenience for
    /// callers that have not grouped threads/drafts by path).
    public static func build(
        file: DiffFile,
        threads: [PRThread],
        drafts: [DraftComment],
        outdatedExpanded: Bool
    ) -> [Row] {
        build(
            file: file,
            fileThreads: threads.filter { $0.path == file.path },
            fileDrafts: drafts.filter { $0.path == file.path },
            outdatedExpanded: outdatedExpanded
        )
    }

    /// Builds rows for one file whose threads/drafts are ALREADY filtered to
    /// this file's path (callers group by path once instead of per file).
    /// Attachments are indexed by (side, line) before the line loop, so the
    /// cost is O(lines + threads + drafts), not O(lines × threads). Thread
    /// sort keys (including `lastCommentAt`, a map+max over comments) are
    /// computed once per thread before sorting.
    public static func build(
        file: DiffFile,
        fileThreads: [PRThread],
        fileDrafts: [DraftComment],
        outdatedExpanded: Bool
    ) -> [Row] {
        var rows: [Row] = []

        let sortedThreads = fileThreads
            .map { (thread: $0, key: ($0.line ?? $0.originalLine ?? Int.max, $0.lastCommentAt)) }
            .sorted { $0.key < $1.key }
            .map(\.thread)
        let sortedDrafts = fileDrafts.filter { !$0.isOrphaned }
            .sorted { ($0.line, $0.createdAt) < ($1.line, $1.createdAt) }
        let orphanDrafts = fileDrafts
            .filter { $0.isOrphaned }
            .sorted { ($0.line, $0.createdAt) < ($1.line, $1.createdAt) }

        let outdated = sortedThreads.filter { $0.isOutdated }
        let active = sortedThreads.filter { !$0.isOutdated }

        // Index active threads and drafts by anchor line per side — O(threads +
        // drafts) instead of scanning every thread/draft for every diff line.
        var leftThreads: [Int: [PRThread]] = [:]
        var rightThreads: [Int: [PRThread]] = [:]
        for t in active {
            guard let anchor = threadAnchor(t) else { continue }
            if t.side == "LEFT" {
                leftThreads[anchor, default: []].append(t)
            } else {
                rightThreads[anchor, default: []].append(t)
            }
        }
        var leftDrafts: [Int: [DraftComment]] = [:]
        var rightDrafts: [Int: [DraftComment]] = [:]
        for d in sortedDrafts {
            if d.side == "LEFT" {
                leftDrafts[d.line, default: []].append(d)
            } else {
                rightDrafts[d.line, default: []].append(d)
            }
        }

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
                    if let new = line.newLine, let ts = rightThreads[new] {
                        for t in ts {
                            rows.append(.thread(threadID: t.id))
                            attached.insert(t.id)
                        }
                    }
                    if let old = line.oldLine, let ts = leftThreads[old] {
                        for t in ts {
                            rows.append(.thread(threadID: t.id))
                            attached.insert(t.id)
                        }
                    }
                    if let new = line.newLine, let ds = rightDrafts[new] {
                        for d in ds {
                            rows.append(.draft(draftID: d.id))
                            attached.insert(d.id.uuidString)
                        }
                    }
                    if let old = line.oldLine, let ds = leftDrafts[old] {
                        for d in ds {
                            rows.append(.draft(draftID: d.id))
                            attached.insert(d.id.uuidString)
                        }
                    }
                }
            }
        }

        // Unanchored non-orphaned drafts (defensive): append at end.
        for d in sortedDrafts where !attached.contains(d.id.uuidString) {
            rows.append(.draft(draftID: d.id))
        }
        for t in active where !attached.contains(t.id) {
            rows.append(.thread(threadID: t.id))
        }

        // Dedicated orphaned section.
        if !orphanDrafts.isEmpty {
            rows.append(.orphanedHeader)
            for d in orphanDrafts {
                rows.append(.draft(draftID: d.id))
            }
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
