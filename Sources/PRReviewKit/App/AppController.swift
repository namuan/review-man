import Foundation

/// Handles all input and drives background GitHub operations. Runs entirely on
/// the main tick; network work runs as cancellable tasks and finished outcomes
/// are applied later via `drainPending()`. Operations are tracked per lane
/// (fetch / submit / reply-by-thread / resolve-by-thread / persistence), so
/// unrelated operations never invalidate each other.
public final class AppController {

    public enum Outcome {
        /// A fetch succeeded and is awaiting async head-SHA migration.
        case fetch(FetchBundle)
        /// Migration finished; apply the bundle with the migrated drafts and
        /// viewed marks, plus the nonmodal status message.
        case fetchApplied(FetchBundle, [DraftComment], Set<String>, String)
        case fetchFailed(Error)
        /// Migration could not preserve local state; the model is unchanged.
        case migrationFailed(String)
        case submitDone(SubmitResult)
        case submitFailed(Error)
        case replyDone
        case replyFailed(Error)
        case resolveDone
        case resolveFailed(threadID: String, wasResolved: Bool, error: Error)
        case persistenceSaved
        case persistenceFailed(operation: String, Error)
    }

    public let model: AppModel
    private let client: GitHubServing?
    private let persistence: any ReviewPersisting
    private let clipboard: ClipboardWriting
    private let lock = NSLock()
    private var pending: [(token: OperationToken, outcome: Outcome)] = []
    private var deleteDraftID: UUID?
    private let tracker = OperationTracker()
    private let operations: ReviewOperations?

    public init(
        model: AppModel,
        client: GitHubServing?,
        clipboard: ClipboardWriting = SystemClipboard(),
        persistence: any ReviewPersisting = ReviewPersistence.shared
    ) {
        self.model = model
        self.client = client
        self.clipboard = clipboard
        self.persistence = persistence
        self.operations = client.map { ReviewOperations(service: $0, persistence: persistence) }
    }

    private func deliver(_ token: OperationToken, _ outcome: Outcome) {
        lock.lock()
        pending.append((token, outcome))
        lock.unlock()
    }

    /// Starts an operation on a lane. The newest fetch cancels the previous
    /// in-flight fetch; writes are never cancelled by a refresh. Cancellation
    /// of a task drops its outcome without showing an error.
    private func launch(_ lane: OperationLane, _ operation: @escaping () async throws -> Outcome) {
        let token = tracker.begin(lane)
        model.loading = true
        let task = Task { [weak self] in
            do {
                let outcome = try await operation()
                self?.deliver(token, outcome)
            } catch is CancellationError {
                self?.discard(token)
            } catch {
                // Operation closures map their own errors to outcomes; anything
                // escaping here is a programming error and is dropped quietly.
                self?.discard(token)
            }
        }
        if lane == .fetch {
            tracker.cancelPreviousFetchTask()
            tracker.setFetchTask(task)
        }
    }

    private func discard(_ token: OperationToken) {
        tracker.complete(token)
    }

    /// Applies any finished background work; call on every tick.
    public func drainPending() {
        var batch: [(OperationToken, Outcome)] = []
        lock.lock()
        batch = pending
        pending.removeAll()
        lock.unlock()
        for (token, outcome) in batch {
            guard tracker.isCurrent(token) else {
                tracker.complete(token)
                continue
            }
            switch outcome {
            case .fetch(let bundle):
                // Begin the async head-SHA migration. The token stays active
                // until the migration outcome lands, keeping loading true.
                let snapshot = (model.endpoint, model.headOID, model.drafts, model.viewed)
                let task = Task { [weak self] in
                    guard let self else { return }
                    let result = await self.migrateFetch(snapshot: snapshot, bundle: bundle)
                    self.deliver(token, result)
                }
                tracker.setMigrationTask(task)
            default:
                tracker.complete(token)
                applyOutcome(outcome)
            }
        }
        model.loading = tracker.hasActiveOperations
        model.dirty = true
        if let until = model.messageUntil, until < Date() {
            model.message = nil
            model.dirty = true
        }
    }

