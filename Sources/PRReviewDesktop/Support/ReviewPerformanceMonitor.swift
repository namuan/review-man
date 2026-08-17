import Foundation
import os
import PRReviewKit

/// Main-actor coordinator for the UI part of the Phase 1 baseline.
///
/// The monitor measures the interval from a file selection to the first
/// interactive diff frame. It also emits signposts for navigation and draft
/// editor presentation so Instruments can correlate user actions with SwiftUI
/// work. It owns no review state and is safe to leave enabled in production.
@MainActor
public final class ReviewPerformanceMonitor {

    private struct PendingDiffSelection {
        let token: UUID
        let path: String
        let lineCount: Int
        let startedAt: UInt64
        let signpostID: OSSignpostID
    }

    private struct PendingDraftEditor {
        let path: String
        let line: Int
        let startedAt: UInt64
        let signpostID: OSSignpostID
    }

    private var pendingDiffSelection: PendingDiffSelection?
    private var pendingDraftEditor: PendingDraftEditor?

    public init() {}

    public func beginFileSelection(path: String, lineCount: Int) {
        finishPendingDiffSelection(reason: "superseded")
        pendingDiffSelection = PendingDiffSelection(
            token: UUID(),
            path: path,
            lineCount: lineCount,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            signpostID: PerformanceLog.begin("DiffFileSelection")
        )
        PerformanceLog.event("DiffFileSelectionRequested")
    }

    /// Starts a selection measurement for the initial file when no sidebar or
    /// canvas action preceded the first diff view.
    public func ensureFileSelection(path: String, lineCount: Int) {
        guard pendingDiffSelection?.path != path else { return }
        beginFileSelection(path: path, lineCount: lineCount)
    }

    /// Called from the diff view's `onAppear`. The extra main-queue turn marks
    /// the point after SwiftUI has had a chance to commit the first frame.
    public func diffDidAppear(path: String, lineCount: Int, rowCount: Int, hunkCount: Int) {
        ensureFileSelection(path: path, lineCount: lineCount)
        guard let pending = pendingDiffSelection, pending.path == path else { return }

        PerformanceLog.event("DiffFirstVisible")
        AppLog.info(
            "perf",
            "diff-visible path=\(path); lines=\(lineCount); hunks=\(hunkCount); rows=\(rowCount)"
        )

        let token = pending.token
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      let current = self.pendingDiffSelection,
                      current.token == token else { return }
                self.recordFirstInteractiveFrame(current)
            }
        }
    }

    public func diffDidDisappear(path: String) {
        guard pendingDiffSelection?.path == path else { return }
        finishPendingDiffSelection(reason: "disappeared-before-frame")
    }

    public func recordNavigation() {
        // Keep this hot path to a signpost only. File logging would distort
        // the keyboard-navigation measurement when a key is held down.
        PerformanceLog.event("DiffNavigation")
    }

    public func beginDraftEditor(path: String, line: Int) {
        if let pendingDraftEditor {
            PerformanceLog.end("DraftEditorPresentation", id: pendingDraftEditor.signpostID)
        }
        pendingDraftEditor = PendingDraftEditor(
            path: path,
            line: line,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            signpostID: PerformanceLog.begin("DraftEditorPresentation")
        )
        PerformanceLog.event("DraftEditorRequested")
    }

    public func draftEditorDidAppear(path: String, line: Int) {
        guard let pending = pendingDraftEditor,
              pending.path == path,
              pending.line == line else { return }
        PerformanceLog.end("DraftEditorPresentation", id: pending.signpostID)
        pendingDraftEditor = nil
        AppLog.info(
            "perf",
            "draft-editor-visible path=\(path); line=\(line); elapsedMs=\(elapsedMilliseconds(since: pending.startedAt))"
        )
    }

    private func recordFirstInteractiveFrame(_ pending: PendingDiffSelection) {
        PerformanceLog.end("DiffFileSelection", id: pending.signpostID)
        pendingDiffSelection = nil
        AppLog.info(
            "perf",
            "diff-first-interactive path=\(pending.path); lines=\(pending.lineCount); elapsedMs=\(elapsedMilliseconds(since: pending.startedAt))"
        )
    }

    private func finishPendingDiffSelection(reason: String) {
        guard let pending = pendingDiffSelection else { return }
        PerformanceLog.end("DiffFileSelection", id: pending.signpostID)
        pendingDiffSelection = nil
        AppLog.info(
            "perf",
            "diff-selection-ended path=\(pending.path); reason=\(reason); elapsedMs=\(elapsedMilliseconds(since: pending.startedAt))"
        )
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> String {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        return String(format: "%.2f", Double(elapsed) / 1_000_000)
    }
}
