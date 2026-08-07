import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

/// Incremental-update semantics of `ReviewPresentation`: local mutations
/// (viewed toggles, draft changes, resolve/reply) must rebuild only the parts
/// that changed — never the whole snapshot — while keeping every derived index
/// (`rowsByFile`, `diffRowsByFile`, `fileIndexByPath`, `threadByID`,
/// `draftByID`, sidebar counts) consistent.
final class ReviewPresentationMutationTests: XCTestCase {

    private let twoFileDiff = """
    diff --git a/A.swift b/A.swift
    --- a/A.swift
    +++ b/A.swift
    @@ -1,3 +1,4 @@
     keep1
    -old2
    +new2
    +new3

    diff --git a/B.swift b/B.swift
    --- a/B.swift
    +++ b/B.swift
    @@ -1,2 +1,2 @@
     keepB1
    -oldB
    +newB
    """

    private func makePresentation(drafts: [DraftComment] = [], threads: [PRThread] = []) -> ReviewPresentation {
        ReviewPresentation(
            endpoint: nil, pr: nil,
            files: DiffParser.parse(twoFileDiff),
            threads: threads, drafts: drafts, viewed: []
        )
    }

    private func thread(id: String, path: String = "A.swift", line: Int = 2) -> PRThread {
        PRThread(
            id: id, path: path, line: line, originalLine: line, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
    }

    /// A thread with one comment per listed author, so "hide by any author"
    /// semantics are exercisable (an author can appear as a reply, not just
    /// the root commenter).
    private func threadWithAuthors(
        id: String, path: String = "A.swift", line: Int = 2, authors: [String], outdated: Bool = false
    ) -> PRThread {
        PRThread(
            id: id, path: path, line: outdated ? nil : line, originalLine: line, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: outdated, isResolved: false,
            comments: authors.enumerated().map { i, author in
                PRComment(databaseId: i + 1, author: author, body: "hi from \(author)", createdAt: Date())
            }
        )
    }

    // MARK: - withViewed

    func testWithViewedChangesOnlySidebarFlags() {
        let original = makePresentation()
        let updated = original.withViewed(["A.swift"])

        XCTAssertEqual(updated.viewed, ["A.swift"])
        XCTAssertEqual(updated.sidebarItems.first { $0.path == "A.swift" }?.isViewed, true)
        XCTAssertEqual(updated.sidebarItems.first { $0.path == "B.swift" }?.isViewed, false)
        // Rows and display rows are untouched by a viewed toggle.
        XCTAssertEqual(updated.rowsByFile, original.rowsByFile)
        XCTAssertEqual(updated.diffRowsByFile, original.diffRowsByFile)
        XCTAssertEqual(updated.pathlessOrphanIDs, original.pathlessOrphanIDs)
        XCTAssertEqual(updated.draftByID, original.draftByID)
        XCTAssertEqual(updated.threadByID, original.threadByID)
    }

    func testWithViewedTogglingOffRestoresFlag() {
        let original = makePresentation()
        let on = original.withViewed(["A.swift", "B.swift"])
        let off = on.withViewed(["A.swift"])
        XCTAssertEqual(off.sidebarItems.first { $0.path == "B.swift" }?.isViewed, false)
        XCTAssertEqual(off.sidebarItems.first { $0.path == "A.swift" }?.isViewed, true)
    }

    // MARK: - withDrafts

    func testWithDraftsRebuildsOnlyAffectedFileRows() {
        let original = makePresentation()
        let draft = DraftComment(path: "A.swift", line: 2, side: "RIGHT", body: "comment")
        let updated = original.withDrafts([draft])

        XCTAssertEqual(updated.drafts, [draft])
        XCTAssertEqual(updated.draftByID[draft.id], draft)

        // B.swift rows must be byte-for-byte identical (unaffected file).
        XCTAssertEqual(updated.rowsByFile["B.swift"], original.rowsByFile["B.swift"])
        XCTAssertEqual(updated.diffRowsByFile["B.swift"], original.diffRowsByFile["B.swift"])

        // A.swift rows gained the draft card after its anchor line.
        let aRows = updated.rowsByFile["A.swift"]!
        let lineIdx = aRows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 2))!
        XCTAssertEqual(aRows[lineIdx + 1], .draft(draftID: draft.id))

