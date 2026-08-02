# Phase 4 — Desktop technology spike: results and decision

Date: 2026-08-02 · Machine: Apple M1 Max (arm64), macOS 26.5.2 (Build 25F84),
Swift 6.3.3, Xcode 26.6. Working tree includes Phases 1-3.

## Deliverables

- `Sources/PRReviewBenchmarkSupport/` — deterministic `SyntheticDiffFixture`
  (10k/50k/100k parsed-line diffs, multi-file, multi-hunk, mixed line kinds,
  occasional ~3.1k-5.4k-character lines) and `Measurement` helpers (wall
  timing, Mach `phys_footprint`).
- `Sources/PRReviewBench/` — release-mode headless benchmark.
- `Sources/PRReviewSpike/` — SwiftUI spike app: `LazyVStack` diff rendering of
  real `PRReviewKit` models, stable row IDs derived from file/hunk/line
  anchors, nested horizontal+vertical scrolling, programmatic hunk jumps,
  Shift-click range selection prototype, window-close interception
  (`NSWindowDelegate`), `WindowGroup(for:)` multi-window routing, main-run-loop
  stall watchdog, and a `--smoke` headless pipeline mode. (Drag selection
  across rows, selection edge autoscroll, and synthetic-thread navigation are
  NOT implemented — see Deferred.)
- `Tests/.../SyntheticDiffFixtureTests.swift` — determinism, exact parsed
  counts, mixed kinds, long lines, row-count sanity (121 total tests).

## Core pipeline measurements (release build, median of 3)

| Fixture | parse (incl. word diff) | row build | highlight viewport (200 lines) | highlight all (diagnostic) | footprint after work |
| ------- | ----------------------- | --------- | ------------------------------ | -------------------------- | -------------------- |
| 10,000  | 13 ms                   | <1 ms     | 4 ms                           | 155 ms                     | 13.5 MiB             |
| 50,000  | 67 ms                   | 2 ms      | 4 ms                           | 771 ms                     | 50.2 MiB             |
| 100,000 | 136 ms                  | 3 ms      | 4 ms                           | 1,517 ms                   | 50.2 MiB             |

("after work" = measured after the runs loop, i.e. after fixture generation,
parsing, row building, and the diagnostic eager-highlight pass. The 50k and
100k values plateau at ~50 MiB because the allocator retains its high-water
pages within one process; both are far below the 400 MiB target.)

Spike `--smoke` (debug build, same pipeline as the window): 100k parses in
321 ms + row build 377 ms, 66.4 MiB footprint after assignment.

## Acceptance targets

| Target                                                    | Result                                                                                                                   | Status                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| 50,000-line diff interactive within 2 s                   | 67 ms parse + 2 ms rows (release); viewport tokenization ~4 ms                                                           | PASS (pipeline; huge margin)                  |
| Memory below 400 MB for 100,000-line fixture              | 25.6 MiB footprint after generation; 50.2 MiB after work (release)                                                       | PASS (pipeline; huge margin)                  |
| No main-thread stalls > 100 ms during ordinary navigation | Watchdog implemented (background sampler + main-runloop heartbeat); no stalls observed in smoke/GUI runs on this machine | PASS on macOS 26; final macOS 13 run deferred |
| Smooth trackpad and mouse scrolling                       | LazyVStack virtualization + ~4 ms viewport tokenization; subjective smoothness requires a human on macOS 13              | CONDITIONAL / DEFERRED                        |
| AppKit-backed diff list only if benchmarks require it     | Benchmarks do not require it                                                                                             | Provisional LazyVStack decision               |

## Key finding

Eager syntax highlighting of every line is the only expensive operation
(0.77 s at 50k, 1.5 s at 100k, O(N) in tokens). The production app must
tokenize only rendered/prefetched rows (~4 ms per viewport). This confirms the
Phase 5 design constraint: cache keyed by language + content, viewport-driven.

## Decision (provisional)

**Provisionally retain `LazyVStack`** for the Phase 5 diff pane: row
construction is negligible (µs/row), identity is stable, and viewport-only
tokenization keeps interaction in the low milliseconds. This is a pipeline
decision only — it does not prove smooth rendering or stall-free navigation in
the SwiftUI view. If a macOS 13 hardware run shows recurring hitches (or the
Phase 5 selection/scroll implementation proves brittle), switch to a
view-based `NSTableView` inside an `NSScrollView`.

## Deferred (Phase 5/10 gates)

- Final macOS 13 interactive matrix (this machine is macOS 26): Shift-click
  range selection (prototype present), drag selection across rows (NOT
  implemented — a row-local DragGesture cannot span rows; needs a global
  gesture or AppKit hit-testing bridge), selection edge autoscroll (NOT
  implemented), nested-scroll feel, close interception (implemented; programmatic
  `close()` bypasses the delegate for the confirmed state), multi-window dedup
  (`WindowGroup(for:)` implemented; focus behavior to confirm by hand).
- Synthetic threads: the fixture generator produces no review threads, so
  "Next thread" in the spike has no targets; thread navigation is a Phase 5/6
  concern, not proven here.
- Finder launch, `pr-review://` URL delivery, and the terminal launcher
  require the Phase 5 app bundle (Info.plist) and are Phase 5/10 checks.
- Instruments Time Profiler / Core Animation / Allocations confirmation on
  qualified hardware.

## Generator note

Long lines are ~3.1k-5.4k characters (60-99 repeats of a ~55-char segment),
placed once per 5,000 lines _per file_ (the counter resets per file, not
globally).

## How to reproduce

```sh
swift test
swift build -c release
.build/release/PRReviewBench --fixture 50000 --runs 3
.build/release/PRReviewBench --fixture 100000 --runs 3
swift run PRReviewSpike --smoke
swift run PRReviewSpike          # interactive window
```
