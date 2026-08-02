import Foundation

/// Shared layout metrics so the controller can map mouse coordinates and
/// compute row heights identically to the renderer.
public enum AppLayout {

    public struct Metrics {
        public let fileW: Int
        public let contentTop: Int
        public let contentBottom: Int
        public let diffX: Int
        public let diffW: Int
        public let diffH: Int
        public let fileH: Int
    }

    public static func metrics(screenW: Int, screenH: Int) -> Metrics {
        let fileW = min(40, max(26, screenW / 4))
        let contentTop = 2
        let contentBottom = max(contentTop + 1, screenH - 2) // exclusive
        let diffX = fileW + 1
        let diffW = max(10, screenW - diffX)
        let diffH = contentBottom - contentTop
        return Metrics(
            fileW: fileW,
            contentTop: contentTop,
            contentBottom: contentBottom,
            diffX: diffX,
            diffW: diffW,
            diffH: diffH,
            fileH: contentBottom - contentTop
        )
    }

    /// Height in screen lines of a single diff row at the given content width.
    public static func rowHeight(_ row: Row, model: AppModel, width: Int) -> Int {
        switch row {
        case .hunkHeader, .line, .outdatedHeader, .empty:
            return 1
        case .thread(let id):
            guard let t = model.thread(byID: id) else { return 1 }
            if model.expandedThreads.contains(id) {
                var h = 1
                for c in t.comments {
                    h += 1 // author/time sub-header
                    let body = c.body.isEmpty ? 1 : wrapText(c.body, width: max(10, width - 4)).count
                    h += body
                }
                return h + 1
            }
            return 2 // collapsed
        case .draft(let id):
            guard let d = model.draft(byID: id) else { return 1 }
            let body = d.body.isEmpty ? 1 : wrapText(d.body, width: max(10, width - 4)).count
            return 1 + body + 1
        }
    }

    /// Total screen-line height of a file's rows at the given width.
    public static func totalHeight(model: AppModel, fileIndex: Int, width: Int) -> Int {
        let rows = model.rows.isEmpty ? [] : model.rows[fileIndex]
        return rows.reduce(0) { $0 + rowHeight($1, model: model, width: width) }
    }

    /// Screen line (relative to the pane content, starting at 0) where a row
    /// begins, in the given file.
    public static func lineOfRow(model: AppModel, fileIndex: Int, rowIndex: Int, width: Int) -> Int {
        let rows = model.rows.isEmpty ? [] : model.rows[fileIndex]
        var y = 0
        for i in 0..<min(rowIndex, rows.count) {
            y += rowHeight(rows[i], model: model, width: width)
        }
        return y
    }

    /// The row index under a screen line (relative to pane content), if any.
    public static func rowAtLine(model: AppModel, fileIndex: Int, line: Int, width: Int) -> Int? {
        let rows = model.rows.isEmpty ? [] : model.rows[fileIndex]
        var y = 0
        for (i, row) in rows.enumerated() {
            let h = rowHeight(row, model: model, width: width)
            if line >= y && line < y + h { return i }
            y += h
        }
        return nil
    }
}

/// Pure function: renders the whole app frame into a screen buffer.
public enum AppView {

    public static func render(model: AppModel, into s: Screen) {
        let w = s.width
        let h = s.height
        s.clear()
        let m = AppLayout.metrics(screenW: w, screenH: h)

        renderTopBars(model, s, w)
        renderFilePane(model, s, m)
        renderDiffPane(model, s, m)

        // message + status
        renderMessage(model, s, h - 2, w)
        renderStatus(model, s, h - 1, w)

        // overlays
        switch model.mode {
        case .normal, .search, .visual:
            break
        case .help:
            renderHelp(model, s, w, h)
        case .edit:
            renderEditor(model, s, w, h)
        case .compose:
            renderComposer(model, s, w, h)
        case .prBody:
            renderPRBody(model, s, w, h)
        case .confirmQuit:
            renderConfirm(s, w, h, message: model.drafts.isEmpty
                ? "Quit?"
                : "Discard \(model.drafts.count) unsent draft comment\(model.drafts.count == 1 ? "" : "s") and quit?")
        case .confirmDeleteDraft:
            renderConfirm(s, w, h, message: "Delete this draft comment?")
        }
        model.dirty = false
    }

