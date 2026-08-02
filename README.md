# review-man

A native macOS app for reviewing GitHub pull requests — plus the original
terminal UI. Read the diff, comment on lines, reply to threads, resolve,
approve or request changes, all anchored to the authenticated `gh` CLI.

> **Status**: the desktop migration is implemented end-to-end (Phases 1–10 of
> [DESKTOP_UI_MIGRATION_PLAN.md](DESKTOP_UI_MIGRATION_PLAN.md)). The
> terminal UI remains the shipped executable until the release gates
> (notarization, clean-account Finder testing, native Intel, and actual macOS 13
> testing) pass. See the plan checklist for the live status.

## Desktop app

`PR Review.app` is a native SwiftUI application built from the `PRReview.xcodeproj`
project. One resizable window per pull request, with multiple PRs in separate
windows and no duplicates for the same repository + PR.

- **Read the diff** with SF Mono, fixed line-number gutters, horizontal
  scrolling, syntax coloring, and word-level change highlighting.
- **Comment inline**: click a line and add a draft (deleted lines become
  LEFT-side comments), or Shift-click for a multi-line range comment. Drafts
  are edited and deleted in place, with Undo/Redo, and persist automatically.
- **Threads**: expand, reply (retryable on failure), resolve/unresolve with
  optimistic updates and rollback.
- **Review**: comment, approve, or request changes with a summary; orphaned
  drafts (whose anchor left the diff) are excluded from submission and
  reattach automatically when their line returns.
- **File sidebar** with native search, status letters, ± counts, comment
  badges, and locally-persisted viewed marks.
- **`gh` onboarding**: the app discovers `gh` from your PATH, Apple Silicon or
  Intel Homebrew, or MacPorts (or a user-selected executable) and shows
  actionable status for missing, unauthenticated, expired, or under-scoped
  installations — without ever invoking a login shell.
- Full native menus and shortcuts, dark/light + high-contrast appearance,
  reduced-motion and reduced-transparency handling, and VoiceOver labels.

### Build and run the app

```sh
git clone https://github.com/namuan/review-man.git
cd review-man
open PRReview.xcodeproj        # then run the PRReviewApp scheme
```

or build from the command line:

```sh
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReviewApp -configuration Release build
```

or use the Makefile, which copies a directly-launchable app bundle to
`build/PR Review.app`:

```sh
make app     # Debug build at build/PR Review.app
make run     # build + launch
make demo    # build + launch in offline demo mode
make app CONFIG=Release UNIVERSAL=1   # universal arm64 + x86_64 release
```

The app registers the `pr-review://` URL scheme. `open pr-review://open/owner/repo/123`
opens or focuses that PR's window.

## Terminal UI

The `pr-review` executable is still the shipped terminal UI and will become a
thin launcher for the desktop app once the release gates pass. For now it runs
the original full-featured terminal review loop:

```sh
pr-review https://github.com/owner/repo/pull/123   # full URL
pr-review owner/repo#123                           # shorthand
pr-review 123                                      # current repo, bare number
pr-review --demo                                   # offline sample PR
```

### Terminal key bindings

| Key | Action |
| --- | --- |
| `j/k`, `↑/↓` | move cursor / selection |
| `Ctrl-D` / `Ctrl-U`, `PgDn/PgUp` | half page / page |
| `g` / `G` | first / last line |
| `Tab` | switch pane (files ↔ diff) |
| `Enter` | open file · expand thread · expand outdated |
| `{` / `}` | previous / next hunk |
| `[` / `]` | previous / next file |
| `C` | jump to next comment thread |
| `←` / `→` | horizontal scroll |
| `c` | add draft comment at cursor (deleted lines → LEFT side) |
| `V` … move … `c` | multi-line range comment |
| `e` | edit draft under cursor |
| `x` | delete draft under cursor |
| `X` | resolve / unresolve thread under cursor |
| `r` | reply to thread |
| `v` | toggle viewed (local only) |
| `/` | filter files |
| `s` | submit review (event: `1/2/3`, body: `b`, submit: `y`) |
| `y` | yank current line (`path:line`) to clipboard |
| `o` | open PR in browser |
| `p` | show PR description |
| `R` | refresh PR data |
| `?` | help |
| `q`, `Ctrl-C` | quit (confirms when drafts exist) |

