import Foundation

/// Handles all input and drives background GitHub operations. Runs entirely on
/// the main tick; heavy work is dispatched to a queue and applied later via
/// `drainPending()`, guarded by a generation counter.
public final class AppController {

    public enum Outcome {
        case fetch(FetchBundle)
        case fetchFailed(Error)
        case submitDone
        case submitFailed(Error)
        case replyDone
        case replyFailed(Error)
        case resolveDone
        case resolveFailed(threadID: String, wasResolved: Bool, error: Error)
    }

    public let model: AppModel
    private let client: GitHubClient?
    private let workQueue = DispatchQueue(label: "pr-review.work")
    private let lock = NSLock()
    private var pending: [(generation: Int, outcome: Outcome)] = []
    private var deleteDraftID: UUID?

    public init(model: AppModel, client: GitHubClient?) {
        self.model = model
        self.client = client
    }

    private func push(_ gen: Int, _ outcome: Outcome) {
        lock.lock()
        pending.append((gen, outcome))
        lock.unlock()
    }

    /// Applies any finished background work; call on every tick.
    public func drainPending() {
        var batch: [(Int, Outcome)] = []
        lock.lock()
        batch = pending
        pending.removeAll()
        lock.unlock()
        for (gen, outcome) in batch {
            guard gen == model.generation else { continue }
            switch outcome {
            case .fetch(let bundle):
                apply(bundle)
                model.loading = false
                model.setMessage("Refreshed.")
            case .fetchFailed(let e):
                model.loading = false
                model.setMessage("Refresh failed: \(e)", isError: true, duration: 15)
            case .submitDone:
                model.drafts.removeAll()
                persistDrafts()
                model.rebuildRows()
                model.setMessage("Review submitted.")
                refresh()
            case .submitFailed(let e):
                model.setMessage("Submit failed: \(e)", isError: true, duration: 20)
            case .replyDone:
                model.setMessage("Reply posted.")
                refresh()
            case .replyFailed(let e):
                model.setMessage("Reply failed: \(e)", isError: true, duration: 15)
            case .resolveDone:
                model.setMessage("Thread updated.")
            case .resolveFailed(let threadID, let wasResolved, let error):
                // roll back the optimistic toggle
                if let idx = model.threads.firstIndex(where: { $0.id == threadID }) {
                    model.threads[idx].isResolved = wasResolved
                    model.rebuildRows()
                }
                model.setMessage("Resolve failed: \(error)", isError: true, duration: 15)
            }
            model.dirty = true
        }
        if let until = model.messageUntil, until < Date() {
            model.message = nil
            model.dirty = true
        }
    }

    private func apply(_ bundle: FetchBundle) {
        model.pr = bundle.pr
        model.headOID = bundle.pr.headRefOid
        model.files = bundle.files
        model.threads = bundle.threads
        model.selectedFile = min(model.selectedFile, max(0, model.files.count - 1))
        model.rebuildRows()
        model.dirty = true
    }

    // MARK: - Main dispatch

    public func handle(_ key: Key, screenW: Int, screenH: Int) {
        model.dirty = true
        switch model.mode {
        case .normal:
            handleNormal(key, screenW: screenW, screenH: screenH)
        case .search:
            handleSearch(key)
        case .visual:
            handleVisual(key, screenW: screenW, screenH: screenH)
        case .edit:
            handleEdit(key)
        case .compose:
            handleCompose(key)
        case .help:
            handleHelp(key)
        case .prBody:
            handlePRBody(key)
        case .confirmQuit:
            handleConfirmQuit(key)
        case .confirmDeleteDraft:
            handleConfirmDelete(key)
        }
        model.dirty = true
    }

    // MARK: - Normal mode

