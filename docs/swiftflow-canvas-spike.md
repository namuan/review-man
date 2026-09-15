# SwiftFlow change-canvas spike

This branch evaluates replacing the custom change-canvas rendering/viewport engine with SwiftFlow while preserving review-man's PR-specific model and behavior.

## Scope

`SwiftFlowCanvasSpikeView` adapts the existing `CanvasTree`/`TreePlan` output into SwiftFlow nodes and edges. SwiftFlow owns node/edge rendering, hit testing, panning, pinch zooming, viewport state, fit-to-view, and selection. Review-man continues to own folder/file semantics, collapse state, comment/viewed metadata, and opening the focused diff.

The first spike intentionally keeps the deterministic `TreePlan` positions. That isolates renderer/viewport performance from a simultaneous layout-algorithm change and makes an A/B comparison meaningful. If the renderer wins, a follow-up can benchmark SwiftFlow's `.tree(direction: .leftToRight, ...)` auto-layout and remove `TreePlan` too.

The production canvas remains the default. Launch the app with `--swiftflow-canvas` to select the spike for comparison.

## Toolchain note

SwiftFlow 0.1.1 requires Swift 6.1. The package manifest is therefore raised from Swift tools 5.9 to 6.1 on this spike branch. This is the largest adoption constraint and should be treated as part of the evaluation rather than silently folded into production.

## Validation

Run the existing demo tiers and compare the current canvas against the SwiftFlow spike for:

- initial graph construction and first render
- pan/zoom responsiveness
- memory at `large` (250 files / 40k lines) and `xlarge` (800 files / 120k lines)
- collapse/expand reflow
- file activation and viewed/comment metadata
- VoiceOver and keyboard behavior

## Remaining parity work before replacement

The spike proves the rendering boundary but does not delete the existing canvas yet. Before switching the default implementation, port the current canvas search overlay, directional keyboard navigation/focus restoration, one-level collapse/expand commands, and search-to-node centering to `SwiftFlowInstance`. Keep the existing `CanvasScale` degradation policy regardless of renderer: graph-node scalability and mounting full diff-card contents are separate performance concerns.
