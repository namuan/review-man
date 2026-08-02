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
        // Orphaned drafts (anchors no longer in the diff) are never submitted.
        let comments = drafts
            .filter { !$0.isOrphaned }
            .map { d in
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

    /// Writes JSON to a private temp file (mode 0600) and returns its path
    /// (for `gh api --input`). Callers are responsible for removing the file.
    static func writeJSONToTemp<T: Encodable>(_ value: T) throws -> String {
        try writeJSONToTemp(value, in: FileManager.default.temporaryDirectory)
    }

    static func writeJSONToTemp<T: Encodable>(_ value: T, in directory: URL) throws -> String {
        let data = try JSONEncoder().encode(value)
        let url = try SecureTemporaryFile.make(prefix: "prr-payload", in: directory)
        do {
            // Write through a handle opened on the already-private file so the
            // default-permission `Data.write(.atomic)` replacement is avoided.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return url.path
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