    private func handleNormal(_ key: Key, screenW: Int, screenH: Int) {
        let m = AppLayout.metrics(screenW: screenW, screenH: screenH)
        let contentW = m.diffW - 1

        switch key {
        case .char(let c):
            switch c {
            case "q": requestQuit()
            case "?": model.helpScroll = 0; model.mode = .help
            case "j": moveCursor(1, contentW: contentW, diffH: m.diffH)
            case "k": moveCursor(-1, contentW: contentW, diffH: m.diffH)
            case "g": moveCursor(to: 0, contentW: contentW, diffH: m.diffH)
            case "G": moveCursor(to: model.fileRows.count - 1, contentW: contentW, diffH: m.diffH)
            case "{": jumpHunk(-1)
            case "}": jumpHunk(1)
            case "[": changeFile(-1)
            case "]": changeFile(1)
            case "C": jumpThread(1)
            case "c":
                if model.focus == .diff { startComment() }
            case "V":
                if model.focus == .diff {
                    model.visualStartRow = model.cursorRow
                    model.mode = .visual
                }
            case "e": editDraftAtCursor()
            case "x": requestDeleteDraft()
            case "X": toggleResolve()
            case "r": startReply()
            case "v": toggleViewed()
            case "/": model.filter = ""; model.mode = .search
            case "s": startCompose()
            case "y": yankLine()
            case "o": openInBrowser()
            case "p": model.prBodyScroll = 0; model.mode = .prBody
            case "R": refresh()
            default: break
            }
        case .ctrl("c"):
            requestQuit()
        case .ctrl("d"):
            moveCursor(max(1, m.diffH / 2), contentW: contentW, diffH: m.diffH)
        case .ctrl("u"):
            moveCursor(-max(1, m.diffH / 2), contentW: contentW, diffH: m.diffH)
        case .pageDown:
            moveCursor(m.diffH, contentW: contentW, diffH: m.diffH)
        case .pageUp:
            moveCursor(-m.diffH, contentW: contentW, diffH: m.diffH)
        case .up, .down, .left, .right, .home, .end:
            handleArrow(key, contentW: contentW, diffH: m.diffH)
        case .tab, .backtab:
            model.focus = (model.focus == .files) ? .diff : .files
        case .enter:
            handleEnter()
        case .escape:
            model.message = nil
        case .mouseDown(_, let col, let row):
            handleMouseDown(col: col, row: row, screenW: screenW, screenH: screenH)
        case .mouseWheelUp(let col, let row):
            handleWheel(up: true, col: col, row: row, screenW: screenW, screenH: screenH)
        case .mouseWheelDown(let col, let row):
            handleWheel(up: false, col: col, row: row, screenW: screenW, screenH: screenH)
        default:
            break
        }
    }

    private func handleArrow(_ key: Key, contentW: Int, diffH: Int) {
        switch key {
        case .down: moveCursor(1, contentW: contentW, diffH: diffH)
        case .up: moveCursor(-1, contentW: contentW, diffH: diffH)
        case .left: model.hScroll = max(0, model.hScroll - 8)
        case .right: model.hScroll += 8
        case .home: moveCursor(to: 0, contentW: contentW, diffH: diffH)
        case .end: moveCursor(to: model.fileRows.count - 1, contentW: contentW, diffH: diffH)
        default: break
        }
    }

    private func handleEnter() {
        if model.focus == .files {
            if model.mode == .search { model.mode = .normal }
            model.focus = .diff
            moveCursor(to: 0, contentW: 60, diffH: 20)
            return
        }
        // diff pane: toggle thread expansion / outdated section
        guard let row = model.row(at: model.cursorRow) else { return }
        switch row {
        case .thread(let id):
            if model.expandedThreads.contains(id) {
                model.expandedThreads.remove(id)
            } else {
                model.expandedThreads.insert(id)
            }
            model.rebuildRows()
        case .outdatedHeader:
            model.outdatedExpanded.toggle()
            model.rebuildRows()
        default:
            break
        }
    }

    // MARK: - Movement

    private func moveCursor(_ delta: Int, contentW: Int, diffH: Int) {
        guard !model.fileRows.isEmpty else { return }
        let count = model.fileRows.count
        model.cursorRow = min(max(0, model.cursorRow + delta), count - 1)
        keepCursorVisible(contentW: contentW, diffH: diffH)
    }

    private func moveCursor(to index: Int, contentW: Int, diffH: Int) {
        guard !model.fileRows.isEmpty else { return }
        model.cursorRow = min(max(0, index), model.fileRows.count - 1)
        keepCursorVisible(contentW: contentW, diffH: diffH)
    }

    private func keepCursorVisible(contentW: Int, diffH: Int) {
        guard !model.fileRows.isEmpty else { return }
        let fi = model.currentFileIndex
        let line = AppLayout.lineOfRow(model: model, fileIndex: fi, rowIndex: model.cursorRow, width: contentW)
        let height = AppLayout.rowHeight(model.fileRows[model.cursorRow], model: model, width: contentW)
        let visible = max(1, diffH - 1)
        if line < model.scrollRow {
            model.scrollRow = max(0, line)
        } else if line + height > model.scrollRow + visible {
            model.scrollRow = max(0, line + height - visible)
        }
    }