    // MARK: - Top bars

    private static func renderTopBars(_ model: AppModel, _ s: Screen, _ w: Int) {
        var runs: [(String, Style)] = []
        runs.append((" PR #\(model.pr?.number ?? 0)", Theme.titleBarAccent))
        runs.append(("  \(model.pr?.title ?? "loading…")", Theme.titleBar))
        s.runs(0, 0, runs, maxWidth: w)

        let right = model.pr.map { " \($0.author) · \($0.headRefName) → \($0.baseRefName) " } ?? ""
        s.text(w - displayWidth(of: right), 0, right, Theme.titleBarDim, maxWidth: w)

        let state = model.stateLabel
        let stateStyle: Style
        switch state {
        case "OPEN": stateStyle = Theme.ok
        case "MERGED": stateStyle = Theme.magenta
        case "CLOSED": stateStyle = Theme.error
        case "DRAFT": stateStyle = Theme.warn
        default: stateStyle = Theme.titleBar
        }
        if !state.isEmpty {
            let label = " \(state) "
            s.text(w - displayWidth(of: right) - displayWidth(of: label), 0, label, stateStyle)
        }

        // stats bar
        var stats: [(String, Style)] = []
        if let pr = model.pr {
            stats.append((" +\(pr.additions)", Theme.ok))
            stats.append((" −\(pr.deletions)", Theme.error))
            stats.append(("  \(pr.changedFiles) files ", Theme.statsBar))
        } else {
            stats.append((" loading… ", Theme.statsBar))
        }
        stats.append(("· \(model.threads.count) threads ", Theme.statsBar))
        if !model.drafts.isEmpty {
            stats.append(("· \(model.drafts.count) drafts ", Theme.warn))
        }
        if let decision = model.reviewDecisionLabel {
            stats.append(("· \(decision) ", Theme.statsKey))
        }
        if model.loading {
            stats.append(("⟳ refreshing… ", Theme.accentBold))
        }
        s.fill(0, 1, w, 1, Theme.statsBar)
        s.runs(0, 1, stats, maxWidth: w)
    }

    // MARK: - File pane

    private static func renderFilePane(_ model: AppModel, _ s: Screen, _ m: AppLayout.Metrics) {
        let w = m.fileW
        s.fill(0, m.contentTop, w, m.fileH, Style(fg: .palette(252)))
        // header
        s.fill(0, m.contentTop, w, 1, Theme.paneHeader)
        var header: [(String, Style)] = [(" Files (\(model.files.count))", Theme.paneHeaderAccent)]
        if model.mode == .search {
            header.append((" · filter:", Theme.paneHeader))
            s.text(displayWidth(of: header[0].0) + displayWidth(of: header[1].0), m.contentTop,
                   model.filter + (model.filter.isEmpty ? " " : ""), Theme.filterActive,
                   maxWidth: w - displayWidth(of: header[0].0) - displayWidth(of: header[1].0))
        }
        s.runs(0, m.contentTop, header, maxWidth: w)

        let indices = model.filteredFileIndices()
        let listTop = m.contentTop + 1
        let visible = m.fileH - 1
        // clamp fileScroll to selection visibility
        var scroll = model.fileScroll
        if let selPos = indices.firstIndex(of: model.currentFileIndex) {
            if selPos < scroll { scroll = selPos }
            if selPos >= scroll + visible { scroll = selPos - visible + 1 }
        }
        for row in 0..<visible {
            let idx = scroll + row
            guard idx < indices.count else { break }
            let fi = indices[idx]
            let file = model.files[fi]
            let isSelected = fi == model.currentFileIndex
            let y = listTop + row
            s.fill(0, y, w, 1, isSelected ? Theme.selected : Style(fg: .palette(252)))
            var letterStyle: Style = Theme.statusLetterMod
            switch file.status {
            case .added: letterStyle = Theme.statusLetterAdd
            case .deleted: letterStyle = Theme.statusLetterDel
            case .renamed: letterStyle = Theme.statusLetterRename
            case .modified: letterStyle = Theme.statusLetterMod
            }
            s.text(0, y, " \(file.status.letter)", isSelected ? letterStyle.merging(Style(fg: .palette(16))) : letterStyle)

            // right side: marks + counts
            var right = ""
            if file.tooLarge { right += " !" }
            if file.isBinary { right += " B" }
            if model.threadCount(forPath: file.path) > 0 { right += " ●" }
            if model.viewed.contains(file.path) { right += " ✓" }
            right += " +\(file.additions) −\(file.deletions)"
            let pathWidth = max(1, w - displayWidth(of: right) - 2)
            let pathText = tailPath(file.path, width: pathWidth)
            s.text(1, y, pathText, isSelected ? Style(fg: .palette(16)) : Theme.text, maxWidth: pathWidth)
            s.text(w - displayWidth(of: right), y, right, isSelected ? Style(fg: .palette(16), dim: true) : Theme.dim)
        }
        if indices.isEmpty {
            s.text(1, listTop, "no matches", Theme.emptyHint)
        }
        // separator
        s.fill(w, m.contentTop, 1, m.fileH, Style(fg: .palette(236)))
    }

