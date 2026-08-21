import AppKit
import SwiftUI

/// A user-configurable keyboard shortcut for a review command.
public struct ReviewShortcut: Codable, Equatable {
    public enum Modifier: String, Codable, CaseIterable {
        case command
        case option
        case control
        case shift
    }

    public let key: Character
    public let modifiers: Set<Modifier>

    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    public init(key: Character, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        guard key.count == 1, let character = key.first else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Shortcut keys must be one character.")
        }
        self.init(key: character, modifiers: try container.decode(Set<Modifier>.self, forKey: .modifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(key), forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }

    public init?(event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key.count == 1,
              let character = key.first else {
            return nil
        }
        self.init(key: character, modifiers: Self.modifiers(for: event.modifierFlags))
    }

    public var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key), modifiers: eventModifiers)
    }

    public var displayString: String {
        let modifierSymbols = [
            (Modifier.control, "⌃"),
            (Modifier.option, "⌥"),
            (Modifier.shift, "⇧"),
            (Modifier.command, "⌘")
        ]
        return modifierSymbols
            .filter { modifiers.contains($0.0) }
            .map { $0.1 }
            .joined() + key.uppercased()
    }

    private var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    private static func modifiers(for flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        var result: Set<Modifier> = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

public enum ReviewShortcutCommand: String, CaseIterable, Identifiable {
    case toggleDiffLayout
    case toggleSidebar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggleDiffLayout: "Toggle Diff Layout"
        case .toggleSidebar: "Toggle Sidebar"
        }
    }

    var defaultShortcut: ReviewShortcut {
        switch self {
        case .toggleDiffLayout:
            ReviewShortcut(key: "d", modifiers: [.command, .control, .option])
        case .toggleSidebar:
            ReviewShortcut(key: "s", modifiers: [.command, .control])
        }
    }
}

/// Stores application-level shortcut settings in the user's defaults database.
/// UserDefaults is macOS's standard persistence mechanism for non-sensitive
/// application preferences.
@MainActor
public final class ReviewShortcutPreferences: ObservableObject {
    public static let shared = ReviewShortcutPreferences()

    private static let storagePrefix = "PRReview.reviewShortcut."

    @Published private var shortcuts: [ReviewShortcutCommand: ReviewShortcut]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = Dictionary(uniqueKeysWithValues: ReviewShortcutCommand.allCases.map { command in
            (command, Self.load(command, defaults: defaults))
        })
    }

    public func shortcut(for command: ReviewShortcutCommand) -> ReviewShortcut {
        shortcuts[command] ?? command.defaultShortcut
    }

    /// Saves a shortcut unless it duplicates another configurable command.
    @discardableResult
    public func set(_ shortcut: ReviewShortcut, for command: ReviewShortcutCommand) -> Bool {
        guard !shortcuts.contains(where: { $0.key != command && $0.value == shortcut }) else {
            return false
        }
        shortcuts[command] = shortcut
        persist(shortcut, for: command)
        return true
    }

    public func restoreDefaults() {
        for command in ReviewShortcutCommand.allCases {
            let shortcut = command.defaultShortcut
            shortcuts[command] = shortcut
            defaults.removeObject(forKey: Self.storageKey(for: command))
        }
    }

    private static func load(_ command: ReviewShortcutCommand, defaults: UserDefaults) -> ReviewShortcut {
        guard let data = defaults.data(forKey: storageKey(for: command)),
              let shortcut = try? JSONDecoder().decode(ReviewShortcut.self, from: data) else {
            return command.defaultShortcut
        }
        return shortcut
    }

    private func persist(_ shortcut: ReviewShortcut, for command: ReviewShortcutCommand) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: Self.storageKey(for: command))
    }

    private static func storageKey(for command: ReviewShortcutCommand) -> String {
        storagePrefix + command.rawValue
    }
}
