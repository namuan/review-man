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

        // Syntax token foregrounds.
        for token in tokens
        where token.range.lowerBound >= 0 && token.range.upperBound <= charCount {
            guard let start = stringIndex(of: token.range.lowerBound, in: content),
                  let end = stringIndex(of: token.range.upperBound, in: content),
                  start < end,
                  let s = AttributedString.Index(start, within: text),
                  let e = AttributedString.Index(end, within: text),
                  s < e else { continue }
            text[s..<e].foregroundColor = palette.foreground(for: token.kind)
        }

        // Word-level change backgrounds (base kind color must survive).
        if let emphasis = line.emphasis, !emphasis.isEmpty,
           emphasis.lowerBound >= 0 && emphasis.upperBound <= charCount {
            guard let start = stringIndex(of: emphasis.lowerBound, in: content),
                  let end = stringIndex(of: emphasis.upperBound, in: content),
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

    /// Maps a Character offset to a String index; nil when out of bounds.
    private static func stringIndex(of charOffset: Int, in content: String) -> String.Index? {
        guard charOffset >= 0 else { return nil }
        var idx = content.startIndex
        for _ in 0..<charOffset {
            guard idx < content.endIndex else { return nil }
            idx = content.index(after: idx)
        }
        return idx
    }
}
