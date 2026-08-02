# Desktop UI Migration Plan

## Goal

Replace the terminal interface with a native macOS desktop application while preserving the existing pull request review workflow and reusable core logic.

The shipping product will be `PR Review.app`. The existing `pr-review` executable will remain as a lightweight launcher so terminal users can continue opening pull requests, including bare PR numbers resolved from the current repository.

## Migration checklist

Status legend: `[ ]` not started, `[~]` in progress, `[x]` done. Sub-items are checked as the work lands and is verified.

- [x] Phase 1 — Establish the parity contract
  - [x] Baseline: `swift test` passes 56 tests (0 failures) before characterization; the suite is 69 tests after Phase 1.
  - [x] Baseline: `swift run pr-review --demo --dump 10x24` succeeds.
  - [x] Test-count documentation verified: README already states 56 tests; removed the stale plan claim that it said 52.
  - [x] Feature matrix completed and classifications agreed (see `docs/desktop-parity-matrix.md`).
  - [x] Characterization tests: clipboard text.
  - [x] Characterization tests: draft filenames and JSON compatibility.
  - [x] Characterization tests: LEFT and RIGHT anchors.
  - [x] Characterization tests: multi-line range payloads.
  - [x] Characterization tests: head-SHA refresh behavior (documents the missing re-anchoring).
  - [x] Characterization tests: resolve rollback.
  - [x] Characterization tests: diff fallback behavior.
  - [x] Phase 1 verification rerun (`swift test`, demo dump, `git diff --check`).
- [x] Phase 2 — Harden the reusable core
  - [x] Export `PRReviewKit` as a library product and retain the `pr-review` executable product.
  - [x] Add async `GitHubServing` and `ReviewPersisting` protocols.
  - [x] Replace synchronous command execution with cancellable async execution (`CommandProcess`, `withTaskCancellationHandler`, timeout, single-finish coordinator).
  - [x] Resolve and cache one absolute inherited-PATH `gh` executable path per runner (`GitHubExecutableResolver`).
  - [x] Secure temporary response and payload files with mode `0600` and cleanup on every path (`SecureTemporaryFile`).
  - [x] Ensure diagnostics do not expose credentials, request bodies, or private response bodies (`CommandProcess.label`).
  - [x] Use GraphQL variables for review-thread IDs and cursors, including a null initial cursor.
  - [x] Replace the global generation counter with independently tracked fetch, submit, reply-by-thread, and resolve-by-thread operations (`OperationTracker`).
  - [x] Convert the CLI bootstrap to async (`main.swift` top-level await) and retain `--demo --dump` behavior.
  - [x] Add async cancellation, cleanup, GraphQL-variable, stale-fetch, and independent-operation tests (suite now 95 tests).
  - [x] Phase 2 verification: `swift test` (3 stable runs), package build, demo dump, real-PR smoke test, `git diff --check`.
^- [x] Phase 3 — Make persistence reliable
  - [x] Add shared actor-backed `ReviewPersistence` with injected-directory tests.
  - [x] Preserve legacy draft/viewed filenames, JSON shape, and numeric `Date` compatibility (`isOrphaned` never persisted).
  - [x] Replace `DraftStore` and all silent persistence writes.
  - [x] Surface persistence failures in `AppModel` session state (`persistenceFailure`) and nonmodal messages.
  - [x] Serialize repository access through one shared application instance (actor).
  - [x] Add atomic replacement and deterministic failure-path tests.
  - [x] Add orphaned-draft validation (`DraftAnchorValidator`), orphan section rendering, deletion, automatic reattachment, and submission exclusion (controller + `PayloadBuilder`).
  - [x] Implement ordered head-SHA migration (old-head save → new-head load/copy → validate → viewed reset) and viewed-mark reset.
  - [x] Replace obsolete head-change characterization coverage with migration tests.
  - [x] Phase 3 verification: `swift test` (116 tests, stable ×4), `swift build`, demo dump, real-PR smoke test, `git diff --check`.
