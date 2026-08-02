import Foundation

/// Display width (columns) of a grapheme cluster. Approximate but good enough
/// for CJK (2), combining marks (0) and most emoji (2).
public func displayWidth(of ch: Character) -> Int {
    var w = 1
    for s in ch.unicodeScalars {
        switch s.value {
        case 0x0300...0x036F, 0x0483...0x0489, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
             0x20D0...0x20FF, 0xFE00...0xFE0F, 0x200B...0x200F, 0xFE20...0xFE2F:
            continue // zero-width (combining marks, joiners, ZWJ/ZWNBSP)
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            w = max(w, 2)
        default:
            break
        }
    }
    return w
}

public func displayWidth(of s: String) -> Int {
    s.reduce(0) { $0 + displayWidth(of: $1) }
}

/// Truncates to `width` columns, appending an ellipsis when truncated.
public func truncateToWidth(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    if displayWidth(of: s) <= width { return s }
    var out = ""
    var w = 0
    for ch in s {
        let cw = displayWidth(of: ch)
        if w + cw > max(0, width - 1) { break }
        out.append(ch)
        w += cw
    }
    return out + "…"
}

/// Pads (or truncates) `s` to exactly `width` columns.
public func padToWidth(_ s: String, _ width: Int) -> String {
    let w = displayWidth(of: s)
    if w >= width { return truncateToWidth(s, width) }
    return s + String(repeating: " ", count: width - w)
}

/// Expands tabs relative to a starting column. Tabs advance to the next
/// multiple of `tabWidth` columns.
public func expandTabs(_ s: String, from column: Int = 0, tabWidth: Int = 4) -> String {
    var out = ""
    var col = column
    for ch in s {
        if ch == "\t" {
            let spaces = tabWidth - (col % tabWidth)
            out += String(repeating: " ", count: spaces)
            col += spaces
        } else {
            out.append(ch)
            col += displayWidth(of: ch)
        }
    }
    return out
}

/// Word-wraps text to `width` columns. Long words are hard-split.
public func wrapText(_ s: String, width: Int) -> [String] {
    guard width > 1 else { return s.components(separatedBy: "\n") }
    var lines: [String] = []
    for rawLine in s.components(separatedBy: "\n") {
        if rawLine.isEmpty { lines.append(""); continue }
        var current = ""
        var currentW = 0
        for word in rawLine.split(separator: " ", omittingEmptySubsequences: false) {
            let wstr = String(word)
            let ww = displayWidth(of: wstr)
            if currentW + (current.isEmpty ? 0 : 1) + ww <= width {
                if current.isEmpty { current = wstr } else { current += " " + wstr }
                currentW += (current.isEmpty ? 0 : 1) + ww
            } else {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                    currentW = 0
                }
                if ww <= width {
                    current = wstr
                    currentW = ww
                } else {
                    // hard split
                    var chunk = ""
                    var chunkW = 0
                    for ch in wstr {
                        let cw = displayWidth(of: ch)
                        if chunkW + cw > width {
                            lines.append(chunk)
                            chunk = ""
                            chunkW = 0
                        }
                        chunk.append(ch)
                        chunkW += cw
                    }
                    current = chunk
                    currentW = chunkW
                }
            }
        }
        lines.append(current)
    }
    return lines
}

/// Truncates a file path for narrow columns, preferring to keep the tail
/// (file name and innermost directories) visible.
public func tailPath(_ path: String, width: Int) -> String {
    if displayWidth(of: path) <= width { return path }
    guard width > 4 else { return truncateToWidth(path, width) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var tail = ""
    var used = 0
    for i in stride(from: parts.count - 1, through: 0, by: -1) {
        let piece = (i == parts.count - 1) ? parts[i] : parts[i] + "/"
        if used + displayWidth(of: piece) + 1 > width - 1 { break }
        tail = piece + tail
        used += displayWidth(of: piece)
    }
    if tail.isEmpty { return truncateToWidth(path, width) }
    return "…/" + truncateToWidth(tail, max(0, width - 2))
}

/// Human-readable relative time ("3d ago", "2h ago").
public func timeAgo(_ date: Date) -> String {
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: Date())
}

/// ISO8601 date used by GitHub APIs.
public func parseGHDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