    // MARK: - Diff pane

    private static func renderDiffPane(_ model: AppModel, _ s: Screen, _ m: AppLayout.Metrics) {
        let x = m.diffX
        let w = m.diffW
        s.fill(x, m.contentTop, w, m.fileH, Style(fg: .palette(252)))

        guard let file = model.currentFile else {
            s.text(x + 1, m.contentTop + 1, "No files in this PR.", Theme.emptyHint)
            return
        }

        // header
        s.fill(x, m.contentTop, w, 1, Theme.paneHeader)
        var header: [(String, Style)] = []
        header.append((" \(file.path)", Theme.paneHeaderAccent))
        let statusText = file.tooLarge ? " (diff too large)" : (file.isBinary ? " (binary)" : "")
        header.append((statusText, Theme.paneHeaderDim))
        if !file.tooLarge && !file.isBinary {
            let hunks = file.hunks.count
            let hunk = (model.currentHunkIndex() ?? 0) + 1
            let info = "  hunk \(hunk)/\(hunks)  +\(file.additions) −\(file.deletions)"
            s.text(x + w - displayWidth(of: info), m.contentTop, info, Theme.paneHeaderDim)
        }
        s.runs(x, m.contentTop, header, maxWidth: w)

        // content window
        let listTop = m.contentTop + 1
        let visibleH = m.fileH - 1
        let contentW = w - 1
        let fileIndex = model.currentFileIndex
        let rows = model.fileRows
        let heights = rows.map { AppLayout.rowHeight($0, model: model, width: contentW) }
        let totalH = heights.reduce(0, +)
        var scroll = min(max(0, model.scrollRow), max(0, totalH - 1))

        // keep cursor visible
        let cursorLine = AppLayout.lineOfRow(model: model, fileIndex: fileIndex, rowIndex: model.cursorRow, width: contentW)
        let cursorHeight = model.cursorRow < heights.count ? heights[model.cursorRow] : 1
        if cursorLine < scroll { scroll = max(0, cursorLine) }
        if cursorLine + cursorHeight > scroll + visibleH { scroll = max(0, cursorLine + cursorHeight - visibleH) }

        var y = listTop - scroll
        for (ri, row) in rows.enumerated() {
            let h = heights[ri]
            if y >= listTop + visibleH { break }
            if y >= listTop {
                let width = contentW
                switch row {
                case .hunkHeader(let hi):
                    renderHunkHeader(file, hi, x, y, w, s, model)
                case .line(let hi, let li):
                    renderDiffLine(model, file, hi, li, ri, x, y, width, s)
                case .thread(let id):
                    renderThreadCard(model, id, x, y, width, s)
                case .draft(let id):
                    renderDraftCard(model, id, x, y, width, s)
                case .outdatedHeader:
                    s.fill(x, y, w, 1, Theme.outdatedBadge)
                    s.text(x + 1, y, " Outdated comments — Enter to \(model.outdatedExpanded ? "collapse" : "expand")", Theme.dim)
                case .empty:
                    s.text(x + 1, y, "(no changes)", Theme.emptyHint)
                }
            }
            y += h
        }
    }

    private static func renderHunkHeader(_ file: DiffFile, _ hi: Int, _ x: Int, _ y: Int, _ w: Int, _ s: Screen, _ model: AppModel) {
        guard hi < file.hunks.count else { return }
        let hunk = file.hunks[hi]
        s.fill(x, y, w, 1, Theme.hunkHeader)
        s.text(x + 1, y, " \(hunk.header)", Theme.hunkHeaderText, maxWidth: w - 2)
    }

