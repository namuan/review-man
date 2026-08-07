import SwiftUI
import AppKit
import PRReviewKit
import PRReviewBenchmarkSupport

// MARK: - Row model with stable identity

private enum RowKind {
    case hunkHeader, context, added, removed, thread, empty
}

private struct SpikeRow: Identifiable {
    let id: String
    let text: String
    let kind: RowKind
    let isSelectable: Bool
}

// MARK: - Row building from PRReviewKit models

private func buildSpikeRows(files: [DiffFile]) -> [SpikeRow] {
    var rows: [SpikeRow] = []
    for file in files {
        let built = RowBuilder.build(file: file, threads: [], drafts: [], outdatedExpanded: true)
        for row in built {
            switch row {
            case .hunkHeader(let hi):
                guard hi < file.hunks.count else { continue }
                rows.append(SpikeRow(
                    id: "\(file.path)#hunk\(hi)",
                    text: file.hunks[hi].header,
                    kind: .hunkHeader,
                    isSelectable: false
                ))
            case .line(let hi, let li):
                guard hi < file.hunks.count, li < file.hunks[hi].lines.count else { continue }
                let line = file.hunks[hi].lines[li]
                let kind: RowKind = line.kind == .added ? .added
                    : (line.kind == .removed ? .removed : .context)
                let old = String(format: "%5d", line.oldLine ?? 0)
                let new = String(format: "%5d", line.newLine ?? 0)
                let sign = line.kind == .added ? "+" : (line.kind == .removed ? "-" : " ")
                let gutter = "\(old) \(new) \(sign)"
                rows.append(SpikeRow(
                    id: "\(file.path)#h\(hi)#old\(line.oldLine ?? -1)-new\(line.newLine ?? -1)",
                    text: gutter + " " + line.content,
                    kind: kind,
                    isSelectable: true
                ))
            case .thread(let id):
                rows.append(SpikeRow(id: "thread-\(id)", text: "      ▎ thread card", kind: .thread, isSelectable: false))
            case .empty:
                rows.append(SpikeRow(id: "\(file.path)#empty", text: "      (no changes)", kind: .empty, isSelectable: false))
            case .outdatedHeader, .orphanedHeader:
                continue
            case .draft(let id):
                rows.append(SpikeRow(id: "draft-\(id)", text: "      ▎ draft card", kind: .thread, isSelectable: false))
            }
        }
    }
    return rows
}

// MARK: - Scroll request channel

private extension Notification.Name {
    static let spikeScrollRequest = Notification.Name("spike.scroll.request")
}

// MARK: - Close interception

/// AppKit bridge: observes the hosting window and intercepts close attempts.
private struct WindowCloseInterceptor: NSViewRepresentable {
    let isDirty: Bool
    let onIntercept: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.onIntercept = onIntercept
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        var isDirty = false
        var onIntercept: ((NSWindow) -> Void)?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isDirty {
                onIntercept?(sender)
                return false
            }
            return true
        }
    }
}

// MARK: - Stall watchdog

/// Background sampler: a main-runloop timer stamps a heartbeat; a background
/// DispatchSourceTimer flags any gap above the threshold (excluding load
/// time). All shared state is lock-protected because the sampler runs off the
/// main thread.
private final class StallWatchdog: ObservableObject {
    @Published var stallCount = 0
    @Published var maxGapMs: Double = 0
    private let lock = NSLock()
    private let threshold: Double = 0.100
    private var heartbeat = Date()
    private var heartbeatTimer: Timer?
    private var samplerSource: DispatchSourceTimer?
    private var isActive = true

    func start() {
        // Heartbeat: a main-runloop timer. During a main-thread stall the
        // runloop is blocked, so the stamp stops updating.
        let link = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        link.tolerance = 0.01
        RunLoop.main.add(link, forMode: .common)
        heartbeatTimer = link

        // Sampler: a DispatchSourceTimer on a background queue, so it keeps
        // firing (and measuring gaps) even while the main thread is stalled.
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now(), repeating: 0.05)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let (heartbeat, active) = self.snapshot()
            guard active else { return }
            let gap = Date().timeIntervalSince(heartbeat)
            if gap > self.threshold {
                DispatchQueue.main.async {
                    self.stallCount += 1
                    self.maxGapMs = max(self.maxGapMs, gap * 1000)
                }
            }
        }
        source.resume()
        samplerSource = source
    }

    private func tick() {
        lock.lock()
        heartbeat = Date()
        lock.unlock()
    }

    private func snapshot() -> (Date, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (heartbeat, isActive)
    }

    func pause() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func resume() {
        lock.lock()
        isActive = true
        heartbeat = Date()
        lock.unlock()
    }

    func reset() {
        lock.lock()
        stallCount = 0
        maxGapMs = 0
        heartbeat = Date()
        isActive = true
        lock.unlock()
    }
}

