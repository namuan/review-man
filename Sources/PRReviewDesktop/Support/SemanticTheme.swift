import SwiftUI
import PRReviewKit

/// Semantic colors for the diff display, adapting to the current appearance.
/// (Phase 7 adds full light/dark + high-contrast tuning; this is the Phase 5
/// palette.)
public enum SemanticTheme {

    public struct Palette {
        public let addedForeground: SwiftUI.Color
        public let removedForeground: SwiftUI.Color
        public let contextForeground: SwiftUI.Color
        public let addedBackground: SwiftUI.Color
        public let removedBackground: SwiftUI.Color
        public let wordAddedBackground: SwiftUI.Color
        public let wordRemovedBackground: SwiftUI.Color
        public let gutterForeground: SwiftUI.Color
        public let gutterBackground: SwiftUI.Color
        public let hunkHeaderForeground: SwiftUI.Color
        public let hunkHeaderBackground: SwiftUI.Color
        public let threadAccent: SwiftUI.Color
        public let threadResolved: SwiftUI.Color
        public let keyword: SwiftUI.Color
        public let string: SwiftUI.Color
        public let comment: SwiftUI.Color
        public let number: SwiftUI.Color
        public let type: SwiftUI.Color
        public let directive: SwiftUI.Color

        public func foreground(for kind: TokenKind) -> SwiftUI.Color {
            switch kind {
            case .plain: return contextForeground
            case .keyword: return keyword
            case .string: return string
            case .comment: return comment
            case .number: return number
            case .type: return type
            case .directive: return directive
            }
        }
    }

    public static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    /// Higher-contrast variants for `accessibilityIncreaseContrast`.
    public static func palette(for scheme: ColorScheme, increasedContrast: Bool) -> Palette {
        guard increasedContrast else { return palette(for: scheme) }
        return scheme == .dark ? darkHighContrast : lightHighContrast
    }

    public static let lightHighContrast = Palette(
        addedForeground: Color(red: 0.0, green: 0.35, blue: 0.0),
        removedForeground: Color(red: 0.65, green: 0.0, blue: 0.0),
        contextForeground: Color(red: 0.0, green: 0.0, blue: 0.0),
        addedBackground: Color(red: 0.80, green: 0.92, blue: 0.80),
        removedBackground: Color(red: 0.96, green: 0.82, blue: 0.82),
        wordAddedBackground: Color(red: 0.60, green: 0.85, blue: 0.60),
        wordRemovedBackground: Color(red: 0.94, green: 0.60, blue: 0.60),
        gutterForeground: Color(red: 0.25, green: 0.25, blue: 0.25),
        gutterBackground: Color(red: 0.88, green: 0.88, blue: 0.88),
        hunkHeaderForeground: Color(red: 0.10, green: 0.30, blue: 0.55),
        hunkHeaderBackground: Color(red: 0.82, green: 0.90, blue: 0.98),
        threadAccent: Color(red: 0.45, green: 0.20, blue: 0.80),
        threadResolved: Color(red: 0.35, green: 0.35, blue: 0.35),
        keyword: Color(red: 0.45, green: 0.10, blue: 0.65),
        string: Color(red: 0.50, green: 0.15, blue: 0.05),
        comment: Color(red: 0.30, green: 0.30, blue: 0.30),
        number: Color(red: 0.0, green: 0.25, blue: 0.65),
        type: Color(red: 0.05, green: 0.40, blue: 0.45),
        directive: Color(red: 0.55, green: 0.30, blue: 0.05)
    )

    public static let darkHighContrast = Palette(
        addedForeground: Color(red: 0.45, green: 0.90, blue: 0.45),
        removedForeground: Color(red: 1.0, green: 0.45, blue: 0.45),
        contextForeground: Color(red: 1.0, green: 1.0, blue: 1.0),
        addedBackground: Color(red: 0.06, green: 0.25, blue: 0.06),
        removedBackground: Color(red: 0.30, green: 0.08, blue: 0.08),
        wordAddedBackground: Color(red: 0.10, green: 0.45, blue: 0.10),
        wordRemovedBackground: Color(red: 0.55, green: 0.10, blue: 0.10),
        gutterForeground: Color(red: 0.45, green: 0.45, blue: 0.45),
        gutterBackground: Color(red: 0.06, green: 0.06, blue: 0.06),
        hunkHeaderForeground: Color(red: 0.45, green: 0.80, blue: 1.0),
        hunkHeaderBackground: Color(red: 0.06, green: 0.14, blue: 0.28),
        threadAccent: Color(red: 0.80, green: 0.50, blue: 1.0),
        threadResolved: Color(red: 0.60, green: 0.60, blue: 0.60),
        keyword: Color(red: 0.90, green: 0.55, blue: 1.0),
        string: Color(red: 1.0, green: 0.60, blue: 0.40),
        comment: Color(red: 0.55, green: 0.55, blue: 0.55),
        number: Color(red: 0.55, green: 0.80, blue: 1.0),
        type: Color(red: 0.50, green: 0.90, blue: 0.85),
        directive: Color(red: 0.95, green: 0.65, blue: 0.40)
    )

