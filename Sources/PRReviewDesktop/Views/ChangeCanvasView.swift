import SwiftUI
import PRReviewKit

/// A spatial overview of every file changed by the pull request.
///
/// This is a canvas of complete file patches, not a second truncated diff.
/// Cards grow with the number of hunks and lines they contain, so the shape
/// of the board reflects the shape of the PR. Selecting a card opens the
/// existing focused diff view for comments and line-level review.
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
    @State private var canvasContentSize = CGSize.zero

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
                            viewportWidth: geometry.size.width,
                            viewportHeight: geometry.size.height
                        )
                    }
                    // Attach magnification to a parent of the ScrollView. This
                    // lets pinch gestures pass through cards while native
                    // two-axis scrolling stays untouched.
                    .simultaneousGesture(magnificationGesture)
                }
            }
            .accessibilityIdentifier("change-canvas-pane")
        }
    }

    private var canvasToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Change canvas")
                    .font(.headline)
                Text("Complete patches · Pinch or ⌘+/⌘− to zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private func canvasScroll(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
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
            ZStack(alignment: .topLeading) {
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
                .padding(24)
                .background {
                    Canvas { context, size in
                        drawGrid(in: &context, size: size)
                    }
                    .allowsHitTesting(false)
                }
                // scaleEffect changes pixels, not layout. Measure the unscaled
                // board and give the scroll view a matching scaled content frame;
                // otherwise the cards look larger but the scroll view still thinks
                // the board has its original size.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CanvasContentSizeKey.self,
                            value: proxy.size
                        )
                    }
                }
                .scaleEffect(zoom, anchor: .topLeading)
            }
            // Align the transformed board to the top-left explicitly. Without
            // a wrapper, SwiftUI can center a transformed child in the scroll
            // content area and leave a large blank band above the first card.
            .frame(
                width: max(canvasContentSize.width, boardWidth + 48) * zoom,
                height: max(
                    canvasContentSize.height,
                    viewportHeight / max(zoom, 0.01)
                ) * zoom,
                alignment: .topLeading
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(CanvasContentSizeKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            canvasContentSize = size
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

    private func fileCard(_ file: DiffFile, width: CGFloat) -> some View {
        Button {
            open(file)
        } label: {
            ChangeCanvasCard(store: store, file: file)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .topLeading)
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

    private func open(_ file: DiffFile) {
        store.select(filePath: file.path)
        showCanvas = false
    }

    private func fileIsViewed(_ file: DiffFile) -> Bool {
        store.review?.viewed.contains(file.path) == true
    }

    private func canvasAccessibilityLabel(for file: DiffFile) -> String {
        let viewed = fileIsViewed(file) ? ", viewed" : ""
        return "\(file.path), complete patch, \(file.additions) additions, \(file.deletions) deletions\(viewed)"
    }
}

private struct CanvasContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// A variable-height file card containing every hunk and every diff line.
/// Long lines wrap rather than disappearing behind a preview truncation.
private struct ChangeCanvasCard: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile

    var body: some View {
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
                fullPatch
                    .padding(.top, 8)
            }

            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right")
                Text("Open focused diff for comments")
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
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
