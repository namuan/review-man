# Desktop UI Migration Plan

## Goal

Replace the terminal interface with a native macOS desktop application while preserving the existing pull request review workflow and reusable core logic.

The shipping product will be `PR Review.app`. The existing `pr-review` executable will remain as a lightweight launcher so terminal users can continue opening pull requests, including bare PR numbers resolved from the current repository.

## Current architecture review

The project is a Swift 5.9 package targeting macOS 13 with no third-party dependencies.

Reusable components:

- Unified diff parsing and models
- Word-level diff calculation
- Syntax highlighting
- GitHub models and payload construction
- GitHub access through the authenticated `gh` CLI
- Draft and viewed-state persistence
- Demo data
- Thread and draft row anchoring

Components to replace:

- Raw terminal management
- ANSI key decoding and rendering
- Terminal color theme
- `AppView`
- TUI input handling in `AppController`
- Terminal-specific state in `AppModel`
- Screen dump rendering tests

Important issues discovered:

- `AppController.swift` and `AppView.swift` are large and mix several responsibilities.
- GitHub commands are synchronous and cannot currently be cancelled.
- A single generation counter lets unrelated operations invalidate each other.
- Persistence failures are silently ignored.
- Multiple windows could overwrite the same draft file.
- Refreshing after the head SHA changes does not implement the draft re-anchoring promised by the README.
- Syntax tokens are cached by content only, which can return the wrong language highlighting.
- The README reports 52 tests, but the suite contains 56 test methods.
- Finder-launched applications need more reliable `gh` executable discovery.

## Product decisions

### Platform and framework

- Build a native SwiftUI macOS application.
- Retain the macOS 13 deployment target.
- Use `ObservableObject` and `@Published` because the Observation framework requires macOS 14.
- Use small AppKit bridges where macOS 13 SwiftUI is insufficient:
  - Keyboard event routing
  - Window-close interception
  - Window focusing and deduplication
  - Clipboard and browser integration
- Start with `LazyVStack` for diff rendering.
- Move the diff pane to `NSTableView` or `NSCollectionView` only if performance benchmarks require it.

### Distribution

- Add an Xcode application project for app bundles, assets, signing, URL handling, UI tests, archiving, and notarization.
- Continue using Swift Package Manager for `PRReviewKit` and its tests.
- Use direct distribution rather than the Mac App Store while the application depends on the external `gh` executable.
- Produce a notarized ZIP before considering a DMG.

### Window model

- Use one resizable window per pull request.
- Support multiple pull requests in separate windows.
- Prevent duplicate windows for the same repository and PR.
- A new blank window displays the Open Pull Request interface.
- Closing a window does not warn merely because persisted drafts exist.
- Warn when:
  - An inline editor contains unpersisted text
  - The latest persistence operation failed
  - A submit operation has an uncertain result

### Launcher compatibility

Keep `Sources/pr-review/main.swift`, but replace the TUI entry point with a desktop launcher.

The launcher will:

1. Accept a full GitHub URL, `owner/repo#number`, or a bare number.
2. Resolve bare numbers while it still has the terminal working directory.
3. Send a normalized endpoint to the app using a registered `pr-review://` URL.
4. Open or focus the corresponding PR window.

## Proposed structure

```text
Package.swift
Sources/
  PRReviewKit/
    Diff/
    GH/
      CommandRunner.swift
      GitHubClient.swift
      GitHubService.swift
    Highlight/
    Models/
    Persistence/
      ReviewPersistence.swift
    ReviewRows/
  pr-review/
    main.swift

PRReviewApp/
  App/
    PRReviewApp.swift
    AppCoordinator.swift
    ReviewCommands.swift
  Model/
    ReviewSessionStore.swift
    ReviewSelection.swift
    PresentationState.swift
  Views/
    ReviewWindowView.swift
    OpenPullRequestView.swift
    PullRequestHeaderView.swift
    FileSidebarView.swift
    DiffView.swift
    DiffLineView.swift
    HunkHeaderView.swift
    ThreadCardView.swift
    DraftEditorView.swift
    SubmitReviewView.swift
    PullRequestDetailsView.swift
    DependencyStatusView.swift
  Support/
    DiffAttributedStringBuilder.swift
    SemanticTheme.swift
    KeyboardEventBridge.swift
    WindowLifecycleBridge.swift
  Resources/
    Assets.xcassets

PRReviewAppTests/
PRReviewAppUITests/
PRReview.xcodeproj/
```

