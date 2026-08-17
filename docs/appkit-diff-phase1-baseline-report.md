# Phase 1 baseline report

Status: exploratory baseline

Date: 17 August 2026

## Executive summary

The headless pipeline scales predictably with diff size.

At 100,000 parsed lines:

- parsing, including word-diff calculation, takes 284ms
- full presentation construction takes 14ms
- row construction takes 4ms
- highlighting all lines takes 1.60s
- highlighting the first 200 lines takes 4ms
- cold rendered-line caching takes 9ms
- warm rendered-line caching takes 0.1ms
- the working footprint is 66.4 MiB

These results do not include SwiftUI layout, view creation, scrolling or actual frame rate. The next measurement must use Instruments with the application running.

## Scope and method

The benchmark ran with:

```sh
make baseline
```

The command ran 3 release-mode samples for each fixture:

- 10,000 lines across 50 files
- 50,000 lines across 250 files
- 100,000 lines across 500 files

The fixtures include multiple hunks, mixed line kinds and generated long lines. The benchmark also measures incremental viewed, draft and thread mutations.

The measurements ran on:

- machine: Apple M1 Max
- operating system: Version 26.5.2, build 25F84
- sample statistic: median of 3 runs

Reports are generated under `build/perf/`. The directory is ignored by Git.

## Results by fixture size

### 10,000 lines

- parse including word diff: 28.3ms
- row build: 0.42ms
- full presentation build: 1.46ms
- first 200 lines highlighted: 4.09ms
- cold cache for 200 lines: 9.28ms
- warm cache for 200 lines: 0.10ms
- all-line highlighting diagnostic: 196ms
- footprint after generation: 5.4 MiB
- footprint after benchmark work: 18.0 MiB

### 50,000 lines

- parse including word diff: 142ms
- row build: 2.08ms
- full presentation build: 6.45ms
- first 200 lines highlighted: 4.05ms
- cold cache for 200 lines: 9.37ms
- warm cache for 200 lines: 0.10ms
- all-line highlighting diagnostic: 796ms
- footprint after generation: 20.0 MiB
- footprint after benchmark work: 60.1 MiB

### 100,000 lines

- parse including word diff: 284ms
- row build: 4.18ms
- full presentation build: 14.1ms
- first 200 lines highlighted: 4.09ms
- cold cache for 200 lines: 9.33ms
- warm cache for 200 lines: 0.10ms
- all-line highlighting diagnostic: 1.60s
- footprint after generation: 36.3 MiB
- footprint after benchmark work: 66.4 MiB

## Findings

### Parsing scales linearly

Parsing grows from 28ms at 10,000 lines to 284ms at 100,000 lines. This is expected and is not currently large enough to explain a long UI pause by itself.

Word-diff calculation is included in this stage.

### Full-file highlighting is expensive

The all-line highlighting diagnostic grows from 196ms to 1.60s. The viewport-only measurement stays near 4ms because the current renderer highlights lines on demand.

This supports keeping syntax highlighting demand-driven. It also suggests that eagerly highlighting an entire large file would be the wrong optimisation.

### The rendered-line cache works well after warm-up

The cold viewport takes about 9ms. The same viewport takes about 0.1ms when cached.

The current cache hit ratio is 50% in this diagnostic because the benchmark deliberately measures one cold pass followed by one warm pass.

### Presentation and row construction are not the main headless cost

Full presentation construction remains below 15ms at 100,000 lines. Row construction remains below 5ms.

This points the next investigation towards SwiftUI view creation, layout, text rendering and scrolling rather than row-model construction.

### Memory grows with diff size

The working footprint reaches 66.4 MiB for the 100,000-line fixture. This is acceptable for the current headless pipeline, but the AppKit prototype should keep visible-row state bounded and avoid retaining a view for every line.

## Phase 1 instrumentation

The application now emits `os_signpost` intervals under:

- subsystem: `com.prreview.app`
- category: `performance`

Instrumented phases and actions include:

- `DiffParse`
- `DemoFixtureBuild`
- `PresentationBuild`
- `DiffFileSelection`
- `DraftEditorPresentation`
- `DiffNavigation`

The application log also records the file-selection-to-first-interactive-frame measurement:

```text
~/Library/Logs/PR Review/PRReview.log
```

The `DiffFileSelection` interval starts when the focused diff becomes the selected view and ends after SwiftUI receives two main-queue turns after the diff appears. This is a proxy for the first interactive frame. Instruments should verify the exact frame timing.

## Measurements still needed

The headless benchmark does not measure:

- SwiftUI body evaluation time
- SwiftUI layout and display-list construction
- time to first interactive frame in the real application
- scroll frame rate
- main-thread blocking during scrolling
- line-selection latency in the real window
- comment-editor presentation latency in the real window

Use Instruments with the application launched in demo mode. Profile at least the 50,000-line and 100,000-line fixtures.

## Decision for the next phase

The current data does not justify an AppKit rewrite by itself. It does justify measuring the real SwiftUI renderer because the headless model and cache stages are relatively small.

Proceed to the AppKit read-only spike only if Instruments shows that SwiftUI view creation, layout or scrolling is the dominant cost at large file sizes.

If the UI profile confirms that result, continue profiling the custom `NSScrollView` drawing surface with the same fixtures and acceptance measurements.
