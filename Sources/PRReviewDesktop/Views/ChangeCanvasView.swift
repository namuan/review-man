import SwiftUI
import Foundation
import PRReviewKit

/// A spatial overview of every file changed by the pull request.
///
/// This is a canvas of complete file patches, not a second truncated diff.
/// Cards grow with the number of hunks and lines they contain, so the shape
/// of the board reflects the shape of the PR. Selecting a card opens the
/// existing focused diff view for comments and line-level review.
/// How much detail the change canvas renders, chosen from the PR's size.
/// Full cards render every hunk and line; once a PR is large enough to
/// degrade, cards collapse to the file name only. This keeps the canvas
/// usable on `make demo` scale PRs.
public enum CanvasScale: Equatable {
    case full
    case condensed
    case summary

    /// PRs larger than 60 files or ~12k diff lines get condensed cards;
    /// larger than 300 files or ~60k lines get summary-only cards. A full
    /// canvas additionally stays within a small render budget: full cards
    /// mount one row per hunk line, so diffs beyond `fullCardLineBudget`
    /// rows collapse to file-name cards even when the file/line thresholds
    /// are not crossed. The demo tiers map as: small stays full, medium
    /// condenses (10k demo lines exceed the budget), large condenses,
    /// xlarge degrades to summaries.
    public static let condensedFileThreshold = 60
    public static let condensedLineThreshold = 12_000
    public static let fullCardLineBudget = 2_000
    public static let summaryFileThreshold = 300
    public static let summaryLineThreshold = 60_000

    public static func forFiles(_ files: [DiffFile]) -> CanvasScale {
        let totalLines = files.reduce(0) { $0 + $1.lineCount }
        if files.count > summaryFileThreshold || totalLines > summaryLineThreshold {
            return .summary
        }
        if files.count > condensedFileThreshold
            || totalLines > condensedLineThreshold
            || totalLines > fullCardLineBudget {
            return .condensed
        }
        return .full
    }
}

public struct ChangeCanvasView: View {
    public static let defaultZoom: CGFloat = 0.85
    public static let minimumZoom: CGFloat = 0.55
    public static let maximumZoom: CGFloat = 1.35
    public static let zoomStep: CGFloat = 0.1

    @ObservedObject public var store: ReviewSessionStore
    public let files: [DiffFile]
    @Binding public var showCanvas: Bool
    @Binding public var zoom: CGFloat

    @State private var pinchStartZoom: CGFloat?
    /// At most one condensed card expands inline at a time, preserving the
    /// large-PR canvas's light layout while allowing focused inspection.
    @State private var expandedCondensedPath: String?

