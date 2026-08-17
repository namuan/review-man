import Foundation

/// Parses git unified diff text (as served by `gh api ... Accept: vnd.github.v3.diff`)
/// into structured `DiffFile`s. Total parser: unknown lines are skipped, never crash.
public enum DiffParser {

    public static func parse(_ text: String) -> [DiffFile] {
        PerformanceLog.measure(
            name: "DiffParse",
            label: "diff-parse bytes=\(text.utf8.count)"
        ) {
            parseImpl(text)
        }
    }

    private static func parseImpl(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunk: DiffHunk?
        var oldLn = 0
        var newLn = 0
        var renameFrom: String?

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }

        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
            renameFrom = nil
        }

        // Iterate lines as Substrings (zero-copy views into `text`) instead of
        // `components(separatedBy:)`, which materializes a full copy of every
        // line String while the original payload is still alive. Peak memory
        // for a multi-megabyte diff drops to roughly (payload + model), not
        // (payload + line-array + model).
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.hasPrefix("diff --git ") {
                flushFile()
                var f = DiffFile()
                let rest = rawLine.dropFirst("diff --git ".count)
                if let (a, b) = parseGitPaths(String(rest)) {
                    f.oldPath = a
                    f.newPath = b
                }
                current = f
                continue
            }
            guard current != nil else { continue }

            if rawLine.hasPrefix("new file mode") {
                current?.status = .added
                continue
            }
            if rawLine.hasPrefix("deleted file mode") {
                current?.status = .deleted
                continue
            }
            if rawLine.hasPrefix("similarity index") || rawLine.hasPrefix("dissimilarity index") {
                continue
            }
            if rawLine.hasPrefix("rename from ") {
                renameFrom = String(rawLine.dropFirst("rename from ".count))
                current?.status = .renamed
                continue
            }
            if rawLine.hasPrefix("rename to ") {
                current?.status = .renamed
                let old = renameFrom ?? current?.oldPath
                if var c = current {
                    c.oldPath = old
                    c.newPath = String(rawLine.dropFirst("rename to ".count))
                    current = c
                }
                continue
            }
            if rawLine.hasPrefix("Binary files") || rawLine.hasPrefix("GIT binary patch") {
                current?.isBinary = true
                continue
            }
            if rawLine.hasPrefix("index ") || rawLine.hasPrefix("old mode") || rawLine.hasPrefix("new mode")
                || rawLine.hasPrefix("copy from") || rawLine.hasPrefix("copy to") {
                continue
            }
            if rawLine.isEmpty {
                // Blank lines separate files in the stream. Inside a hunk they
                // are only consumed as context while the declared counts are
                // not yet exhausted (guards against phantom trailing lines).
                guard hunk != nil else { continue }
                let oldDone = oldLn - hunk!.oldStart >= hunk!.oldCount
                let newDone = newLn - hunk!.newStart >= hunk!.newCount
                guard !(oldDone && newDone) else { continue }
                hunk?.lines.append(DiffLine(kind: .context, content: "", oldLine: oldLn, newLine: newLn))
                oldLn += 1
                newLn += 1
                continue
            }
            if rawLine.hasPrefix("--- ") {
                let p = String(rawLine.dropFirst(4))
                current?.oldPath = (p == "/dev/null") ? nil : stripPathPrefix(p)
                continue
            }
            if rawLine.hasPrefix("+++ ") {
                let p = String(rawLine.dropFirst(4))
                current?.newPath = (p == "/dev/null") ? nil : stripPathPrefix(p)
                continue
            }
            if rawLine.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(String(rawLine)) {
                    hunk = parsed
                    oldLn = parsed.oldStart
                    newLn = parsed.newStart
                }
                continue
            }
            if rawLine.hasPrefix("\\") {
                continue // "\ No newline at end of file"
            }
            guard hunk != nil else { continue }

            let body = String(rawLine.dropFirst())
            if rawLine.hasPrefix("+") {
                hunk?.lines.append(DiffLine(kind: .added, content: body, oldLine: nil, newLine: newLn))
                newLn += 1
            } else if rawLine.hasPrefix("-") {
                hunk?.lines.append(DiffLine(kind: .removed, content: body, oldLine: oldLn, newLine: nil))
                oldLn += 1
            } else {
                // context line (starts with a space) or a truly empty line
                hunk?.lines.append(DiffLine(kind: .context, content: body, oldLine: oldLn, newLine: newLn))
                oldLn += 1
                newLn += 1
            }
        }
        flushFile()

        for i in files.indices {
            WordDiff.applyEmphasis(&files[i])
        }
        return files
    }

    static func stripPathPrefix(_ p: String) -> String {
        if p.hasPrefix("a/") || p.hasPrefix("b/") { return String(p.dropFirst(2)) }
        return p
    }

    /// Parses `a/path b/path` (paths may be quoted when they contain spaces).
    static func parseGitPaths(_ s: String) -> (String, String)? {
        var aEnd: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == " " {
                // first single space not followed by another space
                let next = s.index(after: i)
                if next < s.endIndex, s[next] != " " {
                    aEnd = i
                    break
                }
            }
            i = s.index(after: i)
        }
        guard let aEnd, s.hasPrefix("a/") else { return nil }
        let a = stripPathPrefix(String(s[..<aEnd]))
        let b = stripPathPrefix(String(s[s.index(after: aEnd)...]))
        return (a, b)
    }

    /// Parses `@@ -l[,c] +l[,c] @@ section`
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        let parts = line.components(separatedBy: "@@")
        guard parts.count >= 2 else { return nil }
        let rangePart = parts[1].trimmingCharacters(in: .whitespaces)
        let context = parts.count > 2
            ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
            : ""
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        for token in rangePart.split(separator: " ") {
            if token.hasPrefix("-") {
                (oldStart, oldCount) = parseRange(String(token.dropFirst()))
            } else if token.hasPrefix("+") {
                (newStart, newCount) = parseRange(String(token.dropFirst()))
            }
        }
        return DiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            context: context,
            lines: []
        )
    }

    /// "1" -> (1, 1); "1,13" -> (1, 13); "0,0" -> (0, 0)
    static func parseRange(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return (0, 0) }
        if parts.count > 1, let count = Int(parts[1]) {
            return (start, count)
        }
        return (start, 1)
    }
}
