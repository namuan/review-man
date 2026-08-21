import AppKit
import SwiftUI

/// Native Settings content for the app-defined navigation and diff shortcuts.
@MainActor
public struct ShortcutSettingsView: View {
    @ObservedObject private var preferences: ReviewShortcutPreferences
    @State private var errorMessage: String?
    @State private var recordingCommand: ReviewShortcutCommand?

    public init(preferences: ReviewShortcutPreferences? = nil) {
        self.preferences = preferences ?? .shared
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Action")
                            .columnHeaderStyle()
                        Text("Shortcut")
                            .columnHeaderStyle()
                            .frame(width: 132, alignment: .leading)
                        Color.clear
                            .frame(width: 64, height: 1)
                    }

                    ForEach(ReviewShortcutCommand.allCases) { command in
                        GridRow {
                            Text(command.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ShortcutRecorderButton(
                                title: "Shortcut for \(command.title)",
                                shortcut: preferences.shortcut(for: command),
                                isRecording: recordingBinding(for: command),
                                onRecord: { shortcut in
                                    record(shortcut, for: command)
                                }
                            )
                            .frame(width: 132, alignment: .leading)

                            if recordingCommand == command {
                                Button("Cancel") {
                                    recordingCommand = nil
                                }
                                .frame(width: 64, alignment: .leading)
                            } else {
                                Color.clear
                                    .frame(width: 64, height: 1)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                Text("Changes apply immediately and are saved for future launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                Text("Choose shortcuts for your most-used review controls.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recordingBinding(for command: ReviewShortcutCommand) -> Binding<Bool> {
        Binding(
            get: { recordingCommand == command },
            set: { isRecording in
                if isRecording {
                    recordingCommand = command
                } else if recordingCommand == command {
                    recordingCommand = nil
                }
            }
        )
    }

    private func record(_ shortcut: ReviewShortcut, for command: ReviewShortcutCommand) -> Bool {
        let wasSaved = preferences.set(shortcut, for: command)
        errorMessage = wasSaved ? nil : "That shortcut is already assigned to another action."
        return wasSaved
    }

    private func restoreDefaults() {
        preferences.restoreDefaults()
        errorMessage = nil
    }
}

private extension View {
    func columnHeaderStyle() -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    let title: String
    let shortcut: ReviewShortcut
    @Binding var isRecording: Bool
    let onRecord: (ReviewShortcut) -> Bool

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.setAccessibilityLabel(title)
        button.configure(shortcut: shortcut, isRecording: isRecording)
        button.onRecord = onRecord
        button.onRecordingChange = { isRecording in
            self.isRecording = isRecording
        }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.setAccessibilityLabel(title)
        button.onRecord = onRecord
        button.onRecordingChange = { isRecording in
            self.isRecording = isRecording
        }
        button.configure(shortcut: shortcut, isRecording: isRecording)
    }

    final class RecorderButton: NSButton {
        var onRecord: ((ReviewShortcut) -> Bool)?
        var onRecordingChange: ((Bool) -> Void)?

        private var shortcut = ReviewShortcut(key: "d", modifiers: [.command])
        private var isRecording = false {
            didSet {
                title = isRecording ? "Type Shortcut" : shortcut.displayString
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            focusRingType = .default
            setButtonType(.momentaryPushIn)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        func configure(shortcut: ReviewShortcut, isRecording: Bool) {
            self.shortcut = shortcut
            guard self.isRecording != isRecording else {
                if !isRecording { title = shortcut.displayString }
                return
            }
            self.isRecording = isRecording
            if !isRecording, window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard !isRecording else { return }
            isRecording = true
            onRecordingChange?(true)
        }

        override func resignFirstResponder() -> Bool {
            if isRecording {
                isRecording = false
                onRecordingChange?(false)
            }
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
            if onRecord?(shortcut) == true {
                self.shortcut = shortcut
            }
            endRecording()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            keyDown(with: event)
            return true
        }

        override func cancelOperation(_ sender: Any?) {
            endRecording()
        }

        private func endRecording() {
            guard isRecording else { return }
            isRecording = false
            onRecordingChange?(false)
            window?.makeFirstResponder(nil)
        }
    }
}