Editor mode: `Esc` saves (empty text deletes the draft), `Ctrl-C` cancels,
`Ctrl-A`/`Ctrl-E`/`Ctrl-K`/`Ctrl-U` work, pasting is supported.

## Features shared by both UIs

- **Full unified-diff engine** (parsed locally): added/deleted/modified/renamed
  files, binary files, hunk headers with context, correct old/new line numbers,
  word-level intra-line change highlighting, and a per-file "diff too large"
  fallback when the raw diff endpoint fails.
- **Syntax highlighting** for ~17 languages (Swift, Go, Rust, Python, JS/TS,
  C/C++, Java, Kotlin, Ruby, shell, JSON, YAML, TOML, SQL, HTML…), cached per
  language and content with bounded growth.
- **Inline comment threads** anchored to their lines, with LEFT-side (deleted
  line) support, resolved state, and outdated-thread sections.
- **Draft comments** with multi-line editing, multi-line range comments, and
  **automatic persistence to disk** — drafts survive crashes and restarts and
  survive head-SHA changes (valid anchors are kept, invalid ones are marked
  orphaned and excluded from submission until they reattach).
- **Submit**: comment / approve / request-changes, anchored to the head commit
  SHA; submissions reject 422s when the head moved (refresh re-fetches and
  re-anchors).
- **Demo mode** with an embedded sample PR for offline exploration and UI
  tests.

## Requirements

- macOS 13+ with Swift 5.9+ (`swift --version`) and Xcode (the app), or just
  Command Line Tools (the terminal UI).
- The [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated:
  `brew install gh && gh auth login` (needs `repo` scope).

## Install (terminal UI)

```sh
git clone https://github.com/namuan/review-man.git
cd review-man
swift build -c release
cp .build/release/pr-review /usr/local/bin/
```

No dependencies are downloaded — `swift build` works offline.

## Design notes

- **Drafts are local until you submit.** They are persisted to
  `~/Library/Application Support/pr-review/` keyed by `owner_repo_number_sha`
  and restored when you reopen the same head.
- **Replies are sent immediately** (GitHub's reply API has no pending-review
  batching). Only top-level comments are submitted as one review.
- **Viewed marks are local only** (per head SHA); they are not pushed to GitHub.
- **LEFT-side comments** use old-file line numbers; **RIGHT-side** use new-file
  line numbers, exactly as the GitHub API requires.
- **Orphaned drafts**: when a head changes and a draft's line disappears, the
  draft is marked orphaned, excluded from submission, and shown in its own
  section; it reattaches automatically if its anchor returns.
- **`gh` discovery**: inherited PATH, then Apple Silicon Homebrew, Intel
  Homebrew, and MacPorts, or an explicitly selected executable; health is
  checked with `gh --version`, `gh auth status`, and a minimal authenticated
  API request.

## Testing

```sh
swift test   # 198 unit tests: diff parser, word diff, highlighter, row/payload
             # builders, draft persistence, async cancellation + ordering,
             # head-SHA migration + orphans, syntax cache, dependency health,
             # desktop store/workflows/commands, launcher + URL handling
```

`PRReviewAppUITests` (demo-mode UI tests) are scaffolded in the Xcode project;
full UI-test execution is recorded as manual/pending until a maintained
interactive runner exists. `PRReviewBench` (release mode) generates 10k/50k/100k
line synthetic diffs and measures the large-diff acceptance targets — see
[`docs/phase4-technology-spike.md`](docs/phase4-technology-spike.md).

Terminal smoke preview:

```sh
pr-review --demo --dump 100x32
```

## Project layout

```text
Sources/
  PRReviewKit/          reusable core (diff, highlight, GitHub, persistence,
                        review operations, row building)
  PRReviewDesktop/      SwiftUI app: store, workflows, views, commands, themes
  pr-review/            terminal UI executable (future desktop launcher)
PRReviewApp/            app bundle host (URL scheme, coordinator)
PRReviewAppUITests/     demo-mode UI tests
PRReview.xcodeproj/     Xcode project (xcodegen project.yml)
Tests/
  PRReviewKitTests/     core unit tests
  PRReviewDesktopTests/ desktop store/workflow/command unit tests
docs/                   parity matrix, technology spike, phase-4 results
```

## License

MIT — see [LICENSE](LICENSE).