## Implementation phases

### Phase 1: Establish the parity contract

Before refactoring:

- Run `swift test` and the demo dump command.
- Correct the documented test count.
- Create a feature matrix covering every current command and workflow.
- Mark each behavior as:
  - Preserve
  - Intentional desktop change
  - Existing bug to fix
- Add characterization tests for:
  - Clipboard text
  - Draft filenames and JSON compatibility
  - LEFT and RIGHT anchors
  - Multi-line range payloads
  - Head SHA changes
  - Resolve rollback
  - Diff fallback behavior

### Phase 2: Harden the reusable core

Modify `Package.swift` to export `PRReviewKit` as a library product while retaining the `pr-review` launcher executable.

Add:

- `CommandRunning`
- `GitHubServing`
- `ReviewPersisting`

Refactor command execution so it:

- Is genuinely asynchronous
- Terminates the child `gh` process when cancelled
- Uses one resolved absolute `gh` executable path
- Cleans temporary files on every path
- Uses restrictive permissions for temporary response files
- Does not log credentials or private response bodies
- Uses GraphQL variables rather than interpolating IDs and cursors

Track operations independently:

- Initial load and refresh
- Submit review
- Reply by thread
- Resolve mutation by thread

Do not use one global generation counter.

### Phase 3: Make persistence reliable

Replace silent `try?` writes with a shared persistence repository that:

- Uses atomic writes
- Reports failures to the session store
- Supports an injected directory in tests
- Serializes access across windows
- Preserves these exact legacy locations:

```text
~/Library/Application Support/pr-review/
drafts-owner_repo_number_sha.json
viewed-owner_repo_number_sha.json
```

When the head SHA changes:

1. Persist the old-head state.
2. Load any existing state for the new SHA.
3. If no new-head draft state exists, copy old drafts and validate their anchors.
4. Keep exact valid anchors attached.
5. Mark invalid anchors as orphaned.
6. Exclude orphaned drafts from submission until they are reattached or deleted.
7. Reset viewed marks for the new head.
8. Show a clear nonmodal status message.

### Phase 4: Build a desktop technology spike

Before implementing every workflow, verify macOS 13 behavior for:

- Shift-click and drag range selection
- Selection autoscroll
- Nested horizontal and vertical scrolling
- Programmatic scrolling to hunks and threads
- Window-close interception
- Multiple-window routing
- Large diff rendering

Create synthetic 10,000, 50,000, and 100,000-line diffs.

Initial acceptance targets for a release build on Apple Silicon:

- No main-thread stalls longer than 100 ms during ordinary navigation
- A 50,000-line diff becomes interactive within 2 seconds
- Memory remains below 400 MB for the 100,000-line fixture
- Smooth trackpad and mouse scrolling

Use an AppKit-backed diff list if these targets are not met.

### Phase 5: Build the read-only desktop UI

Create a `NavigationSplitView` containing:

- A collapsible file sidebar
- Native file search
- File status, additions, deletions, comments, and viewed state
- A detail pane with PR header and diff
- Loading, empty, binary, too-large, and error states

The diff pane will provide:

- SF Mono rendering
- Fixed line-number gutters
- Horizontal scrolling
- Syntax-colored `AttributedString` content
- Word-level change backgrounds
- Hunk headers
- Inline active, resolved, and outdated thread cards
- Stable row identities based on file, hunk, side, and line anchors

Fix syntax caching by including language and content in the cache key and bounding cache growth.

### Phase 6: Implement review workflows

Implement incrementally:

