import Foundation
import Combine
import PRReviewKit

/// A nonmodal status banner (message + whether it is an error).
public struct SessionBanner: Equatable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Where a command asks the window to move focus.
public enum ReviewFocusTarget: Equatable {
    case sidebarSearch
    case diff
    case submitSheet
    case none
}

/// The desktop session store: owns the GitHub service, persistence, a
/// per-window syntax token cache, and the load lifecycle. All state is
/// published on the main actor. Phase 5 is read-only; Phase 6 adds review
/// operations through a shared core service rather than the TUI controller.
@MainActor
public final class ReviewSessionStore: ObservableObject {

    @Published public var state: PresentationState = .welcome
    @Published public var review: ReviewPresentation?
    @Published public var selection = ReviewSelection()
    @Published public var sidebarSearch = ""
    @Published public var banner: SessionBanner?
    @Published public var isBusy = false
    @Published public var persistenceFailure: PersistenceFailure?
    /// One-shot focus request consumed by the window (commands route here).
    @Published public var requestFocus: ReviewFocusTarget = .none
    /// The single hovered diff row (Phase 7: one identity, not per-row state).
    @Published public var hoveredRowID: DiffRowID?
    // Phase 8 dependency health.
    @Published public var _dependencyStatus: GitHubDependencyStatus?
    @Published public var isCheckingDependency = false
    var didStartDependencyCheck = false
    var suppressDependencyCheck = false
    var dependencyGeneration = 0
    // Phase 6 workflow state.
    @Published public var draftEditor: DraftEditorState?
    @Published public var replyEditors: [String: ReplyEditorState] = [:]
    @Published public var submitState: SubmitPresentationState = .hidden
    @Published public var submitEvent: ReviewEvent = .comment
    @Published public var submitBody = ""
    @Published public var submitValidationMessage: String?

    public let service: GitHubServing
    public let persistence: ReviewPersisting
    /// Rendered diff lines, cached so file switches in large PRs don't
    /// re-tokenize / re-attribute the viewport. Bounded LRU, per window.
    public let diffLineCache = DiffLineCache()

    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    /// The most recent requested reference (or "demo"), retained for retry.
    public private(set) var lastRequestedReference: String?
    var demoSession = false
    var resolveGenerations: [String: Int] = [:]
    var refreshTask: Task<Void, Never>?
    var refreshGeneration = 0
    var submitTask: Task<Void, Never>?
    var undoStack: [DraftMutation] = []
    var redoStack: [DraftMutation] = []
    /// Test diagnostics: how many resolve completions (success or failure) the
    /// store has processed. Lets tests wait until every released resolve has
    /// been handled before asserting rollback behavior.
    var resolveHandlingCount = 0
    let preference: GitHubExecutablePreference
    let dependencyRunner: CommandRunning?

    public init(
        service: GitHubServing,
        persistence: ReviewPersisting,
        preference: GitHubExecutablePreference = GitHubExecutablePreference(),
        dependencyRunner: CommandRunning? = nil
    ) {
        self.service = service
        self.persistence = persistence
        self.preference = preference
        self.dependencyRunner = dependencyRunner
    }

    // MARK: - Loading

    public func openDemo(scale: DemoScale = .small, files: Int? = nil, lines: Int? = nil) {
        suppressDependencyCheck = true
        startLoad(reference: nil, demo: true, scale: scale, files: files, lines: lines)
    }

    /// Opens a qualified reference (full URL or `owner/repo#number`).
    public func open(reference: String) {
        startLoad(reference: reference, demo: false, scale: .small)
    }

    public func cancelLoad() {
        // Invalidate the generation so even a cancellation-uncooperative load
        // cannot apply a stale result after the user cancelled.
        loadGeneration += 1
        loadTask?.cancel()
        if case .loading = state {
            state = .welcome
        }
        isBusy = false
    }

    private func startLoad(reference: String?, demo: Bool, scale: DemoScale, files: Int? = nil, lines: Int? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()

        lastRequestedReference = demo ? "demo" : reference
        let label = demo ? "demo-\(scale)" : (reference ?? "")
        state = .loading(reference: label)
        isBusy = true
        banner = nil

        let loader = ReviewSessionLoader(service: service, persistence: persistence)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation: ReviewPresentation
                if demo {
                    presentation = try await loader.loadDemo(scale: scale, files: files, lines: lines)
                } else {
                    presentation = try await loader.load(reference: reference ?? "")
                }
                try Task.checkCancellation()
                guard generation == self.loadGeneration else { return }
                self.review = presentation
                self.demoSession = demo
                self.submitState = .hidden
                self.draftEditor = nil
                self.replyEditors = [:]
                self.clearDraftHistory()
                // Retain the previously selected path when it still exists.
                let kept = self.selection.filePath
                let stillPresent = kept.map { keptPath in
                    presentation.files.contains { $0.path == keptPath }
                } ?? false
                let path = stillPresent ? kept : presentation.files.first?.path
                self.selection = ReviewSelection(filePath: path)
                self.state = presentation.files.isEmpty ? .empty : .loaded
                self.isBusy = false
            } catch is CancellationError {
                // Superseded or explicitly cancelled: leave state as set.
            } catch {
                guard generation == self.loadGeneration else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self.banner = SessionBanner(text: message, isError: true)
                self.state = .failed(message: message)
                self.isBusy = false
            }
        }
    }

    // MARK: - Sidebar selection

    /// Applies a sidebar selection, retaining it if the file still exists.
    public func select(filePath: String?) {
        if let path = filePath, review?.files.contains(where: { $0.path == path }) == true {
            selection.filePath = path
        } else {
            selection.filePath = review?.files.first?.path
        }
        selection.rowID = nil
    }

    public var selectedFile: DiffFile? {
        guard let path = selection.filePath else { return nil }
        return review?.files.first { $0.path == path }
    }

    public var filteredSidebarItems: [FileSidebarItem] {
        guard let review else { return [] }
        let query = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return review.sidebarItems }
        return review.sidebarItems.filter {
            $0.path.lowercased().contains(query)
                || $0.statusLetter.lowercased() == query
        }
    }
}
