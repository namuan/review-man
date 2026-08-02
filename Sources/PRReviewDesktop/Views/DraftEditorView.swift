import SwiftUI
import PRReviewKit

/// Inline draft comment editor (new or editing an existing draft).
public struct DraftEditorView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let editor: DraftEditorState

    @FocusState private var focused: Bool

    public init(store: ReviewSessionStore, editor: DraftEditorState) {
        self.store = store
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { store.draftEditor?.text ?? "" },
                set: { newValue in
                    var editor = store.draftEditor
                    editor?.text = newValue
                    store.draftEditor = editor
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 140)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            .onAppear { focused = true }
            .accessibilityIdentifier("draft-editor")
            HStack(spacing: 8) {
                Button("Save") { store.saveDraftEditor() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("draft-save-button")
                Button("Cancel") { store.cancelDraftEditor() }
                    .accessibilityIdentifier("draft-cancel-button")
                Spacer()
                if let draft = editor.draftID {
                    Button("Delete") {
                        if let draft = store.review?.drafts.first(where: { $0.id == editor.draftID }) {
                            store.cancelDraftEditor()
                            store.deleteDraft(draft)
                        }
                    }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("draft-delete-button")
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let start = editor.startLine, start != editor.line {
            return "Comment on \(editor.path):\(start)–\(editor.line) (\(editor.side))"
        }
        return "Comment on \(editor.path):\(editor.line) (\(editor.side))"
    }
}

/// Submit-review sheet: event picker, summary, included-draft list, and
/// validation/uncertain messaging.
public struct SubmitReviewView: View {
    @ObservedObject public var store: ReviewSessionStore
    @Environment(\.dismiss) private var dismiss

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Submit review")
                .font(.headline)

            Picker("Event", selection: $store.submitEvent) {
                ForEach(ReviewEvent.allCases, id: \.self) { event in
                    Text(event.label).tag(event)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Summary")
                .font(.caption)
            TextEditor(text: $store.submitBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                .accessibilityIdentifier("submit-body-editor")

            let submittable = (store.review?.drafts ?? []).filter { !$0.isOrphaned }
            let orphans = (store.review?.drafts ?? []).count - submittable.count
            VStack(alignment: .leading, spacing: 2) {
                Text("Drafts included (\(submittable.count))\(orphans > 0 ? " · \(orphans) orphaned excluded" : "")")
                    .font(.caption)
                ForEach(submittable.prefix(6), id: \.id) { draft in
                    Text("· \(draft.path):\(draft.line)  \(draft.body.split(separator: "\n").first.map(String.init) ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let message = store.submitValidationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("submit-validation")
            }
            if case .failed(let message) = store.submitState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("submit-error")
            }
            if case .uncertain(let message) = store.submitState {
                Label(message, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("submit-uncertain")
            }

            HStack {
                Button("Cancel") {
                    store.cancelSubmit()
                    dismiss()
                }
                Spacer()
                Button("Submit") { store.submitReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.submitState == .submitting)
                    .accessibilityIdentifier("submit-button")
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
    }
}