    public static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, value))
    }

    private let cardMinimumWidth: CGFloat = 340
    private let cardMaximumWidth: CGFloat = 560
    private let cardGap: CGFloat = 22

    public init(
        store: ReviewSessionStore,
        files: [DiffFile],
        showCanvas: Binding<Bool>,
        zoom: Binding<CGFloat>
    ) {
        self.store = store
        self.files = files
        self._showCanvas = showCanvas
        self._zoom = zoom
    }

    public var body: some View {
        if files.isEmpty {
            EmptyStateView(
                icon: "square.grid.3x3",
                title: "Nothing to map",
                message: "This pull request has no changed files."
            )
        } else {
            VStack(spacing: 0) {
                canvasToolbar
                Divider()
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        canvasScroll(
                            viewportWidth: geometry.size.width
                        )
                    }
                    // Attach magnification to a parent of the ScrollView. This
                    // lets pinch gestures pass through cards while native
                    // two-axis scrolling stays untouched.
                    .simultaneousGesture(magnificationGesture)
                }
            }
            .accessibilityIdentifier("change-canvas-pane")
            .onChange(of: store.review?.pr?.headRefOid) { _ in
                // A reload/new PR must not carry an inline expansion to a
                // coincidentally named file in the next review.
                expandedCondensedPath = nil
            }
        }
    }

    private var canvasToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Change canvas")
                    .font(.headline)
                Text(toolbarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if scale != .full {
                Text(scale == .condensed ? "Condensed" : "Overview")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
                    .help(scale == .condensed
                        ? "Option-click a file name to expand it in the canvas; click to open the focused diff."
                        : "Very large PR — cards show file names. Click a card to open the focused diff.")
            }
            Text("\(files.count) files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider()
                .frame(height: 18)

            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out (Command minus)")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
                .accessibilityLabel("Canvas zoom \(Int(zoom * 100)) percent")

            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in (⌘+)")
            .accessibilityLabel("Zoom in (Command plus)")

            Button("Reset") {
                resetZoom()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Reset canvas zoom (⌘0)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("change-canvas-toolbar")
    }

    private var scale: CanvasScale {
        CanvasScale.forFiles(files)
    }

    private var toolbarSubtitle: String {
        switch scale {
        case .full:
            return "Complete patches · Pinch or ⌘+/⌘− to zoom"
        case .condensed:
            return "Option-click a file name to expand · Pinch or ⌘+/⌘− to zoom"
        case .summary:
            return "File names only for very large PRs · Pinch or ⌘+/⌘− to zoom"
        }
    }

    private func canvasScroll(viewportWidth: CGFloat) -> some View {
        let minimumBoardWidth = cardMinimumWidth * 2 + cardGap
        let maximumBoardWidth = cardMaximumWidth * 4 + cardGap * 3
        let boardWidth = min(
            max(viewportWidth - 48, minimumBoardWidth),
            maximumBoardWidth
        )
        let columnCount = max(
            1,
            min(4, Int((boardWidth + cardGap) / (cardMinimumWidth + cardGap)))
        )
        let columnWidth = (boardWidth - CGFloat(columnCount - 1) * cardGap)
            / CGFloat(columnCount)

        return ScrollView([.horizontal, .vertical], showsIndicators: true) {
            // scaleEffect changes pixels, not layout. CanvasZoomLayout measures
            // the unscaled board and reports the zoomed size synchronously in
            // the same layout pass, so the scroll document always matches the
            // rendered board. The previous preference-based measurement could
            // deliver a stale or viewport-sized height, which left the
            // document with no vertical range and killed trackpad scrolling.
            CanvasZoomLayout(zoom: zoom) {
                HStack(alignment: .top, spacing: cardGap) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        VStack(alignment: .leading, spacing: cardGap) {
                            ForEach(
                                Array(files.enumerated()).filter { $0.offset % columnCount == column },
                                id: \.element.path
                            ) { _, file in
                                fileCard(file, width: columnWidth)
                            }
                        }
                        .frame(width: columnWidth, alignment: .topLeading)
                    }
                }
                .frame(width: boardWidth, alignment: .leading)
                // Force the masonry columns to report their intrinsic height
                // instead of accepting the vertical ScrollView proposal.
                .fixedSize(horizontal: false, vertical: true)
                .padding(CanvasLayoutMetrics.outerPadding)
                .background {
                    Canvas { context, size in
                        drawGrid(in: &context, size: size)
                    }
                    .allowsHitTesting(false)
                }
                .scaleEffect(zoom, anchor: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onMoveCommand { direction in
            // The canvas itself navigates files with the arrow keys. Once a
            // card is opened, the focused diff restores line-level movement.
            switch direction {
            case .up:
                store.selectPreviousFile()
            case .down:
                store.selectNextFile()
            default:
                break
            }
        }
    }

    private func fileCard(_ file: DiffFile, width: CGFloat) -> some View {
        let isInlineExpanded = expandedCondensedPath == file.path
        return Button {
            handleCardClick(file)
        } label: {
            ChangeCanvasCard(
                store: store,
                file: file,
                scale: scale,
                isInlineExpanded: isInlineExpanded
            )
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .topLeading)
        .help(cardHelp(isInlineExpanded: isInlineExpanded))
        .contextMenu {
            Button("Open focused diff") { open(file) }
            Button(fileIsViewed(file) ? "Mark unviewed" : "Mark viewed") {
                store.toggleViewed(filePath: file.path)
            }
        }
        .accessibilityIdentifier("canvas-file-\(file.path)")
        .accessibilityLabel(canvasAccessibilityLabel(for: file))
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                }
                let start = pinchStartZoom ?? zoom
                zoom = Self.clampedZoom(start * value)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private func zoomIn() {
        zoom = Self.clampedZoom(zoom + Self.zoomStep)
    }

    private func zoomOut() {
        zoom = Self.clampedZoom(zoom - Self.zoomStep)
    }

    private func resetZoom() {
        zoom = Self.defaultZoom
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 28
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        context.stroke(path, with: .color(Color.gray.opacity(0.09)), lineWidth: 0.5)
    }

    private func handleCardClick(_ file: DiffFile) {
        if scale == .condensed, NSEvent.modifierFlags.contains(.option) {
            expandedCondensedPath = expandedCondensedPath == file.path ? nil : file.path
        } else {
            open(file)
        }
    }

    private func cardHelp(isInlineExpanded: Bool) -> String {
        guard scale == .condensed else { return "Open focused diff" }
        return isInlineExpanded
            ? "Option-click to collapse this patch"
            : "Option-click to expand this patch in the canvas"
    }

    private func open(_ file: DiffFile) {
        store.select(filePath: file.path)
        showCanvas = false
    }

    private func fileIsViewed(_ file: DiffFile) -> Bool {
        store.review?.viewed.contains(file.path) == true
    }

    private func canvasAccessibilityLabel(for file: DiffFile) -> String {
        let viewed = fileIsViewed(file) ? ", viewed" : ""
        let detail = scale == .full ? "complete patch" : "file entry"
        return "\(file.path), \(detail), \(file.additions) additions, \(file.deletions) deletions\(viewed)"
    }
}

private enum CanvasLayoutMetrics {
    static let outerPadding: CGFloat = 24
    static let compactCardHeight: CGFloat = 48
}

/// Sizes the scroll document to the zoomed board. `scaleEffect` only changes
/// rendering, not layout, so without this wrapper the scroll view would think
/// the board is its unscaled size. Measuring here, synchronously in the same
/// layout pass, avoids the asynchronous preference that previously left the
/// document at (or below) the viewport height and killed vertical trackpad
/// scrolling.
private struct CanvasZoomLayout: Layout {
    var zoom: CGFloat

    struct Cache {
        var invocationID: Int = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        cache.invocationID += 1
        let start = CFAbsoluteTimeGetCurrent()
        let raw = subviews[0].sizeThatFits(.unspecified)
        let measureElapsed = CFAbsoluteTimeGetCurrent() - start
        let z = max(zoom, 0.01)
        let size = CGSize(
            width: max(raw.width * z, proposal.width ?? raw.width * z),
            height: max(raw.height * z, proposal.height ?? raw.height * z)
        )
        let totalElapsed = CFAbsoluteTimeGetCurrent() - start
        AppLog.info("canvas", "CANVAS_METRIC fit #\(cache.invocationID) proposal=(\(proposal.width.map(String.init) ?? "nil"), \(proposal.height.map(String.init) ?? "nil")) zoom=\(zoom) raw=\(raw) size=\(size) measureMs=\(Int(measureElapsed * 1000)) fitMs=\(Int(totalElapsed * 1000))")
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        // The child lays out at its unscaled size; the scaleEffect anchored at
        // .topLeading scales it to fill the zoomed document bounds exactly.
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        AppLog.info("canvas", "CANVAS_METRIC place bounds=\(bounds.size) ms=\(Int(elapsed * 1000))")
    }
}

/// A variable-height file card. The rendered detail follows `scale`: full
/// cards show every hunk and line; every degraded tier (condensed and
/// summary) is just the file name.
private struct ChangeCanvasCard: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile
    let scale: CanvasScale
    let isInlineExpanded: Bool

    var body: some View {
        Group {
            if scale == .full || isInlineExpanded {
                detailedBody
            } else {
                // Degraded tiers show the minimal file-name card by default.
                // Condensed cards can opt into one inline full patch.
                summaryBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Degraded PRs: the card is just the file name (plus its status letter
    /// and viewed mark) so hundreds of cards stay instant to render.
    private var summaryBody: some View {
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))

            Text(file.path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if fileIsViewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CanvasLayoutMetrics.compactCardHeight)
    }

    private var detailedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            metadata
            ChangeDensityStrip(lines: allLines, isUnavailable: file.isBinary || file.tooLarge)
                .frame(height: 10)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if file.isBinary {
                unavailableState("Binary file", systemImage: "doc.zipper")
            } else if file.tooLarge {
                unavailableState("Patch unavailable", systemImage: "exclamationmark.triangle")
            } else if file.hunks.isEmpty {
                Text("No textual changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                // Only `.full` cards render a patch; degraded tiers show
                // `summaryBody` instead of this body at all.
                fullPatch
                    .padding(.top, 8)
            }

            HStack(spacing: 5) {
                Image(systemName: isInlineExpanded ? "option" : "arrow.up.right")
                Text(isInlineExpanded ? "Option-click to collapse" : "Open focused diff for comments")
                Spacer()
                if fileIsViewed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))

            Image(systemName: fileIcon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(file.path)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text("+\(file.additions)")
                .foregroundStyle(.green)
            Text("−\(file.deletions)")
                .foregroundStyle(.red)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(file.lineCount) diff lines")
                .foregroundStyle(.secondary)
            if threadCount > 0 {
                Label("\(threadCount)", systemImage: "bubble.left.fill")
                    .foregroundStyle(.purple)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 12)
    }

    private var fullPatch: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.08))

                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    ChangeCanvasLine(line: line)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 12)
    }

    private func unavailableState(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(title == "Patch unavailable" ? .orange : .secondary)
            .padding(14)
    }

    private var allLines: [DiffLine] {
        file.hunks.flatMap(\.lines)
    }

    private var threadCount: Int {
        store.review?.sidebarItems.first(where: { $0.path == file.path })?.threadCount ?? 0
    }

    private var fileIsViewed: Bool {
        store.review?.viewed.contains(file.path) == true
    }

    private var isSelected: Bool {
        store.selection.filePath == file.path
    }

    private var borderColor: Color {
        isSelected ? .accentColor.opacity(0.8) : Color.gray.opacity(0.22)
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .modified: return .secondary
        }
    }

    private var fileIcon: String {
        switch file.status {
        case .added: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.triangle.2.circlepath"
        case .modified: return "doc.text"
        }
    }
}

