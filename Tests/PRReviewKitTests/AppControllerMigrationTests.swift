import XCTest
@testable import PRReviewKit

/// Serves queued fetch bundles, one per refresh.
private final class QueueService: GitHubServing {
    private let lock = NSLock()
    private var bundles: [FetchBundle]
    private var next = 0

    init(_ bundles: [FetchBundle]) {
        self.bundles = bundles
    }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }

    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        lock.lock()
        let idx = min(next, max(0, bundles.count - 1))
        next += 1
        lock.unlock()
        return bundles[idx]
    }

    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
}

final class AppControllerMigrationTests: XCTestCase {

    private let ep = PREndpoint(owner: "o", repo: "r", number: 1)

    /// Standard diff: RIGHT lines 1 (keep1), 2 (new2), 3 (new3); LEFT line 2 (old2).
    private let diffWithLine2 = """
    diff --git a/Src.swift b/Src.swift
    --- a/Src.swift
    +++ b/Src.swift
    @@ -1,3 +1,4 @@
     keep1
    -old2
    +new2
    +new3
    """

    /// Diff where RIGHT line 2 does not exist (only new line 1).
    private let diffWithoutLine2 = """
    diff --git a/Src.swift b/Src.swift
    --- a/Src.swift
    +++ b/Src.swift
    @@ -1,1 +1,1 @@
     keep1
    """

    private func bundle(sha: String, diff: String) -> FetchBundle {
        FetchBundle(
            pr: PRInfo(
                number: 1, title: "t", body: nil, author: "a", state: "OPEN",
                isDraft: false, headRefOid: sha, headRefName: "h", baseRefName: "b",
                additions: 1, deletions: 1, changedFiles: 1, reviewDecision: nil,
                url: "https://github.com/o/r/pull/1"
            ),
            files: DiffParser.parse(diff),
            threads: []
        )
    }

    private func makeController(
        persistence: InMemoryReviewPersistence,
        service: GitHubServing,
        headSHA: String = "",
        drafts: [DraftComment] = [],
        viewed: Set<String> = []
    ) -> AppController {
        let model = AppModel()
        model.endpoint = ep
        model.headOID = headSHA
        model.drafts = drafts
        model.viewed = viewed
        return AppController(model: model, client: service, persistence: persistence)
    }

    private func drainUntil(_ controller: AppController, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            controller.drainPending()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Head-SHA migration

    func testOldHeadStateIsPersistedBeforeMigration() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [draft], viewed: ["Src.swift"]
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        XCTAssertEqual(persistence.savedDrafts(for: ep, sha: "oldsha"), [draft])
        XCTAssertEqual(persistence.savedViewed(for: ep, sha: "oldsha"), ["Src.swift"])
    }

    func testMissingNewHeadStateCopiesOldDraftsWithSameUUIDs() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [draft], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        let copied = persistence.savedDrafts(for: ep, sha: "newsha")
        XCTAssertEqual(copied?.first?.id, draft.id, "UUIDs must be preserved when copying")
        XCTAssertEqual(copied?.first?.body, "note")
        XCTAssertEqual(controller.model.drafts.first?.id, draft.id)
        XCTAssertEqual(controller.model.drafts.first?.isOrphaned, false, "valid anchor stays attached")
    }

    func testExistingNewHeadStateIsNotOverwritten() async {
        let persistence = InMemoryReviewPersistence()
        let existing = DraftComment(path: "Src.swift", line: 3, side: "RIGHT", body: "already here")
        try? await persistence.saveDrafts([existing], for: ep, headSHA: "newsha")
        let oldDraft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "old")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [oldDraft], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        XCTAssertEqual(controller.model.drafts.map(\.id), [existing.id], "existing new-head state wins")
        XCTAssertEqual(persistence.savedDrafts(for: ep, sha: "newsha")?.map(\.id), [existing.id])
    }

    func testInvalidAnchorsBecomeOrphaned() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [draft], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        XCTAssertEqual(controller.model.drafts.first?.isOrphaned, true)
        // Orphaned drafts surface in the dedicated orphan section, not attached.
        XCTAssertTrue(controller.model.fileRows.contains(.orphanedHeader))
        XCTAssertFalse(controller.model.fileRows.dropLast().contains(.draft(draftID: draft.id)))
    }

    func testOrphanReattachesWhenAnchorReturns() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([
                bundle(sha: "b1", diff: diffWithoutLine2),   // line 2 missing → orphan
                bundle(sha: "b2", diff: diffWithLine2),      // line 2 back → reattach
            ]),
            headSHA: "oldsha", drafts: [draft], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "b1" }
        XCTAssertEqual(controller.model.drafts.first?.isOrphaned, true)

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "b2" }
        XCTAssertEqual(controller.model.drafts.first?.isOrphaned, false, "anchor returned; draft reattached")
    }

    func testViewedMarksResetForNewHead() async {
        let persistence = InMemoryReviewPersistence()
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [], viewed: ["a.swift", "b.swift"]
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        XCTAssertEqual(persistence.savedViewed(for: ep, sha: "newsha"), [])
        XCTAssertTrue(controller.model.viewed.isEmpty)
    }

    func testMigrationStatusBannerSurvivesFetchApplication() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [draft], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "newsha" }

        XCTAssertEqual(controller.model.message?.text, "Head changed. Drafts migrated to the new head.")
    }

    func testSaveFailureLeavesModelIntactAndReportsDurableFailure() async {
        let persistence = InMemoryReviewPersistence()
        persistence.failure = PersistenceError.saveFailed("disk full")
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "newsha", diff: diffWithLine2)]),
            headSHA: "oldsha", drafts: [draft], viewed: ["a.swift"]
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.persistenceFailure != nil }

        // Old review state is preserved; nothing was applied.
        XCTAssertEqual(controller.model.headOID, "oldsha")
        XCTAssertEqual(controller.model.drafts.map(\.id), [draft.id])
        XCTAssertTrue(controller.model.message?.isError ?? false)
        XCTAssertEqual(controller.model.persistenceFailure?.operation, "refresh")
    }

    // MARK: - First load and same-SHA

    func testFirstLoadUsesPersistedStateForTheFetchedHead() async {
        let persistence = InMemoryReviewPersistence()
        let saved = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "saved")
        try? await persistence.saveDrafts([saved], for: ep, headSHA: "firstsha")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "firstsha", diff: diffWithLine2)]),
            headSHA: "", drafts: [], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "firstsha" }

        XCTAssertEqual(controller.model.drafts.map(\.id), [saved.id])
        XCTAssertEqual(controller.model.drafts.first?.isOrphaned, false)
    }

    func testFirstLoadRestoresPersistedViewedMarks() async {
        let persistence = InMemoryReviewPersistence()
        try? await persistence.saveViewed(["a.swift", "b.swift"], for: ep, headSHA: "firstsha")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "firstsha", diff: diffWithLine2)]),
            headSHA: "", drafts: [], viewed: []
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.headOID == "firstsha" }

        XCTAssertEqual(controller.model.viewed, ["a.swift", "b.swift"])
    }

    func testSameShaKeepsInMemoryDrafts() async {
        let persistence = InMemoryReviewPersistence()
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let controller = makeController(
            persistence: persistence,
            service: QueueService([bundle(sha: "same", diff: diffWithLine2)]),
            headSHA: "same", drafts: [draft], viewed: ["a.swift"]
        )

        controller.refresh()
        await drainUntil(controller) { controller.model.pr != nil }

        XCTAssertEqual(controller.model.drafts.map(\.id), [draft.id])
        XCTAssertEqual(controller.model.viewed, ["a.swift"])
    }
}
