import SwiftUI
import Foundation
import PRReviewKit

/// A spatial overview of every file changed by the pull request, drawn as a
/// left-to-right folder tree: the repository root sits at the far left and
/// directories branch right, one column per depth level, with each changed
/// file as a compact leaf chip. Elbow connectors trace the folder structure;
/// selecting a chip opens the existing focused diff view for comments and
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
    public static let minimumZoom: CGFloat = 0.4
    public static let maximumZoom: CGFloat = 1.35
    public static let zoomStep: CGFloat = 0.1

    @ObservedObject public var store: ReviewSessionStore
    public let files: [DiffFile]
    @Binding public var showCanvas: Bool
    @Binding public var zoom: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    @State private var pinchStartZoom: CGFloat?
    /// Viewport area available below the toolbar, used to fit the tree.
    @State private var viewportSize: CGSize?
    /// The last measured (unscaled) board size, used by the Fit button.
    @State private var boardSize: CGSize?
    /// True once the initial board measurement has had its chance to fit-zoom;
    /// reset when a new PR loads so its map gets the same treatment.
    @State private var didAutoFit = false

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
                // Attach magnification to a parent of the ScrollView. This
                // lets pinch gestures pass through chips while native
                // two-axis scrolling stays untouched. The GeometryReader
                // reports the viewport so the tree can auto-fit on load.
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        canvasScroll
                    }
                    .onAppear {
                        viewportSize = geometry.size
                        // The board preference can arrive before onAppear when
                        // the first layout beats the appear callback; retry
                        // the fit once the viewport is known.
                        if let board = boardSize {
                            fitInitialZoom(board: board)
                        }
                    }
                    .onChange(of: geometry.size) { newSize in
                        viewportSize = newSize
                    }
                    .onPreferenceChange(CanvasBoardSizeKey.self) { board in
                        boardSize = board
                        fitInitialZoom(board: board)
                    }
                    .simultaneousGesture(magnificationGesture)
                }
            }
            .accessibilityIdentifier("change-canvas-pane")
            .onChange(of: store.review?.pr?.headRefOid) { _ in
                // A reload/new PR gets a fresh fit-zoom pass.
                didAutoFit = false
            }
        }
    }

    private var canvasToolbar: some View {
        let tree = CanvasTree.build(from: files)
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
                        ? "Large PR — compact file chips. Click a chip to open the focused diff."
                        : "Very large PR — file chips only. Click a chip to open the focused diff.")
            }
            Text("\(tree.folderCount) folders · \(tree.fileCount) files")
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

            Button("Fit") {
                fitToBoard()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Zoom to fit the whole tree")
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
            return "Folder tree, left to right · Pinch or ⌘+/⌘− to zoom"
        case .condensed:
            return "Compact chips for large PRs · Folder tree, left to right"
        case .summary:
            return "File names only for very large PRs · Folder tree, left to right"
        }
    }

    private var canvasScroll: some View {
        let tree = CanvasTree.build(from: files)
        let plan = treePlan(for: tree)

        return ScrollView([.horizontal, .vertical], showsIndicators: true) {
            // scaleEffect changes pixels, not layout. CanvasZoomLayout measures
            // the unscaled board and reports the zoomed size synchronously in
            // the same layout pass, so the scroll document always matches the
            // rendered board. The previous preference-based measurement could
            // deliver a stale or viewport-sized height, which left the
            // document with no vertical range and killed trackpad scrolling.
            CanvasZoomLayout(zoom: zoom) {
                ZStack(alignment: .topLeading) {
                    // Connector lines under the chips: elbow from each folder
                    // to its children, derived from the same pure plan.
                    treeConnectors(plan: plan)

                    ForEach(Array(tree.nodes.enumerated()), id: \.element.id) { index, node in
                        treeNodeView(node: node, descendantFileCount: tree.subtreeFileCounts[index])
                            .position(x: plan.frames[index].midX, y: plan.frames[index].midY)
                    }
                }
                .frame(width: plan.boardSize.width, height: plan.boardSize.height)
                .fixedSize()
                .background {
                    mapSea
                }
                .background {
                    // Reports the unscaled board size (preference value) so
                    // the Fit button and the initial fit-zoom can frame the
                    // whole tree in the viewport.
                    GeometryReader { proxy in
                        Color.clear.preference(key: CanvasBoardSizeKey.self, value: proxy.size)
                    }
                }
                .scaleEffect(zoom, anchor: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Open ocean behind the board: the gradient stays fixed while the
            // board (waves, compass, chips) scrolls and zooms above it.
            LinearGradient(
                colors: [MapPalette.seaTop(colorScheme), MapPalette.seaBottom(colorScheme)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .onMoveCommand { direction in
            // The canvas itself navigates files with the arrow keys. Once a
            // chip is opened, the focused diff restores line-level movement.
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

    /// Node sizes are fixed by kind (folder chip vs file chip), so the plan
    /// is a pure function of the tree structure — no measurement needed.
    private func treePlan(for tree: CanvasTree) -> TreePlan {
        let sizes = tree.nodes.map { node in
            node.isFolder
                ? CGSize(width: TreeMetrics.folderWidth, height: TreeMetrics.folderHeight)
                : CGSize(width: TreeMetrics.fileWidth, height: TreeMetrics.fileHeight)
        }
        return TreePlan.compute(
            sizes: sizes,
            depths: tree.depths,
            parents: tree.parents,
            columnGap: TreeMetrics.columnGap,
            rowGap: TreeMetrics.rowGap,
            padding: TreeMetrics.padding
        )
    }

    @ViewBuilder
    private func treeNodeView(node: CanvasTree.Node, descendantFileCount: Int) -> some View {
        if node.isFolder {
            TreeFolderChip(node: node, descendantFileCount: descendantFileCount)
        } else if let file = node.file {
            Button {
                open(file)
            } label: {
                TreeFileChip(store: store, file: file)
            }
            .buttonStyle(.plain)
            .help("Open focused diff")
            .contextMenu {
                Button("Open focused diff") { open(file) }
                Button(fileIsViewed(file) ? "Mark unviewed" : "Mark viewed") {
                    store.toggleViewed(filePath: file.path)
                }
            }
            .accessibilityIdentifier("canvas-file-\(file.path)")
            .accessibilityLabel(canvasAccessibilityLabel(for: file))
        }
    }

    /// Elbow connectors between parent folders and their children, drawn in
    /// the same coordinate space the plan places nodes in.
    private func treeConnectors(plan: TreePlan) -> some View {
        Canvas { context, size in
            let lineColor = Color.secondary.opacity(0.4)
            for link in plan.links {
                let parent = plan.frames[link.parent]
                let child = plan.frames[link.child]
                let startX = parent.maxX
                let endX = child.minX
                let midX = startX + (endX - startX) / 2
                var path = Path()
                path.move(to: CGPoint(x: startX, y: parent.midY))
                path.addLine(to: CGPoint(x: midX, y: parent.midY))
                path.addLine(to: CGPoint(x: midX, y: child.midY))
                path.addLine(to: CGPoint(x: endX, y: child.midY))
                context.stroke(path, with: .color(lineColor), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// Zoom that frames `board` inside `viewport` with a small ocean margin.
    private func fittedZoom(board: CGSize, viewport: CGSize) -> CGFloat {
        let scaleX = (viewport.width - 32) / board.width
        let scaleY = (viewport.height - 32) / board.height
        return min(scaleX, scaleY) * 0.94
    }

    /// "Fit" button: zooms the tree down (or up) so its bounding box sits
    /// fully inside the viewport with a small ocean margin.
    private func fitToBoard() {
        guard let board = boardSize, let viewport = viewportSize,
              board.width > 0, board.height > 0 else {
            AppLog.info("canvas", "CANVAS_FIT skipped board=\(String(describing: boardSize)) viewport=\(String(describing: viewportSize))")
            return
        }
        zoom = Self.clampedZoom(fittedZoom(board: board, viewport: viewport))
        AppLog.info("canvas", "CANVAS_FIT board=\(board) viewport=\(viewport) zoom=\(zoom)")
    }

    /// Zooms the newly laid-out board down (once) so the whole tree is
    /// visible without scrolling. Manual zooming afterwards is never
    /// overridden.
    private func fitInitialZoom(board: CGSize) {
        guard !didAutoFit, let viewport = viewportSize, board.width > 0, board.height > 0 else { return }
        didAutoFit = true
        let fit = fittedZoom(board: board, viewport: viewport)
        guard fit < zoom else { return }
        zoom = Self.clampedZoom(fit)
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
        return "\(file.path), \(file.additions) additions, \(file.deletions) deletions\(viewed)"
    }
}

// MARK: - Folder tree

/// A left-to-right directory tree of the PR's changed files: folders branch
/// right, files are leaves. Mirrors the real folder structure (no singleton
/// promotion), flattened in pre-order with parent/depth bookkeeping so the
/// layout and the connector drawing stay in lockstep.
struct CanvasTree: Equatable {
    struct Node: Identifiable, Equatable {
        let id: String
        let name: String
        let path: String
        let isFolder: Bool
        let file: DiffFile?

        init(folderPath: String, name: String) {
            self.id = "folder:\(folderPath)"
            self.name = name
            self.path = folderPath
            self.isFolder = true
            self.file = nil
        }

        init(file: DiffFile) {
            self.id = "file:\(file.path)"
            self.name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            self.path = file.path
            self.isFolder = false
            self.file = file
        }
    }

    /// Pre-order flattening; `parents[i]` is the parent node index of node
    /// `i`, or nil for the implicit root folder.
    let nodes: [Node]
    let parents: [Int?]
    let depths: [Int]
    /// Number of changed files in each node's subtree (the root counts all).
    let subtreeFileCounts: [Int]

    var folderCount: Int { nodes.filter(\.isFolder).count }
    var fileCount: Int { nodes.filter { !$0.isFolder }.count }

    static func build(from files: [DiffFile]) -> CanvasTree {
        var nodes: [Node] = []
        var parents: [Int?] = []
        var depths: [Int] = []

        func visit(prefix: [String], parentIndex: Int?, depth: Int, items: [DiffFile]) {
            let folderPath = prefix.joined(separator: "/")
            let nodeIndex = nodes.count
            nodes.append(Node(
                folderPath: folderPath,
                name: prefix.isEmpty ? "Root" : prefix.last ?? folderPath
            ))
            parents.append(parentIndex)
            depths.append(depth)

            var subdirectoryItems: [String: [DiffFile]] = [:]
            var directFiles: [DiffFile] = []
            for item in items {
                let parts = item.path.split(separator: "/")
                if parts.count == prefix.count + 1 {
                    directFiles.append(item)
                } else if parts.count > prefix.count + 1 {
                    subdirectoryItems[String(parts[prefix.count]), default: []].append(item)
                }
            }
            // Subfolders first (their subtrees hang above this folder's own
            // files), then the folder's direct files, all sorted by name.
            for name in subdirectoryItems.keys.sorted() {
                visit(
                    prefix: prefix + [name],
                    parentIndex: nodeIndex,
                    depth: depth + 1,
                    items: subdirectoryItems[name] ?? []
                )
            }
            for file in directFiles.sorted(by: {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }) {
                nodes.append(Node(file: file))
                parents.append(nodeIndex)
                depths.append(depth + 1)
            }
        }

        visit(prefix: [], parentIndex: nil, depth: 0, items: files)

        var children: [[Int]] = Array(repeating: [], count: nodes.count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }
        var subtreeCounts = nodes.map { $0.isFolder ? 0 : 1 }
        for index in stride(from: nodes.count - 1, through: 0, by: -1) {
            subtreeCounts[index] += children[index].reduce(0) { $0 + subtreeCounts[$1] }
        }
        return CanvasTree(
            nodes: nodes,
            parents: parents,
            depths: depths,
            subtreeFileCounts: subtreeCounts
        )
    }
}

// MARK: - Tree geometry

/// Pure geometry for the left-to-right tree: every depth gets one column
/// (root leftmost), nodes stack vertically by subtree span, and a parent is
/// vertically centered over its children. All frames are returned in board
/// coordinates (inset by `padding`), so the layout, the connector drawing,
/// and the fit-zoom all agree without any measurement round-trips.
struct TreePlan {
    struct Link: Equatable {
        var parent: Int
        var child: Int
    }

    var frames: [CGRect]
    var links: [Link]
    var boardSize: CGSize

    static func compute(
        sizes: [CGSize],
        depths: [Int],
        parents: [Int?],
        columnGap: CGFloat,
        rowGap: CGFloat,
        padding: CGFloat
    ) -> TreePlan {
        let count = sizes.count
        guard count > 0 else {
            return TreePlan(frames: [], links: [], boardSize: .zero)
        }

        // One column per depth; column width is the widest node at that depth.
        var maxWidthByDepth: [Int: CGFloat] = [:]
        for (index, depth) in depths.enumerated() {
            maxWidthByDepth[depth] = max(maxWidthByDepth[depth] ?? 0, sizes[index].width)
        }
        let maxDepth = depths.max() ?? 0
        var columnX: [CGFloat] = []
        var cursor: CGFloat = 0
        for depth in 0...maxDepth {
            columnX.append(cursor)
            if depth < maxDepth {
                cursor += (maxWidthByDepth[depth] ?? 0) + columnGap
            }
        }

        var children: [[Int]] = Array(repeating: [], count: count)
        for (index, parent) in parents.enumerated() {
            if let parent {
                children[parent].append(index)
            }
        }

        // Subtree height bottom-up (children appear after their parent in the
        // pre-order flattening, so reverse iteration visits them first).
        var subtreeHeight = sizes.map(\.height)
        for index in stride(from: count - 1, through: 0, by: -1) {
            guard !children[index].isEmpty else { continue }
            let span = children[index].reduce(CGFloat(0)) { $0 + subtreeHeight[$1] }
                + CGFloat(max(children[index].count - 1, 0)) * rowGap
            subtreeHeight[index] = max(sizes[index].height, span)
        }

        // Top-down placement: leaves start at the cursor; a parent is centered
        // over the span of its children.
        var nodeY: [CGFloat] = Array(repeating: 0, count: count)
        func assignY(_ index: Int, minY: CGFloat) -> CGFloat {
            let own = sizes[index].height
            if children[index].isEmpty {
                nodeY[index] = minY
                return minY + own
            }
            var cursor = minY
            for child in children[index] {
                cursor = assignY(child, minY: cursor)
            }
            let span = cursor - minY
            nodeY[index] = minY + span / 2 - own / 2
            return max(cursor, nodeY[index] + own)
        }
        if count > 0 {
            _ = assignY(0, minY: 0)
        }

        // Layout-space frames, then the tight bounding box shifted into the
        // board by `padding`.
        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = minX
        var maxX = -minX
        var maxY = -minX
        for index in 0..<count {
            let frame = CGRect(
                x: columnX[depths[index]],
                y: nodeY[index],
                width: sizes[index].width,
                height: sizes[index].height
            )
            frames.append(frame)
            minX = min(minX, frame.minX)
            minY = min(minY, frame.minY)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        let shiftX = padding - minX
        let shiftY = padding - minY
        frames = frames.map { $0.offsetBy(dx: shiftX, dy: shiftY) }

        var links: [Link] = []
        for (index, parent) in parents.enumerated() {
            if let parent {
                links.append(Link(parent: parent, child: index))
            }
        }

        return TreePlan(
            frames: frames,
            links: links,
            boardSize: CGSize(
                width: maxX - minX + padding * 2,
                height: maxY - minY + padding * 2
            )
        )
    }
}

private enum TreeMetrics {
    static let folderWidth: CGFloat = 190
    static let folderHeight: CGFloat = 54
    static let fileWidth: CGFloat = 250
    static let fileHeight: CGFloat = 50
    static let columnGap: CGFloat = 48
    static let rowGap: CGFloat = 24
    static let padding: CGFloat = 40
}

// MARK: - Chips

/// A folder node: icon, name, and the number of changed files in its subtree.
private struct TreeFolderChip: View {
    let node: CanvasTree.Node
    let descendantFileCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(node.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(descendantFileCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(width: TreeMetrics.folderWidth, height: TreeMetrics.folderHeight)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name), folder, \(descendantFileCount) \(descendantFileCount == 1 ? "file" : "files")")
    }
}

/// A file leaf: status letter, short name, ± counts, viewed mark. Compact at
/// every scale — the tree is a structure overview; patches stay in the
/// focused diff.
private struct TreeFileChip: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))

            Text(fileName)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text("+\(file.additions) −\(file.deletions)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if fileIsViewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: TreeMetrics.fileWidth, height: TreeMetrics.fileHeight)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    private var fileName: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
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
}

// MARK: - Board support

/// Reports the unscaled size of the board up to `ChangeCanvasView` so the
/// Fit button and the initial fit-zoom can frame the whole tree in the
/// viewport.
private struct CanvasBoardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
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
}

/// Sizes the scroll document to the zoomed board. `scaleEffect` only changes
/// rendering, not layout, so without this wrapper the scroll view would think
/// the board is its unscaled size. Measuring here, synchronously in the same
/// layout pass, avoids the asynchronous preference that previously left the
/// document at (or below) the viewport height and killed trackpad scrolling.
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