    private func jumpHunk(_ dir: Int) {
        let rows = model.fileRows
        guard !rows.isEmpty else { return }
        var i = model.cursorRow + dir
        while i >= 0 && i < rows.count {
            if case .hunkHeader = rows[i] {
                model.cursorRow = i
                return
            }
            i += dir
        }
    }

    private func jumpThread(_ dir: Int) {
        let rows = model.fileRows
        guard !rows.isEmpty else { return }
        var i = model.cursorRow + dir
        while i >= 0 && i < rows.count {
            if case .thread = rows[i] {
                model.cursorRow = i
                return
            }
            i += dir
        }
    }

    private func changeFile(_ dir: Int) {
        guard !model.files.isEmpty else { return }
        let filtered = model.filteredFileIndices()
        guard !filtered.isEmpty else { return }
        let pos = filtered.firstIndex(of: model.currentFileIndex) ?? 0
        let next = min(max(0, pos + dir), filtered.count - 1)
        model.selectedFile = filtered[next]
        model.cursorRow = 0
        model.scrollRow = 0
        model.hScroll = 0
        model.dirty = true
    }

    // MARK: - Files

    private func toggleViewed() {
        guard let file = model.currentFile else { return }
        if model.viewed.contains(file.path) {
            model.viewed.remove(file.path)
        } else {
            model.viewed.insert(file.path)
        }
        persistViewed()
    }

    // MARK: - Comments

    private func startComment() {
        guard let info = model.cursorLineInfo(), let file = model.currentFile else { return }
        let line = info.line
        let side: String
        let lineNum: Int?
        switch line.kind {
        case .added, .context:
            side = "RIGHT"
            lineNum = line.newLine
        case .removed:
            side = "LEFT"
            lineNum = line.oldLine
        }
        guard let n = lineNum else { return }
        model.editor = TextEditor()
        model.editorTarget = .newDraft(path: file.path, line: n, side: side, startLine: nil, startSide: nil)
        model.mode = .edit
    }

    private func visualComment() {
        guard let start = model.visualStartRow else {
            model.mode = .normal
            model.visualStartRow = nil
            return
        }
        let end = model.cursorRow
        let lo = min(start, end)
        let hi = max(start, end)
        let startRow = model.row(at: lo)
        let endRow = model.row(at: hi)
        guard case .line(let h1, let l1)? = startRow,
              case .line(let h2, let l2)? = endRow,
              let f = model.currentFile,
              let line1 = f.line(at: h1, l1),
              let line2 = f.line(at: h2, l2) else {
            model.mode = .normal
            model.visualStartRow = nil
            return
        }
        func anchor(_ line: DiffLine) -> (side: String, num: Int)? {
            switch line.kind {
            case .added, .context:
                guard let n = line.newLine else { return nil }
                return ("RIGHT", n)
            case .removed:
                guard let n = line.oldLine else { return nil }
                return ("LEFT", n)
            }
        }
        guard let a1 = anchor(line1), let a2 = anchor(line2) else {
            model.mode = .normal
            model.visualStartRow = nil
            return
        }
        if a1.side != a2.side {
            // mixed sides: fall back to a single-line comment on the current row
            model.mode = .normal
            model.visualStartRow = nil
            startComment()
            return
        }
        let (side, startNum) = (a1.side, min(a1.num, a2.num))
        let endNum = max(a1.num, a2.num)
        model.editor = TextEditor()
        model.editorTarget = .newDraft(
            path: f.path, line: endNum, side: side,
            startLine: startNum == endNum ? nil : startNum,
            startSide: startNum == endNum ? nil : side
        )
        model.mode = .edit
        model.visualStartRow = nil
    }

    private func editDraftAtCursor() {
        guard model.focus == .diff, let row = model.row(at: model.cursorRow) else { return }
        guard case .draft(let id) = row, let d = model.draft(byID: id) else { return }
        model.editor = TextEditor(text: d.body)
        model.editorTarget = .editDraft(id)
        model.mode = .edit
    }

    private func requestDeleteDraft() {
        guard model.focus == .diff, let row = model.row(at: model.cursorRow) else { return }
        guard case .draft(let id) = row else { return }
        deleteDraftID = id
        model.mode = .confirmDeleteDraft
    }