private struct ChangeCanvasLine: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number(line.oldLine))
                .frame(width: 34, alignment: .trailing)
            Text(number(line.newLine))
                .frame(width: 34, alignment: .trailing)
            Text(prefix)
                .fontWeight(.bold)
                .frame(width: 14)
            Text(line.content.isEmpty ? " " : line.content)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.88))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(backgroundColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 2)
        }
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .added: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        case .context: return .clear
        }
    }

    private var accentColor: Color {
        switch line.kind {
        case .added: return .green.opacity(0.8)
        case .removed: return .red.opacity(0.8)
        case .context: return .clear
        }
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

private struct ChangeDensityStrip: View {
    let lines: [DiffLine]
    let isUnavailable: Bool

    var body: some View {
        Canvas { context, size in
            if isUnavailable || lines.isEmpty {
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                    with: .color(Color.gray.opacity(0.16))
                )
                return
            }

            let count = min(lines.count, 240)
            let barWidth = size.width / CGFloat(max(count, 1))
            for index in 0..<count {
                let line = lines[index]
                let color: Color
                switch line.kind {
                case .added: color = .green
                case .removed: color = .red
                case .context: color = .gray.opacity(0.24)
                }
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: 0,
                    width: max(1, barWidth - 0.7),
                    height: size.height
                )
                context.fill(Path(rect), with: .color(color.opacity(line.kind == .context ? 0.45 : 0.8)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel(densityAccessibilityLabel)
    }

    private var densityAccessibilityLabel: String {
        guard !isUnavailable else { return "Patch unavailable" }
        let additions = lines.filter { $0.kind == .added }.count
        let deletions = lines.filter { $0.kind == .removed }.count
        return "Change density, \(additions) additions and \(deletions) deletions"
    }
}