- [x] Phase 4 — Desktop technology spike
  - [x] Added deterministic 10,000/50,000/100,000-line unified-diff generator (`SyntheticDiffFixture`) shared by tests, benchmark, and spike.
  - [x] Verified every generated fixture parses to exactly its requested number of `DiffLine` values with valid hunk counts and mixed line kinds (tests).
  - [x] Added release-mode headless benchmark (`PRReviewBench`) for parse, row build, viewport + eager highlighting, counts, and physical footprint.
  - [x] Recorded release benchmark baselines for 10k/50k/100k on Apple Silicon (Apple M1 Max).
  - [x] Added macOS 13-targeted SwiftUI spike (`PRReviewSpike`) using `LazyVStack`, stable row IDs from file/hunk/line anchors, real `PRReviewKit` parsing, first-draw/stall instrumentation, and `--smoke` headless mode. (Spike run on macOS 26; see deferral below.)
  - [x] Verified large-diff loading and hunk programmatic scrolling; nested horizontal/vertical scrolling implemented (feel matrix deferred to macOS 13 gate).
  - [x] Prototype-only on this machine: Shift-click range selection and window-close interception (`NSWindowDelegate`, programmatic close bypass for the confirmed state) and `WindowGroup(for:)` multi-window routing. Drag selection across rows, selection edge autoscroll, and synthetic-thread navigation are NOT implemented in the spike and are deferred to Phase 5/6.
  - [x] Measured 50k pipeline readiness: 67 ms parse + 2 ms row build + ~4 ms viewport highlighting ≪ 2 s target (pipeline, not full SwiftUI first-draw).
  - [x] Measured 100k post-work process footprint: 25.6 MiB ≪ 400 MiB target; main-thread watchdog (background sampler) shows no stalls during smoke runs.
  - [x] Decision recorded (provisional): retain `LazyVStack` — pipeline benchmarks do not require AppKit; see `docs/phase4-technology-spike.md`.
  - [x] Phase 4 verification: fixture tests (suite now 121), `swift build -c release`, benchmark reports, spike smoke + GUI launch, `git diff --check`.
  - [ ] DEFERRED to the Phase 10 release gate: run the interactive matrix on an actual macOS 13 system (this machine is macOS 26), confirm scroll smoothness/selection/close/routing by hand, and capture Instruments evidence.
- [x] Phase 5 — Build the read-only desktop UI
  - [x] Created `PRReview.xcodeproj` (via xcodegen `project.yml`) and the `PRReviewApp` bundle host; all reusable desktop code lives in the `PRReviewDesktop` SPM library target (unit-tested by `swift test`).
  - [x] Registered the `pr-review` URL scheme in Info.plist and routed normalized endpoints (`pr-review://open/owner/repo/number`) and plain GitHub URLs through `AppCoordinator` → store (launcher replacement stays Phase 10).
  - [x] Added `ReviewSessionStore` (@MainActor ObservableObject), `PresentationState`, `ReviewSelection` (path-based), load cancellation, stale-load rejection via load generation, and injected service/persistence seams.
  - [x] Added demo loading and qualified real-PR loading via `ReviewSessionLoader`; bare-number input is rejected in Finder-launched UI with an explanatory message.
  - [x] Built `NavigationSplitView` with collapsible `.searchable` file sidebar: status letters, ± counts (unavailable → "--" for too-large), comment badges, binary/too-large markers, viewed checkmarks.
  - [x] Built the PR header plus welcome, loading, empty, binary, oversized, and error detail states.
  - [x] Rendered the diff with `LazyVStack`, typed `DiffRowID` (file/hunk/kind/old/new anchors), SF Mono, fixed-width gutters, nested horizontal+vertical scrolling, hunk headers, and read-only active/resolved/outdated thread cards + draft cards.
  - [x] Added viewport-driven `AttributedString` rendering (`DiffAttributedStringBuilder`: Character-offset-safe syntax foregrounds + word-change backgrounds).
  - [x] Replaced the content-only token cache with the bounded per-window LRU `SyntaxTokenCache` (keyed by language + content) in PRReviewKit; migrated `AppModel` to it.
  - [x] Added SPM unit coverage (PRReviewDesktopTests, 11 tests; suite now 136): presentation states, demo/real load, bare-number rejection, fetch failure, stale-load rejection, sidebar filter/selection fallback, stable row IDs, attributed builder syntax+word-background coexistence, Unicode/combining/invalid-range safety, cache bounds.
  - [x] Added accessibility identifiers for open field/buttons, sidebar rows, PR header, diff lines/hunks/threads, and all states (Phase 9 UI tests will use them).
  - [x] Phase 5 verification: `swift test` (136), `swift build`, `xcodebuild` app build, app launch smoke test, demo/manual real-PR loading, `git diff --check`.
  - [ ] macOS 13 interactive matrix remains a Phase 10 release gate (see Phase 4 deferral).
