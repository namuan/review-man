import Foundation

/// A single character cell on screen.
public struct Cell: Equatable {
    public var ch: Character = " "
    public var style: Style = .plain
    /// True when this cell is the second half of a wide (2-column) character.
    public var continuation = false
}

/// Double-buffered character grid with row-level diff rendering.
public final class Screen {
    public private(set) var width: Int
    public private(set) var height: Int
    private var cells: [Cell]
    private var prevRowStrings: [String] = []
    /// Plain (unstyled) rows of the last rendered frame, for tests and --dump.
    public private(set) var plainRows: [String] = []

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        cells = [Cell](repeating: Cell(), count: self.width * self.height)
    }

    public func resize(_ w: Int, _ h: Int) {
        width = max(1, w)
        height = max(1, h)
        cells = [Cell](repeating: Cell(), count: width * height)
        prevRowStrings = []
        plainRows = []
    }

    public func clear() {
        cells = [Cell](repeating: Cell(), count: width * height)
    }

    public func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ style: Style) {
        guard w > 0, h > 0 else { return }
        for row in y..<(y + h) {
            guard row >= 0, row < height else { continue }
            for col in x..<(x + w) {
                guard col >= 0, col < width else { continue }
                cells[row * width + col] = Cell(ch: " ", style: style)
            }
        }
    }

    public func put(_ x: Int, _ y: Int, _ ch: Character, _ style: Style) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        cells[y * width + x] = Cell(ch: ch, style: style)
    }

    public func text(_ x: Int, _ y: Int, _ s: String, _ style: Style, maxWidth: Int = Int.max) {
        guard y >= 0, y < height else { return }
        let limit: Int
        if maxWidth == Int.max {
            limit = width
        } else {
            limit = min(width, max(0, x) + max(0, maxWidth))
        }
        var col = x
        for ch in s {
            let w = displayWidth(of: ch)
            if w == 0 {
                // zero-width chars are not rendered but still "consume" nothing
                continue
            }
            if col + w > limit || col < 0 { break }
            if col >= 0 && col < width {
                cells[y * width + col] = Cell(ch: ch, style: style)
                if w == 2 {
                    if col + 1 < width {
                        cells[y * width + col + 1] = Cell(ch: " ", style: style, continuation: true)
                    }
                    col += 2
                } else {
                    col += 1
                }
            }
        }
    }

    /// Writes a list of styled runs left-to-right.
    public func runs(_ x: Int, _ y: Int, _ runs: [(String, Style)], maxWidth: Int = Int.max) {
        var col = x
        for (s, st) in runs {
            let used = col - x
            let remaining: Int
            if maxWidth == Int.max {
                remaining = Int.max
            } else {
                remaining = max(0, maxWidth - used)
            }
            text(col, y, s, st, maxWidth: remaining)
            col += displayWidth(of: s)
            if col - x >= maxWidth { break }
        }
    }

    /// Draws a box border. Returns nothing.
    public func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ style: Style, title: String? = nil, titleStyle: Style? = nil) {
        let left = x, right = x + w - 1, top = y, bottom = y + h - 1
        put(left, top, "╭", style)
        put(right, top, "╮", style)
        put(left, bottom, "╰", style)
        put(right, bottom, "╯", style)
        for col in (left + 1)..<right { put(col, top, "─", style) }
        for col in (left + 1)..<right { put(col, bottom, "─", style) }
        for row in (top + 1)..<bottom {
            put(left, row, "│", style)
            put(right, row, "│", style)
        }
        if let title {
            let t = " \(title) "
            text(left + 1, top, t, titleStyle ?? style)
        }
    }

    // MARK: - Rendering

    private func buildStyledRows() -> [String] {
        var result: [String] = []
        result.reserveCapacity(height)
        for row in 0..<height {
            var runs: [(String, Style)] = []
            var start = 0
            var col = 0
            while col < width {
                let idx = row * width + col
                let cell = cells[idx]
                if cell.continuation {
                    col += 1
                    continue
                }
                if runs.isEmpty {
                    runs.append(("", cell.style))
                    start = col
                } else if runs[runs.count - 1].1 != cell.style {
                    let slice = sliceRow(row: row, from: start, to: col)
                    runs[runs.count - 1].0 = slice
                    runs.append(("", cell.style))
                    start = col
                }
                col += 1
            }
            if !runs.isEmpty {
                runs[runs.count - 1].0 = sliceRow(row: row, from: start, to: width)
                // strip trailing plain spaces
                while let last = runs.last, last.1 == .plain, last.0.hasSuffix(" ") {
                    runs[runs.count - 1].0 = String(last.0.dropLast())
                    if runs[runs.count - 1].0.isEmpty { runs.removeLast() } else { break }
                }
                var line = ""
                for (s, st) in runs {
                    guard !s.isEmpty else { continue }
                    line += st.sgr + s
                }
                result.append(line)
            } else {
                result.append("")
            }
        }
        return result
    }

    private func sliceRow(row: Int, from a: Int, to b: Int) -> String {
        guard b > a else { return "" }
        var s = ""
        for col in a..<b {
            let cell = cells[row * width + col]
            if !cell.continuation {
                s.append(cell.ch)
            }
        }
        return s
    }

    private func buildPlainRows() -> [String] {
        var result: [String] = []
        for row in 0..<height {
            var s = ""
            for col in 0..<width {
                let cell = cells[row * width + col]
                if !cell.continuation { s.append(cell.ch) }
            }
            result.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Emits the frame to the terminal, only rewriting changed rows.
    public func render(to term: Terminal) {
        let rowsNow = buildStyledRows()
        var out = ANSI.syncOn
        for y in 0..<height {
            guard y < rowsNow.count else { break }
            let s = rowsNow[y]
            if y < prevRowStrings.count, prevRowStrings[y] == s, !s.isEmpty {
                continue
            }
            // Erase to end-of-line so shrunken rows don't leave stale text.
            out += ANSI.cursorTo(y, 0) + s + "\u{1b}[0m\u{1b}[K"
        }
        out += ANSI.syncOff
        term.write(out)
        prevRowStrings = rowsNow
        plainRows = buildPlainRows()
    }

    /// Plain-text dump of the frame, used by --dump and tests.
    public func debugDump() -> String {
        buildPlainRows().joined(separator: "\n")
    }
}
