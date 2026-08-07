import Foundation
import PRReviewKit

/// A snapshot of the store state a command needs to decide enablement. Pure
/// and unit-testable without SwiftUI.
public struct ReviewCommandContext {
    public let state: PresentationState
    public let isDemo: Bool
    public let hasSelectedFile: Bool
    /// True when the selection resolves to a commentable diff line.
    public let hasCommentableSelection: Bool
    public let selectedThreadIsActive: Bool
    public let selectedThreadHasRootComment: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let draftEditorOpen: Bool
    public let submitHidden: Bool
    public let isSubmitting: Bool
    public let canSubmit: Bool
    public let hasPRURL: Bool
    /// Any distinct comment author exists (hide menu is offerable).
    public let hasReviewers: Bool
    /// At least one reviewer is currently hidden (show-all is offerable).
    public let hasHiddenReviewers: Bool

    public init(
        state: PresentationState, isDemo: Bool, hasSelectedFile: Bool,
        hasCommentableSelection: Bool, selectedThreadIsActive: Bool,
        selectedThreadHasRootComment: Bool, canUndo: Bool, canRedo: Bool,
        draftEditorOpen: Bool, submitHidden: Bool, isSubmitting: Bool,
        canSubmit: Bool, hasPRURL: Bool,
        hasReviewers: Bool = false, hasHiddenReviewers: Bool = false
    ) {
        self.state = state
        self.isDemo = isDemo
        self.hasSelectedFile = hasSelectedFile
        self.hasCommentableSelection = hasCommentableSelection
        self.selectedThreadIsActive = selectedThreadIsActive
        self.selectedThreadHasRootComment = selectedThreadHasRootComment
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.draftEditorOpen = draftEditorOpen
        self.submitHidden = submitHidden
        self.isSubmitting = isSubmitting
        self.canSubmit = canSubmit
        self.hasPRURL = hasPRURL
        self.hasReviewers = hasReviewers
        self.hasHiddenReviewers = hasHiddenReviewers
    }
}

/// Dynamic enablement for the Review menu and toolbar, derived purely from
/// `ReviewCommandContext`.
public struct ReviewCommandAvailability {

    public let canOpen: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let canFind: Bool
    public let canAddComment: Bool
    public let canReply: Bool
    public let canResolve: Bool
    public let canToggleViewed: Bool
    public let canSubmit: Bool
    public let canRefresh: Bool
    public let canOpenInBrowser: Bool
    public let canCopyLine: Bool
    public let canToggleSidebar: Bool
    public let canHideReviewer: Bool
    public let canShowHiddenComments: Bool

    public init(context: ReviewCommandContext) {
        let loaded = context.state == .loaded
        // An empty PR (no changed files) is still reviewable via a body-only
        // review, so submit stays available in the .empty state.
        let reviewable = loaded || context.state == .empty
        canOpen = true
        canUndo = context.canUndo
        canRedo = context.canRedo
        canFind = loaded
        canAddComment = loaded && context.hasCommentableSelection && !context.draftEditorOpen
        canReply = loaded && context.selectedThreadIsActive && context.selectedThreadHasRootComment
        canResolve = loaded && context.selectedThreadIsActive
        canToggleViewed = loaded && context.hasSelectedFile
        canSubmit = reviewable && context.submitHidden && !context.isSubmitting && context.canSubmit
        canRefresh = loaded
        canOpenInBrowser = loaded && context.hasPRURL
        canCopyLine = loaded && context.hasCommentableSelection
        canToggleSidebar = loaded
        canHideReviewer = loaded && context.hasReviewers
        canShowHiddenComments = loaded && context.hasHiddenReviewers
    }
}
