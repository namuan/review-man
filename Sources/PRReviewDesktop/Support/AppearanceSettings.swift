import AppKit

/// Accessibility preference reads for macOS 13 (the SwiftUI environment keys
/// for these arrive in macOS 14; the NSWorkspace accessors are the 13-safe
/// source). Read at view-appear time; live change observation is a Phase 9
/// refinement.
public enum AppearanceSettings {
    public static var increasedContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