- [x] Phase 6 — Implement review workflows
  - [x] Extracted and tested PRReviewKit `ReviewOperations` (refresh/migrate, saveDrafts/saveViewed, submit with snapshot, reply, setResolved) plus `DraftRangeValidator`, `DiffLineAnchor`, `DraftMutation`, `ReviewUtilities` (exact clipboard text, PR URL). Head-SHA migration moved out of `AppController` into `ReviewOperations.migrate`; the TUI now delegates submit/reply/resolve/migrate through it.
  - [x] Desktop store rebuilt presentations from mutable session data (`ReviewSessionStore` + workflows extension), with durable `persistenceFailure`, per-lane busy state, resolve generations, and banner reporting.
  - [x] Inline single-line and multi-line draft creation, editing, deletion (empty-new discards, empty-edit deletes), and durable persistence errors (inline `DraftEditorView`).
  - [x] macOS 13-compatible value-based draft undo/redo (`DraftMutation` stacks; Edit-menu wiring in Phase 7).
  - [x] Validated Shift-click range selection (one file/hunk/side, commentable endpoints, reverse normalization, card endpoints rejected, invalid → explanation banner). Drag-range selection with AppKit autoscroll is NOT implemented — deferred (Phase 4 spike deferral stands; macOS 13 manual matrix at Phase 10 gate).
  - [x] Retryable thread replies (body + thread/comment ID retained on failure; Retry/Edit controls; demo appends locally).
  - [x] Optimistic resolve/unresolve with per-thread generation-protected rollback (stale failures ignored; threads independent).
  - [x] Locally persisted viewed-file toggles (immediate publish + durable save).
  - [x] Submit sheet (comment/approve/request-changes, summary, included-draft list with orphan exclusion, approval-without-summary validation, snapshot-only draft removal, retryable failure + uncertain-result state).
  - [x] Refresh with head-SHA migration via `ReviewOperations.migrate`; selected path preserved across refresh. (Line-anchor rowID restoration is path-only in this phase — `rowID` resets; full anchor restoration is a Phase 9 refinement.)
  - [x] Browser opening (`NSWorkspace`) and exact `path:line content` clipboard copying.
  - [x] Core + desktop-store tests for all workflows (suite now 195).
  - [x] Phase 6 verification: `swift test` (195), `swift build`, Xcode app build + launch, TUI demo dump still works, `git diff --check`.
- [x] Phase 7 — Add native Mac interaction
  - [x] Per-window session ownership: the app host's `WindowGroup(for:)` creates one `ReviewSessionStore` per window key; `AppCoordinator` routes URLs and enforces duplicate-window policy; commands act on the focused window via `focusedSceneValue`.
  - [x] Tested command availability (`ReviewCommandAvailability`, pure `ReviewCommandContext`) and action routing through `ReviewCommands` + notification routing (`CommandRoutingModifier`).
  - [x] File (New Window Cmd-N, Open PR Cmd-O, Close), Edit (Undo Cmd-Z, Redo Shift-Cmd-Z, Find Cmd-F), Review (Add Comment, Reply, Resolve, Toggle Viewed, Submit, Refresh) and Navigate (Toggle Sidebar, Prev/Next File, Prev/Next Hunk) menus with dynamic enablement and non-conflicting shortcuts.
  - [x] Open-Pull-Request sheet for loaded reviews (`OpenPullRequestForm` reused by welcome + sheet) and toolbar parity (Open, Submit, Refresh, Comment, Toggle Viewed, Copy, Browser) with corrected preconditions.
  - [x] Focused diff keyboard navigation: `onMoveCommand` arrows move among commentable lines with scroll-into-view; file/hunk navigation via commands; Escape precedence (`cancelTransientInteraction`: draft editor → reply editors → submit → load → banner); visible dismissible status banner in the loaded state.
  - [x] Context menus: diff line (Comment, Copy), draft card (Edit, Delete), thread card (Reply, Resolve/Unresolve), file row (Toggle Viewed).
  - [x] Single-identity hover feedback (`store.hoveredRowID`) + selected-line background treatment.
  - [x] Dark/light palettes (Phase 5), high-contrast palette variants, reduced-motion (disables scroll animations) and reduced-transparency (solid banner) handling via macOS 13-safe `AppearanceSettings` (NSWorkspace accessors — the SwiftUI environment keys are macOS 14+).
  - [x] VoiceOver labels: per-line combined labels (kind + line number + path + content), hunk/thread/draft/sidebar labels, banner label + dismiss, header traits on sheets.
  - [x] Phase 7 SPM unit tests (6; suite now 195): availability by state/editors, commentable-line navigation, file/hunk navigation, Escape precedence, undo-history cleared on reload.
  - [x] Phase 7 verification: `swift test` (195), `swift build`, Xcode app build + launch, TUI demo regression, `git diff --check`. (Live menu/keyboard/VoiceOver/appearance feel is manual territory deferred to Phase 9 UI tests and the macOS 13 gate.)
