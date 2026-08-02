import SwiftUI
import PRReviewKit

/// One diff line: fixed-width old/new gutters plus syntax-colored, word-level
/// highlighted content. Tokenization is demand-driven per realized line.
public struct DiffLineView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let file: DiffFile
    public let hunkIndex: Int
    public let lineIndex: Int

    @Environment(\.colorScheme) private var colorScheme

    public init(store: ReviewSessionStore, file: DiffFile, hunkIndex: Int, lineIndex: Int) {
        self.store = store
        self.file = file
        self.hunkIndex = hunkIndex
        self.lineIndex = lineIndex
    }

    public var body: some View {
        guard let diffLine = file.line(at: hunkIndex, lineIndex) else {
            return AnyView(EmptyView())
        }
        let palette = SemanticTheme.palette(
            for: colorScheme, increasedContrast: AppearanceSettings.increasedContrast
        )
        let gutterWidth = CGFloat(file.gutterDigits * 2 + 3)
        let background = kindBackground(diffLine.kind, palette: palette)

        let gutter = DiffAttributedStringBuilder.gutterText(for: diffLine, digits: file.gutterDigits)
        // Request tokens only when this line is actually realized (viewport-driven).
        let tokens = store.tokenCache.tokens(for: diffLine.content, language: Highlighter.language(for: file.path))
        let content = DiffAttributedStringBuilder.build(line: diffLine, tokens: tokens, palette: palette)

        return AnyView(
            HStack(spacing: 0) {
                Text(gutter)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.gutterForeground)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.leading, 6)
                    .background(palette.gutterBackground.opacity(0.5))
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .background(selectionOrHoverBackground(for: diffLine))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { handleTap(hunkIndex: hunkIndex, lineIndex: lineIndex) }
            .onHover { hovering in
                store.hoveredRowID = hovering ? DiffRowID.line(
                    file: file.path, hunk: hunkIndex, kind: diffLine.kind,
                    old: diffLine.oldLine, new: diffLine.newLine
                ) : nil
            }
            .contextMenu {
                Button("Comment") {
                    if let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: hunkIndex, lineIndex: lineIndex) {
                        store.beginDraft(at: DraftStartAnchor(
                            path: anchor.path, side: anchor.side, line: anchor.line,
                            startLine: anchor.startLine, startSide: anchor.startSide
                        ))
                    }
                }
                Button("Copy \(file.path):\(diffLine.newLine ?? diffLine.oldLine ?? 0)") {
                    _ = store.copyLineToClipboard(file: file, hunkIndex: hunkIndex, lineIndex: lineIndex)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lineAccessibilityLabel(for: diffLine))
            .accessibilityIdentifier("diff-line-\(file.path)-h\(hunkIndex)-\(diffLine.oldLine ?? -1)-\(diffLine.newLine ?? -1)")
        )
    }

    /// Selected rows win over hovered rows; hover uses a light overlay so it
    /// does not fight the kind background.
    private func selectionOrHoverBackground(for diffLine: DiffLine) -> SwiftUI.Color {
        let id = DiffRowID.line(
            file: file.path, hunk: hunkIndex, kind: diffLine.kind,
            old: diffLine.oldLine, new: diffLine.newLine
        )
        if store.selection.rowID == id { return SwiftUI.Color.accentColor.opacity(0.18) }
        if store.hoveredRowID == id { return SwiftUI.Color.gray.opacity(0.10) }
        return kindBackground(diffLine.kind, palette: SemanticTheme.palette(
            for: colorScheme, increasedContrast: AppearanceSettings.increasedContrast
        ))
    }

    /// One meaningful VoiceOver label per line.
    private func lineAccessibilityLabel(for diffLine: DiffLine) -> String {
        let kindWord: String
        switch diffLine.kind {
        case .added: kindWord = "Added"
        case .removed: kindWord = "Removed"
        case .context: kindWord = "Context"
        }
        let lineNumber = diffLine.newLine ?? diffLine.oldLine ?? 0
        return "\(kindWord) line \(lineNumber), \(file.path): \(diffLine.content)"
    }

    /// Click selects the line; Shift-click completes a range. Ranges are
    /// validated and either begin a draft or show an explanation.
    private func handleTap(hunkIndex: Int, lineIndex: Int) {
        guard let diffLine = file.line(at: hunkIndex, lineIndex) else { return }
        let isShift = NSEvent.modifierFlags.contains(.shift)
        if isShift, let startRow = store.selection.rowID {
            // Shift-click: build the range from the current line + anchor line.
            let end = (file, hunkIndex, lineIndex)
            var start: (file: DiffFile, hunkIndex: Int, lineIndex: Int)?
            if let position = store.linePosition(for: startRow, in: file) {
                start = (file, position.hunk, position.lineIndex)
            }
            let result = DraftRangeValidator().validate(start: start, end: end)
            switch result {
            case .single(let anchor):
                store.beginDraft(at: DraftStartAnchor(
                    path: anchor.path, side: anchor.side, line: anchor.line
                ))
            case .range(let anchor):
                store.beginDraft(at: DraftStartAnchor(
                    path: anchor.path, side: anchor.side, line: anchor.line,
                    startLine: anchor.startLine, startSide: anchor.startSide
                ))
            case .invalid(let reason):
                store.banner = SessionBanner(text: reason, isError: true)
            }
            store.selection.rowID = nil
        } else {
            store.selection.rowID = DiffRowID.line(
                file: file.path, hunk: hunkIndex, kind: diffLine.kind,
                old: diffLine.oldLine, new: diffLine.newLine
            )
        }
    }

    private func kindBackground(_ kind: DiffLine.Kind, palette: SemanticTheme.Palette) -> SwiftUI.Color {
        switch kind {
        case .added: return palette.addedBackground
        case .removed: return palette.removedBackground
        case .context: return .clear
        }
    }
}

