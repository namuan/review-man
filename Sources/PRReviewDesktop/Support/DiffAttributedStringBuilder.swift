import Foundation
import SwiftUI
import PRReviewKit

/// Builds an `AttributedString` for one diff line: base kind color, syntax
/// token foregrounds, then word-change backgrounds — all using Character
/// offsets (the tokenizer and word-diff code are Character-based). Invalid or
/// out-of-bounds ranges are ignored safely.
public enum DiffAttributedStringBuilder {

    public static func build(
        line: DiffLine,
        tokens: [CodeToken],
        palette: SemanticTheme.Palette
    ) -> AttributedString {
        let content = line.content
        let charCount = content.count
        var text = AttributedString(content)
        text.foregroundColor = foreground(for: line.kind, palette: palette)

        // Precompute Character-offset → String.Index once (O(n)); the old
        // per-token scan made build O(tokens × contentLength), which dominated
        // file-switch latency on long lines.
        let indices = stringIndices(for: content)
        let indexAt = { (offset: Int) -> String.Index? in
            guard offset >= 0, offset < indices.count else { return nil }
            return indices[offset]
        }

        // Syntax token foregrounds.
        for token in tokens
        where token.range.lowerBound >= 0 && token.range.upperBound <= charCount {
            guard let start = indexAt(token.range.lowerBound),
                  let end = indexAt(token.range.upperBound),
                  start < end,
                  let s = AttributedString.Index(start, within: text),
                  let e = AttributedString.Index(end, within: text),
                  s < e else { continue }
            text[s..<e].foregroundColor = palette.foreground(for: token.kind)
        }

        // Word-level change backgrounds (base kind color must survive).
        if let emphasis = line.emphasis, !emphasis.isEmpty,
           emphasis.lowerBound >= 0 && emphasis.upperBound <= charCount {
            guard let start = indexAt(emphasis.lowerBound),
                  let end = indexAt(emphasis.upperBound),
                  start < end,
                  let s = AttributedString.Index(start, within: text),
                  let e = AttributedString.Index(end, within: text),
                  s < e else { return text }
            let background = line.kind == .added
                ? palette.wordAddedBackground
                : palette.wordRemovedBackground
            text[s..<e].backgroundColor = background
        }
        return text
    }

    public static func gutterText(for line: DiffLine, digits: Int) -> String {
        func pad(_ n: Int?) -> String {
            guard let n else { return String(repeating: " ", count: digits) }
            return String(format: "%\(digits)d", n)
        }
        let sign: Character
        switch line.kind {
        case .added: sign = "+"
        case .removed: sign = "-"
        case .context: sign = " "
        }
        return "\(pad(line.oldLine)) \(pad(line.newLine)) \(sign)"
    }

    private static func foreground(for kind: DiffLine.Kind, palette: SemanticTheme.Palette) -> SwiftUI.Color {
        switch kind {
        case .added: return palette.addedForeground
        case .removed: return palette.removedForeground
        case .context: return palette.contextForeground
        }
    }

    /// Character offset → String.Index, precomputed once per line (O(n) total
    /// instead of O(n) per token).
    private static func stringIndices(for content: String) -> [String.Index] {
        var idxs: [String.Index] = []
        idxs.reserveCapacity(content.count + 1)
        var i = content.startIndex
        idxs.append(i)
        while i < content.endIndex {
            i = content.index(after: i)
            idxs.append(i)
        }
        return idxs
    }
}