- [x] Phase 8 — Add dependency onboarding
  - [x] `GitHubExecutableResolver` now resolves from a user-selected override (re-verified on every resolve so a stale selection fails loudly), inherited PATH, Apple Silicon Homebrew, Intel Homebrew, and MacPorts — single-flight cached automatic discovery (injectable path + fallback seams preserved) with `GitHubExecutableInfo` metadata + `invalidateCache()`.
  - [x] `GitHubExecutablePreference` persists the validated user-selected executable at `PRReview.gitHubExecutableOverridePath` (path-only, never contents/credentials), with select/clear.
  - [x] `GitHubDependencyChecker` runs the direct, shell-free `gh --version` → `gh auth status --hostname github.com --active` → `gh api user --include` checks through the existing `CommandRunning` seam, with bounded sanitized diagnostics (no tokens, no response bodies, no `--show-token`).
  - [x] Status mapping: missing / unusable / unauthenticated / expired-or-revoked / under-scoped / ready / unknownFailure; fine-grained tokens without classic OAuth headers are NOT rejected (scope shown as "Not reported").
  - [x] `ReviewSessionStore` dependency state: nonblocking startup check (welcome screen), `recheckDependency()` with generation-based stale rejection and fresh resolver per check; preference changes recheck; opening a PR is NOT gated on health (existing error UI remains the failure path).
  - [x] `DependencyStatusView` + welcome/failure `DependencyStatusCard`: path/source/version/account/scope, status-specific copyable instructions (`brew install gh`, `gh auth login`, `gh auth refresh -h github.com -s repo`), Locate (NSOpenPanel) / Clear / Re-check; nothing spawns a shell or runs `gh auth login`.
  - [x] Offline tests (11; suite now 195): resolver override/path/fallback ordering, stale override failure, invalidation, health ready/missing/unauthenticated/expired/under-scoped/fine-grained classification with a scripted runner, command-order + no-shell assertion.
  - [x] Phase 8 verification: `swift test` (181, stable ×3), `swift build`, Xcode app build + launch, TUI demo regression, `git diff --check`. (Controlled-PATH/Finder-like launch smoke and manual panel interaction are Phase 9/macOS-13 manual items.)
