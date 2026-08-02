import Foundation

/// Builds API payloads. `ReviewPayload` matches GitHub's "Create a review"
/// REST contract: `commit_id`, `event`, `body`, `comments[{path,line,side,body}]`.
public enum PayloadBuilder {

    struct ReviewComment: Encodable {
        let path: String
        let line: Int
        let side: String
        let body: String
        let start_line: Int?
        let start_side: String?

        enum CodingKeys: String, CodingKey {
            case path, line, side, body, start_line, start_side
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(line, forKey: .line)
            try c.encode(side, forKey: .side)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(start_line, forKey: .start_line)
            try c.encodeIfPresent(start_side, forKey: .start_side)
        }
    }

    struct ReviewPayload: Encodable {
        let commit_id: String
        let event: String
        let body: String
        let comments: [ReviewComment]
    }

    static func reviewPayload(
        commitID: String,
        body: String,
        event: String,
        drafts: [DraftComment]
    ) -> ReviewPayload {
        let comments = drafts.map { d in
            ReviewComment(
                path: d.path,
                line: d.line,
                side: d.side,
                body: d.body,
                start_line: d.startLine,
                start_side: d.startSide
            )
        }
        return ReviewPayload(commit_id: commitID, event: event, body: body, comments: comments)
    }

    /// Writes JSON to a temp file and returns its path (for `gh api --input`).
    static func writeJSONToTemp<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prr-payload-\(UUID().uuidString).json")
        try data.write(to: url)
        return url.path
    }
}