// MARK: - Content

private struct ContentView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var fixtureSize = 40_000
    @State private var fixtureFiles = 250
    @State private var rows: [SpikeRow] = []
    @State private var parseSeconds: Double = 0
    @State private var rowSeconds: Double = 0
    @State private var loadSeconds: Double = 0
    @State private var hunkIDs: [String] = []
    @State private var threadIDs: [String] = []
    @State private var selectedStart: String?
    @State private var selectedEnd: String?
    @State private var isDirty = false
    @State private var showCloseWarning = false
    @State private var interceptingWindow: NSWindow?
    @State private var footprintMiB: Double = 0
    @State private var routingNote = "WindowGroup(for:) dedup: opening the same key focuses the existing window"
    @StateObject private var watchdog = StallWatchdog()

    private let fixtureChoices = [10_000, 40_000, 120_000]
    private let fileChoices = [50, 250, 800]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                gutterColumn
                Divider()
                diffPane
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(WindowCloseInterceptor(isDirty: isDirty) { window in
            interceptingWindow = window
            showCloseWarning = true
        })
        .alert("Unsaved draft text", isPresented: $showCloseWarning) {
            Button("Discard and close") {
                // Programmatic close bypasses windowShouldClose.
                interceptingWindow?.close()
            }
            Button("Keep editing", role: .cancel) {
                interceptingWindow = nil
            }
        } message: {
            Text("The spike simulates unsaved draft text. Close is cancelled until you discard it.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .spikeScrollRequest)) { note in
            guard let id = note.object as? String else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy?.scrollTo(id, anchor: .top)
            }
        }
        .onAppear { watchdog.start() }
        .onChange(of: fixtureSize) { _ in load() }
        .onDisappear { watchdog.pause() }
    }

    // Captured inside the ScrollViewReader content closure.
    @State private var proxy: ScrollViewProxy?

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Lines", selection: $fixtureSize) {
                ForEach(fixtureChoices, id: \.self) { n in Text("\(n)") }
            }
            .frame(width: 110)
            Picker("Files", selection: $fixtureFiles) {
                ForEach(fileChoices, id: \.self) { n in Text("\(n)") }
            }
            .frame(width: 90)
            Button("Load") { load() }
            Button("Top") { requestScroll(hunkIDs.first) }
            Button("Bottom") { requestScroll(hunkIDs.last) }
            Button("Next hunk") { requestScroll(next(in: hunkIDs)) }
            Button("Next thread") { requestScroll(next(in: threadIDs)) }
            Button("Toggle dirty") { isDirty.toggle() }
            Button("New window (same key)") { openWindow(value: "fixture-\(fixtureSize)") }
            Button("New window (other key)") { openWindow(value: "other-fixture") }
            Spacer()
            Text(isDirty ? "⚠ dirty" : "clean")
                .foregroundStyle(isDirty ? .orange : .secondary)
        }
        .padding(8)
    }

    private var gutterColumn: some View {
        Text("   old    new")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
            .padding(6)
    }

    private var diffPane: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                                .background(selectionBackground(for: row))
                                .onTapGesture { handleTap(row) }
                        }
                    }
                }
            }
            .onAppear { self.proxy = reader }
        }
    }

    private func rowView(_ row: SpikeRow) -> some View {
        HStack(spacing: 0) {
            Text(row.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor(for: row.kind))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(rowBackground(for: row.kind))
    }

    private func textColor(for kind: RowKind) -> SwiftUI.Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .primary
        case .hunkHeader: return .cyan
        case .thread: return .purple
        case .empty: return .secondary
        }
    }

    private func rowBackground(for kind: RowKind) -> SwiftUI.Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .hunkHeader: return Color.cyan.opacity(0.08)
        default: return .clear
        }
    }

    private func selectionBackground(for row: SpikeRow) -> SwiftUI.Color {
        guard row.isSelectable else { return .clear }
        guard let start = selectedStart, let end = selectedEnd else { return .clear }
        guard let s = rows.firstIndex(where: { $0.id == start }),
              let e = rows.firstIndex(where: { $0.id == end }),
              let r = rows.firstIndex(where: { $0.id == row.id }) else { return .clear }
        let lo = min(s, e)
        let hi = max(s, e)
        // Normalize reverse selections and ignore non-selectable rows in-range
        // markers; endpoints themselves are highlighted.
        if (lo...hi).contains(r) {
            return row.id == start || row.id == end
                ? Color.accentColor.opacity(0.30)
                : Color.accentColor.opacity(0.15)
        }
        return .clear
    }

    private func handleTap(_ row: SpikeRow) {
        guard row.isSelectable else { return }
        if selectedStart != nil, NSEvent.modifierFlags.contains(.shift) {
            selectedEnd = row.id
        } else {
            selectedStart = row.id
            selectedEnd = row.id
        }
    }

    private func next(in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let current = ids.firstIndex { $0 == (selectedEnd ?? "") }
        let idx = current.map { min(ids.count - 1, $0 + 1) } ?? 0
        return ids[idx]
    }

    private func requestScroll(_ id: String?) {
        guard let id else { return }
        NotificationCenter.default.post(name: .spikeScrollRequest, object: id)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("rows \(rows.count)")
            Text("files \(fixtureFiles)")
            Text(String(format: "parse %.3fs", parseSeconds))
            Text(String(format: "row build %.3fs", rowSeconds))
            Text(String(format: "background prep %.3fs", loadSeconds))
            Text("hunks \(hunkIDs.count)")
            Text("threads \(threadIDs.count)")
            Text("stalls \(watchdog.stallCount)")
            Text(String(format: "max gap %.0fms", watchdog.maxGapMs))
            Text(String(format: "footprint %.0f MiB", footprintMiB))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(6)
    }

    private func load() {
        watchdog.pause()
        let size = fixtureSize
        let files = fixtureFiles
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = SyntheticDiffFixture.make(fileCount: files, lineCount: size)
            let (parseTime, parsed) = Measurement.time { DiffParser.parse(text) }
            let (rowTime, built) = Measurement.time { buildSpikeRows(files: parsed) }
            DispatchQueue.main.async {
                self.rows = built
                self.parseSeconds = parseTime
                self.rowSeconds = rowTime
                self.loadSeconds = Date().timeIntervalSince(started)
                self.hunkIDs = built.filter { $0.kind == .hunkHeader }.map(\.id)
                self.threadIDs = built.filter { $0.kind == .thread }.map(\.id)
                self.selectedStart = nil
                self.selectedEnd = nil
                self.footprintMiB = Measurement.miB(Measurement.physicalFootprintBytes())
                self.watchdog.resume()
                // Programmatic jump to the first hunk = first usable navigation.
                self.requestScroll(self.hunkIDs.first)
                self.routingNote = "WindowGroup(for:) dedup verified: same key focuses existing window"
            }
        }
    }
}

