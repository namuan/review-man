import XCTest
@testable import PRReviewKit

// MARK: - Test doubles

/// A per-operation gate: `wait()` suspends until the test releases the waiter
/// (with success or an injected error), or until the awaiting task is
/// cancelled. `auto` makes new calls return immediately.
private final class Gate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []
    var auto = false
    /// When false, cancellation leaves the waiter blocked (a service that
    /// ignores cancellation); the waiter completes only when released.
    var respectsCancellation = true

    func wait() async throws {
        if auto { return }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled.contains(id) {
                    cancelled.remove(id)
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: cont))
                    lock.unlock()
                }
            }
        }, onCancel: {
            guard self.respectsCancellation else { return }
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                lock.unlock()
                w.continuation.resume(throwing: CancellationError())
            } else {
                cancelled.insert(id)
                lock.unlock()
            }
        })
    }

    func release() {
        release(result: .success(()))
    }

    func release(error: Error) {
        release(result: .failure(error))
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private func release(result: Result<Void, Error>) {
        lock.lock()
        guard !waiters.isEmpty else {
            lock.unlock()
            return
        }
        let w = waiters.removeFirst()
        lock.unlock()
        w.continuation.resume(with: result)
    }
}

/// A GitHubServing double with a gate per operation kind, recording every call.
private final class ScriptedService: GitHubServing {
    let fetchGate = Gate()
    let submitGate = Gate()
    let replyGate = Gate()
    let resolveGate = Gate()

    var fetchResults: [FetchBundle]
    private(set) var fetchCount = 0
    private(set) var submitCalls: [(commitID: String, body: String, event: String)] = []
    private(set) var replyCalls: [(commentID: Int, body: String)] = []
    private(set) var resolveCalls: [(id: String, resolved: Bool)] = []
    private let callLock = NSLock()
    private var callCount = 0

    init(fetchResults: [FetchBundle]) {
        self.fetchResults = fetchResults
    }

    func ensureAvailable() async throws {}
    func resolveEndpoint(from argument: String) async throws -> PREndpoint {
        PREndpoint(owner: "o", repo: "r", number: 1)
    }

    func fetchAll(_ ep: PREndpoint) async throws -> FetchBundle {
        // Assign the bundle at CALL time (not completion time) so the result
        // for each logical fetch is deterministic regardless of task races.
        callLock.lock()
        let idx = min(callCount, max(0, fetchResults.count - 1))
        callCount += 1
        callLock.unlock()
        try await fetchGate.wait()
        fetchCount += 1
        return fetchResults[idx]
    }

    func submitReview(
        _ ep: PREndpoint, commitID: String, body: String, event: String, drafts: [DraftComment]
    ) async throws {
        try await submitGate.wait()
        submitCalls.append((commitID, body, event))
    }

    func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) async throws {
        try await replyGate.wait()
        replyCalls.append((commentID, body))
    }

    func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) async throws {
        try await resolveGate.wait()
        resolveCalls.append((threadID, resolved))
    }
}

// MARK: - Tests

final class AppControllerOperationTests: XCTestCase {

    private let endpoint = PREndpoint(owner: "o", repo: "r", number: 1)

    private func makePR(_ title: String) -> PRInfo {
        PRInfo(
            number: 1, title: title, body: nil, author: "a", state: "OPEN",
            isDraft: false, headRefOid: "sha-\(title)", headRefName: "h", baseRefName: "b",
            additions: 1, deletions: 1, changedFiles: 1, reviewDecision: nil,
            url: "https://github.com/o/r/pull/1"
        )
    }

    private func makeModel(service: GitHubServing, persistence: InMemoryReviewPersistence = InMemoryReviewPersistence()) -> AppController {
        let model = AppModel()
        model.endpoint = endpoint
        return AppController(model: model, client: service, persistence: persistence)
    }

