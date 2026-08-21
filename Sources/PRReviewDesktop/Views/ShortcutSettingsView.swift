import AppKit
import SwiftUI

/// Native Settings content for the app-defined navigation and diff shortcuts.
@MainActor
public struct ShortcutSettingsView: View {
    @ObservedObject private var preferences: ReviewShortcutPreferences
    @State private var errorMessage: String?

    public init(preferences: ReviewShortcutPreferences? = nil) {
        self.preferences = preferences ?? .shared
    }

    public var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(ReviewShortcutCommand.allCases) { command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        ShortcutRecorderButton(
                            title: "Shortcut for \(command.title)",
                            shortcut: preferences.shortcut(for: command)
                        ) { shortcut in
                            record(shortcut, for: command)
                        }
                    }
                }
            }

            Section {
                Text("Click a field, then press Command plus the key you want to use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Restore Defaults", action: restoreDefaults)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }

    private func record(_ shortcut: ReviewShortcut, for command: ReviewShortcutCommand) {
        errorMessage = preferences.set(shortcut, for: command)
            ? nil
            : "That shortcut is already assigned to another action."
    }

    private func restoreDefaults() {
        preferences.restoreDefaults()
        errorMessage = nil
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    let title: String
    let shortcut: ReviewShortcut
    let onRecord: (ReviewShortcut) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.setAccessibilityLabel(title)
        button.onRecord = onRecord
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.setAccessibilityLabel(title)
        button.onRecord = onRecord
        button.shortcut = shortcut
    }

    final class RecorderButton: NSButton {
        var onRecord: ((ReviewShortcut) -> Void)?
        var shortcut: ReviewShortcut {
            didSet {
                guard !isRecording else { return }
                title = shortcut.displayString
            }
        }

        private var isRecording = false {
            didSet {
                title = isRecording ? "Type Shortcut" : shortcut.displayString
            }
        }

        override init(frame frameRect: NSRect) {
            shortcut = ReviewShortcut(key: "d", modifiers: [.command])
            super.init(frame: frameRect)
            bezelStyle = .rounded
            focusRingType = .default
            setButtonType(.momentaryPushIn)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            guard let shortcut = ReviewShortcut(event: event) else {
                NSSound.beep()
                return
            }
            onRecord?(shortcut)
            window?.makeFirstResponder(nil)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            keyDown(with: event)
            return true
        }

        override func cancelOperation(_ sender: Any?) {
            window?.makeFirstResponder(nil)
        }
    }
}