    private static func renderDiffLine(
        _ model: AppModel, _ file: DiffFile, _ hi: Int, _ li: Int,
        _ rowIndex: Int, _ x: Int, _ y: Int, _ width: Int, _ s: Screen
    ) {
        guard let line = file.line(at: hi, li) else { return }
        let isCursor = rowIndex == model.cursorRow
        let inVisual: Bool = {
            guard let start = model.visualStartRow else { return false }
            return (start...model.cursorRow).contains(rowIndex) || (model.cursorRow...start).contains(rowIndex)
        }()

        var base: Style
        switch line.kind {
        case .added: base = isCursor ? Theme.addedCursor : Theme.added
        case .removed: base = isCursor ? Theme.removedCursor : Theme.removed
        case .context: base = isCursor ? Theme.cursor : (inVisual ? Theme.visualSelect : .plain)
        }
        if inVisual && !isCursor {
            base = base.merging(Style(bg: .palette(60)))
        }

        let ow = file.gutterDigits
        let nw = file.gutterDigits
        let gutterW = ow + 1 + nw + 1 + 1

        // gutter
        var oldTxt = ""
        if let o = line.oldLine { oldTxt = String(o) } else { oldTxt = String(repeating: " ", count: ow) }
        oldTxt = padToWidth(oldTxt, ow)
        var newTxt = ""
        if let n = line.newLine { newTxt = String(n) } else { newTxt = String(repeating: " ", count: nw) }
        newTxt = padToWidth(newTxt, nw)
        let sign: String
        var gutterStyle: Style
        switch line.kind {
        case .added: sign = "+"; gutterStyle = isCursor ? Theme.gutterAdd.merging(Style(bg: .palette(29))) : Theme.gutterAdd
        case .removed: sign = "−"; gutterStyle = isCursor ? Theme.gutterDel.merging(Style(bg: .palette(89))) : Theme.gutterDel
        case .context: sign = " "; gutterStyle = Theme.gutter
        }
        let gutterText = oldTxt + " " + newTxt + " " + sign
        s.text(x, y, gutterText, gutterStyle, maxWidth: gutterW)

        // content
        let cw = max(0, width - gutterW)
        let content = expandTabs(line.content)
        let visible = truncateToWidth(droppingDisplayWidth(content, model.hScroll), cw)

        // styled runs
        var runs: [(String, Style)] = []
        var curStyle: Style?
        var curText = ""
        func flush() {
            if !curText.isEmpty, let cs = curStyle {
                runs.append((curText, cs))
                curText = ""
            }
        }
        let chars = Array(visible)
        let emphasisStyle = line.kind == .added ? Theme.addedEmph : Theme.removedEmph
        let tokens = model.tokens(for: visible, path: file.path)
        // emphasis offsets are computed on the raw content; only valid without
        // horizontal scrolling and without tab expansion shifting columns
        let emphasis = (model.hScroll == 0 && !line.content.contains("\t")) ? line.emphasis : nil
        for idx in 0..<chars.count {
            var st = base
            if let e = emphasis, e.contains(idx) {
                st = st.merging(emphasisStyle)
            }
            if let tok = tokens.first(where: { $0.range.contains(idx) }) {
                st = st.merging(Theme.token(tok.kind))
            }
            if st != curStyle {
                flush()
                curStyle = st
            }
            curText.append(chars[idx])
        }
        flush()
        s.runs(x + gutterW, y, runs, maxWidth: cw)
        // fill remaining width of the row so the background extends fully
        let used = gutterW + min(displayWidth(of: visible), cw)
        if used < width {
            s.fill(x + used, y, width - used, 1, base)
        }
    }