        // Sidebar thread count for A.swift increments; B.swift stays 0.
        XCTAssertEqual(updated.sidebarItems.first { $0.path == "A.swift" }?.threadCount, 1)
        XCTAssertEqual(updated.sidebarItems.first { $0.path == "B.swift" }?.threadCount, 0)
    }

    func testWithDraftsRemovingDraftRebuildsAffectedRows() {
        let draft = DraftComment(path: "A.swift", line: 2, side: "RIGHT", body: "comment")
        let original = makePresentation(drafts: [draft])
        let updated = original.withDrafts([])

        XCTAssertTrue(updated.drafts.isEmpty)
        XCTAssertNil(updated.draftByID[draft.id])
        // Removing the draft returns A.swift rows to the no-draft layout.
        XCTAssertFalse(updated.rowsByFile["A.swift"]!.contains(.draft(draftID: draft.id)))
        XCTAssertEqual(updated.sidebarItems.first { $0.path == "A.swift" }?.threadCount, 0)
    }

    func testWithDraftsPathlessOrphansAttachToLastFile() {
        let original = makePresentation()
        let orphan = DraftComment(path: "vanished.swift", line: 1, side: "RIGHT", body: "lost", isOrphaned: true)
        let updated = original.withDrafts([orphan])

        XCTAssertEqual(updated.pathlessOrphanIDs, [orphan.id])
        let lastRows = updated.rowsByFile["B.swift"]!
        XCTAssertTrue(lastRows.contains(.orphanedHeader))
        XCTAssertTrue(lastRows.contains(.draft(draftID: orphan.id)))
        // Removing it restores the last file's rows.
        let restored = updated.withDrafts([])
        XCTAssertTrue(restored.pathlessOrphanIDs.isEmpty)
        XCTAssertFalse(restored.rowsByFile["B.swift"]!.contains(.orphanedHeader))
    }

    // MARK: - withThread

    func testWithThreadResolveDoesNotRebuildRows() {
        let t = thread(id: "t1")
        let original = makePresentation(threads: [t])
        var resolved = t
        resolved.isResolved = true
        let updated = original.withThread(resolved)

        XCTAssertEqual(updated.threadByID["t1"]?.isResolved, true)
        XCTAssertEqual(updated.threads.first?.isResolved, true)
        // Resolving changes no rows: identical arrays, same file count.
        XCTAssertEqual(updated.rowsByFile, original.rowsByFile)
        XCTAssertEqual(updated.diffRowsByFile, original.diffRowsByFile)
    }

    func testWithThreadReplyRebuildsFileRowsAndPreservesIndexes() {
        let t = thread(id: "t1")
        let original = makePresentation(threads: [t])
        var replied = t
        replied.comments.append(PRComment(databaseId: 2, author: "you", body: "reply", createdAt: Date()))
        let updated = original.withThread(replied)

        XCTAssertEqual(updated.threadByID["t1"]?.comments.count, 2)
        XCTAssertEqual(updated.threads.count, 1)
        // Unaffected file B rows identical.
        XCTAssertEqual(updated.rowsByFile["B.swift"], original.rowsByFile["B.swift"])
        // Indexes stay consistent.
        XCTAssertEqual(updated.fileIndexByPath, original.fileIndexByPath)
        XCTAssertEqual(updated.draftByID, original.draftByID)
        XCTAssertEqual(updated.sidebarItems, original.sidebarItems)
    }

    func testWithThreadUnknownIDReturnsSelf() {
        let original = makePresentation(threads: [thread(id: "t1")])
        let updated = original.withThread(thread(id: "missing"))
        XCTAssertEqual(updated.threads, original.threads)
    }

    /// Pathless orphans surface on the LAST file's rows; a reply on that file
    /// rebuilds its rows and must re-attach them.
    func testWithThreadReplyOnLastFileKeepsPathlessOrphans() {
        let orphan = DraftComment(path: "vanished.swift", line: 1, side: "RIGHT", body: "lost", isOrphaned: true)
        let t = thread(id: "t1", path: "B.swift", line: 2)
        let original = makePresentation(drafts: [orphan], threads: [t])
        XCTAssertTrue(original.rowsByFile["B.swift"]!.contains(.draft(draftID: orphan.id)))

        var replied = t
        replied.comments.append(PRComment(databaseId: 2, author: "you", body: "reply", createdAt: Date()))
        let updated = original.withThread(replied)

        let lastRows = updated.rowsByFile["B.swift"]!
        XCTAssertTrue(lastRows.contains(.orphanedHeader))
        XCTAssertTrue(lastRows.contains(.draft(draftID: orphan.id)), "reply rebuild must re-attach pathless orphans")
        XCTAssertEqual(updated.pathlessOrphanIDs, [orphan.id])
    }

    // MARK: - withHiddenReviewers

    func testWithHiddenReviewersHidesThreadsByAnyAuthor() {
        // jane is a REPLY author on t1, not the root commenter: hiding her
        // must still hide the whole thread.
        let janeReply = threadWithAuthors(id: "t1", line: 2, authors: ["bob", "jane"])
        let bobThread = threadWithAuthors(id: "t2", line: 3, authors: ["bob"])
        let carolThread = threadWithAuthors(id: "t3", path: "B.swift", line: 1, authors: ["carol"])
        let original = makePresentation(threads: [janeReply, bobThread, carolThread])

        let hidden = original.withHiddenReviewers(["jane"])

        XCTAssertFalse(hidden.rows(for: "A.swift").contains(.thread(threadID: "t1")), "reply authorship hides the thread")
        XCTAssertTrue(hidden.rows(for: "A.swift").contains(.thread(threadID: "t2")), "unrelated thread stays")
        XCTAssertTrue(hidden.rows(for: "B.swift").contains(.thread(threadID: "t3")), "other file untouched")
        XCTAssertEqual(hidden.sidebarItems.first { $0.path == "A.swift" }?.threadCount, 1)
        XCTAssertEqual(hidden.sidebarItems.first { $0.path == "B.swift" }?.threadCount, 1)
        // The full list and lookup keep hidden threads: unhide, resolve, and
        // reply workflows still need them.
        XCTAssertEqual(hidden.threads.count, 3)
        XCTAssertNotNil(hidden.threadByID["t1"])
        XCTAssertEqual(hidden.hiddenReviewers, ["jane"])
    }

    func testWithHiddenReviewersUnhideRestoresThreads() {
        let original = makePresentation(threads: [threadWithAuthors(id: "t1", authors: ["jane"])])
        let hidden = original.withHiddenReviewers(["jane"])
        XCTAssertFalse(hidden.rows(for: "A.swift").contains(.thread(threadID: "t1")))

        let restored = hidden.withHiddenReviewers([])
        XCTAssertTrue(restored.rows(for: "A.swift").contains(.thread(threadID: "t1")))
        XCTAssertEqual(restored.sidebarItems.first { $0.path == "A.swift" }?.threadCount, 1)
        XCTAssertTrue(restored.hiddenReviewers.isEmpty)
    }

    func testWithHiddenReviewersRebuildsOnlyAffectedFiles() {
        let janeA = threadWithAuthors(id: "t1", authors: ["jane"])
        let carolB = threadWithAuthors(id: "t2", path: "B.swift", authors: ["carol"])
        let original = makePresentation(threads: [janeA, carolB])

        let hidden = original.withHiddenReviewers(["jane"])

        XCTAssertNotEqual(hidden.rowsByFile["A.swift"], original.rowsByFile["A.swift"])
        XCTAssertEqual(hidden.rowsByFile["B.swift"], original.rowsByFile["B.swift"], "untouched file reuses its rows")
        XCTAssertEqual(hidden.diffRowsByFile["B.swift"], original.diffRowsByFile["B.swift"])
    }

    func testWithHiddenReviewersUnchangedSetIsNoop() {
        let original = makePresentation(threads: [threadWithAuthors(id: "t1", authors: ["jane"])])
        let same = original.withHiddenReviewers([])
        XCTAssertEqual(same.hiddenReviewers, original.hiddenReviewers)
        XCTAssertEqual(same.rowsByFile, original.rowsByFile)
        XCTAssertEqual(same.sidebarItems, original.sidebarItems)
    }

    func testWithHiddenReviewersHidesOutdatedThreadsToo() {
        let outdated = threadWithAuthors(id: "t1", authors: ["jane"], outdated: true)
        let original = makePresentation(threads: [outdated])
        let hidden = original.withHiddenReviewers(["jane"])
        XCTAssertFalse(hidden.rows(for: "A.swift").contains(.thread(threadID: "t1")))
        XCTAssertEqual(hidden.sidebarItems.first { $0.path == "A.swift" }?.threadCount, 0)
    }

    /// Incremental updates keep applying the hidden filter whenever rows are
    /// rebuilt (drafts added, replies received).
    func testWithDraftsAndWithThreadRespectActiveHiddenSet() {
        let jane = threadWithAuthors(id: "t1", authors: ["jane"])
        let hidden = makePresentation(threads: [jane]).withHiddenReviewers(["jane"])

        let draft = DraftComment(path: "A.swift", line: 2, side: "RIGHT", body: "d")
        let withDraft = hidden.withDrafts([draft])
        XCTAssertFalse(withDraft.rows(for: "A.swift").contains(.thread(threadID: "t1")))
        XCTAssertTrue(withDraft.rows(for: "A.swift").contains(.draft(draftID: draft.id)))

        var replied = jane
        replied.comments.append(PRComment(databaseId: 9, author: "carol", body: "r", createdAt: Date()))
        let withReply = hidden.withThread(replied)
        XCTAssertFalse(withReply.rows(for: "A.swift").contains(.thread(threadID: "t1")), "reply rebuild keeps the thread hidden")
    }

    // MARK: - Indexes built by the full initializer

    func testFullBuildProducesConsistentIndexes() {
        let draft = DraftComment(path: "A.swift", line: 2, side: "RIGHT", body: "c")
        let t = thread(id: "t1")
        let presentation = makePresentation(drafts: [draft], threads: [t])

        XCTAssertEqual(presentation.fileIndexByPath["A.swift"], 0)
        XCTAssertEqual(presentation.fileIndexByPath["B.swift"], 1)
        XCTAssertEqual(presentation.threadByID["t1"], t)
        XCTAssertEqual(presentation.draftByID[draft.id], draft)
        XCTAssertEqual(presentation.diffRows(for: presentation.files[0]).count,
                       presentation.rows(for: "A.swift").count)
    }

    // MARK: - Sidebar searchable

    func testSidebarSearchableIsPrecomputed() {
        let presentation = makePresentation()
        let item = presentation.sidebarItems[0]
        XCTAssertEqual(item.searchable, "a.swift", "searchable is the lowercased path")
    }
}
