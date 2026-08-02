import Foundation

/// A 256-palette or truecolor RGB color.
public enum Color: Equatable {
    case palette(Int)
    case rgb(Int, Int, Int)
}

/// A text style: foreground/background plus text attributes.
public struct Style: Equatable {
    public var fg: Color?
    public var bg: Color?
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool

    public init(
        fg: Color? = nil,
        bg: Color? = nil,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
    }

    public static let plain = Style()

    /// Returns a copy of this style with `other` layered on top of it.
    public func merging(_ other: Style) -> Style {
        var s = self
        if let f = other.fg { s.fg = f }
        if let b = other.bg { s.bg = b }
        s.bold = s.bold || other.bold
        s.dim = s.dim || other.dim
        s.italic = s.italic || other.italic
        s.underline = s.underline || other.underline
        return s
    }

    /// SGR escape sequence that resets then applies this style.
    public var sgr: String {
        var codes: [String] = []
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        switch fg {
        case .palette(let n)?: codes.append("38;5;\(n)")
        case .rgb(let r, let g, let b)?: codes.append("38;2;\(r);\(g);\(b)")
        case nil: break
        }
        switch bg {
        case .palette(let n)?: codes.append("48;5;\(n)")
        case .rgb(let r, let g, let b)?: codes.append("48;2;\(r);\(g);\(b)")
        case nil: break
        }
        if codes.isEmpty { return "\u{1b}[0m" }
        return "\u{1b}[0m\u{1b}[\(codes.joined(separator: ";"))m"
    }
}

/// Convenience constructors for the 16 base ANSI colors (index 0-15).
public extension Color {
    static let black = Color.palette(0)
    static let red = Color.palette(1)
    static let green = Color.palette(2)
    static let yellow = Color.palette(3)
    static let blue = Color.palette(4)
    static let magenta = Color.palette(5)
    static let cyan = Color.palette(6)
    static let white = Color.palette(7)
}

/// Raw ANSI control sequences used by the terminal layer.
public enum ANSI {
    public static let esc = "\u{1b}"
    public static let altScreenOn = "\u{1b}[?1049h"
    public static let altScreenOff = "\u{1b}[?1049l"
    public static let cursorHide = "\u{1b}[?25l"
    public static let cursorShow = "\u{1b}[?25h"
    public static let mouseOn = "\u{1b}[?1000h\u{1b}[?1006h"
    public static let mouseOff = "\u{1b}[?1000l\u{1b}[?1006l"
    public static let bracketedPasteOn = "\u{1b}[?2004h"
    public static let bracketedPasteOff = "\u{1b}[?2004l"
    public static let syncOn = "\u{1b}[?2026h"
    public static let syncOff = "\u{1b}[?2026l"

    public static func cursorTo(_ row: Int, _ col: Int) -> String {
        "\u{1b}[\(row + 1);\(col + 1)H"
    }

    public static func restore() -> String {
        syncOff + bracketedPasteOff + mouseOff + cursorShow + altScreenOff + "\u{1b}[0m"
    }
}
