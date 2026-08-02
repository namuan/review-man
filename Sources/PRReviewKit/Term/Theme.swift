import Foundation

/// Central color/style definitions for the app (256-color palette).
public enum Theme {
    // Base text
    public static let text = Style(fg: .palette(252))
    public static let dim = Style(fg: .palette(245))
    public static let faint = Style(fg: .palette(240))
    public static let accent = Style(fg: .palette(75))
    public static let accentBold = Style(fg: .palette(75), bold: true)
    public static let warn = Style(fg: .palette(214))
    public static let error = Style(fg: .palette(203), bold: true)
    public static let ok = Style(fg: .palette(114))
    public static let magenta = Style(fg: .palette(135))

    // Bars
    public static let titleBar = Style(fg: .palette(255), bg: .palette(236))
    public static let titleBarAccent = Style(fg: .palette(81), bg: .palette(236), bold: true)
    public static let titleBarDim = Style(fg: .palette(245), bg: .palette(236))
    public static let statsBar = Style(fg: .palette(250), bg: .palette(235))
    public static let statsKey = Style(fg: .palette(223), bg: .palette(235), bold: true)
    public static let statusBar = Style(fg: .palette(250), bg: .palette(238))
    public static let statusKey = Style(fg: .palette(223), bg: .palette(238), bold: true)
    public static let statusMode = Style(fg: .palette(16), bg: .palette(222), bold: true)

    // Diff
    public static let gutter = Style(fg: .palette(243))
    public static let gutterAdd = Style(fg: .palette(114), bg: .palette(22))
    public static let gutterDel = Style(fg: .palette(203), bg: .palette(52))
    public static let added = Style(fg: .palette(252), bg: .palette(22))
    public static let removed = Style(fg: .palette(252), bg: .palette(52))
    public static let addedEmph = Style(fg: .palette(255), bg: .palette(28), bold: true)
    public static let removedEmph = Style(fg: .palette(255), bg: .palette(88), bold: true)
    public static let addedCursor = Style(fg: .palette(255), bg: .palette(29))
    public static let removedCursor = Style(fg: .palette(255), bg: .palette(89))
    public static let cursor = Style(fg: .palette(255), bg: .palette(237))
    public static let hunkHeader = Style(fg: .palette(81), bg: .palette(235))
    public static let hunkHeaderText = Style(fg: .palette(117), bg: .palette(235))
    public static let selected = Style(fg: .palette(255), bg: .palette(60))
    public static let selectedDim = Style(fg: .palette(245), bg: .palette(238))
    public static let statusLetterAdd = Style(fg: .palette(114), bold: true)
    public static let statusLetterDel = Style(fg: .palette(203), bold: true)
    public static let statusLetterMod = Style(fg: .palette(214), bold: true)
    public static let statusLetterRename = Style(fg: .palette(135), bold: true)
    public static let emptyHint = Style(fg: .palette(240))

    // Comments
    public static let threadBorder = Style(fg: .palette(63))
    public static let threadResolved = Style(fg: .palette(240))
    public static let threadDraft = Style(fg: .palette(214))
    public static let threadAuthor = Style(fg: .palette(75), bold: true)
    public static let draftBadge = Style(fg: .palette(16), bg: .palette(222), bold: true)
    public static let outdatedBadge = Style(fg: .palette(245), bg: .palette(238))

    // File list
    public static let paneHeader = Style(fg: .palette(255), bg: .palette(236))
    public static let paneHeaderAccent = Style(fg: .palette(81), bg: .palette(236), bold: true)
    public static let paneHeaderDim = Style(fg: .palette(245), bg: .palette(236))
    public static let viewedMark = Style(fg: .palette(240))
    public static let commentDot = Style(fg: .palette(214), bold: true)
    public static let filterActive = Style(fg: .palette(222), bg: .palette(237))

    // Overlays
    public static let overlayBorder = Style(fg: .palette(66))
    public static let overlayTitle = Style(fg: .palette(81), bold: true)
    public static let overlayBody = Style(fg: .palette(252))
    public static let caret = Style(fg: .palette(16), bg: .palette(252))
    public static let visualSelect = Style(fg: .palette(255), bg: .palette(60))

    // Syntax tokens (fg only; merged over the diff line background)
    public static func token(_ kind: TokenKind) -> Style {
        switch kind {
        case .keyword: return Style(fg: .palette(176), bold: true)
        case .string: return Style(fg: .palette(150))
        case .comment: return Style(fg: .palette(244), italic: true)
        case .number: return Style(fg: .palette(215))
        case .type: return Style(fg: .palette(81))
        case .directive: return Style(fg: .palette(204))
        case .plain: return .plain
        }
    }
}
