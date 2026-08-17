import SwiftUI
import Foundation
import PRReviewKit

/// A spatial overview of every file changed by the pull request, drawn as a
/// map: each folder becomes an island, and the files inside it are grouped
/// together on that island. Cards grow with the number of hunks and lines
/// they contain, so the shape of the board reflects the shape of the PR.
/// Selecting a card opens the existing focused diff view for comments and
/// line-level review.
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
    @Environment(\.colorScheme) private var colorScheme

    @State private var pinchStartZoom: CGFloat?
    /// At most one condensed card expands inline at a time, preserving the
    /// large-PR canvas's light layout while allowing focused inspection.
    @State private var expandedCondensedPath: String?

    public static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, value))
    }

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
                icon: "map",
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
        let islands = CanvasIsland.makeIslands(from: files)
        return HStack(spacing: 10) {
            Image(systemName: "map")
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
            Text("\(islands.count) \(islands.count == 1 ? "island" : "islands") · \(files.count) files")
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
            return "Complete patches · files grouped into folder islands"
        case .condensed:
            return "Option-click a file name to expand · folder islands"
        case .summary:
            return "File names only for very large PRs · folder islands"
        }
    }

    private var cardWidth: CGFloat {
        scale == .summary ? IslandMetrics.cardWidthSummary : IslandMetrics.cardWidthFull
    }

    private func canvasScroll(viewportWidth: CGFloat) -> some View {
        let islands = CanvasIsland.makeIslands(from: files)
        let islandWidths = islands.map { islandWidth(for: $0) }
        let maxIslandWidth = islandWidths.max()
            ?? cardWidth + IslandMetrics.padding * 2
        let availableWidth = max(viewportWidth - 48, maxIslandWidth)
        let maxColumns = scale == .full ? 4 : 6
        let columnCount = max(
            1,
            min(maxColumns, Int((availableWidth + IslandMetrics.islandGap) / (maxIslandWidth + IslandMetrics.islandGap)))
        )
        let boardWidth = CGFloat(columnCount) * maxIslandWidth
            + CGFloat(columnCount - 1) * IslandMetrics.islandGap

        return ScrollView([.horizontal, .vertical], showsIndicators: true) {
            // scaleEffect changes pixels, not layout. CanvasZoomLayout measures
            // the unscaled board and reports the zoomed size synchronously in
            // the same layout pass, so the scroll document always matches the
            // rendered board. The previous preference-based measurement could
            // deliver a stale or viewport-sized height, which left the
            // document with no vertical range and killed trackpad scrolling.
            CanvasZoomLayout(zoom: zoom) {
                IslandFlowLayout(
                    spacing: IslandMetrics.islandGap,
                    shelfGap: IslandMetrics.shelfGap
                ) {
                    ForEach(islands) { island in
                        islandView(island)
                    }
                }
                .frame(width: boardWidth, alignment: .top)
                // Force the islands to report their intrinsic height instead
                // of accepting the vertical ScrollView proposal.
                .fixedSize(horizontal: false, vertical: true)
                .padding(CanvasLayoutMetrics.outerPadding)
                .background {
                    mapSea
                }
                .scaleEffect(zoom, anchor: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Open ocean behind the board: the gradient stays fixed while the
            // board (waves, compass, islands) scrolls and zooms above it.
            LinearGradient(
                colors: [MapPalette.seaTop(colorScheme), MapPalette.seaBottom(colorScheme)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

    /// One folder island: an organic landmass behind a header, a flowing
    /// wrap of file cards, and a totals footer.
    private func islandView(_ island: CanvasIsland) -> some View {
        let width = islandWidth(for: island)
        let seed = UInt64(truncatingIfNeeded: island.id.hashValue)
        return VStack(alignment: .leading, spacing: 10) {
            islandHeader(island)

            WrapFlowLayout(
                spacing: IslandMetrics.cardSpacing,
                rowSpacing: IslandMetrics.rowSpacing
            ) {
                ForEach(island.files, id: \.path) { file in
                    fileCard(file, width: cardWidth)
                }
            }
            .frame(width: width - IslandMetrics.padding * 2, alignment: .leading)

            islandFooter(island)
        }
        .padding(IslandMetrics.padding)
        .frame(width: width, alignment: .topLeading)
        .background {
            IslandBlobShape(seed: seed)
                .fill(LinearGradient(
                    colors: [MapPalette.landTop(colorScheme), MapPalette.landBottom(colorScheme)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    IslandBlobShape(seed: seed)
                        .stroke(MapPalette.shore(colorScheme), lineWidth: 1.2)
                }
                .shadow(
                    color: colorScheme == .dark
                        ? Color.black.opacity(0.4)
                        : Color(red: 0.25, green: 0.42, blue: 0.55).opacity(0.3),
                    radius: 9,
                    y: 3
                )
        }
        .rotationEffect(.degrees(islandRotation(island)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas-island-\(island.path.isEmpty ? "root" : island.path)")
        .accessibilityLabel("Folder island \(island.accessibilityName), \(island.files.count) files")
    }

    private func islandHeader(_ island: CanvasIsland) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: island.path.isEmpty ? "square.grid.2x2.fill" : "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(island.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(island.files.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Text(island.path.isEmpty ? "Top level" : island.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func islandFooter(_ island: CanvasIsland) -> some View {
        let badges = islandBadges(island)
        return HStack(spacing: 7) {
            Text("+\(island.additions)")
                .foregroundStyle(.green)
            Text("−\(island.deletions)")
                .foregroundStyle(.red)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(island.lineCount) diff lines")
            if badges.threads > 0 {
                Label("\(badges.threads)", systemImage: "bubble.left.fill")
                    .foregroundStyle(.purple)
            }
            if badges.viewed > 0 {
                Label("\(badges.viewed)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// Thread and viewed aggregates for an island, from the session store.
    private func islandBadges(_ island: CanvasIsland) -> (threads: Int, viewed: Int) {
        guard let items = store.review?.sidebarItems, !island.files.isEmpty else { return (0, 0) }
        let paths = Set(island.files.map(\.path))
        var threads = 0
        var viewed = 0
        for item in items where paths.contains(item.path) {
            threads += item.threadCount
            if item.isViewed { viewed += 1 }
        }
        return (threads, viewed)
    }

    /// Islands lay files out on one row for a couple of files, two per row
    /// beyond that, so landmasses get a natural range of widths.
    private func islandWidth(for island: CanvasIsland) -> CGFloat {
        let count = island.files.count
        let perRow = count >= 3 ? 2 : 1
        let cardsWide = min(count, perRow)
        let inner = CGFloat(cardsWide) * cardWidth
            + CGFloat(max(cardsWide - 1, 0)) * IslandMetrics.cardSpacing
        return inner + IslandMetrics.padding * 2
    }

    /// A gentle, deterministic tilt per island so the archipelago never
    /// reads as a rigid grid.
    private func islandRotation(_ island: CanvasIsland) -> Double {
        let seed = UInt64(truncatingIfNeeded: island.id.hashValue)
        let value = Double(seed % 71) / 71
        return (value - 0.5) * 2.4
    }

    private var mapSea: some View {
        Canvas { context, size in
            let wave = MapPalette.wave(colorScheme)
            var row: CGFloat = 22
            var index = 0
            while row < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: row))
                var x: CGFloat = 0
                while x <= size.width {
                    let y = row + CGFloat(sin(Double(x) / 76.0 + Double(index) * 1.4)) * 3.5
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 14
                }
                context.stroke(path, with: .color(wave), lineWidth: 1)
                row += 54 + CGFloat(index % 3) * 8
                index += 1
            }
            drawCompass(in: &context, center: CGPoint(x: size.width - 68, y: 72), size: 26, color: wave)
        }
        .allowsHitTesting(false)
    }

    private func drawCompass(in context: inout GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        context.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - size, y: center.y - size,
                width: size * 2, height: size * 2
            )),
            with: .color(color),
            lineWidth: 1.2
        )
        var spokes = Path()
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            let length = i.isMultiple(of: 2) ? size - 4 : size - 10
            spokes.move(to: center)
            spokes.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(angle)) * CGFloat(length),
                y: center.y + CGFloat(sin(angle)) * CGFloat(length)
            ))
        }
        context.stroke(spokes, with: .color(color), lineWidth: 1)
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

// MARK: - Island model

/// A group of changed files that share a folder, laid out as one landmass
/// on the change canvas. Files whose directory holds only a single PR file
/// are promoted up to a parent island so the map shows real islands instead
/// of one-file specks nested deep in the tree.
struct CanvasIsland: Identifiable, Equatable {
    /// Full folder path (empty for files at the repository root).
    let path: String
    let files: [DiffFile]

    var id: String { path }

    var fileCount: Int { files.count }

    /// Last path component, or a friendly title for the root island.
    var name: String {
        guard !path.isEmpty else { return "Root" }
        return String(path.split(separator: "/").last ?? "")
    }

    var accessibilityName: String {
        path.isEmpty ? "top level" : path
    }

    var additions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    var deletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    var lineCount: Int {
        files.reduce(0) { $0 + $1.lineCount }
    }

    /// Groups the PR's files into folder islands. Directories that contain a
    /// single changed file merge into their parent; the island contents and
    /// the island list are deterministic (files sorted by path, islands by
    /// size then path) regardless of input order and PR size.
    static func makeIslands(from files: [DiffFile]) -> [CanvasIsland] {
        var directCounts: [String: Int] = [:]
        for file in files {
            directCounts[directory(of: file.path), default: 0] += 1
        }

        func effectiveDirectory(_ dir: String) -> String {
            var current = dir
            while !current.isEmpty, (directCounts[current] ?? 0) <= 1 {
                current = directory(of: current)
            }
            return current
        }

        var grouped: [String: [DiffFile]] = [:]
        for file in files {
            grouped[effectiveDirectory(directory(of: file.path)), default: []].append(file)
        }

        return grouped
            .map { path, groupedFiles in
                CanvasIsland(
                    path: path,
                    files: groupedFiles.sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.fileCount != rhs.fileCount {
                    return lhs.fileCount > rhs.fileCount
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

// MARK: - Map layout

private enum IslandMetrics {
    static let padding: CGFloat = 16
    static let cardSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
    static let islandGap: CGFloat = 26
    static let shelfGap: CGFloat = 18
    static let cardWidthFull: CGFloat = 320
    static let cardWidthSummary: CGFloat = 190
}

private enum MapPalette {
    static func seaTop(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.10, green: 0.19, blue: 0.27)
            : Color(red: 0.83, green: 0.90, blue: 0.95)
    }

    static func seaBottom(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.06, green: 0.12, blue: 0.20)
            : Color(red: 0.72, green: 0.83, blue: 0.92)
    }

    static func wave(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.45, green: 0.68, blue: 0.87).opacity(0.22)
            : Color(red: 0.30, green: 0.52, blue: 0.70).opacity(0.26)
    }

    static func landTop(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.30, green: 0.34, blue: 0.33)
            : Color(red: 0.97, green: 0.92, blue: 0.76)
    }

    static func landBottom(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.24, green: 0.28, blue: 0.28)
            : Color(red: 0.91, green: 0.85, blue: 0.64)
    }

    static func shore(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.55, green: 0.66, blue: 0.62).opacity(0.40)
            : Color(red: 0.53, green: 0.49, blue: 0.33).opacity(0.50)
    }
}

/// An organic landmass: a smooth catmull-rom loop around the content rect
/// whose edge points wobble by a deterministic amount seeded from the
/// island's identity. Corners keep a gentler ripple than the straight runs
/// so the shape reads as hand-drawn coastline rather than noise.
private struct IslandBlobShape: Shape {
    var seed: UInt64
    var wobble: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var rng = SplitMix64(seed: seed &+ 0x1234_5678_9ABC_DEF0)
        let minSide = min(rect.width, rect.height)
        let amplitude = min(wobble, max(2, minSide * 0.035))
        let inset = rect.insetBy(dx: amplitude, dy: amplitude)
        guard inset.width > 2, inset.height > 2 else { return Path(rect) }

        let points = perimeterPoints(in: inset, amplitude: amplitude, rng: &rng)
        guard points.count >= 4 else { return Path(rect) }

        var path = Path()
        for index in 0..<points.count {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let after = points[(index + 2) % points.count]
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: current.y + (next.y - previous.y) / 6
            )
            let control2 = CGPoint(
                x: next.x - (after.x - current.x) / 6,
                y: next.y - (after.y - current.y) / 6
            )
            if index == 0 {
                path.move(to: current)
            }
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        path.closeSubpath()
        return path
    }

    /// 16 sample points around the perimeter (4 per side, corners included)
    /// with a deterministic perpendicular jitter; corners jitter less.
    private func perimeterPoints(in rect: CGRect, amplitude: CGFloat, rng: inout SplitMix64) -> [CGPoint] {
        var points: [CGPoint] = []
        let steps = 4
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)
            let corner = step == 0 || step == steps - 1
            let jitter = amplitude * (corner ? 0.35 : 1.0) * Self.noise(&rng)
            points.append(CGPoint(x: rect.minX + t * rect.width, y: rect.minY - jitter))      // top
        }
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)
            let corner = step == 0 || step == steps - 1
            let jitter = amplitude * (corner ? 0.35 : 1.0) * Self.noise(&rng)
            points.append(CGPoint(x: rect.maxX + jitter, y: rect.minY + t * rect.height))     // right
        }
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)
            let corner = step == 0 || step == steps - 1
            let jitter = amplitude * (corner ? 0.35 : 1.0) * Self.noise(&rng)
            points.append(CGPoint(x: rect.maxX - t * rect.width, y: rect.maxY + jitter))      // bottom
        }
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)
            let corner = step == 0 || step == steps - 1
            let jitter = amplitude * (corner ? 0.35 : 1.0) * Self.noise(&rng)
            points.append(CGPoint(x: rect.minX - jitter, y: rect.maxY - t * rect.height))     // left
        }
        return points
    }

    /// Uniform noise in [-1, 1] from the sequence RNG.
    private static func noise(_ rng: inout SplitMix64) -> CGFloat {
        let value = Double(rng.next() % 1_000_000) / 500_000 - 1
        return CGFloat(value)
    }
}

