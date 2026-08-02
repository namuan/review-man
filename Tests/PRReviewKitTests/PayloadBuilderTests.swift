import XCTest
@testable import PRReviewKit

final class PayloadBuilderTests: XCTestCase {

    func testReviewPayloadShape() throws {
        let drafts = [
            DraftComment(path: "Src.swift", line: 42, side: "RIGHT", body: "Looks good"),
            DraftComment(path: "Old.swift", line: 7, side: "LEFT", body: "This line is removed", startLine: 5, startSide: "LEFT"),
        ]
        let payload = PayloadBuilder.reviewPayload(
            commitID: "abc123", body: "Summary", event: "APPROVE", drafts: drafts
        )
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["commit_id"] as? String, "abc123")
        XCTAssertEqual(obj["event"] as? String, "APPROVE")
        XCTAssertEqual(obj["body"] as? String, "Summary")
        let comments = try XCTUnwrap(obj["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.count, 2)
        // RIGHT-side comment: line and side only, no start fields
        XCTAssertEqual(comments[0]["path"] as? String, "Src.swift")
        XCTAssertEqual(comments[0]["line"] as? Int, 42)
        XCTAssertEqual(comments[0]["side"] as? String, "RIGHT")
        XCTAssertNil(comments[0]["start_line"])
        XCTAssertNil(comments[0]["start_side"])
        // LEFT-side range comment carries old-line numbers
        XCTAssertEqual(comments[1]["side"] as? String, "LEFT")
        XCTAssertEqual(comments[1]["line"] as? Int, 7)
        XCTAssertEqual(comments[1]["start_line"] as? Int, 5)
        XCTAssertEqual(comments[1]["start_side"] as? String, "LEFT")
    }

    func testEmptyDraftsProducesEmptyCommentsArray() throws {
        let payload = PayloadBuilder.reviewPayload(commitID: "x", body: "", event: "COMMENT", drafts: [])
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let comments = try XCTUnwrap(obj["comments"] as? [[String: Any]])
        XCTAssertTrue(comments.isEmpty)
    }

    /// Multi-line ranges must keep `line`/`side`/`start_line`/`start_side`
    /// intact for both RIGHT and LEFT drafts, while single-line comments omit
    /// both start fields.
    func testReviewPayloadPreservesMultilineRangesForBothSides() throws {
        let drafts = [
            DraftComment(path: "New.swift", line: 12, side: "RIGHT", body: "r",
                         startLine: 10, startSide: "RIGHT"),
            DraftComment(path: "Old.swift", line: 7, side: "LEFT", body: "l",
                         startLine: 4, startSide: "LEFT"),
            DraftComment(path: "One.swift", line: 1, side: "RIGHT", body: "s"),
        ]
        let payload = PayloadBuilder.reviewPayload(
            commitID: "abc", body: "b", event: "COMMENT", drafts: drafts
        )
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let comments = try XCTUnwrap(obj["comments"] as? [[String: Any]])

        XCTAssertEqual(comments.count, 3)
        // RIGHT range
        XCTAssertEqual(comments[0]["path"] as? String, "New.swift")
        XCTAssertEqual(comments[0]["line"] as? Int, 12)
        XCTAssertEqual(comments[0]["side"] as? String, "RIGHT")
        XCTAssertEqual(comments[0]["start_line"] as? Int, 10)
        XCTAssertEqual(comments[0]["start_side"] as? String, "RIGHT")
        // LEFT range
        XCTAssertEqual(comments[1]["path"] as? String, "Old.swift")
        XCTAssertEqual(comments[1]["line"] as? Int, 7)
        XCTAssertEqual(comments[1]["side"] as? String, "LEFT")
        XCTAssertEqual(comments[1]["start_line"] as? Int, 4)
        XCTAssertEqual(comments[1]["start_side"] as? String, "LEFT")
        // Single-line comment: no start fields.
        XCTAssertEqual(comments[2]["line"] as? Int, 1)
        XCTAssertNil(comments[2]["start_line"])
        XCTAssertNil(comments[2]["start_side"])
    }

    /// Orphaned drafts are excluded from the review payload; valid drafts keep
    /// their exact fields.
    func testOrphanedDraftsExcludedFromPayload() throws {
        let drafts = [
            DraftComment(path: "a.swift", line: 2, side: "RIGHT", body: "valid"),
            DraftComment(path: "a.swift", line: 7, side: "LEFT", body: "lost",
                         startLine: 4, startSide: "LEFT", isOrphaned: true),
            DraftComment(path: "b.swift", line: 1, side: "RIGHT", body: "also valid"),
        ]
        let payload = PayloadBuilder.reviewPayload(
            commitID: "x", body: "", event: "COMMENT", drafts: drafts
        )
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let comments = try XCTUnwrap(obj["comments"] as? [[String: Any]])

        XCTAssertEqual(comments.count, 2, "orphaned draft must be excluded")
        XCTAssertEqual(comments[0]["path"] as? String, "a.swift")
        XCTAssertEqual(comments[0]["line"] as? Int, 2)
        XCTAssertEqual(comments[1]["path"] as? String, "b.swift")
    }
}