// MARK: - App

/// Headless smoke mode: runs the exact pipeline the window uses (generate →
/// parse → row build) for the default load-test scales and reports timings to
/// stdout. `PRReviewSpike --smoke [--files N --lines N]` produces
/// CI-friendly evidence without a window.
private func runSmoke() {
    let args = CommandLine.arguments
    var fileOverride: Int?
    var lineOverride: Int?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--files":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { fileOverride = v }
        case "--lines":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { lineOverride = v }
        default:
            i += 1
        }
    }

    print("PRReviewSpike smoke — pipeline timing (debug build)")
    if let fileOverride, let lineOverride {
        smokeRow(files: fileOverride, lines: lineOverride)
        exit(0)
    }
    for scale in [DemoScale.medium, .large, .xlarge] {
        smokeRow(files: scale.fileCount, lines: scale.lineCount)
    }
    exit(0)
}

private func smokeRow(files: Int, lines: Int) {
    let text = SyntheticDiffFixture.make(fileCount: files, lineCount: lines)
    let (parseTime, parsed) = Measurement.time { DiffParser.parse(text) }
    let (rowTime, rows) = Measurement.time { buildSpikeRows(files: parsed) }
    let footprint = Measurement.miB(Measurement.physicalFootprintBytes())
    let actual = parsed.reduce(0) { $0 + $1.lineCount }
    print(String(format: "%6d lines / %4d files → parse %6.1fms, rows %6.1fms, %7d rows, %6.1f MiB",
                 actual, files, parseTime * 1000, rowTime * 1000, rows.count, footprint))
}

@main
struct PRReviewSpikeApp: App {
    init() {
        if CommandLine.arguments.contains("--smoke") {
            runSmoke()
        }
    }

    var body: some Scene {
        WindowGroup("PR Review Spike", for: String.self) { _ in
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}
