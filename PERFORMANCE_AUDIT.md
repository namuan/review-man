# PR Review performance audit

## Scope

This is a code-first performance review of the macOS app, focused on avoiding UI hangs, dropped frames, slow file switching, slow navigation, long load times, and memory growth on large pull requests.

No Instruments trace was supplied, so findings are ranked by likely impact based on code paths and algorithmic complexity. Validate the highest-priority items with a Release-build SwiftUI Instruments and Time Profiler capture before and after implementation.

## Existing strengths

The current design already includes several useful performance protections:

- `LazyVStack` limits diff-row realization to the viewport.
- Diff rows have stable, anchor-derived identities.
- Rendered diff lines are cached.
- Demo fixture generation and parsing run off the main actor.
- Persistence is isolated in an actor and writes atomically.
- Async load, refresh, and resolve operations use cancellation or generation guards.
- Word-diff processing caps pathological line lengths.

## Priority 0: address first

### 1. Fix retained caches and release stores when windows close

**Evidence**

- `DiffLineCache.Node` has strong `prev` and `next` references: `Sources/PRReviewDesktop/Support/DiffLineCache.swift:43-51`.
- Nodes in the list therefore form retain cycles. `removeAll()` clears the dictionary, head, and tail, but does not break links between all remaining nodes: `DiffLineCache.swift:156-162`.
- `AppCoordinator` retains every `ReviewSessionStore` ever created in `stores`, with no removal path when a window closes: `PRReviewApp/App/PRReviewApp.swift:45,92-107`.
- Each store owns a `DiffLineCache` that may hold up to 32,768 attributed lines: `ReviewSessionStore.swift:58-60`, `DiffLineCache.swift:63`.

**Why it matters**

Closing review windows does not currently release their stores. Even after adding store cleanup, the bidirectional cache list can retain its nodes. Opening many large pull requests can therefore cause persistent memory growth, increased allocator pressure, cache misses, and eventual system-level paging lag.

**Suggestions**

- Make the LRU back-link weak (`weak var prev`) or explicitly unlink every node during cache cleanup and deinitialization.
- Add an explicit window lifecycle callback that removes the keyed store from `AppCoordinator.stores` when its window closes.
- Cancel outstanding load, refresh, submit, resolve, and dependency tasks when a store is released.
- Clear the rendered-line cache when loading a different PR or head SHA unless cross-review cache reuse is intentionally required.
- Add a lifecycle test proving that closing a window releases its store and cache.

### 2. Reduce `ReviewSessionStore` invalidation fan-out

**Evidence**

- One `ObservableObject` publishes state for selection, hover, search, banners, dependency health, draft editing, reply editing, and submit editing: `ReviewSessionStore.swift:31-54`.
- `ReviewWindowView`, `FileSidebarView`, `DiffView`, every `DiffRowView`, every `DiffLineView`, every `ThreadCardView`, and editor views observe the entire store.
- Hovering a line writes `hoveredRowID`: `DiffLineView.swift:68-73`.
- Draft text writes `store.draftEditor` on every keystroke: `DraftEditorView.swift:21-27`.
- Reply text replaces a value in the published `replyEditors` dictionary on every keystroke: `DiffLineView.swift:247-255`.
- Submit text binds directly to published `submitBody`: `DraftEditorView.swift:90-95`.

**Why it matters**

Any published change emits the store's shared `objectWillChange`. A hover transition or editor keystroke can invalidate the sidebar, toolbar, diff pane, and all realized rows, even when most views do not depend on that property. The rendered-line cache reduces computation inside each row but does not prevent SwiftUI from reevaluating the view hierarchy.

**Suggestions**

- Split the store into narrower observable models, for example session content, selection/hover, sidebar filtering, draft editor, reply editor, submit editor, and dependency health.
- Pass immutable row values and small bindings into leaf views instead of the entire store.
- Keep hover state local to the diff pane or individual row. Consider a lightweight selection model observed only by row backgrounds.
- Keep editor text in local `@State`; commit to the session store on Save/Send, or debounce updates if crash recovery requires live persistence.
- Use Combine publishers with `removeDuplicates()` for derived command availability and other repeated values.
- Use SwiftUI Instruments to compare view-body update counts while moving the pointer and typing in each editor.

### 3. Stop rebuilding the complete presentation for local mutations

**Evidence**

