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
}