    /// Drops the first `w` display columns of a string.
    private static func droppingDisplayWidth(_ s: String, _ w: Int) -> String {
        guard w > 0 else { return s }
        var col = 0
        var idx = s.startIndex
        while idx < s.endIndex, col < w {
            col += displayWidth(of: s[idx])
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    private static func renderThreadCard(_ model: AppModel, _ id: String, _ x: Int, _ y: Int, _ width: Int, _ s: Screen) {
        guard let t = model.thread(byID: id) else { return }
        let collapsed = !model.expandedThreads.contains(id)
        let border = t.isResolved ? Theme.threadResolved : Theme.threadBorder
        let y0 = y

        var badges = ""
        if t.isResolved { badges += " · resolved" }
        let title = "\(t.rootComment?.author ?? "?") · \(t.rootComment.map { timeAgo($0.createdAt) } ?? "")\(badges)"
        s.text(x, y0, "▎", border)
        s.text(x + 2, y0, truncateToWidth(title, width - 4), t.isResolved ? Theme.dim : Theme.text)

        if collapsed {
            s.text(x + 2, y0 + 1, "\(t.comments.count) comment\(t.comments.count == 1 ? "" : "s") · Enter to expand", Theme.faint)
            return
        }
        var yy = y0 + 1
        for c in t.comments {
            if yy - y0 >= 100 { break }
            s.text(x + 2, yy, "\(c.author) · \(timeAgo(c.createdAt))", Theme.dim)
            yy += 1
            let bodyLines = wrapText(c.body, width: max(10, width - 6))
            for bl in bodyLines {
                guard yy - y0 < 100 else { break }
                s.text(x + 4, yy, truncateToWidth(bl, width - 6), Theme.overlayBody)
                yy += 1
            }
        }
    }

    private static func renderDraftCard(_ model: AppModel, _ id: UUID, _ x: Int, _ y: Int, _ width: Int, _ s: Screen) {
        guard let d = model.draft(byID: id) else { return }
        let y0 = y
        s.text(x, y0, "▎", Theme.threadDraft)
        s.text(x + 2, y0, "You · draft \(d.side == "LEFT" ? "(left)" : "")", Theme.draftBadge)
        var yy = y0 + 1
        let bodyLines = wrapText(d.body, width: max(10, width - 6))
        for bl in bodyLines {
            guard yy - y0 < 100 else { break }
            s.text(x + 4, yy, truncateToWidth(bl, width - 6), Theme.overlayBody)
            yy += 1
        }
    }

    // MARK: - Message + status

    private static func renderMessage(_ model: AppModel, _ s: Screen, _ y: Int, _ w: Int) {
        guard let msg = model.message, let until = model.messageUntil, until >= Date() else { return }
        let style = msg.isError ? Theme.error : Theme.dim
        let prefix = msg.isError ? "⚠ " : ""
        s.text(1, y, prefix + truncateToWidth(msg.text, w - 2), style)
    }

    private static func renderStatus(_ model: AppModel, _ s: Screen, _ y: Int, _ w: Int) {
        s.fill(0, y, w, 1, Theme.statusBar)
        var left: [(String, Style)]
        switch model.mode {
        case .normal:
            left = statusKeys("a comment · e edit · x del · r reply · s submit · v viewed · / filter · R refresh · ? help · q quit")
        case .search:
            left = statusKeys("filter files — type to search, Enter/Esc done")
        case .visual:
            left = statusKeys("visual: move to extend, c comment range, Esc cancel")
        case .edit:
            left = statusKeys("editing — Esc save · Ctrl-C cancel")
        case .compose:
            left = statusKeys("1/2/3 event · b body · y submit · Esc cancel")
        case .help:
            left = statusKeys("j/k scroll · Esc close")
        case .prBody:
            left = statusKeys("j/k scroll · Esc close")
        case .confirmQuit, .confirmDeleteDraft:
            left = statusKeys("y yes · n no")
        }
        s.runs(0, y, left, maxWidth: w)

        var right = ""
        if let pr = model.pr {
            right += " #\(pr.number)"
        }
        if !model.files.isEmpty {
            right += " file \(model.currentFileIndex + 1)/\(model.files.count)"
            if model.cursorRow > 0 {
                right += " · row \(model.cursorRow + 1)"
            }
        }
        if !model.drafts.isEmpty {
            right += " · drafts \(model.drafts.count)"
        }
        if !model.viewed.isEmpty {
            right += " · viewed \(model.viewed.count)"
        }
        s.text(w - displayWidth(of: right), y, right, Theme.statusBar)
    }

    private static func statusKeys(_ s: String) -> [(String, Style)] {
        [(s, Theme.statusBar)]
    }

    // MARK: - Overlays

    private static func overlayBox(_ s: Screen, w: Int, h: Int, bw: Int, bh: Int, title: String) -> (x: Int, y: Int) {
        let x = max(0, (w - bw) / 2)
        let y = max(0, (h - bh) / 2)
        s.fill(0, 0, w, h, Style(fg: .palette(240)))
        s.box(x, y, bw, bh, Theme.overlayBorder, title: title, titleStyle: Theme.overlayTitle)
        return (x, y)
    }

    private static func renderEditor(_ model: AppModel, _ s: Screen, _ w: Int, _ h: Int) {
        let bw = min(w - 6, 92)
        let bh = min(h - 6, 16)
        let (x, y) = overlayBox(s, w: w, h: h, bw: bw, bh: bh, title: editorTitle(model))

        let edW = bw - 4
        let edH = bh - 4
        let edX = x + 2
        let edY = y + 2

        // clamp editor scroll
        var e = model.editor
        if e.row < e.scrollRow { e.scrollRow = e.row }
        if e.row >= e.scrollRow + edH { e.scrollRow = e.row - edH + 1 }
        if e.col < e.scrollCol { e.scrollCol = e.col }
        if e.col >= e.scrollCol + edW { e.scrollCol = e.col - edW + 1 }

        for row in 0..<edH {
            let li = e.scrollRow + row
            guard li < e.lines.count else { break }
            let text = String(e.lines[li].dropFirst(e.scrollCol))
            s.text(edX, edY + row, truncateToWidth(text, edW), Theme.overlayBody, maxWidth: edW)
            // caret
            if li == e.row {
                let caretCol = e.col - e.scrollCol
                if caretCol >= 0 && caretCol < edW {
                    let chars = Array(text)
                    let ch: Character = caretCol < chars.count ? chars[caretCol] : " "
                    s.put(edX + caretCol, edY + row, ch, Theme.caret)
                }
            }
        }

        let footer = model.editorTarget.map { target -> String in
            switch target {
            case .composerBody: return "Esc apply to review · Ctrl-C cancel"
            default: return "Esc save · Ctrl-C cancel (empty text deletes the draft)"
            }
        } ?? "Esc save · Ctrl-C cancel"
        s.text(x + 2, y + bh - 1, truncateToWidth(footer, bw - 4), Theme.dim)
    }

    private static func editorTitle(_ model: AppModel) -> String {
        guard let t = model.editorTarget else { return "Editor" }
        switch t {
        case .newDraft(let path, let line, let side, let startLine, _):
            var label = "Comment on \(path):\(line) (\(side))"
            if let s = startLine, s != line { label = "Comment on \(path):\(s)–\(line) (\(side))" }
            return label
        case .editDraft(let id):
            guard let d = model.draft(byID: id) else { return "Edit draft" }
            return "Edit draft · \(d.path):\(d.line)"
        case .reply(_, _):
            return "Reply to thread"
        case .composerBody:
            return "Review summary"
        }
    }

    private static func renderComposer(_ model: AppModel, _ s: Screen, _ w: Int, _ h: Int) {
        let bw = min(w - 6, 96)
        let bh = min(h - 6, 22)
        let (x, y) = overlayBox(s, w: w, h: h, bw: bw, bh: bh, title: "Submit review")

        var yy = y + 1
        for event in ReviewEvent.allCases {
            let mark = event == model.composerEvent ? "●" : "○"
            let style = event == model.composerEvent ? Theme.accentBold : Theme.dim
            s.text(x + 2, yy, "\(mark) \(event.label)", style)
            yy += 1
        }
        yy += 1

        s.text(x + 2, yy, "Summary:", Theme.dim)
        yy += 1
        let bodyPreview = model.composerBody.isEmpty ? "(empty — press b to edit)" : model.composerBody
        let previewLines = wrapText(bodyPreview, width: bw - 4)
        for (i, pl) in previewLines.prefix(3).enumerated() {
            s.text(x + 4, yy + i, truncateToWidth(pl, bw - 6), Theme.overlayBody)
        }
        yy += min(3, previewLines.count) + 1

        s.text(x + 2, yy, "Drafts included (\(model.drafts.count)):", Theme.dim)
        yy += 1
        for d in model.drafts.prefix(6) {
            let preview = d.body.split(separator: "\n").first.map(String.init) ?? ""
            s.text(x + 4, yy, truncateToWidth("· \(d.path):\(d.line)  \(preview)", bw - 6), Theme.warn)
            yy += 1
        }
        if model.drafts.count > 6 {
            s.text(x + 4, yy, "… and \(model.drafts.count - 6) more", Theme.faint)
        }

        if let err = model.composerError {
            let lines = wrapText(err, width: bw - 4)
            for (i, el) in lines.prefix(2).enumerated() {
                s.text(x + 2, y + bh - 3 + i, truncateToWidth(el, bw - 4), Theme.error)
            }
        }
        s.text(x + 2, y + bh - 1, "1/2/3 event · b body · y submit · Esc/Ctrl-C cancel", Theme.dim)
    }

    private static func renderPRBody(_ model: AppModel, _ s: Screen, _ w: Int, _ h: Int) {
        let bw = min(w - 8, 100)
        let bh = h - 8
        let (x, y) = overlayBox(s, w: w, h: h, bw: bw, bh: max(10, bh), title: "PR description")
        let text = model.pr?.body ?? ""
        let lines = wrapText(text.isEmpty ? "(no description)" : text, width: bw - 4)
        let visible = bh - 2
        let scroll = min(model.prBodyScroll, max(0, lines.count - visible))
        for i in 0..<visible {
            let li = scroll + i
            guard li < lines.count else { break }
            s.text(x + 2, y + 1 + i, truncateToWidth(lines[li], bw - 4), Theme.overlayBody)
        }
    }

    private static func renderHelp(_ model: AppModel, _ s: Screen, _ w: Int, _ h: Int) {
        let bw = min(w - 6, 84)
        let bh = h - 4
        let (x, y) = overlayBox(s, w: w, h: h, bw: bw, bh: max(10, bh), title: "Key bindings")

        let items: [(String, String)] = [
            ("j/k, ↓/↑", "move cursor / selection"),
            ("Ctrl-D / Ctrl-U", "half page down / up"),
            ("PgDn / PgUp", "page down / up"),
            ("g / G", "first / last line"),
            ("Tab", "switch pane (files ↔ diff)"),
            ("Enter", "open file · expand thread · expand outdated"),
            ("{ / }", "previous / next hunk"),
            ("[ / ]", "previous / next file"),
            ("C", "jump to next comment thread"),
            ("← / →", "horizontal scroll"),
            ("c", "add draft comment at cursor (deleted lines → LEFT)"),
            ("V … c", "visual range comment (start_line .. line)"),
            ("e", "edit draft under cursor"),
            ("x", "delete draft under cursor"),
            ("X", "resolve / unresolve thread under cursor"),
            ("r", "reply to thread (sent immediately)"),
            ("v", "toggle viewed (local only)"),
            ("/", "filter files"),
            ("s", "submit review (comment / approve / request changes)"),
            ("y", "yank current line (path:line) to clipboard"),
            ("o", "open PR in browser"),
            ("p", "show PR description"),
            ("R", "refresh PR data"),
            ("?", "help"),
            ("q / Ctrl-C", "quit (confirms when drafts exist)"),
            ("Editor", "Esc save · Ctrl-C cancel"),
        ]
        let visible = bh - 2
        let scroll = min(model.helpScroll, max(0, items.count - visible))
        var yy = y + 1
        for i in scroll..<min(scroll + visible, items.count) {
            let (k, d) = items[i]
            s.runs(x + 2, yy, [
                (padToWidth(k, 20), Theme.statusKey),
                (truncateToWidth(d, bw - 24), Theme.overlayBody),
            ])
            yy += 1
        }
    }

    private static func renderConfirm(_ s: Screen, _ w: Int, _ h: Int, message: String) {
        let bw = min(w - 10, 60)
        let bh = 5
        let x = max(0, (w - bw) / 2)
        let y = max(0, (h - bh) / 2)
        s.box(x, y, bw, bh, Theme.overlayBorder, title: "Confirm", titleStyle: Theme.warn)
        s.text(x + 2, y + 1, truncateToWidth(message, bw - 4), Theme.overlayBody)
        s.text(x + 2, y + 3, "y yes · n no", Theme.dim)
    }
}