- Every assignment to `session` calls `publish(session:)`, which creates a new `ReviewPresentation`: `ReviewSessionStoreWorkflows.swift:90-113`.
- `ReviewPresentation.init` rebuilds rows for every file: `ReviewPresentation.swift:106-115`.
- It also rescans all threads and drafts for every sidebar item: `ReviewPresentation.swift:130-145`.
- Viewed toggles, resolve toggles, draft changes, undo/redo, local replies, and submit changes all republish the session. Examples: `ReviewSessionStoreWorkflows.swift:288-313,361-368`.
- The comment in `ReviewPresentation` says rows are built once per load, but mutation publishing means they are rebuilt far more often.

**Why it matters**

For a large PR, toggling one viewed mark or resolving one thread can rebuild all file rows and sidebar metadata synchronously on the main actor. The cost grows with total PR lines and files rather than the single changed item.

**Suggestions**

- Separate immutable loaded data from mutable review state.
- Keep file/hunk/line structures and base line rows stable across draft, thread, and viewed mutations.
- Rebuild only the affected file's row list when a draft or thread changes.
- Update only the affected sidebar item when viewed or thread counts change.
- Store rows and sidebar items in indexed mutable snapshots or dedicated observable submodels rather than reconstructing the entire `ReviewPresentation`.
- Add benchmark stages for `toggleViewed`, `toggleResolved`, adding a draft, deleting a draft, undo, and redo on the `large` and `xlarge` fixtures.

### 4. Make background presentation assembly explicit and keep republishing off the main actor

**Evidence**

- `ReviewSessionStore` is `@MainActor`, and local mutation/refresh publication eventually assigns through `self.session`, rebuilding `ReviewPresentation` on the store's actor: `ReviewSessionStore.swift:28`; `ReviewSessionStoreWorkflows.swift:90-113`.
- Initial assembly occurs inside non-actor-isolated async loader methods, and demo generation/parsing is explicitly detached: `ReviewSessionLoader.swift:21-68`. The intended executor boundaries are not instrumented or enforced by a dedicated builder abstraction.
- Refresh applies the fetched result by republishing the full presentation from the main-actor store.

**Why it matters**

The initial loader may execute its nonisolated work on the generic executor, but local mutations and refresh publication demonstrably rebuild derived data from the main-actor store. Large transformations should be explicitly isolated from UI publication so future refactors cannot accidentally move them onto the main actor.

**Suggestions**

- Introduce a pure, Sendable presentation-builder layer that runs on a detached task or dedicated actor.
- Build row indexes, sidebar metadata, anchor indexes, and lookup dictionaries off-main.
- Publish one completed immutable snapshot on the main actor.
- Apply the same path to refresh and any local mutation that still requires rebuilding derived data.
- Add signposts and executor/thread assertions around fetch, parse, anchor validation, row building, sidebar aggregation, and main-actor publication.

## Priority 1: high-value improvements

### 5. Replace nested row-builder scans with anchor indexes

**Evidence**

- `RowBuilder` filters the complete thread and draft arrays for every file: `Sources/PRReviewKit/App/RowBuilder.swift:29-38`.
- For each diff line, it loops through every active thread and draft in that file: `RowBuilder.swift:55-84`.
- Thread sorting repeatedly evaluates `lastCommentAt`; that property maps and finds the maximum comment date on each comparator call.

**Why it matters**

Current complexity approaches `lines × (threads + drafts)` per file, in addition to global filtering. Files with many comments or drafts make row construction disproportionately expensive.

**Suggestions**

- Group threads and drafts by path once before building any files.
- Within each file, index attachments by `(side, line)` so row assembly becomes close to `O(lines + threads + drafts)`.
- Precompute thread sort keys, including last-comment date, once before sorting.
- Preserve deterministic attachment order in each anchor bucket.
- Benchmark a synthetic file with thousands of lines and hundreds of threads/drafts.

### 6. Precompute navigation and lookup indexes

**Evidence**

- Every arrow-key move rebuilds all commentable line IDs and then searches the array: `ReviewSessionStoreWorkflows.swift:605-626`.
- Every hunk move remaps all display rows and extracts hunk IDs: `ReviewSessionStoreWorkflows.swift:646-656`.
- `selectedFile`, file validation, adjacent-file selection, thread lookup, and draft lookup use repeated linear searches: `ReviewSessionStore.swift:168-179`, `DiffRowView.swift:59-67`.

**Why it matters**

Holding an arrow key on a very large file repeatedly scans and allocates arrays for the same unchanged data. Linear ID lookups also add work to frequently reevaluated row bodies.

**Suggestions**