/// A unified hunk header row.
public struct HunkHeaderView: View {
    public let hunk: DiffHunk

    public init(hunk: DiffHunk) {
        self.hunk = hunk
    }

    public var body: some View {
        Text(hunk.header)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SwiftUI.Color.gray.opacity(0.08))
            .accessibilityIdentifier("hunk-header")
    }
}

/// An inline thread card: active (accent), resolved (dimmed), or outdated
/// (under the outdated header). Reply and resolve controls (Phase 6).
public struct ThreadCardView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let thread: PRThread

    public init(store: ReviewSessionStore, thread: PRThread) {
        self.store = store
        self.thread = thread
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    let root = thread.rootComment
                    Text("\(root?.author ?? "?") · \(root.map { timeAgo($0.createdAt) } ?? "")\(thread.isResolved ? " · resolved" : "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(thread.isResolved ? .secondary : .primary)
                    ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(comment.author) · \(timeAgo(comment.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(comment.body)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                        }
                    }
                    if !thread.isOutdated {
                        HStack(spacing: 10) {
                            Button("Reply") { store.beginReply(threadID: thread.id) }
                                .font(.caption2)
                                .accessibilityIdentifier("thread-reply-button-\(thread.id)")
                            Button(thread.isResolved ? "Unresolve" : "Resolve") {
                                store.toggleResolved(threadID: thread.id)
                            }
                            .font(.caption2)
                            .accessibilityIdentifier("thread-resolve-button-\(thread.id)")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let reply = store.replyEditors[thread.id] {
                replyEditor(reply)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !thread.isOutdated {
                Button("Reply") { store.beginReply(threadID: thread.id) }
                Button(thread.isResolved ? "Unresolve" : "Resolve") {
                    store.toggleResolved(threadID: thread.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-card-\(thread.id)")
    }

    private func replyEditor(_ reply: ReplyEditorState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: Binding(
                get: { store.replyEditors[reply.threadID]?.body ?? "" },
                set: { newValue in
                    var editor = store.replyEditors[reply.threadID]
                    editor?.body = newValue
                    store.replyEditors[reply.threadID] = editor
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 48)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            .accessibilityIdentifier("reply-editor-\(reply.threadID)")
            HStack(spacing: 8) {
                if reply.retryFailed {
                    Label("Failed — Retry keeps your text", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Spacer()
                if reply.retryFailed {
                    Button("Edit") {
                        var e = store.replyEditors[reply.threadID]
                        e?.retryFailed = false
                        store.replyEditors[reply.threadID] = e
                    }
                    .font(.caption2)
                }
                Button(reply.retryFailed ? "Retry" : "Send") { store.sendReply(threadID: reply.threadID) }
                    .buttonStyle(.borderedProminent)
                    .font(.caption2)
                    .accessibilityIdentifier("reply-send-button-\(reply.threadID)")
                Button("Cancel") { store.cancelReply(threadID: reply.threadID) }
                    .font(.caption2)
            }
        }
        .padding(.leading, 9)
    }

    private var accentColor: SwiftUI.Color {
        thread.isResolved ? .gray : (thread.isOutdated ? .secondary : .purple)
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
