import SwiftUI
import PRReviewKit

/// Focused command target: the store of the active review window. Windows
/// publish their store via `.focusedSceneValue`, and commands act only on the
/// focused window.
public struct ReviewCommandTargetKey: FocusedValueKey {
    public typealias Value = ReviewSessionStore
}

public extension FocusedValues {
    var reviewCommandTarget: ReviewSessionStore? {
        get { self[ReviewCommandTargetKey.self] }
        set { self[ReviewCommandTargetKey.self] = newValue }
    }
}

/// SwiftUI Commands for the review window. Presentation only — enablement is
/// derived from `ReviewCommandAvailability`, and actions re-check their
/// preconditions in the store. The focused store drives both.
public struct ReviewCommands: Commands {

    @FocusedValue(\.reviewCommandTarget) private var focusedStore

    public init() {}

    public var body: some Commands {
        // The system File > New Window (Cmd-N) is provided by WindowGroup(for:)
        // and is scoped correctly; we only add Open Pull Request.
        CommandGroup(after: .newItem) {
            Button("Open Pull Request…") {
                NotificationCenter.default.post(name: .reviewOpenRequest, object: focusedStore)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(focusedStore == nil)
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Draft") {
                focusedStore?.undoDraft()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!availability.canUndo)

            Button("Redo Draft") {
                focusedStore?.redoDraft()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!availability.canRedo)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Files") {
                focusedStore?.requestFocus = .sidebarSearch
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!availability.canFind)
        }

        CommandMenu("Review") {
            Button("Add Comment") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewAddCommentRequest, object: focusedStore)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!availability.canAddComment)

            Button("Reply") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewReplyRequest, object: focusedStore)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!availability.canReply)

            Button("Resolve / Unresolve") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewResolveRequest, object: focusedStore)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!availability.canResolve)

            Button("Toggle Viewed") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewToggleViewedRequest, object: focusedStore)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(!availability.canToggleViewed)

            Divider()

            Menu("Hide Comments by…") {
                if let names = focusedStore?.reviewerNames, !names.isEmpty {
                    ForEach(names, id: \.self) { name in
                        Button(name) {
                            focusedStore?.hideReviewer(name)
                        }
                    }
                } else {
                    Text("No commenters yet")
                }
            }
            .disabled(!availability.canHideReviewer)

            Button("Show Hidden Comments") {
                focusedStore?.unhideAllReviewers()
            }
            .disabled(!availability.canShowHiddenComments)

            Divider()

            Button("Submit Review…") {
                focusedStore?.requestFocus = .submitSheet
                NotificationCenter.default.post(name: .reviewSubmitRequest, object: focusedStore)
            }
            .keyboardShortcut(KeyEquivalent.return, modifiers: [.command, .shift])
            .disabled(!availability.canSubmit)

            Button("Refresh") {
                focusedStore?.requestFocus = .diff
                NotificationCenter.default.post(name: .reviewRefreshRequest, object: focusedStore)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!availability.canRefresh)
        }

        CommandMenu("Navigate") {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .reviewToggleSidebarRequest, object: focusedStore)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            Button("Previous File") {
                NotificationCenter.default.post(name: .reviewPreviousFileRequest, object: focusedStore)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next File") {
                NotificationCenter.default.post(name: .reviewNextFileRequest, object: focusedStore)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Hunk") {
                NotificationCenter.default.post(name: .reviewPreviousHunkRequest, object: focusedStore)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            Button("Next Hunk") {
                NotificationCenter.default.post(name: .reviewNextHunkRequest, object: focusedStore)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
        }
    }

    private var availability: ReviewCommandAvailability {
        guard let store = focusedStore else {
            return ReviewCommandAvailability(context: ReviewCommandContext(
                state: .welcome, isDemo: false, hasSelectedFile: false,
                hasCommentableSelection: false, selectedThreadIsActive: false,
                selectedThreadHasRootComment: false, canUndo: false, canRedo: false,
                draftEditorOpen: false, submitHidden: true, isSubmitting: false,
                canSubmit: false, hasPRURL: false
            ))
        }
        return ReviewCommandAvailability(context: store.commandContext())
    }
}

public extension Notification.Name {
    static let reviewNewWindowRequest = Notification.Name("review.newWindow")
    static let reviewOpenRequest = Notification.Name("review.open")
    static let reviewFindRequest = Notification.Name("review.find")
    static let reviewAddCommentRequest = Notification.Name("review.addComment")
    static let reviewReplyRequest = Notification.Name("review.reply")
    static let reviewResolveRequest = Notification.Name("review.resolve")
    static let reviewToggleViewedRequest = Notification.Name("review.toggleViewed")
    static let reviewSubmitRequest = Notification.Name("review.submit")
    static let reviewRefreshRequest = Notification.Name("review.refresh")
    static let reviewToggleSidebarRequest = Notification.Name("review.toggleSidebar")
    static let reviewPreviousFileRequest = Notification.Name("review.previousFile")
    static let reviewNextFileRequest = Notification.Name("review.nextFile")
    static let reviewPreviousHunkRequest = Notification.Name("review.previousHunk")
    static let reviewNextHunkRequest = Notification.Name("review.nextHunk")
}