- Store `fileByPath`, `fileIndexByPath`, `threadByID`, and `draftByID` dictionaries in the presentation snapshot.
- Precompute commentable row IDs, row-position maps, and hunk IDs per file.
- Track the current navigation index directly instead of locating the selected ID on every command.
- Rebuild only the affected indexes when file rows change.

### 7. Make rendered-line cache keys cheaper and improve cache lifecycle

**Evidence**

- `DiffLineCache.Key` stores and hashes the complete `Language` value and line content: `DiffLineCache.swift:20-40`.
- `Language` contains arrays and large keyword sets, so synthesized hashing/equality is substantially heavier than a compact identifier.
- `Highlighter.language(for:)` resolves the language from the path for every realized line: `DiffLineView.swift:38-43`.
- Cache accounting measures content characters, not the actual memory retained by `AttributedString`, keys, nodes, and attribute runs.

**Why it matters**

Cache hits are in a hot rendering path. Hashing a full language definition and resolving file extensions per row wastes work. The current memory bounds can also significantly underestimate actual retained memory.

**Suggestions**

- Add a compact `LanguageID` and resolve it once per file.
- Pass the resolved ID/language from `DiffView` or the presentation snapshot into line views.
- Key cached rendering by stable review generation + file/hunk/line identity + theme, then clear the cache when the review generation changes. This avoids hashing full content and language definitions on every hit.
- Bound the cache using estimated rendered bytes or measured cost, not only source character count.
- Record cache hits, misses, evictions, retained entries, and estimated bytes in benchmark diagnostics.
- Consider prewarming only the first viewport of the selected and adjacent files after higher-priority invalidation work is complete.

### 8. Parallelize independent GitHub fetches with bounded concurrency

**Evidence**

- PR metadata, diff, and threads are fetched sequentially: `Sources/PRReviewKit/GH/GitHubClient.swift:411-415`.
- Extra comment pages are fetched serially for each thread: `GitHubClient.swift:381-399`.

**Why it matters**

For remote PRs, process startup and network latency can dominate loading. The three top-level fetches are independent. A review with many long threads also accumulates serial round trips.

**Suggestions**

- Use `async let` for PR metadata, diff, and thread fetches after endpoint and dependency validation.
- Fetch additional thread-comment pages with a bounded task group rather than unbounded parallelism or complete serialization.
- Confirm that concurrent `gh` subprocesses and authentication/config access are safe.
- Preserve cancellation and fail-fast semantics.
- Measure wall-clock load time separately from CPU time.

### 9. Cache formatters and precompute thread display data

**Evidence**

- `RelativeDateTimeFormatter` is allocated for every `timeAgo` call: `DiffLineView.swift:291-295`.
- A thread renders the root timestamp and every comment timestamp, repeating `Date()` and formatter work.
- `parseGHDate` creates a new `ISO8601DateFormatter` per parsed comment: `Sources/PRReviewKit/ReviewTypes.swift:4-10`.

**Why it matters**

Formatter construction is expensive. Large or frequently invalidated thread cards amplify the cost during loading and rendering.

**Suggestions**

- Reuse cached formatter instances with appropriate isolation/thread-safety.
- Parse GitHub timestamps through one decoder/formatter strategy per fetch operation.
- Precompute thread presentation strings when the thread snapshot changes.
- Update relative times on a low-frequency shared timer only if live updates are required.

### 10. Index draft anchors once

**Evidence**

- `DraftAnchorValidator` finds a file by scanning all files for every draft.
- It then scans hunks and lines for each end of each draft range: `Sources/PRReviewKit/App/DraftAnchorValidator.swift:23-70`.

**Why it matters**

Revalidation cost grows with `drafts × files × lines`. Head-SHA migration on a large PR with many local comments can become a visible load or refresh delay.

**Suggestions**

- Build a path-to-file index and `(side, line) -> hunkIndex` anchor maps once per fetched diff.
- Reuse those maps for draft revalidation, commentability checks, selection navigation, and thread attachment.
- Keep the index in the immutable review snapshot.

## Priority 2: worthwhile after profiling

### 11. Coalesce persistence writes

Every viewed toggle writes and sorts the full viewed set, and every draft change writes all drafts. Rapid actions can queue redundant actor work and filesystem writes.

Suggestions:

- Debounce writes briefly and persist only the latest snapshot per `(endpoint, headSHA, state kind)`.
- Flush pending changes when the window closes or app resigns active.
- Keep atomic replacement and failure reporting.
- Avoid delaying user-visible in-memory updates.

