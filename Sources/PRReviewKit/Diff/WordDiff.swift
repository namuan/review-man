import Foundation

/// Computes character-level "what changed" ranges within paired removed/added
/// lines, using common prefix/suffix trimming. Degrades gracefully on
/// pathological input (very long lines) via a hard length cap.
public enum WordDiff {

    static let maxLineLength = 1000

    public static func applyEmphasis(_ file: inout DiffFile) {
        for h in file.hunks.indices {
            var i = 0
            let count = file.hunks[h].lines.count
            while i < count {
                guard file.hunks[h].lines[i].kind == .removed else {
                    i += 1
                    continue
                }
                var j = i
                while j < count, file.hunks[h].lines[j].kind == .removed { j += 1 }
                var k = j
                while k < count, file.hunks[h].lines[k].kind == .added { k += 1 }
                let removedCount = j - i
                let addedCount = k - j
                let n = min(removedCount, addedCount)
                for p in 0..<n {
                    let r = file.hunks[h].lines[i + p].content
                    let a = file.hunks[h].lines[j + p].content
                    let (ro, ao) = emphasisRanges(old: r, new: a)
                    file.hunks[h].lines[i + p].emphasis = ro
                    file.hunks[h].lines[j + p].emphasis = ao
                }
                i = k
            }
        }
    }

    /// Returns the changed (middle) character ranges for the old and new text.
    /// Both are nil when the texts are identical.
    public static func emphasisRanges(old: String, new: String) -> (Range<Int>?, Range<Int>?) {
        let a = Array(old.prefix(maxLineLength))
        let b = Array(new.prefix(maxLineLength))
        if a == b { return (nil, nil) }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < (a.count - prefix), suffix < (b.count - prefix),
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let ar = prefix < (a.count - suffix) ? prefix..<(a.count - suffix) : nil
        let br = prefix < (b.count - suffix) ? prefix..<(b.count - suffix) : nil
        return (ar, br)
    }
}