^- [~] Phase 9 — Testing
  - [x] Retain and rerun all parser, highlighting, payload, and row-building tests (part of the 198-test suite).
  - [x] Unit coverage for all plan categories: async process cancellation, independent operation ordering, stale refresh rejection, resolve rollback (+stale protection), persistence failures, legacy JSON compatibility, head-SHA migration, orphaned drafts, stable row IDs, Unicode/emoji/combining/tabs, range validity, exact clipboard output, URL handling.
  - [x] Desktop-launcher argument normalization + URL handoff coverage (`LauncherRequestParserTests`: --demo, full URL, owner/repo#number, bare-number delegation, invalid/multiple refs, exact `pr-review://open/...` output).
  - [x] Added `PRReviewAppUITests` via XcodeGen (`bundle.ui-testing`, `TEST_TARGET_NAME: PRReviewApp`); `xcodebuild build-for-testing` succeeds and the bundle is discovered.
  - [x] App-host `--demo` launch argument (offline demo without gh/persistence/dependency checks) for deterministic UI-test entry.
  - [x] Unique stable accessibility identifiers for diff lines (`diff-line-<path>-h<hunk>-<old>-<new>`), thread cards, and draft cards; close-warning alert + buttons.
  - [x] Implemented the close-warning behavior (`CloseWarningBridge`: intercepts close when `persistenceFailure != nil`, Keep Editing / Close Anyway via programmatic close).
  - [x] Wrote demo-mode UI tests (open via launch argument, open via welcome button, sidebar file filter, toolbar comment draft editor, submit sheet) using the identifiers.
  - [ ] UI-TEST EXECUTION RECORDED AS MANUAL/PENDING: one UI test executed and drove the app on this machine (proving the harness attaches), but the environment's out-of-date CoreSimulator pairing makes full-suite UI execution unreliable; selector/hierarchy tuning and a full interactive pass require a maintained GUI session or CI runner (per Sage guidance: an unrun UI suite is not a passing UI suite). The macOS 13 manual matrix (Shift-click range gesture, close interception feel, window routing, scrolling) remains a Phase 10 gate.
  - [x] Phase 9 verification: `swift test` (198, stable), `swift build`, `xcodebuild build-for-testing`, Xcode app build + launch, `git diff --check`.
- [~] Phase 10 — Release and cleanup
  - [x] Xcode release configuration: macOS 13 target, `ENABLE_HARDENED_RUNTIME`, ad-hoc signing for local development (Developer ID is an external gate).
  - [x] App Info.plist registers the `pr-review` URL scheme; parser + URL handoff have unit coverage (`LauncherRequestParser`, `ReviewURLCoordinator`).
  - [x] Universal Release app build verified: `lipo -archs` reports `x86_64 arm64`; `codesign --verify --deep --strict` passes (valid on disk, satisfies designated requirement); `codesign --display` shows the hardened-runtime `adhoc,runtime` flags; `spctl` rejects the ad-hoc build as EXPECTED (a Developer ID-signed, notarized artifact must pass — external gate).
  - [x] Dual-arch demo smoke on this Apple Silicon host: the app runs under both `arch -arm64` and `arch -x86_64` (Rosetta translation — NOT an Intel-hardware gate).
  - [x] Universal `pr-review` launcher artifact built via `lipo -create` from arm64+x86_64 release slices; `lipo -archs` reports `x86_64 arm64`; `--version` runs.
  - [x] Desktop/core unit suite recorded at 198 tests; UI-test full execution recorded as manual/pending (Phase 9).
  - [ ] EXTERNAL GATE — Developer ID signing, notarization + stapling of a ZIP (`notarytool submit --wait` → Accepted → `stapler staple` → `stapler validate`), and `spctl` acceptance of the final artifact (requires Apple credentials — not available in this environment).
  - [ ] EXTERNAL GATE — Clean standard-user account outside Xcode: Finder launch, `gh` discovery/authentication, draft + viewed persistence restore, browser opening, `open 'pr-review://…'` routing, launcher forms (URL / owner#repo / bare number / --demo / --help / --version).
  - [ ] EXTERNAL GATE — Native Apple Silicon hardware matrix.
  - [ ] EXTERNAL GATE — Native Intel hardware matrix (Rosetta is insufficient).
  - [ ] EXTERNAL GATE — Actual macOS 13 interactive/accessibility/large-diff/Instruments matrix (this host is macOS 26).
  - [ ] TUI removal (Term/, CLI.swift, AppView.swift, TUI input in AppController, terminal state in AppModel, custom terminal editor, ScreenDump/ScrollingRender/TextEditor/TextUtil tests; relocate shared `PersistenceFailure`/`ReviewEvent`; `DemoData` builds `ReviewPresentation` directly; `pr-review/main.swift` becomes the pure launcher with a `pr-review://demo` route) — NOT executed: the plan gates removal on the release gates passing, which they cannot here. The removal commit is fully specified (see the migration session notes) for after the external gates pass.
  - [ ] Rebuild, sign, notarize, and externally smoke-test the post-removal artifact (external gate).
  - [ ] README + version/build metadata updates after the release gates pass (the current README still documents the terminal UI, which remains the shipped TUI until removal).

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

- `GitHubServing`
- `ReviewPersisting`

`CommandRunning` (the synchronous seam introduced in Phase 1) is completed and
hardened: genuinely asynchronous, child `gh` process terminated on cancellation,
one resolved absolute `gh` executable path, temporary files cleaned on every
path, restrictive permissions for temporary response files, no credential or
private response-body logging, and GraphQL variables rather than interpolated
IDs and cursors.

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
