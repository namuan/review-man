import XCTest
@testable import PRReviewKit

/// Captures clipboard writes instead of spawning `pbcopy`.
private final class FakeClipboard: ClipboardWriting {
    var written: [String] = []
    var error: Error?

    func write(_ text: String) throws {
        if let error { throw error }
        written.append(text)
    }
}

final class AppControllerTests: XCTestCase {

    private func makeModel() -> AppModel {
        let model = AppModel()
        model.endpoint = PREndpoint(owner: "o", repo: "r", number: 1)
        model.files = DiffParser.parse("""
        diff --git a/Src.swift b/Src.swift
        --- a/Src.swift
        +++ b/Src.swift
        @@ -1,3 +1,4 @@
         keep1
        -old2
        +new2
        +new3
        """)
        model.rebuildRows()
        return model
    }

    // MARK: - Clipboard

    /// The yank contract is the exact text `path:line content` (line content
    /// without its diff prefix). RIGHT lines use the new line number, LEFT
    /// (removed) lines use the old line number.
    func testYankWritesExactPathLineAndContentForRightAndLeftLines() {
        let model = makeModel()
        model.focus = .diff
        let clipboard = FakeClipboard()
        let controller = AppController(model: model, client: nil, clipboard: clipboard)

        // Row layout: 0 hunkHeader, 1 keep1, 2 old2, 3 new2, 4 new3.
        model.cursorRow = 3 // added "new2" -> RIGHT, new line 2
        controller.handle(.char("y"), screenW: 100, screenH: 40)
        XCTAssertEqual(clipboard.written.last, "Src.swift:2 new2")

        model.cursorRow = 2 // removed "old2" -> LEFT, old line 2
        controller.handle(.char("y"), screenW: 100, screenH: 40)
        XCTAssertEqual(clipboard.written.last, "Src.swift:2 old2")
    }

    // MARK: - Fetch application and draft revalidation

    /// Applying a fetch revalidates drafts against the new diff: valid anchors
    /// stay attached, invalid anchors become orphans in their own section.
    func testApplyFetchRevalidatesDraftsAgainstNewDiff() {
        let model = makeModel()
        model.headOID = "oldsha"
        let valid = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "valid")
        let invalid = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost")
        model.drafts = [valid, invalid]
        model.viewed = ["Src.swift"]

        let controller = AppController(model: model, client: nil)
        let newPR = PRInfo(
            number: 1, title: "retitled", body: nil, author: "a", state: "OPEN",
            isDraft: false, headRefOid: "newsha", headRefName: "h", baseRefName: "b",
            additions: 1, deletions: 0, changedFiles: 1, reviewDecision: nil,
            url: "https://github.com/o/r/pull/1"
        )
        controller.applyFetch(FetchBundle(pr: newPR, files: model.files, threads: []))

        XCTAssertEqual(model.headOID, "newsha")
        XCTAssertEqual(model.pr?.title, "retitled")
        XCTAssertEqual(model.drafts[0].id, valid.id)
        XCTAssertEqual(model.drafts[0].isOrphaned, false, "valid anchor stays attached")
        XCTAssertEqual(model.drafts[1].id, invalid.id)
        XCTAssertEqual(model.drafts[1].isOrphaned, true, "invalid anchor becomes orphaned")
        XCTAssertTrue(model.fileRows.contains(.orphanedHeader))
        XCTAssertFalse(model.fileRows.dropLast().contains(.draft(draftID: invalid.id)))
    }

    // MARK: - Resolve rollback

    /// A failed resolve mutation must roll the optimistic toggle back, rebuild
    /// rows, and surface an error message.
    func testResolveFailureRollsBackOptimisticThreadStateAndRebuildsRows() {
        let model = makeModel()
        let thread = PRThread(
            id: "t1", path: "Src.swift", line: 2, originalLine: 2, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: true,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
        model.threads = [thread]
        model.rebuildRows()

        let controller = AppController(model: model, client: nil)
        controller.applyOutcome(.resolveFailed(
            threadID: "t1", wasResolved: false, error: GitHubError.api("boom")
        ))

        XCTAssertEqual(model.threads[0].isResolved, false)
        XCTAssertTrue(model.fileRows.contains(.thread(threadID: "t1")))
        XCTAssertEqual(model.message?.isError, true)
        XCTAssertTrue(model.message?.text.contains("Resolve failed") ?? false)
    }

    // MARK: - CLI bootstrap model loading

    private let ep = PREndpoint(owner: "o", repo: "r", number: 1)

    private func makePRInfo(sha: String = "sha") -> PRInfo {
        PRInfo(
            number: 1, title: "t", body: nil, author: "a", state: "OPEN",
            isDraft: false, headRefOid: sha, headRefName: "h", baseRefName: "b",
            additions: 1, deletions: 1, changedFiles: 1, reviewDecision: nil,
            url: "https://github.com/o/r/pull/1"
        )
    }

    /// Restored drafts are validated at bootstrap: invalid anchors become
    /// orphans (and are excluded from submission), valid ones stay attached.
    func testMakeModelValidatesRestoredDrafts() async {
        let persistence = InMemoryReviewPersistence()
        let valid = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "ok")
        let invalid = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost")
        try? await persistence.saveDrafts([valid, invalid], for: ep, headSHA: "sha")

        let model = await PRReviewCLI.makeModel(
            endpoint: ep, pr: makePRInfo(), files: makeModel().files, threads: [],
            persistence: persistence
        )

        XCTAssertEqual(model.drafts.count, 2)
        XCTAssertEqual(model.drafts[0].id, valid.id)
        XCTAssertEqual(model.drafts[0].isOrphaned, false)
        XCTAssertEqual(model.drafts[1].id, invalid.id)
        XCTAssertEqual(model.drafts[1].isOrphaned, true)
    }

    /// A local-state load failure resets BOTH drafts and viewed marks (no
    /// partial restore) and records the durable failure.
    func testMakeModelLoadFailureResetsAllLocalState() async {
        let persistence = InMemoryReviewPersistence()
        persistence.failure = PersistenceError.loadFailed("boom")

        let model = await PRReviewCLI.makeModel(
            endpoint: ep, pr: makePRInfo(), files: makeModel().files, threads: [],
            persistence: persistence
        )

        XCTAssertTrue(model.drafts.isEmpty)
        XCTAssertTrue(model.viewed.isEmpty)
        XCTAssertEqual(model.persistenceFailure?.operation, "load")
        XCTAssertTrue(model.persistenceFailure?.message.contains("boom") ?? false)
    }
}
