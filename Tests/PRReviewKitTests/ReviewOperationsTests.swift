import XCTest
@testable import PRReviewKit

/// Records service calls and can inject failures.
private final class RecordingService: GitHubServing {
    var bundle: FetchBundle?
    var fetchError: Error?
    private(set) var submitCalls: [(commitID: String, event: String, draftCount: Int)] = []
    private(set) var replyCalls: [(commentID: Int, body: String)] = []
    private(set) var resolveCalls: [(id: String, resolved: Bool)] = []
    var resolveError: Error?

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }
    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        if let fetchError { throw fetchError }
        return bundle ?? FetchBundle(pr: makePRInfo(), files: [], threads: [])
    }
    func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {
        submitCalls.append((commitID, event, drafts.count))
    }
    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {
        replyCalls.append((commentID, body))
    }
    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {
        if let resolveError { throw resolveError }
        resolveCalls.append((threadID, resolved))
    }
}

private final class MemoryPersistence: ReviewPersisting {
    private var stateByKey: [String: PersistedDraftState] = [:]
    private var viewedByKey: [String: Set<String>] = [:]
    private var hiddenByPR: [String: Set<String>] = [:]
    var failOnSave = false
    private(set) var savedDraftCounts: [Int] = []

    private func key(_ ep: PREndpoint, _ sha: String) -> String {
        "\(ep.owner)/\(ep.repo)#\(ep.number)@\(sha)"
    }

    private func prKey(_ ep: PREndpoint) -> String {
        "\(ep.owner)/\(ep.repo)#\(ep.number)"
    }

    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState {
        stateByKey[key(endpoint, headSHA)] ?? .missing
    }
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {
        if failOnSave { throw PersistenceError.saveFailed("injected") }
        savedDraftCounts.append(drafts.count)
        stateByKey[key(endpoint, headSHA)] = .present(drafts)
    }
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> {
        viewedByKey[key(endpoint, headSHA)] ?? []
    }
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {
        if failOnSave { throw PersistenceError.saveFailed("injected") }
        viewedByKey[key(endpoint, headSHA)] = viewed
    }
    func loadHiddenReviewers(for endpoint: PREndpoint) async throws -> Set<String> {
        hiddenByPR[prKey(endpoint)] ?? []
    }
    func saveHiddenReviewers(_ hidden: Set<String>, for endpoint: PREndpoint) async throws {
        if failOnSave { throw PersistenceError.saveFailed("injected") }
        hiddenByPR[prKey(endpoint)] = hidden
    }

    func setDraftState(_ state: PersistedDraftState, endpoint: PREndpoint, sha: String) {
        stateByKey[key(endpoint, sha)] = state
    }

    func setHiddenReviewers(_ hidden: Set<String>, endpoint: PREndpoint) {
        hiddenByPR[prKey(endpoint)] = hidden
    }
}

private func makePRInfo(sha: String = "sha") -> PRInfo {
    PRInfo(number: 1, title: "t", body: nil, author: "a", state: "OPEN", isDraft: false,
           headRefOid: sha, headRefName: "h", baseRefName: "b",
           additions: 1, deletions: 1, changedFiles: 1, reviewDecision: nil, url: "https://github.com/o/r/pull/1")
}

private let sampleDiff = """
diff --git a/Src.swift b/Src.swift
--- a/Src.swift
+++ b/Src.swift
@@ -1,3 +1,4 @@
 keep1
-old2
+new2
+new3
"""

final class ReviewOperationsTests: XCTestCase {

    private let ep = PREndpoint(owner: "o", repo: "r", number: 1)

    // MARK: - Migration