    /// Applies a single operation outcome to the model. Internal so tests can
    /// exercise failure paths without spawning background work.
    func applyOutcome(_ outcome: Outcome) {
        switch outcome {
        case .fetch:
            break // handled by drainPending via the async migration path
        case .fetchApplied(let bundle, let drafts, let viewed, let message):
            applyFetch(bundle, drafts: drafts, viewed: viewed, message: message)
        case .fetchFailed(let e):
            model.loading = false
            model.setMessage("Refresh failed: \(e)", isError: true, duration: 15)
        case .migrationFailed(let reason):
            model.persistenceFailure = PersistenceFailure(
                operation: "refresh", message: reason
            )
            model.setMessage("Refresh was not applied: \(reason)", isError: true, duration: 20)
        case .submitDone(let result):
            // Remove only drafts equal to the submitted snapshot (drafts
            // created or edited while submission was in flight stay local).
            let submitted = result.submitted.drafts
            model.drafts.removeAll { draft in
                submitted.contains(draft)
            }
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
        case .persistenceSaved:
            model.persistenceFailure = nil
        case .persistenceFailed(let operation, let error):
            model.persistenceFailure = PersistenceFailure(
                operation: operation, message: "\(error)"
            )
            let label = operation == "viewed" ? "viewed marks" : "drafts"
            model.setMessage("Could not save local \(label). Changes remain in memory.", isError: true, duration: 15)
        }
    }

    /// Applies a fetched bundle with the given (already migrated and validated)
    /// drafts and viewed marks. Internal so tests can drive it directly.
    func applyFetch(
        _ bundle: FetchBundle,
        drafts: [DraftComment]? = nil,
        viewed: Set<String>? = nil,
        message: String? = nil
    ) {
        // Revalidation is idempotent: anchors are recomputed against the new
        // diff, so stale legacy drafts become orphans and reappearing anchors
        // automatically reattach.
        let validated = DraftAnchorValidator.revalidated(drafts ?? model.drafts, against: bundle.files)
        model.pr = bundle.pr
        model.headOID = bundle.pr.headRefOid
        model.files = bundle.files
        model.threads = bundle.threads
        model.drafts = validated
        if let viewed {
            model.viewed = viewed
        }
        model.selectedFile = min(model.selectedFile, max(0, model.files.count - 1))
        model.rebuildRows()
        model.dirty = true
        if let message {
            model.setMessage(message)
        }
    }

