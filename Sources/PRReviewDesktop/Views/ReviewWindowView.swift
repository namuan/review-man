import SwiftUI
import PRReviewKit

/// The review window: a NavigationSplitView (collapsible file sidebar + detail
/// pane) that also hosts the open/loading/empty/error states. Publishes its
/// store as the focused command target and routes command notifications.
public struct ReviewWindowView: View {
    @ObservedObject public var store: ReviewSessionStore
    @State private var showOpenSheet = false
    @State private var sheetReference = ""
    @State private var sidebarVisible = true
    /// The change canvas is the default overview mode. Selecting a file card
    /// or a file in the sidebar switches back to the focused-file view.
    @State private var showCanvas = true
    @State private var canvasZoom = ChangeCanvasView.defaultZoom
    @State private var showCloseWarning = false

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.state {
            case .welcome:
                OpenPullRequestView(store: store)
                    .frame(minWidth: 480, minHeight: 360)
            case .loading(let reference):
                loadingView(reference: reference)
            case .loaded, .empty:
                loadedShell
            case .failed(let message):
                failureView(message: message)
            }
        }
        .focusedSceneValue(\.reviewCommandTarget, store)
        .background(CloseWarningBridge(store: store, showWarning: $showCloseWarning))
        .alert("Local changes may not be saved", isPresented: $showCloseWarning) {
            Button("Keep Editing", role: .cancel) {}
            Button("Close Anyway") {
                // Programmatic close bypasses windowShouldClose (which already
                // returned false to show this dialog).
                NSApp.keyWindow?.close()
            }
            .accessibilityIdentifier("close-anyway-button")
        } message: {
            Text("The last persistence operation failed; your in-memory changes may not survive this window closing.")
        }
        .modifier(CommandRoutingModifier(
            store: store,
            showOpenSheet: $showOpenSheet,
            sidebarVisible: $sidebarVisible,
            canvasZoom: $canvasZoom
        ))
        .toolbar { toolbarContent }
        .onChange(of: store.requestFocus) { _ in
            if store.requestFocus == .sidebarSearch {
                sidebarVisible = true   // reveal the search surface if hidden
            }
            if store.requestFocus != .none { store.requestFocus = .none }
        }
        .sheet(isPresented: $showOpenSheet) {
            VStack(spacing: 16) {
                Text("Open Pull Request")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                OpenPullRequestForm(store: store, reference: $sheetReference)
                    .frame(maxWidth: 420)
                Button("Close") { showOpenSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 480)
            .onAppear { sheetReference = "" }
        }
        .sheet(isPresented: submitSheetBinding) {
            SubmitReviewView(store: store)
        }
        .onExitCommand {
            store.cancelTransientInteraction()
        }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }

    private var submitSheetBinding: Binding<Bool> {
        Binding(
            get: { store.submitState != .hidden },
            set: { if !$0 { store.cancelSubmit() } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if store.state == .loaded || store.state == .empty {
                let availability = ReviewCommandAvailability(context: store.commandContext())
                Picker("Diff view", selection: $showCanvas) {
                    Text("Canvas").tag(true)
                    Text("Selected file").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .accessibilityLabel("Diff view")
                .accessibilityIdentifier("diff-view-picker")

                Button {
                    showOpenSheet = true
                } label: {
                    Label("Open Pull Request", systemImage: "square.and.arrow.down")
                }
                .help("Open a different pull request")
                .accessibilityIdentifier("toolbar-open")
                Button {
                    store.beginSubmit()
                } label: {
                    Label("Submit Review", systemImage: "paperplane")
                }
                .disabled(!availability.canSubmit)
                .help("Submit the review")
                .accessibilityIdentifier("toolbar-submit")
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!availability.canRefresh)
                .help("Refresh the review")
                .accessibilityIdentifier("toolbar-refresh")
                Button {
                    if let file = store.selectedFile, let position = store.selectedLinePosition(in: file),
                       let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: position.hunk, lineIndex: position.lineIndex) {
                        store.beginDraft(at: DraftStartAnchor(
                            path: anchor.path, side: anchor.side, line: anchor.line,
                            startLine: anchor.startLine, startSide: anchor.startSide
                        ))
                    } else {
                        store.banner = SessionBanner(text: "Select a diff line to comment on.", isError: true)
                    }
                } label: {
                    Label("Comment", systemImage: "bubble.left")
                }
                .disabled(!availability.canAddComment)
                .help("Comment on the selected line")
                .accessibilityIdentifier("toolbar-comment")
                Button {
                    store.toggleViewed(filePath: store.selection.filePath ?? "")
                } label: {
                    Label("Toggle Viewed", systemImage: "checkmark.circle")
                }
                .disabled(!availability.canToggleViewed)
                .help("Toggle viewed state")
                .accessibilityIdentifier("toolbar-viewed")
                Menu {
                    let names = store.reviewerNames
                    if names.isEmpty {
                        Text("No commenters yet")
                    } else {
                        ForEach(names, id: \.self) { name in
                            Button {
                                if store.hiddenReviewers.contains(name) {
                                    store.unhideReviewer(name)
                                } else {
                                    store.hideReviewer(name)
                                }
                            } label: {
                                if store.hiddenReviewers.contains(name) {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }
                    if !store.hiddenReviewers.isEmpty {
                        Divider()
                        Button("Show All Comments") { store.unhideAllReviewers() }
                    }
                } label: {
                    Label("Filter Comments", systemImage: store.hiddenReviewers.isEmpty ? "eye" : "eye.slash")
                }
                .disabled(!availability.canHideReviewer)
                .help(store.hiddenReviewers.isEmpty
                    ? "Hide comments by a reviewer"
                    : "\(store.hiddenReviewers.count) reviewer(s) hidden — adjust the comment filter")
                .accessibilityIdentifier("toolbar-filter-comments")
                Button {
                    if let file = store.selectedFile, let position = store.selectedLinePosition(in: file) {
                        _ = store.copyLineToClipboard(file: file, hunkIndex: position.hunk, lineIndex: position.lineIndex)
                    }
                } label: {
                    Label("Copy Line", systemImage: "doc.on.doc")
                }
                .disabled(!availability.canCopyLine)
                .help("Copy the selected line")
                .accessibilityIdentifier("toolbar-copy")
                Button {
                    store.openInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .disabled(!availability.canOpenInBrowser)
                .help("Open the PR in your browser")
                .accessibilityIdentifier("toolbar-browser")
            }
        }
    }

    private func loadingView(reference: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Opening \(reference)…")
                .foregroundStyle(.secondary)
            Button("Cancel") { store.cancelLoad() }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loading-state")
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Could not open pull request")
                .font(.headline)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("error-message")
            HStack(spacing: 12) {
                if let reference = store.lastRequestedReference, reference != "demo" {
                    Button("Try Again") { store.open(reference: reference) }
                } else {
                    Button("Try Again") { store.openDemo() }
                }
                Button("Open a Different PR") { store.cancelLoad() }
            }
            .padding(.top, 4)
            DependencyStatusCard(store: store)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error-state")
    }

    private var loadedShell: some View {
        NavigationSplitView(columnVisibility: sidebarBinding) {
            FileSidebarView(store: store, showCanvas: $showCanvas)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            detailPane
        }
    }

    private var sidebarBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        if let review = store.review {
            VStack(spacing: 0) {
                PullRequestHeaderView(review: review)
                if !review.hiddenReviewers.isEmpty {
                    hiddenReviewersStrip(review)
                }
                Divider()
                if store.state == .empty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No changed files",
                        message: "This pull request has no file changes."
                    )
                } else if showCanvas {
                    ChangeCanvasView(
                        store: store,
                        files: review.files,
                        showCanvas: $showCanvas,
                        zoom: $canvasZoom
                    )
                } else if let file = store.selectedFile {
                    DiffView(store: store, file: file)
                } else {
                    EmptyStateView(
                        icon: "sidebar.left",
                        title: "Select a file",
                        message: "Choose a file from the sidebar to view its diff."
                    )
                }
                if let banner = store.banner {
                    bannerBar(banner)
                }
            }
        } else {
            EmptyStateView(icon: "questionmark.circle", title: "Nothing loaded", message: "")
        }
    }

    private func hiddenReviewersStrip(_ review: ReviewPresentation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Comments by \(review.hiddenReviewers.sorted().joined(separator: ", ")) hidden")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Show All") { store.unhideAllReviewers() }
                .font(.caption)
                .accessibilityIdentifier("hidden-reviewers-show-all")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(SwiftUI.Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hidden-reviewers-strip")
    }

    private func bannerBar(_ banner: SessionBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(banner.isError ? .red : .secondary)
            Text(banner.text)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                store.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(8)
        .background(AppearanceSettings.reduceTransparency
            ? Color(nsColor: .controlBackgroundColor)
            : Color.gray.opacity(0.1))
        .accessibilityIdentifier("status-banner")
    }
}

