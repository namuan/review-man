import SwiftUI
import AppKit
import PRReviewKit

/// Intercepts window close attempts when the latest persistence operation
/// failed (the plan's close-warning contract). Shows a confirmation; "Close
/// Anyway" bypasses the delegate once via a programmatic close.
public struct CloseWarningBridge: NSViewRepresentable {
    @ObservedObject public var store: ReviewSessionStore
    @Binding public var showWarning: Bool

    public init(store: ReviewSessionStore, showWarning: Binding<Bool>) {
        self.store = store
        self._showWarning = showWarning
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.delegate = context.coordinator
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.store = store
        context.coordinator.showWarning = { showWarning = true }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject, NSWindowDelegate {
        var store: ReviewSessionStore?
        var showWarning: (() -> Void)?
        var forceClose = false

        public func windowShouldClose(_ sender: NSWindow) -> Bool {
            if forceClose { return true }
            if let store, store.persistenceFailure != nil {
                showWarning?()
                return false
            }
            return true
        }
    }
}
