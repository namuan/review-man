# review-man

A full-featured terminal UI for reviewing GitHub pull requests, written in pure
Swift. No Xcode GUI needed for anything — build and run with Swift Package
Manager and the `gh` CLI.

> **Desktop app planned** — a native macOS UI is on the roadmap; see
> [DESKTOP_UI_MIGRATION_PLAN.md](DESKTOP_UI_MIGRATION_PLAN.md).

```
PR #14035  Fix project scope errors during issue creation       DRAFT  maxbeizer · feature/x → trunk
+253 −30  9 files · 0 threads · review required
Files (9)                   api/client.go                                                  hunk 1/3  +54 −0
api/client.go       +54 −0   @@ -8,6 +8,7 @@ import (
api/client_test.go  +27 −0 8   8        "io"
api/queries_projec…  +7 −3 9   9        "net/http"
…
▎ williammartin · 2 days ago
1 comment · Enter to expand
295  +    var current *Worktree
…

a comment · e edit · x del · r reply · s submit · v viewed · / filter · R refresh · ? help · q  #14035 file 1/9
```

## Features

- **Review loop, complete**: read the diff, comment on lines, reply to threads,
  resolve/unresolve, and submit a review (comment / approve / request changes).
- **Full unified-diff engine** (parsed locally): added/deleted/modified/renamed
  files, binary files, hunk headers with context, correct old/new line numbers,
  word-level intra-line change highlighting.
- **Syntax highlighting** for ~17 languages (Swift, Go, Rust, Python, JS/TS,
  C/C++, Java, Kotlin, Ruby, shell, JSON, YAML, TOML, SQL, HTML…).
- **Inline comment threads** anchored to their lines, with left-side (deleted
  line) support, resolved state, and a collapsed "outdated comments" section.
- **Draft comments** with multi-line editor, visual-range multi-line comments,
  and **automatic persistence to disk** — drafts survive crashes and restarts.
- **Submit dialog**: pick an event, write a summary, review the included drafts,
  confirm. Submissions are anchored to the head commit SHA.
- File list with status letters, ± counts, comment dots, viewed tracking
  (local), and a `/` filter. Mouse click + scroll wheel support.
- Keyboard-driven (vim-style): hunks `{}`, files `[]`, threads `C`, refresh `R`,
  yank `y`, open in browser `o`, PR body `p`, help `?`.
- **Demo mode** (`--demo`) with an embedded sample PR, plus a headless
  `--dump` renderer for scripting and CI smoke checks.

## Requirements

- macOS 13+ with Swift 5.9+ (`swift --version`). Xcode is **not** required —
  Command Line Tools suffice.
- The [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated:
  `brew install gh && gh auth login` (needs `repo` scope).

## Install

```sh
git clone https://github.com/namuan/review-man.git
cd review-man
swift build -c release
cp .build/release/pr-review /usr/local/bin/
```

No dependencies are downloaded — `swift build` works offline.

## Usage

```sh
pr-review https://github.com/owner/repo/pull/123   # full URL
pr-review owner/repo#123                           # shorthand
pr-review 123                                      # current repo, bare number
pr-review --demo                                   # offline sample PR
```

### Key bindings

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

## Design notes

- **Drafts are local until you submit.** They are persisted to
  `~/Library/Application Support/pr-review/` keyed by `owner-repo-number-sha`,
  restored when you reopen the same head.
- **Replies are sent immediately** (GitHub's reply API has no pending-review
  batching). Only top-level comments collected via `c` are submitted as one
  review.
- **Viewed marks are local only** (per head SHA); they are not pushed to GitHub.
- **LEFT-side comments** use old-file line numbers; **RIGHT-side** use new-file
  line numbers, exactly as the GitHub API requires.
- If the head commit moves between fetch and submit, GitHub rejects the review
  with a 422 — the message is shown; press `R` to re-fetch (your drafts are
  kept and re-anchored when their lines still exist).
- Very large PRs: if the raw diff endpoint fails, the app falls back to the
  per-file endpoint and shows a "diff too large" placeholder for files without
  patches.

## Testing

```sh
swift test          # 56 unit tests: diff parser, word diff, highlighter,
                    # editor, row builder, payload JSON, screen rendering
```

Non-interactive smoke preview:

```sh
pr-review --demo --dump 100x32
```

## Project layout

```
Sources/PRReviewKit/
  Term/        terminal layer (raw mode, keys, screen, styles, text utils)
  Diff/        unified diff parser + word-level diff
  Highlight/   syntax highlighter + language definitions
  GH/          gh CLI wrapper, GraphQL client, review payloads
  App/         model, view, controller, draft store, demo data
Sources/pr-review/main.swift
Tests/PRReviewKitTests/
```

## License

MIT — see [LICENSE](LICENSE).