1. Select a line and add an inline draft.
2. Edit and delete drafts.
3. Add undo and redo for draft creation, editing, and deletion.
4. Select a range with Shift-click or drag.
5. Reply to threads with retryable failure handling.
6. Resolve and unresolve threads with optimistic updates and rollback.
7. Toggle local viewed state.
8. Submit comment, approval, or change-request reviews.
9. Refresh while preserving selection by path and line anchor.
10. Open the pull request in the browser.
11. Copy exact `path:line content` text to the clipboard.

A valid multi-line selection must:

- Stay within one file and hunk
- Use one GitHub side
- Start and end on commentable diff lines
- Normalize reverse selections
- Ignore inserted thread and draft cards

Invalid ranges will show an explanation instead of silently becoming single-line comments.

### Phase 7: Add native Mac interaction

Provide standard menus and dynamic enablement:

- File: New Window, Open Pull Request, Close
- Edit: Undo, Redo, Find
- Review: Add Comment, Reply, Resolve, Toggle Viewed, Submit Review
- View: Toggle Sidebar, Previous/Next File, Previous/Next Hunk
- Window
- Help

Add:

- Command-key shortcuts
- Arrow-key navigation
- Escape cancellation
- Context menus
- Hover feedback
- Toolbar actions for open, refresh, browser, and submit
- Dark and light appearance
- High-contrast support
- VoiceOver labels
- Reduced-motion and reduced-transparency handling

### Phase 8: Add dependency onboarding

At startup, resolve `gh` from:

- Inherited `PATH`
- Apple Silicon Homebrew
- Intel Homebrew
- MacPorts
- A user-selected executable

Validate with:

- `gh --version`
- `gh auth status`
- A minimal authenticated API request

Show actionable UI for missing, unauthenticated, expired, or under-scoped installations. Do not invoke a login shell.

### Phase 9: Testing

Retain all pure parser, highlighting, payload, and row-building tests.

Add unit tests for:

- Async process cancellation
- Independent operation ordering
- Stale refresh rejection
- Resolve rollback
- Persistence failures
- Legacy JSON compatibility
- Head SHA migration
- Orphaned drafts
- Stable row IDs
- Unicode, emoji, combining characters, and tabs
- Range validity
- Exact clipboard output
- Launcher argument and URL handling

Add demo-mode UI tests for:

- Opening a PR
- Filtering and selecting files
- Navigating files, hunks, and threads
- Adding, editing, undoing, and deleting a draft
- LEFT and multi-line comments
- Replies and retry behavior
- Resolve rollback
- Submit review presentation
- Binary and oversized files
- Dependency errors
- Multiple-window deduplication
- Close warnings after persistence failure

### Phase 10: Release and cleanup

Before removing the TUI:

- Build a signed universal application.
- Enable hardened runtime.
- Notarize and staple a ZIP artifact.
- Verify with `codesign` and `spctl`.
- Test outside Xcode on a clean user account.
- Test both Apple Silicon and Intel.
- Test on an actual macOS 13 system.
- Verify Finder launch, `gh` discovery, authentication, drafts, browser opening, and launcher URLs.

After the desktop release passes these gates, remove:

- `Term/`
- `CLI.swift`
- `AppView.swift`
- TUI input handling from `AppController.swift`
- Terminal-only state from `AppModel.swift`
- The custom terminal editor
- Screen dump and scrolling-render tests

Retain the `pr-review` executable as the desktop launcher.

## Non-goals

The first desktop release will not include:

- iOS or iPadOS support
- Direct GitHub OAuth or token management
- Replacing `gh` with `URLSession`
- Mac App Store distribution
- Collaborative draft synchronization
- A custom app update framework

## Completion criteria

The migration is complete when:

- All existing review workflows are available in the desktop app.
- Draft files remain backward compatible.
- The UI remains responsive on large pull requests.
- Keyboard-only operation is possible.
- Core, app, UI, and performance tests pass.
- A notarized application launches successfully outside Xcode.
- The terminal executable opens the desktop app instead of starting the TUI.
- TUI-only code has been removed.