    func testChangedHeadCopiesOldDraftsAndResetsViewed() async throws {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "new"), files: DiffParser.parse(sampleDiff), threads: [])
        let persistence = MemoryPersistence()
        let ops = ReviewOperations(service: service, persistence: persistence)

        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let result = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(headSHA: "old", drafts: [draft], viewed: ["a.swift"])
        )

        XCTAssertEqual(result.bundle.pr.headRefOid, "new")
        XCTAssertEqual(result.localState.drafts.first?.id, draft.id, "old drafts copied with same UUID")
        XCTAssertEqual(result.localState.drafts.first?.isOrphaned, false, "valid anchor stays attached")
        XCTAssertTrue(result.localState.viewed.isEmpty, "viewed marks reset for the new head")
        XCTAssertTrue(persistence.savedDraftCounts.contains(1), "old-head drafts were persisted")
    }

    func testSameHeadKeepsInMemoryDrafts() async throws {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "sha"), files: DiffParser.parse(sampleDiff), threads: [])
        let persistence = MemoryPersistence()
        let ops = ReviewOperations(service: service, persistence: persistence)

        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")
        let result = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(headSHA: "sha", drafts: [draft], viewed: ["x"])
        )
        XCTAssertEqual(result.localState.drafts, [draft])
        XCTAssertEqual(result.localState.viewed, ["x"])
    }

    // MARK: - Hidden reviewers (PR-scoped)

    func testFirstLoadRestoresHiddenReviewers() async throws {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "new"), files: [], threads: [])
        let persistence = MemoryPersistence()
        persistence.setHiddenReviewers(["jane"], endpoint: ep)
        let ops = ReviewOperations(service: service, persistence: persistence)

        let result = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(headSHA: "", drafts: [], viewed: [])
        )
        XCTAssertEqual(result.localState.hiddenReviewers, ["jane"])
    }

    func testHeadChangeKeepsHiddenReviewers() async throws {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "new"), files: [], threads: [])
        let persistence = MemoryPersistence()
        let ops = ReviewOperations(service: service, persistence: persistence)

        let result = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(
                headSHA: "old", drafts: [], viewed: [], hiddenReviewers: ["jane"]
            )
        )
        XCTAssertEqual(
            result.localState.hiddenReviewers, ["jane"],
            "PR-scoped hidden reviewers survive a head change (unlike viewed marks)"
        )
    }

    func testMigrationSaveFailureThrowsWithoutPartialResult() async {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "new"), files: [], threads: [])
        let persistence = MemoryPersistence()
        persistence.failOnSave = true
        let ops = ReviewOperations(service: service, persistence: persistence)

        do {
            _ = try await ops.refresh(
                endpoint: ep,
                current: ReviewLocalState(headSHA: "old", drafts: [], viewed: [])
            )
            XCTFail("expected a persistence failure")
        } catch {
            // expected
        }
    }

    /// An existing new-head draft file — including an intentionally empty one —
    /// must never be overwritten by copied old drafts.
    func testExistingEmptyNewHeadStateIsNotOverwritten() async throws {
        let service = RecordingService()
        service.bundle = FetchBundle(pr: makePRInfo(sha: "new"), files: DiffParser.parse(sampleDiff), threads: [])
        let persistence = MemoryPersistence()
        persistence.setDraftState(.present([]), endpoint: ep, sha: "new")   // existing new-head state: empty array
        let ops = ReviewOperations(service: service, persistence: persistence)

        let oldDraft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "old")
        let result = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(headSHA: "old", drafts: [oldDraft], viewed: [])
        )

        XCTAssertTrue(result.localState.drafts.isEmpty, "existing empty new-head state wins over copied old drafts")
        XCTAssertEqual(persistence.savedDraftCounts, [1], "only the old-head save happens; no new-head copy")
    }

    /// A draft whose anchor vanishes across a head change becomes orphaned;
    /// when the anchor returns on a later refresh it reattaches automatically.
    func testOrphanReattachesWhenAnchorReturns() async throws {
        let withoutNew2 = """
        diff --git a/Src.swift b/Src.swift
        --- a/Src.swift
        +++ b/Src.swift
        @@ -1,2 +1,1 @@
         keep1
        -old2
        """
        final class QueuedService: GitHubServing {
            let bundles: [FetchBundle]
            var index = 0
            init(_ bundles: [FetchBundle]) { self.bundles = bundles }
            func ensureAvailable() async throws {}
            func resolveEndpoint(from argument: String) async throws -> PREndpoint {
                PREndpoint(owner: "o", repo: "r", number: 1)
            }
            func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
                let bundle = bundles[min(index, bundles.count - 1)]
                index += 1
                return bundle
            }
            func submitReview(_ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]) async throws {}
            func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {}
            func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {}
        }

        let service = QueuedService([
            FetchBundle(pr: makePRInfo(sha: "mid"), files: DiffParser.parse(withoutNew2), threads: []),
            FetchBundle(pr: makePRInfo(sha: "new"), files: DiffParser.parse(sampleDiff), threads: []),
        ])
        let ops = ReviewOperations(service: service, persistence: MemoryPersistence())
        let draft = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "note")

        let orphaned = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(headSHA: "old", drafts: [draft], viewed: [])
        )
        XCTAssertEqual(orphaned.localState.drafts.first?.isOrphaned, true,
                       "draft whose anchor left the diff is orphaned")

        let reattached = try await ops.refresh(
            endpoint: ep,
            current: ReviewLocalState(
                headSHA: "mid",
                drafts: orphaned.localState.drafts,
                viewed: orphaned.localState.viewed
            )
        )
        XCTAssertEqual(reattached.localState.drafts.first?.isOrphaned, false,
                       "anchor returned; draft reattached automatically")
    }

    // MARK: - Submit

    func testSubmitSendsOnlyNonOrphanedDraftsAndReturnsSnapshot() async throws {
        let service = RecordingService()
        let ops = ReviewOperations(service: service, persistence: MemoryPersistence())
        let valid = DraftComment(path: "a", line: 1, side: "RIGHT", body: "ok")
        let orphan = DraftComment(path: "a", line: 1, side: "RIGHT", body: "lost", isOrphaned: true)

        let result = try await ops.submit(
            endpoint: ep, headSHA: "sha", body: "", event: .comment, drafts: [valid, orphan]
        )

        XCTAssertEqual(service.submitCalls.count, 1)
        XCTAssertEqual(service.submitCalls[0].draftCount, 1, "orphan must not be sent")
        XCTAssertEqual(service.submitCalls[0].event, "COMMENT")
        XCTAssertEqual(result.submitted.drafts, [valid])
    }

    // MARK: - Reply / resolve

    func testReplyForwardsBody() async throws {
        let service = RecordingService()
        let ops = ReviewOperations(service: service, persistence: MemoryPersistence())
        try await ops.reply(endpoint: ep, commentID: 7, body: "hi")
        XCTAssertEqual(service.replyCalls.count, 1)
        XCTAssertEqual(service.replyCalls[0].commentID, 7)
        XCTAssertEqual(service.replyCalls[0].body, "hi")
    }

    func testResolveForwardsAndSurfacesErrors() async throws {
        let service = RecordingService()
        let ops = ReviewOperations(service: service, persistence: MemoryPersistence())
        try await ops.setResolved(endpoint: ep, threadID: "t1", resolved: true)
        XCTAssertEqual(service.resolveCalls.count, 1)
        XCTAssertEqual(service.resolveCalls[0].id, "t1")
        XCTAssertEqual(service.resolveCalls[0].resolved, true)

        service.resolveError = GitHubError.api("boom")
        do {
            try await ops.setResolved(endpoint: ep, threadID: "t1", resolved: false)
            XCTFail("expected failure")
        } catch {
            // expected
        }
    }

    // MARK: - Utilities

    func testClipboardTextExactFormat() {
        let right = DiffLine(kind: .added, content: "new2", oldLine: nil, newLine: 2)
        XCTAssertEqual(ReviewUtilities.clipboardText(path: "Src.swift", line: right), "Src.swift:2 new2")
        let left = DiffLine(kind: .removed, content: "old2", oldLine: 2, newLine: nil)
        XCTAssertEqual(ReviewUtilities.clipboardText(path: "Src.swift", line: left), "Src.swift:2 old2")
    }

    func testPullRequestURLValidation() {
        XCTAssertEqual(ReviewUtilities.pullRequestURL("https://github.com/o/r/pull/1")?.absoluteString,
                       "https://github.com/o/r/pull/1")
        XCTAssertNil(ReviewUtilities.pullRequestURL(nil))
        XCTAssertNil(ReviewUtilities.pullRequestURL("not a url"))
        XCTAssertNil(ReviewUtilities.pullRequestURL("ftp://github.com/x"))
    }

    // MARK: - Range validation

    private func file(_ diff: String) -> DiffFile {
        DiffParser.parse(diff)[0]
    }

    func testRangeValidationNormalizesReverseAndRejectsCrossHunk() {
        let f = file(sampleDiff)
        // new2 (new line 2) and new3 (new line 3), same hunk, same side.
        let ok = DraftRangeValidator().validate(
            start: (f, 0, 3), end: (f, 0, 2)
        )
        guard case .range(let anchor) = ok else {
            return XCTFail("expected a normalized range, got \(ok)")
        }
        XCTAssertEqual(anchor.side, "RIGHT")
        XCTAssertEqual(anchor.startLine, 2, "reverse selection normalizes to start <= line")
        XCTAssertEqual(anchor.line, 3)
        XCTAssertEqual(anchor.startSide, "RIGHT")

        // Mixed sides (removed old2 + added new2) are invalid.
        let mixed = DraftRangeValidator().validate(start: (f, 0, 1), end: (f, 0, 2))
        guard case .invalid(let reason) = mixed else {
            return XCTFail("expected mixed-side rejection, got \(mixed)")
        }
        XCTAssertTrue(reason.contains("one diff side"))
    }

    func testRangeValidationRejectsNonCommentableEndpoints() {
        let f = file(sampleDiff)
        // Endpoints that are hunk headers/cards are passed as nil → invalid.
        let nilEndpoint = DraftRangeValidator().validate(start: (f, 0, 1), end: nil)
        guard case .invalid = nilEndpoint else {
            return XCTFail("expected invalid for nil endpoint")
        }
    }

    /// Endpoints in different hunks are rejected with a specific reason.
    func testRangeValidationRejectsCrossHunk() {
        let multiHunk = """
        diff --git a/Src.swift b/Src.swift
        --- a/Src.swift
        +++ b/Src.swift
        @@ -1,2 +1,2 @@
         keep1
        +newA
        @@ -10,1 +11,1 @@
         keep10
        +newB
        """
        let f = file(multiHunk)
        guard f.hunks.count == 2 else { return XCTFail("expected two hunks") }
        let result = DraftRangeValidator().validate(start: (f, 0, 1), end: (f, 1, 1))
        guard case .invalid(let reason) = result else {
            return XCTFail("expected cross-hunk rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("one hunk"))
    }
}