    private func makeDiffModel(service: GitHubServing, persistence: InMemoryReviewPersistence = InMemoryReviewPersistence()) -> AppController {
        let model = AppModel()
        model.endpoint = endpoint
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
        model.threads = [
            PRThread(
                id: "t1", path: "Src.swift", line: 2, originalLine: 2, side: "RIGHT",
                startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
                comments: [PRComment(databaseId: 77, author: "a", body: "hi", createdAt: Date())]
            ),
            PRThread(
                id: "t2", path: "Src.swift", line: 3, originalLine: 3, side: "RIGHT",
                startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
                comments: [PRComment(databaseId: 88, author: "a", body: "yo", createdAt: Date())]
            ),
        ]
        model.rebuildRows()
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

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Stale fetch rejection

    func testOlderFetchCannotReplaceNewerFetchResult() async {
        let service = ScriptedService(fetchResults: [
            FetchBundle(pr: makePR("older"), files: [], threads: []),
            FetchBundle(pr: makePR("newer"), files: [], threads: []),
        ])
        let controller = makeModel(service: service)

        // Fetch #1 ignores cancellation and stays blocked until explicitly
        // released — genuinely exercising the "late result" drop path.
        service.fetchGate.auto = false
        service.fetchGate.respectsCancellation = false
        controller.refresh()                    // fetch #1 would return "older"
        await waitUntil { service.fetchGate.pendingCount >= 1 }

        service.fetchGate.auto = true           // applies only to new calls
        controller.refresh()                    // fetch #2 supersedes and completes with "newer"
        await drainUntil(controller) { controller.model.pr?.title == "newer" }
        XCTAssertEqual(controller.model.pr?.title, "newer")

        // Release the older, still-blocked fetch: its late result must be
        // dropped as stale and must not overwrite the newer one.
        service.fetchGate.release()
        await waitUntil { service.fetchCount >= 2 }
        await drainUntil(controller) { service.fetchCount >= 2 }

        XCTAssertEqual(controller.model.pr?.title, "newer", "older fetch must never overwrite newer")
        XCTAssertFalse(controller.model.message?.isError ?? false)
    }

    // MARK: - Refresh after explicit cancellation

    func testRefreshAfterExplicitCancelStillApplies() async {
        let service = ScriptedService(fetchResults: [
            FetchBundle(pr: makePR("older"), files: [], threads: []),
            FetchBundle(pr: makePR("fresh"), files: [], threads: []),
        ])
        let controller = makeModel(service: service)

        // Fetch #1 ignores cancellation and stays blocked until released; the
        // wait guarantees it has already taken its result index.
        service.fetchGate.auto = false
        service.fetchGate.respectsCancellation = false
        controller.refresh()                            // fetch #1 would return "older"
        await waitUntil { service.fetchGate.pendingCount >= 1 }

        controller.cancelFetch()                        // explicit cancellation
        service.fetchGate.auto = true
        controller.refresh()                            // a new fetch must still apply
        await drainUntil(controller) { controller.model.pr?.title == "fresh" }
        XCTAssertEqual(controller.model.pr?.title, "fresh")

        // Release the cancelled-but-still-blocked older fetch: its late result
        // is stale and must not overwrite the newer one.
        service.fetchGate.release()
        await waitUntil { service.fetchCount >= 2 }
        await drainUntil(controller) { service.fetchCount >= 2 }
        XCTAssertEqual(controller.model.pr?.title, "fresh", "late older result must be dropped")
        XCTAssertFalse(controller.model.message?.isError ?? false)
    }

    // MARK: - Explicit cancellation with a cancellation-uncooperative service

    func testExplicitCancellationDropsLateResultEvenIfServiceIgnoresCancel() async {
        let service = ScriptedService(fetchResults: [
            FetchBundle(pr: makePR("late"), files: [], threads: []),
        ])
        let controller = makeModel(service: service)

        service.fetchGate.auto = true   // completes regardless of cancellation
        controller.refresh()
        controller.cancelFetch()
        await waitUntil { service.fetchCount >= 1 }
        await drainUntil(controller) { !controller.model.loading }

        // The late success must be dropped as stale, not applied.
        XCTAssertNil(controller.model.pr)
        XCTAssertFalse(controller.model.message?.isError ?? false)
    }

    // MARK: - Submit survives a refresh

    func testSubmitCompletesDespiteInterveningRefresh() async {
        let files = DiffParser.parse("""
        diff --git a/Src.swift b/Src.swift
        --- a/Src.swift
        +++ b/Src.swift
        @@ -1,3 +1,4 @@
         keep1
        -old2
        +new2
        +new3
        """)
        let service = ScriptedService(fetchResults: [FetchBundle(pr: makePR("fetched"), files: files, threads: [])])
        let controller = makeModel(service: service)
        // Same head SHA as the fetched bundle: a refresh keeps drafts in memory
        // (same-SHA migration path), so only submitDone can clear them.
        controller.model.headOID = "sha-fetched"
        controller.model.drafts = [DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "draft")]

        // Open composer and submit: submit blocks.
        controller.handle(.char("s"), screenW: 100, screenH: 40)
        controller.handle(.char("y"), screenW: 100, screenH: 40)

        // A refresh completes while the submit is still in flight.
        service.fetchGate.auto = true
        controller.refresh()
        await drainUntil(controller) { controller.model.pr != nil }
        XCTAssertEqual(controller.model.pr?.title, "fetched")

        // The submit outcome must NOT be dropped by the refresh.
        await waitUntil { service.submitGate.pendingCount >= 1 }
        service.submitGate.release()
        await drainUntil(controller) { service.submitCalls.count == 1 && controller.model.drafts.isEmpty }

        XCTAssertEqual(service.submitCalls.count, 1)
        XCTAssertEqual(service.submitCalls[0].event, "COMMENT")
        // Drafts are only cleared by the applied submit outcome.
        XCTAssertTrue(controller.model.drafts.isEmpty)
        XCTAssertFalse(controller.model.message?.isError ?? false)
    }

    // MARK: - Explicit fetch cancellation