    /// Head-SHA migration (Phase 3, now via `ReviewOperations`). Runs off the
    /// main tick against a snapshot taken at drain time; it never mutates the
    /// model. The returned outcome is delivered back to `drainPending` and
    /// applied on the main tick, so a superseding fetch simply drops the
    /// (stale) result.
    private func migrateFetch(
        snapshot: (endpoint: PREndpoint?, headSHA: String, drafts: [DraftComment], viewed: Set<String>),
        bundle: FetchBundle
    ) async -> Outcome {
        guard let endpoint = snapshot.endpoint, !model.isDemo, let operations else {
            return .fetchApplied(bundle, snapshot.drafts, snapshot.viewed, "Refreshed.")
        }
        do {
            let result = try await operations.migrate(
                bundle: bundle,
                endpoint: endpoint,
                current: ReviewLocalState(
                    headSHA: snapshot.headSHA,
                    drafts: snapshot.drafts,
                    viewed: snapshot.viewed
                )
            )
            return .fetchApplied(
                result.bundle,
                result.localState.drafts,
                result.localState.viewed,
                result.message
            )
        } catch is CancellationError {
            return .migrationFailed("cancelled while preserving local state.")
        } catch {
            return .migrationFailed("local state could not be preserved: \(error)")
        }
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
        let wasResolved = t.isResolved
        if let idx = model.threads.firstIndex(where: { $0.id == id }) {
            model.threads[idx].isResolved = newState
        }
        model.rebuildRows()
        guard !model.isDemo, let operations, let ep = model.endpoint else {
            model.setMessage("Demo: resolve toggled locally.")
            return
        }
        launch(.resolve(threadID: id)) {
            do {
                try await operations.setResolved(endpoint: ep, threadID: id, resolved: newState)
                return .resolveDone
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .resolveFailed(threadID: id, wasResolved: wasResolved, error: error)
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
            guard let operations, let ep = model.endpoint else { return }
            launch(.reply(threadID: threadID)) {
                do {
                    try await operations.reply(endpoint: ep, commentID: commentID, body: trimmed)
                    return .replyDone
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return .replyFailed(error)
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
        // Only submittable (non-orphaned) drafts participate in a review.
        let drafts = model.drafts.filter { !$0.isOrphaned }
        model.mode = .normal
        model.composerError = nil
        if event == .approve && body.isEmpty && !drafts.isEmpty {
            model.composerError = "Approvals with inline comments usually include a summary."
            model.mode = .compose
            return
        }
        if model.isDemo {
            model.drafts.removeAll { !$0.isOrphaned }
            persistDrafts()
            model.rebuildRows()
            model.setMessage("Demo mode — review not submitted.")
            return
        }
        guard let operations, let ep = model.endpoint else {
            model.setMessage("Not connected to GitHub.", isError: true)
            return
        }
        model.setMessage("Submitting review…")
        let commitID = model.headOID
        let eventValue = event
        launch(.submit) {
            do {
                let result = try await operations.submit(
                    endpoint: ep, headSHA: commitID, body: body,
                    event: eventValue, drafts: drafts
                )
                return .submitDone(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .submitFailed(error)
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

    /// Persists the current drafts asynchronously. Failures surface through a
    /// `.persistenceFailed` outcome (durable `persistenceFailure` + message)
    /// applied on the main tick.
    private func persistDrafts(_ drafts: [DraftComment]? = nil) {
        guard !model.isDemo, let ep = model.endpoint, !model.headOID.isEmpty else { return }
        let toSave = drafts ?? model.drafts
        let headSHA = model.headOID
        let token = tracker.begin(.persistence)
        Task { [weak self] in
            do {
                try await self?.persistence.saveDrafts(toSave, for: ep, headSHA: headSHA)
                self?.deliver(token, .persistenceSaved)
            } catch is CancellationError {
                self?.discard(token)
            } catch {
                self?.deliver(token, .persistenceFailed(operation: "drafts", error))
            }
        }
    }

    private func persistViewed() {
        guard !model.isDemo, let ep = model.endpoint, !model.headOID.isEmpty else { return }
        let toSave = model.viewed
        let headSHA = model.headOID
        let token = tracker.begin(.persistence)
        Task { [weak self] in
            do {
                try await self?.persistence.saveViewed(toSave, for: ep, headSHA: headSHA)
                self?.deliver(token, .persistenceSaved)
            } catch is CancellationError {
                self?.discard(token)
            } catch {
                self?.deliver(token, .persistenceFailed(operation: "viewed", error))
            }
        }
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
        model.setMessage("Refreshing…")
        launch(.fetch) {
            do {
                return .fetch(try await client.fetchAll(ep))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .fetchFailed(error)
            }
        }
    }

    /// Cancels the in-flight fetch, if any. No error is shown; the loading
    /// indicator clears once the cancelled task unwinds.
    public func cancelFetch() {
        tracker.cancelFetch()
    }

    private func yankLine() {
        guard model.focus == .diff, let info = model.cursorLineInfo(),
              let file = model.currentFile else { return }
        let line = info.line
        let num = line.newLine ?? line.oldLine ?? 0
        let text = "\(file.path):\(num) \(line.content)"
        do {
            try clipboard.write(text)
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