/// Routes command notifications to the focused window's store.
private struct CommandRoutingModifier: ViewModifier {
    @ObservedObject var store: ReviewSessionStore
    @Binding var showOpenSheet: Bool
    @Binding var sidebarVisible: Bool
    @Binding var canvasZoom: CGFloat

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reviewOpenRequest)) { note in
                if (note.object as? ReviewSessionStore) === store {
                    showOpenSheet = true
                } else if note.object == nil, store.state == .welcome {
                    // Unscoped requests only target the welcome window.
                    showOpenSheet = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewFindRequest)) { note in
                guard matches(note) else { return }
                store.requestFocus = .sidebarSearch
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewAddCommentRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile, let position = store.selectedLinePosition(in: file),
                   let anchor = DraftRangeValidator.anchor(for: file, hunkIndex: position.hunk, lineIndex: position.lineIndex) {
                    store.beginDraft(at: DraftStartAnchor(
                        path: anchor.path, side: anchor.side, line: anchor.line,
                        startLine: anchor.startLine, startSide: anchor.startSide
                    ))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewReplyRequest)) { note in
                guard matches(note) else { return }
                if case .thread(let threadID)? = store.selection.rowID {
                    store.beginReply(threadID: threadID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewResolveRequest)) { note in
                guard matches(note) else { return }
                if case .thread(let threadID)? = store.selection.rowID {
                    store.toggleResolved(threadID: threadID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewToggleViewedRequest)) { note in
                guard matches(note) else { return }
                if let path = store.selection.filePath {
                    store.toggleViewed(filePath: path)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewSubmitRequest)) { note in
                guard matches(note) else { return }
                store.beginSubmit()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewRefreshRequest)) { note in
                guard matches(note) else { return }
                store.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewToggleSidebarRequest)) { note in
                guard matches(note) else { return }
                sidebarVisible.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasZoomInRequest)) { note in
                guard matches(note) else { return }
                canvasZoom = ChangeCanvasView.clampedZoom(canvasZoom + ChangeCanvasView.zoomStep)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasZoomOutRequest)) { note in
                guard matches(note) else { return }
                canvasZoom = ChangeCanvasView.clampedZoom(canvasZoom - ChangeCanvasView.zoomStep)
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewCanvasResetZoomRequest)) { note in
                guard matches(note) else { return }
                canvasZoom = ChangeCanvasView.defaultZoom
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewPreviousFileRequest)) { note in
                guard matches(note) else { return }
                store.selectPreviousFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNextFileRequest)) { note in
                guard matches(note) else { return }
                store.selectNextFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewPreviousHunkRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile { store.selectAdjacentHunk(-1, in: file) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .reviewNextHunkRequest)) { note in
                guard matches(note) else { return }
                if let file = store.selectedFile { store.selectAdjacentHunk(1, in: file) }
            }
    }

    private func matches(_ note: Notification) -> Bool {
        guard let object = note.object as? ReviewSessionStore else { return true }
        return object === store
    }
}