    public static let light = Palette(
        addedForeground: SwiftUI.Color(red: 0.05, green: 0.45, blue: 0.15),
        removedForeground: SwiftUI.Color(red: 0.75, green: 0.10, blue: 0.10),
        contextForeground: SwiftUI.Color(red: 0.20, green: 0.20, blue: 0.20),
        addedBackground: SwiftUI.Color(red: 0.86, green: 0.95, blue: 0.86),
        removedBackground: SwiftUI.Color(red: 0.98, green: 0.88, blue: 0.88),
        wordAddedBackground: SwiftUI.Color(red: 0.70, green: 0.90, blue: 0.70),
        wordRemovedBackground: SwiftUI.Color(red: 0.96, green: 0.70, blue: 0.70),
        gutterForeground: SwiftUI.Color(red: 0.45, green: 0.45, blue: 0.45),
        gutterBackground: SwiftUI.Color(red: 0.94, green: 0.94, blue: 0.94),
        hunkHeaderForeground: SwiftUI.Color(red: 0.25, green: 0.40, blue: 0.60),
        hunkHeaderBackground: SwiftUI.Color(red: 0.90, green: 0.94, blue: 0.98),
        threadAccent: SwiftUI.Color(red: 0.55, green: 0.35, blue: 0.80),
        threadResolved: SwiftUI.Color(red: 0.50, green: 0.50, blue: 0.50),
        keyword: SwiftUI.Color(red: 0.55, green: 0.20, blue: 0.70),
        string: SwiftUI.Color(red: 0.55, green: 0.20, blue: 0.10),
        comment: SwiftUI.Color(red: 0.45, green: 0.45, blue: 0.45),
        number: SwiftUI.Color(red: 0.10, green: 0.35, blue: 0.70),
        type: SwiftUI.Color(red: 0.15, green: 0.45, blue: 0.50),
        directive: SwiftUI.Color(red: 0.60, green: 0.35, blue: 0.10)
    )

    public static let dark = Palette(
        addedForeground: SwiftUI.Color(red: 0.55, green: 0.85, blue: 0.55),
        removedForeground: SwiftUI.Color(red: 0.95, green: 0.50, blue: 0.50),
        contextForeground: SwiftUI.Color(red: 0.85, green: 0.85, blue: 0.85),
        addedBackground: SwiftUI.Color(red: 0.10, green: 0.22, blue: 0.10),
        removedBackground: SwiftUI.Color(red: 0.25, green: 0.12, blue: 0.12),
        wordAddedBackground: SwiftUI.Color(red: 0.15, green: 0.40, blue: 0.15),
        wordRemovedBackground: SwiftUI.Color(red: 0.45, green: 0.15, blue: 0.15),
        gutterForeground: SwiftUI.Color(red: 0.55, green: 0.55, blue: 0.55),
        gutterBackground: SwiftUI.Color(red: 0.12, green: 0.12, blue: 0.12),
        hunkHeaderForeground: SwiftUI.Color(red: 0.55, green: 0.75, blue: 0.95),
        hunkHeaderBackground: SwiftUI.Color(red: 0.10, green: 0.16, blue: 0.25),
        threadAccent: SwiftUI.Color(red: 0.75, green: 0.55, blue: 0.95),
        threadResolved: SwiftUI.Color(red: 0.55, green: 0.55, blue: 0.55),
        keyword: SwiftUI.Color(red: 0.85, green: 0.60, blue: 0.95),
        string: SwiftUI.Color(red: 0.95, green: 0.65, blue: 0.45),
        comment: SwiftUI.Color(red: 0.55, green: 0.55, blue: 0.55),
        number: SwiftUI.Color(red: 0.60, green: 0.75, blue: 0.95),
        type: SwiftUI.Color(red: 0.55, green: 0.85, blue: 0.80),
        directive: SwiftUI.Color(red: 0.90, green: 0.70, blue: 0.45)
    )
}
