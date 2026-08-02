import SwiftUI
import AppKit
import PRReviewKit
import PRReviewDesktop

/// The macOS application entry point. Each review window owns its own
/// `ReviewSessionStore`; `WindowGroup(for:)` gives one window per key and
/// `AppCoordinator` owns the stores and URL routing.
@main
struct PRReviewApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("PR Review", for: String.self) { $key in
            ReviewWindowView(store: coordinator.store(for: key))
                .background(OpenWindowProxy())
                .environmentObject(coordinator)
                .onOpenURL { url in
                    coordinator.handle(url: url)
                }
                .onAppear {
                    // UI-test/demo launch path: --demo opens the offline sample
                    // review without gh, persistence, or dependency checks.
                    if coordinator.consumeAutoOpenDemo() {
                        coordinator.store(for: nil).openDemo()
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            ReviewCommands()
        }
    }
}

/// Owns per-window session stores (keyed by the WindowGroup value) and routes
/// incoming URLs and new-window requests. Window creation uses `openWindow`,
/// which is only available from a view context, so a small proxy view inside
/// each window observes these requests and performs the open.
@MainActor
final class AppCoordinator: ObservableObject {

    @Published var pendingOpenReference: String?

    private var stores: [String: ReviewSessionStore] = [:]
    private var autoOpenDemo = CommandLine.arguments.contains("--demo")

    /// Consumed once per process; returns true when the first blank window
    /// should open the demo review.
    func consumeAutoOpenDemo() -> Bool {
        let should = autoOpenDemo
        autoOpenDemo = false
        return should
    }

    func store(for key: String?) -> ReviewSessionStore {
        let resolvedKey = key ?? "default"
        if let existing = stores[resolvedKey] {
            return existing
        }
        // The preference-backed resolver is shared: a user-selected executable
        // affects normal PR operations, not just the health check.
        let preference = GitHubExecutablePreference()
        let resolver = GitHubExecutableResolver(overrideURL: preference.selectedExecutableURL)
        let store = ReviewSessionStore(
            service: GitHubClient(resolver: resolver),
            persistence: ReviewPersistence.shared,
            preference: preference
        )
        stores[resolvedKey] = store
        return store
    }

    /// Accepts `pr-review://open/<owner>/<repo>/<number>` (from the terminal
    /// launcher) and plain `https://github.com/...` URLs.
    func handle(url: URL) {
        guard let reference = ReviewURLCoordinator.reference(for: url) else { return }
        // The proxy view inside each window observes this and calls
        // openWindow(value:) — creating or focusing the keyed window.
        pendingOpenReference = reference
    }

    /// Called by the proxy view to actually open/focus a window.
    func consumePendingOpen(_ open: OpenWindowAction) {
        guard let reference = pendingOpenReference else { return }
        pendingOpenReference = nil
        open(value: reference)
    }
}

/// Hosted inside every review window: observes new-window/open requests and
/// performs the `openWindow(value:)` call, which SwiftUI routes to the
/// WindowGroup — creating a fresh window for a new value or focusing the
/// existing window for the same value (duplicate-window policy).
struct OpenWindowProxy: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(coordinator.$pendingOpenReference) { reference in
                if let reference {
                    openWindow(value: reference)
                    coordinator.pendingOpenReference = nil
                }
            }
    }
}