/// A tiny deterministic PRNG so island coastlines and shelf spacing are
/// stable across redraws.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Shelf-packs islands into the board: islands flow left to right and wrap
/// to the next shelf when they no longer fit, with a touch of deterministic
/// jitter so the archipelago never lines up in a strict grid.
private struct IslandFlowLayout: Layout {
    var spacing: CGFloat = 26
    var shelfGap: CGFloat = 18

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = max(proposal.width ?? 700, 1)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let packed = Self.pack(sizes: sizes, width: width, spacing: spacing, shelfGap: shelfGap)
        return CGSize(width: width, height: packed.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = max(proposal.width ?? bounds.width, 1)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let packed = Self.pack(sizes: sizes, width: width, spacing: spacing, shelfGap: shelfGap)
        for (index, frame) in packed.frames.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private static func pack(
        sizes: [CGSize],
        width: CGFloat,
        spacing: CGFloat,
        shelfGap: CGFloat
    ) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var shelfHeight: CGFloat = 0
        var rng = SplitMix64(seed: 0x5EED_C0FF_EE)

        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += shelfHeight + shelfGap
                shelfHeight = 0
            }
            let jx = CGFloat((Double(rng.next() % 1_000_000) / 1_000_000 - 0.5) * 4)
            let jy = CGFloat((Double(rng.next() % 1_000_000) / 1_000_000 - 0.5) * 4)
            frames.append(CGRect(x: x + jx, y: y + jy, width: size.width, height: size.height))
            x += size.width + spacing
            shelfHeight = max(shelfHeight, size.height)
        }
        return (frames, y + shelfHeight + 12)
    }
}

/// Lays file cards inside an island: left to right, wrapping to a new row
/// when the next card would overflow the island's inner width. Row height
/// is the tallest card on that row so full-patch cards never overlap.
private struct WrapFlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 10

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalWidth = width.isFinite ? width : x
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = max(proposal.width ?? bounds.width, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Scroll document sizing

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

// MARK: - Cards

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