    func testExplicitFetchCancellationShowsNoError() async {
        let service = ScriptedService(fetchResults: [FetchBundle(pr: makePR("never"), files: [], threads: [])])
        let controller = makeModel(service: service)

        service.fetchGate.auto = false
        controller.refresh()          // fetch blocks
        controller.cancelFetch()
        await drainUntil(controller) { !controller.model.loading }

        // No "Refresh failed" error is shown; the stale "Refreshing…" hint is
        // the only message, and it is not an error.
        XCTAssertFalse(controller.model.message?.isError ?? false)
        XCTAssertFalse(controller.model.message?.text.contains("Refresh failed") ?? false)
        XCTAssertNil(controller.model.pr)
    }

    // MARK: - Stale resolve failure must not roll back newer state

    func testStaleResolveFailureDoesNotUndoNewerState() async {
        let service = ScriptedService(fetchResults: [FetchBundle(pr: makePR("x"), files: [], threads: [])])
        let controller = makeDiffModel(service: service)
        controller.model.focus = .diff
        // Rows: 0 hunk, 1 keep1, 2 old2, 3 new2, 4 thread t1, 5 new3, 6 thread t2.
        controller.model.cursorRow = 4

        controller.handle(.char("X"), screenW: 100, screenH: 40)   // resolve #1 (resolved: true), blocks
        await waitUntil { service.resolveGate.pendingCount >= 1 }
        controller.handle(.char("X"), screenW: 100, screenH: 40)   // resolve #2 (resolved: false), blocks
        await waitUntil { service.resolveGate.pendingCount >= 2 }

        // Release #1 (stale) with a failure, then #2 (current) successfully.
        service.resolveGate.release(error: GitHubError.api("boom"))
        service.resolveGate.release()
        await drainUntil(controller) { controller.model.message?.text.contains("Thread updated") ?? false }

        // Only the current resolve succeeded; the failed stale resolve was
        // dropped without producing an error or recording a mutation.
        XCTAssertEqual(service.resolveCalls.count, 1)
        XCTAssertEqual(service.resolveCalls[0].id, "t1")
        XCTAssertEqual(service.resolveCalls[0].resolved, false)
        // The stale failure must not surface or roll back the newer state.
        XCTAssertEqual(controller.model.threads[0].isResolved, false)
        XCTAssertFalse(controller.model.message?.text.contains("Resolve failed") ?? false)
        XCTAssertEqual(controller.model.message?.text, "Thread updated.")
    }

    // MARK: - Reply and resolve on different threads are independent

    func testReplyAndResolveOnDifferentThreadsBothApply() async {
        let service = ScriptedService(fetchResults: [FetchBundle(pr: makePR("x"), files: [], threads: [])])
        let controller = makeDiffModel(service: service)
        controller.model.focus = .diff
        // Rows: 0 hunk, 1 keep1, 2 old2, 3 new2, 4 thread t1, 5 new3, 6 thread t2.

        // Reply to t1.
        controller.model.cursorRow = 4
        controller.handle(.char("r"), screenW: 100, screenH: 40)
        controller.handle(.char("h"), screenW: 100, screenH: 40)
        controller.handle(.char("i"), screenW: 100, screenH: 40)
        controller.handle(.escape, screenW: 100, screenH: 40)      // reply blocks

        // Resolve t2 while the reply is still in flight.
        controller.model.cursorRow = 6
        controller.handle(.char("X"), screenW: 100, screenH: 40)   // resolve blocks

        await waitUntil { service.replyGate.pendingCount >= 1 && service.resolveGate.pendingCount >= 1 }
        service.replyGate.release()
        service.resolveGate.release()
        await drainUntil(controller) {
            service.replyCalls.count == 1
                && service.resolveCalls.count == 1
                && controller.model.threads[1].isResolved == true
        }

        XCTAssertEqual(service.replyCalls.count, 1)
        XCTAssertEqual(service.replyCalls[0].commentID, 77)
        XCTAssertEqual(service.replyCalls[0].body, "hi")
        XCTAssertEqual(service.resolveCalls.count, 1)
        XCTAssertEqual(service.resolveCalls[0].id, "t2")
        XCTAssertEqual(service.resolveCalls[0].resolved, true)
        XCTAssertEqual(controller.model.threads[1].isResolved, true)
        XCTAssertFalse(controller.model.message?.text.contains("failed") ?? false)
    }

    // MARK: - Persistence failure reporting

    func testViewedPersistenceFailureIsLabeledViewed() async {
        let persistence = InMemoryReviewPersistence()
        persistence.failure = PersistenceError.saveFailed("disk full")
        let service = ScriptedService(fetchResults: [FetchBundle(pr: makePR("x"), files: [], threads: [])])
        let controller = makeDiffModel(service: service, persistence: persistence)
        controller.model.headOID = "sha"

        controller.handle(.char("v"), screenW: 100, screenH: 40)   // toggle viewed → persistViewed
        await drainUntil(controller) { controller.model.persistenceFailure != nil }

        XCTAssertEqual(controller.model.persistenceFailure?.operation, "viewed")
        XCTAssertTrue(controller.model.message?.isError ?? false)
        XCTAssertTrue(controller.model.message?.text.contains("viewed marks") ?? false)
    }
}
