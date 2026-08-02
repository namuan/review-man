import XCTest
@testable import PRReviewKit

final class OperationTrackerTests: XCTestCase {

    func testFetchLaneOnlySupersedesOlderFetch() {
        let tracker = OperationTracker()
        let first = tracker.begin(.fetch)
        let second = tracker.begin(.fetch)
        XCTAssertTrue(tracker.isCurrent(second))
        XCTAssertFalse(tracker.isCurrent(first))
    }

    func testDifferentLanesRemainCurrent() {
        let tracker = OperationTracker()
        let fetch = tracker.begin(.fetch)
        let submit = tracker.begin(.submit)
        let replyA = tracker.begin(.reply(threadID: "a"))
        let replyB = tracker.begin(.reply(threadID: "b"))
        let resolveA = tracker.begin(.resolve(threadID: "a"))
        let resolveB = tracker.begin(.resolve(threadID: "b"))
        for token in [fetch, submit, replyA, replyB, resolveA, resolveB] {
            XCTAssertTrue(tracker.isCurrent(token), "expected \(token) to stay current")
        }
    }

    func testSameThreadResolveLaneSupersedes() {
        let tracker = OperationTracker()
        let first = tracker.begin(.resolve(threadID: "t"))
        let second = tracker.begin(.resolve(threadID: "t"))
        XCTAssertFalse(tracker.isCurrent(first))
        XCTAssertTrue(tracker.isCurrent(second))
    }

    func testActiveOperationsTrackCompletions() {
        let tracker = OperationTracker()
        let fetch = tracker.begin(.fetch)
        let submit = tracker.begin(.submit)
        XCTAssertTrue(tracker.hasActiveOperations)
        tracker.complete(fetch)
        XCTAssertTrue(tracker.hasActiveOperations)
        tracker.complete(submit)
        XCTAssertFalse(tracker.hasActiveOperations)
    }
}