Relevant code: `ReviewSessionStoreWorkflows.swift:256-296`; `Sources/PRReviewKit/Persistence/ReviewPersistence.swift:85-126`.

### 12. Reduce raw-diff peak memory

`DiffParser.parse` splits the complete diff with `components(separatedBy:)`, creating an array of all lines while the original string remains alive. The command layer also holds raw `Data`, a decoded `String`, parsed line strings, and final model strings during loading.

Suggestions:

- Parse using `String` line iteration and `Substring` slices to reduce temporary allocations.
- For very large diffs, consider parsing from a file/byte stream rather than materializing the entire payload multiple times.
- Reserve capacities for files, hunks, and lines when counts are known or can be estimated.
- Measure peak physical footprint during fetch and parse, not only after work completes.

Relevant code: `Sources/PRReviewKit/Diff/DiffParser.swift:7-126`; `Sources/PRReviewKit/GH/CommandProcess.swift:314-323`.

### 13. Avoid repeated sidebar normalization and filtering in view updates

`filteredSidebarItems` trims/lowercases the query and lowercases every file path whenever evaluated: `ReviewSessionStore.swift:182-189`. Search text is published on every keystroke, invalidating all store observers.

Suggestions:

- Precompute a normalized searchable path/status field in `FileSidebarItem`.
- Move search state into a sidebar-specific model.
- Debounce filtering for very large file counts while updating the visible query immediately.
- Publish filtered results only when they change.

### 14. Remove type erasure from hot view paths

`DiffView` and `DiffLineView` return `AnyView`: `DiffView.swift:15-37`; `DiffLineView.swift:21-90`.

Suggestions:

- Use `@ViewBuilder`, `Group`, or dedicated branch views to preserve static view identity.
- Verify the effect with SwiftUI Instruments; this is lower priority than invalidation scope and presentation rebuilding.

### 15. Profile nested scrolling and layout passes

The diff uses a vertical scroll view containing a horizontal scroll view, inside `GeometryReader`, with a minimum-width frame on every row: `DiffView.swift:40-70`.

Suggestions:

- Inspect layout passes and hitches with SwiftUI Instruments before changing this structure.
- Compare against a two-axis scroll container or an AppKit-backed virtualized diff view for extremely large files.
- Consider an AppKit `NSTableView`/custom text renderer only if SwiftUI virtualization remains a measured bottleneck after state and data work is fixed.

## Suggested implementation order

1. Fix the cache retain cycle and window/store cleanup.
2. Add signposts and capture a Release-build baseline.
3. Split observable state to stop hover/editor invalidation storms.
4. Replace full `ReviewPresentation` republishing with incremental affected-file updates.
5. Build rows, indexes, and validation data off-main.
6. Index row attachments, navigation, files, threads, drafts, and anchors.
7. Simplify rendered-line cache keys and add cache metrics.
8. Parallelize independent network fetches.
9. Apply formatter, persistence, parser-memory, and view-structure refinements.

## Validation plan

Use the same deterministic fixtures for every comparison:

- `medium`: 50 files / 10,000 lines.
- `large`: 250 files / 40,000 lines.
- `xlarge`: 800 files / 120,000 lines.
- Add a comment-heavy fixture with hundreds of threads and drafts in a few large files.

Capture in a Release build:

1. Initial load until the first diff viewport is usable.
2. Rapid file switching across 20 files, then switching back through them.
3. Continuous hover movement over diff lines.
4. Holding Up/Down through a very large file.
5. Typing continuously in draft, reply, and submit editors.
6. Toggling viewed state on 50 files.
7. Resolving/unresolving 20 threads.
8. Opening and closing many review windows.
9. Refreshing after a head-SHA change with many drafts.

Track:

- Main-thread hangs over 16 ms and over 100 ms.
- SwiftUI body-update counts by view type.
- File-switch median, p95, and maximum latency.
- Initial-load wall time and time-to-first-usable-viewport.
- Peak and steady-state physical footprint.
- Memory after closing every review window.
- Cache hit/miss/eviction rates.
- Row-build and presentation-publication time.
- Network fetch wall time and subprocess count.

## Target outcomes

- Warm file switches stay within one 60 Hz frame at p95.
- Hovering and editor typing do not invalidate the whole diff/sidebar hierarchy.
- Local viewed/thread/draft mutations scale with the affected file, not the full PR.
- Initial load performs no large synchronous transformation on the main actor.
- Closing a window releases its store, tasks, presentation, and caches.
- Memory remains bounded and returns near baseline after all review windows close.
