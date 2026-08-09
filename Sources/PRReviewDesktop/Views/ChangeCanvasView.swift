import SwiftUI
import PRReviewKit

/// A spatial overview of every file changed by the pull request.
///
/// This is intentionally not another long diff: each changed file gets an
/// addressable card on a zoomable canvas. The card shows the file's change
/// shape and a compact preview; selecting it opens the existing focused diff
/// view for the full line-by-line review.
public struct ChangeCanvasView: View {
    @ObservedObject public var store: ReviewSessionStore
    public let files: [DiffFile]
    @Binding public var showCanvas: Bool

    @State private var zoom: CGFloat = 0.9

    private let cardWidth: CGFloat = 300
    private let cardHeight: CGFloat = 242
    private let columnGap: CGFloat = 22
    private let rowGap: CGFloat = 22

    public init(
        store: ReviewSessionStore,
        files: [DiffFile],
        showCanvas: Binding<Bool>
    ) {
        self.store = store
        self.files = files
        self._showCanvas = showCanvas
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
                    let layout = CanvasLayout(
                        fileCount: files.count,
                        viewportWidth: geometry.size.width,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        columnGap: columnGap,
                        rowGap: rowGap
                    )
                    canvasScroll(layout: layout)
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
                Text("Click a file to open its full diff")
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
                zoom = max(0.6, zoom - 0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
                .accessibilityLabel("Canvas zoom \(Int(zoom * 100)) percent")

            Button {
                zoom = min(1.35, zoom + 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")

            Button("Reset") {
                zoom = 0.9
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Reset canvas zoom")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("change-canvas-toolbar")
    }

    private func canvasScroll(layout: CanvasLayout) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                }
                .allowsHitTesting(false)

                ForEach(Array(files.enumerated()), id: \.element.path) { index, file in
                    Button {
                        open(file)
                    } label: {
                        ChangeCanvasCard(store: store, file: file)
                    }
                    .buttonStyle(.plain)
                    .frame(width: cardWidth, height: cardHeight)
                    .offset(x: layout.x(for: index), y: layout.y(for: index))
                    .contextMenu {
                        Button("Open full diff") { open(file) }
                        Button(fileIsViewed(file) ? "Mark unviewed" : "Mark viewed") {
                            store.toggleViewed(filePath: file.path)
                        }
                    }
                    .accessibilityIdentifier("canvas-file-\(file.path)")
                    .accessibilityLabel(canvasAccessibilityLabel(for: file))
                }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(
                width: layout.width * zoom,
                height: layout.height * zoom,
                alignment: .topLeading
            )
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onMoveCommand { direction in
            // Keep arrow-key line navigation available after the reviewer
            // returns to the focused diff view from a card.
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
        return "\(file.path), \(file.additions) additions, \(file.deletions) deletions\(viewed)"
    }
}

private struct CanvasLayout {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat

    init(
        fileCount: Int,
        viewportWidth: CGFloat,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        columnGap: CGFloat,
        rowGap: CGFloat
    ) {
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.columnGap = columnGap
        self.rowGap = rowGap
        let available = max(viewportWidth - 36, cardWidth)
        self.columns = max(1, min(4, Int((available + columnGap) / (cardWidth + columnGap))))
        let rows = max(1, Int(ceil(Double(max(fileCount, 1)) / Double(columns))))
        self.width = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * columnGap
        self.height = CGFloat(rows) * cardHeight + CGFloat(rows - 1) * rowGap
    }

    func x(for index: Int) -> CGFloat {
        CGFloat(index % columns) * (cardWidth + columnGap)
    }

    func y(for index: Int) -> CGFloat {
        CGFloat(index / columns) * (cardHeight + rowGap)
    }
}

/// One file's visual summary on the canvas. The mini preview uses real changed
/// lines, while the density strip encodes every diff line without making the
/// canvas pay the cost of rendering thousands of full text rows.
private struct ChangeCanvasCard: View {
    @ObservedObject var store: ReviewSessionStore
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            metadata
            ChangeDensityStrip(lines: allLines, isBinary: file.isBinary || file.tooLarge)
                .frame(height: 10)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            preview
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right")
                Text("Open full diff")
                Spacer()
                if fileIsViewed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Text("\(file.hunks.count) \(file.hunks.count == 1 ? "hunk" : "hunks")")
                .foregroundStyle(.secondary)
            if threadCount > 0 {
                Label("\(threadCount)", systemImage: "bubble.left.fill")
                    .foregroundStyle(.purple)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var preview: some View {
        if file.isBinary {
            Label("Binary file", systemImage: "doc.zipper")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if file.tooLarge {
            Label("Patch unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if previewLines.isEmpty {
            Text("No textual changes")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 5) {
                        Text(line.kind == .added ? "+" : "−")
                            .fontWeight(.bold)
                            .foregroundStyle(line.kind == .added ? .green : .red)
                            .frame(width: 9)
                        Text(line.content)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (line.kind == .added ? Color.green : Color.red).opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                }
                if changedLineCount > previewLines.count {
                    Text("+\(changedLineCount - previewLines.count) more changed lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var allLines: [DiffLine] {
        file.hunks.flatMap(\.lines)
    }

    private var previewLines: [DiffLine] {
        allLines.filter { $0.kind != .context }.prefix(6).map { $0 }
    }

    private var changedLineCount: Int {
        file.additions + file.deletions
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

private struct ChangeDensityStrip: View {
    let lines: [DiffLine]
    let isBinary: Bool

    var body: some View {
        Canvas { context, size in
            if isBinary || lines.isEmpty {
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
        guard !isBinary else { return "Binary file" }
        let additions = lines.filter { $0.kind == .added }.count
        let deletions = lines.filter { $0.kind == .removed }.count
        return "Change density, \(additions) additions and \(deletions) deletions"
    }
}