    private func startReply() {
        guard model.focus == .diff, let row = model.row(at: model.cursorRow) else { return }
        guard case .thread(let id) = row, let t = model.thread(byID: id),
              let cid = t.rootCommentID else { return }
        model.editor = TextEditor()
        model.editorTarget = .reply(threadID: id, commentID: cid)
        model.mode = .edit
    }

    private func toggleResolve() {
        guard model.focus == .diff, let row = model.row(at: model.cursorRow) else { return }
        guard case .thread(let id) = row, let t = model.thread(byID: id), !t.isOutdated else { return }
        let newState = !t.isResolved
        if let idx = model.threads.firstIndex(where: { $0.id == id }) {
            model.threads[idx].isResolved = newState
        }
        model.rebuildRows()
        guard !model.isDemo, let client, let ep = model.endpoint else {
            model.setMessage("Demo: resolve toggled locally.")
            return
        }
        model.generation += 1
        let gen = model.generation
        let wasResolved = t.isResolved
        workQueue.async { [weak self] in
            do {
                try client.resolveThread(ep, threadID: id, resolved: newState)
                self?.push(gen, .resolveDone)
            } catch {
                self?.push(gen, .resolveFailed(threadID: id, wasResolved: wasResolved, error: error))
            }
        }
    }

    // MARK: - Editor

    private func handleEdit(_ key: Key) {
        switch key {
        case .escape:
            saveEditor()
        case .ctrl("c"):
            model.mode = .normal
            model.editorTarget = nil
        case .tab:
            // swallow tab (editor inserts spaces via handle)
            model.editor.handle(.tab)
        default:
            model.editor.handle(key)
        }
    }

