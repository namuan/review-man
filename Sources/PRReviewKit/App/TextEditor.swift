import Foundation

/// A small multi-line text editor model used for draft comments, replies and
/// review summaries. Grapheme-safe: all editing works on Character arrays.
public struct TextEditor {
    public private(set) var lines: [String]
    public private(set) var row = 0
    public private(set) var col = 0
    public var scrollRow = 0
    public var scrollCol = 0

    public init(text: String = "") {
        let parts = text.components(separatedBy: "\n")
        lines = parts.isEmpty ? [""] : parts
        row = max(0, lines.count - 1)
        col = Array(lines[row]).count
    }

    public var text: String { lines.joined(separator: "\n") }

    public var currentLine: String { lines[row] }

    public mutating func handle(_ key: Key) {
        switch key {
        case .char(let c):
            insert(c)
        case .enter:
            newline()
        case .backspace:
            backspace()
        case .delete:
            deleteForward()
        case .left:
            moveLeft()
        case .right:
            moveRight()
        case .up:
            moveUp()
        case .down:
            moveDown()
        case .home:
            col = 0
        case .end:
            col = Array(lines[row]).count
        case .tab:
            insert(" ")
            insert(" ")
        case .ctrl("a"):
            col = 0
        case .ctrl("e"):
            col = Array(lines[row]).count
        case .ctrl("k"):
            killToEnd()
        case .ctrl("u"):
            killLine()
        case .paste(let text):
            let parts = text.components(separatedBy: "\n")
            for (idx, piece) in parts.enumerated() {
                insert(piece)
                if idx < parts.count - 1 { newline() }
            }
        default:
            break
        }
        clampCol()
    }

    private mutating func insert(_ s: String) {
        guard !s.isEmpty else { return }
        let arr = Array(lines[row])
        lines[row] = String(arr[0..<min(col, arr.count)]) + s + String(arr[min(col, arr.count)...])
        col += s.count
    }

    private mutating func insert(_ c: Character) {
        var arr = Array(lines[row])
        arr.insert(c, at: min(col, arr.count))
        lines[row] = String(arr)
        col += 1
    }

    private mutating func newline() {
        let arr = Array(lines[row])
        let head = String(arr[0..<min(col, arr.count)])
        let tail = String(arr[min(col, arr.count)...])
        lines[row] = head
        lines.insert(tail, at: row + 1)
        row += 1
        col = 0
    }

    private mutating func backspace() {
        if col > 0 {
            var arr = Array(lines[row])
            arr.remove(at: col - 1)
            lines[row] = String(arr)
            col -= 1
        } else if row > 0 {
            let prevLen = Array(lines[row - 1]).count
            lines[row - 1] += lines[row]
            lines.remove(at: row)
            row -= 1
            col = prevLen
        }
    }

    private mutating func deleteForward() {
        let arr = Array(lines[row])
        if col < arr.count {
            var a = arr
            a.remove(at: col)
            lines[row] = String(a)
        } else if row + 1 < lines.count {
            lines[row] += lines[row + 1]
            lines.remove(at: row + 1)
        }
    }

    private mutating func moveLeft() {
        if col > 0 { col -= 1 } else if row > 0 { row -= 1; col = Array(lines[row]).count }
    }

    private mutating func moveRight() {
        if col < Array(lines[row]).count { col += 1 } else if row + 1 < lines.count { row += 1; col = 0 }
    }

    private mutating func moveUp() {
        guard row > 0 else { return }
        row -= 1
        clampCol()
    }

    private mutating func moveDown() {
        guard row + 1 < lines.count else { return }
        row += 1
        clampCol()
    }

    private mutating func clampCol() {
        col = min(col, Array(lines[row]).count)
    }

    private mutating func killToEnd() {
        let arr = Array(lines[row])
        lines[row] = String(arr[0..<min(col, arr.count)])
    }

    private mutating func killLine() {
        lines[row] = ""
        col = 0
    }
}