    private func saveEditor() {
        let text = model.editor.text
        switch model.editorTarget {
        case .newDraft(let path, let line, let side, let startLine, let startSide):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                model.setMessage("Draft discarded (empty).")
            } else {
                model.drafts.append(DraftComment(
                    path: path, line: line, side: side, body: trimmed,
                    startLine: startLine, startSide: startSide
                ))
                persistDrafts()
                model.rebuildRows()
                model.setMessage("Draft added — press s to submit.")
            }
            model.mode = .normal
            model.editorTarget = nil
        case .editDraft(let id):
            if let idx = model.drafts.firstIndex(where: { $0.id == id }) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    model.drafts.remove(at: idx)
                    model.setMessage("Draft deleted.")
                } else {
                    model.drafts[idx].body = trimmed
                    model.setMessage("Draft updated.")
                }
                persistDrafts()
                model.rebuildRows()
            }
            model.mode = .normal
            model.editorTarget = nil
        case .reply(let threadID, let commentID):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.mode = .normal
            model.editorTarget = nil
            guard !trimmed.isEmpty else {
                model.setMessage("Reply discarded (empty).")
                return
            }
            if model.isDemo {
                if let tIdx = model.threads.firstIndex(where: { $0.id == threadID }) {
                    model.threads[tIdx].comments.append(PRComment(
                        databaseId: 9999, author: "you", body: trimmed, createdAt: Date()
                    ))
                    model.rebuildRows()
                }
                model.setMessage("Demo: reply added locally.")
                return
            }
            guard let client, let ep = model.endpoint else { return }
            model.generation += 1
            let gen = model.generation
            model.loading = true
            workQueue.async { [weak self] in
                do {
                    try client.replyToThread(ep, commentID: commentID, body: trimmed)
                    self?.push(gen, .replyDone)
                } catch {
                    self?.push(gen, .replyFailed(error))
                }
            }
        case .composerBody:
            model.composerBody = text
            model.mode = .compose
            model.editorTarget = nil
        case nil:
            model.mode = .normal
        }
    }

    // MARK: - Search

    private func handleSearch(_ key: Key) {
        switch key {
        case .char("j"), .down:
            navigateFiltered(1)
        case .char("k"), .up:
            navigateFiltered(-1)
        case .char(let c):
            model.filter.append(c)
        case .backspace:
            if !model.filter.isEmpty { model.filter.removeLast() }
        case .enter:
            model.mode = .normal
            if model.focus == .diff { model.focus = .files }
        case .escape:
            model.filter = ""
            model.mode = .normal
        default:
            break
        }
    }

    private func navigateFiltered(_ dir: Int) {
        let indices = model.filteredFileIndices()
        guard !indices.isEmpty else { return }
        let pos = indices.firstIndex(of: model.currentFileIndex) ?? 0
        let next = min(max(0, pos + dir), indices.count - 1)
        model.selectedFile = indices[next]
        model.cursorRow = 0
        model.scrollRow = 0
        model.dirty = true
    }

    // MARK: - Visual mode

    private func handleVisual(_ key: Key, screenW: Int, screenH: Int) {
        let m = AppLayout.metrics(screenW: screenW, screenH: screenH)
        let contentW = m.diffW - 1
        switch key {
        case .char("c"):
            visualComment()
        case .char("j"):
            moveCursor(1, contentW: contentW, diffH: m.diffH)
        case .char("k"):
            moveCursor(-1, contentW: contentW, diffH: m.diffH)
        case .char("g"):
            moveCursor(to: 0, contentW: contentW, diffH: m.diffH)
        case .char("G"):
            moveCursor(to: model.fileRows.count - 1, contentW: contentW, diffH: m.diffH)
        case .escape:
            model.mode = .normal
            model.visualStartRow = nil
        case .down: moveCursor(1, contentW: contentW, diffH: m.diffH)
        case .up: moveCursor(-1, contentW: contentW, diffH: m.diffH)
        case .ctrl("d"): moveCursor(max(1, m.diffH / 2), contentW: contentW, diffH: m.diffH)
        case .ctrl("u"): moveCursor(-max(1, m.diffH / 2), contentW: contentW, diffH: m.diffH)
        case .pageDown: moveCursor(m.diffH, contentW: contentW, diffH: m.diffH)
        case .pageUp: moveCursor(-m.diffH, contentW: contentW, diffH: m.diffH)
        default:
            break
        }
    }

    // MARK: - Composer

    private func startCompose() {
        model.composerEvent = .comment
        model.composerBody = ""
        model.composerError = nil
        model.mode = .compose
    }

    private func handleCompose(_ key: Key) {
        switch key {
        case .char(let c):
            switch c {
            case "1", "c": model.composerEvent = .comment
            case "2", "a": model.composerEvent = .approve
            case "3", "x": model.composerEvent = .requestChanges
            case "b":
                model.editor = TextEditor(text: model.composerBody)
                model.editorTarget = .composerBody
                model.mode = .edit
            case "y":
                submitReview()
            default:
                break
            }
        case .escape, .ctrl("c"):
            model.mode = .normal
        default:
            break
        }
    }

    private func submitReview() {
        let event = model.composerEvent
        let body = model.composerBody
        let drafts = model.drafts
        model.mode = .normal
        model.composerError = nil
        if event == .approve && body.isEmpty && !drafts.isEmpty {
            model.composerError = "Approvals with inline comments usually include a summary."
            model.mode = .compose
            return
        }
        if model.isDemo {
            model.drafts.removeAll()
            persistDrafts()
            model.rebuildRows()
            model.setMessage("Demo mode — review not submitted.")
            return
        }
        guard let client, let ep = model.endpoint else {
            model.setMessage("Not connected to GitHub.", isError: true)
            return
        }
        model.generation += 1
        let gen = model.generation
        model.loading = true
        model.setMessage("Submitting review…")
        let commitID = model.headOID
        workQueue.async { [weak self] in
            do {
                try client.submitReview(ep, commitID: commitID, body: body, event: event.apiValue, drafts: drafts)
                self?.push(gen, .submitDone)
            } catch {
                self?.push(gen, .submitFailed(error))
            }
        }
    }

    // MARK: - Help / PR body

    private func handleHelp(_ key: Key) {
        switch key {
        case .char("j"), .down: model.helpScroll += 1
        case .char("k"), .up: model.helpScroll = max(0, model.helpScroll - 1)
        case .escape, .ctrl("c"), .char("q"): model.mode = .normal
        default: break
        }
    }

    private func handlePRBody(_ key: Key) {
        switch key {
        case .char("j"), .down: model.prBodyScroll += 1
        case .char("k"), .up: model.prBodyScroll = max(0, model.prBodyScroll - 1)
        case .escape, .ctrl("c"): model.mode = .normal
        default: break
        }
    }

    // MARK: - Confirmations

    private func requestQuit() {
        if model.drafts.isEmpty && !model.loading {
            model.shouldQuit = true
        } else {
            model.mode = .confirmQuit
        }
    }

    private func handleConfirmQuit(_ key: Key) {
        switch key {
        case .char(let c):
            switch c {
            case "y":
                model.shouldQuit = true
            case "n":
                model.mode = .normal
            default: break
            }
        case .escape, .ctrl("c"):
            model.mode = .normal
        default: break
        }
    }

    private func handleConfirmDelete(_ key: Key) {
        switch key {
        case .char(let c):
            switch c {
            case "y":
                if let id = deleteDraftID,
                   let idx = model.drafts.firstIndex(where: { $0.id == id }) {
                    model.drafts.remove(at: idx)
                    persistDrafts()
                    model.rebuildRows()
                    model.setMessage("Draft deleted.")
                }
                deleteDraftID = nil
                model.mode = .normal
            case "n":
                deleteDraftID = nil
                model.mode = .normal
            default: break
            }
        case .escape, .ctrl("c"):
            deleteDraftID = nil
            model.mode = .normal
        default: break
        }
    }

    // MARK: - Mouse

    private func handleMouseDown(col: Int, row: Int, screenW: Int, screenH: Int) {
        let m = AppLayout.metrics(screenW: screenW, screenH: screenH)
        if col < m.fileW {
            let listTop = m.contentTop + 1
            let idx = model.fileScroll + (row - listTop)
            let indices = model.filteredFileIndices()
            if idx >= 0 && idx < indices.count {
                model.selectedFile = indices[idx]
                model.cursorRow = 0
                model.scrollRow = 0
                model.focus = .files
            }
        } else if col >= m.diffX {
            let contentW = m.diffW - 1
            let line = row - (m.contentTop + 1)
            if let ri = AppLayout.rowAtLine(
                model: model, fileIndex: model.currentFileIndex, line: line, width: contentW
            ) {
                model.cursorRow = ri
                model.focus = .diff
            }
        }
    }

    private func handleWheel(up: Bool, col: Int, row: Int, screenW: Int, screenH: Int) {
        let m = AppLayout.metrics(screenW: screenW, screenH: screenH)
        let delta = up ? -3 : 3
        if col < m.fileW {
            let indices = model.filteredFileIndices()
            guard !indices.isEmpty else { return }
            let pos = indices.firstIndex(of: model.currentFileIndex) ?? 0
            let next = min(max(0, pos + delta), indices.count - 1)
            model.selectedFile = indices[next]
            model.cursorRow = 0
            model.scrollRow = 0
        } else if col >= m.diffX {
            moveCursor(delta, contentW: m.diffW - 1, diffH: m.diffH)
        }
    }

    // MARK: - Misc actions

    private func persistDrafts() {
        guard !model.isDemo, let ep = model.endpoint, !model.headOID.isEmpty else { return }
        DraftStore.saveDrafts(model.drafts, ep, sha: model.headOID)
    }

    private func persistViewed() {
        guard !model.isDemo, let ep = model.endpoint, !model.headOID.isEmpty else { return }
        DraftStore.saveViewed(model.viewed, ep, sha: model.headOID)
    }

    public func refresh() {
        if model.isDemo {
            model.setMessage("Demo mode — nothing to refresh.")
            return
        }
        guard let client, let ep = model.endpoint else {
            model.setMessage("Not connected to GitHub.", isError: true)
            return
        }
        model.generation += 1
        let gen = model.generation
        model.loading = true
        model.setMessage("Refreshing…")
        workQueue.async { [weak self] in
            do {
                let bundle = try client.fetchAll(ep)
                self?.push(gen, .fetch(bundle))
            } catch {
                self?.push(gen, .fetchFailed(error))
            }
        }
    }

    private func yankLine() {
        guard model.focus == .diff, let info = model.cursorLineInfo(),
              let file = model.currentFile else { return }
        let line = info.line
        let num = line.newLine ?? line.oldLine ?? 0
        let text = "\(file.path):\(num) \(line.content)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        proc.standardInput = pipe
        do {
            try proc.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            model.setMessage("Copied \(file.path):\(num)")
        } catch {
            model.setMessage("Could not copy: \(error)", isError: true)
        }
    }

    private func openInBrowser() {
        if model.isDemo {
            model.setMessage("Demo mode — no PR URL to open.")
            return
        }
        guard let url = model.pr?.url else {
            model.setMessage("No PR URL available.", isError: true)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]
        try? proc.run()
    }
}
