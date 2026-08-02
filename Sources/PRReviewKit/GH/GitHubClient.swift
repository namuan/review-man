import Foundation

// MARK: - GraphQL DTOs (file scope so they can be shared across functions)

private struct GQLPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct GQLCommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let body: String
    let author: GQLAuthor?
    let createdAt: String
}

private struct GQLAuthor: Decodable {
    let login: String
}

private struct GQLCommentConn: Decodable {
    let pageInfo: GQLPageInfo
    let nodes: [GQLCommentNode]
}

private struct GQLThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let line: Int?
    let originalLine: Int?
    let diffSide: String?
    let startLine: Int?
    let originalStartLine: Int?
    let comments: GQLCommentConn
}

private struct GQLThreadConn: Decodable {
    let pageInfo: GQLPageInfo
    let nodes: [GQLThreadNode]
}

private struct GQLPR: Decodable {
    let reviewThreads: GQLThreadConn
}

private struct GQLRepo: Decodable {
    let pullRequest: GQLPR
}

private struct GQLThreadsData: Decodable {
    let repository: GQLRepo
}

private struct GQLSingleThread: Decodable {
    struct Wrap: Decodable {
        let comments: GQLCommentConn
    }
    let node: Wrap?
}

/// GitHub client backed by the `gh` CLI. All I/O is synchronous; callers run it
/// on a background queue.
public final class GitHubClient {

    public init() {}

    // MARK: - Endpoint resolution

    /// Accepts: full PR URL, `owner/repo#number`, or a bare number (resolved
    /// against the repository of the current working directory).
    public func resolveEndpoint(from arg: String) throws -> PREndpoint {
        var trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasPrefix("https://github.com/") || trimmed.hasPrefix("http://github.com/") {
            let path = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // ["https:", "github.com", owner, repo, "pull", N]
            if path.count >= 5, path[path.count - 2] == "pull", let n = Int(path[path.count - 1]) {
                return PREndpoint(owner: path[path.count - 4], repo: path[path.count - 3], number: n)
            }
            throw GitHubError.parse("Not a GitHub PR URL: \(arg)")
        }
        // owner/repo#number
        if trimmed.contains("#") {
            let parts = trimmed.split(separator: "#", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[1]) else {
                throw GitHubError.parse("Expected owner/repo#number: \(arg)")
            }
            let repoParts = parts[0].split(separator: "/")
            guard repoParts.count == 2 else {
                throw GitHubError.parse("Expected owner/repo#number: \(arg)")
            }
            return PREndpoint(owner: String(repoParts[0]), repo: String(repoParts[1]), number: n)
        }
        // bare number: resolve repo from cwd
        if let n = Int(trimmed) {
            let out = try GH.run(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
            let name = String(data: out.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = name.split(separator: "/")
            guard parts.count == 2 else {
                throw GitHubError.parse("Could not determine the current repository; use owner/repo#number or a full URL.")
            }
            return PREndpoint(owner: String(parts[0]), repo: String(parts[1]), number: n)
        }
        throw GitHubError.parse("Could not understand PR reference: \(arg)")
    }

    // MARK: - Fetches

    private struct PRInfoDTO: Decodable {
        struct AuthorDTO: Decodable { let login: String }
        let number: Int
        let title: String
        let body: String?
        let state: String
        let isDraft: Bool
        let headRefOid: String
        let headRefName: String
        let baseRefName: String
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let reviewDecision: String?
        let url: String
        let author: AuthorDTO
    }

    public func fetchPRInfo(_ ep: PREndpoint) throws -> PRInfo {
        let fields = "number,title,body,state,isDraft,headRefOid,headRefName,baseRefName,"
            + "additions,deletions,changedFiles,reviewDecision,url,author"
        let dto: PRInfoDTO = try GH.runJSON([
            "pr", "view", "--repo", "\(ep.owner)/\(ep.repo)", String(ep.number), "--json", fields,
        ])
        return PRInfo(
            number: dto.number,
            title: dto.title,
            body: dto.body,
            author: dto.author.login,
            state: dto.state,
            isDraft: dto.isDraft,
            headRefOid: dto.headRefOid,
            headRefName: dto.headRefName,
            baseRefName: dto.baseRefName,
            additions: dto.additions,
            deletions: dto.deletions,
            changedFiles: dto.changedFiles,
            reviewDecision: dto.reviewDecision,
            url: dto.url
        )
    }

    /// Fetches the full unified diff; falls back to the per-file `files`
    /// endpoint when the raw diff fails (huge PRs, 406s, etc).
    public func fetchDiff(_ ep: PREndpoint) throws -> [DiffFile] {
        do {
            let r = try GH.run([
                "api", "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)",
                "-H", "Accept: application/vnd.github.v3.diff",
            ])
            let text = String(data: r.data, encoding: .utf8) ?? ""
            let files = DiffParser.parse(text)
            if !files.isEmpty || text.isEmpty {
                return files
            }
        } catch {
            // fall through to the files endpoint
        }
        return try fetchFilesFallback(ep)
    }

    private struct PRFileDTO: Decodable {
        let filename: String
        let status: String
        let additions: Int
        let deletions: Int
        let changes: Int
        let patch: String?
        let previous_filename: String?
    }

    private func fetchFilesFallback(_ ep: PREndpoint) throws -> [DiffFile] {
        let dtos: [PRFileDTO] = try GH.runJSON([
            "api", "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/files", "--paginate",
        ])
        return dtos.map { dto in
            var file = DiffFile()
            switch dto.status {
            case "added": file.status = .added
            case "removed", "deleted": file.status = .deleted
            case "renamed": file.status = .renamed
            default: file.status = .modified
            }
            if let prev = dto.previous_filename { file.oldPath = prev }
            file.newPath = dto.filename
            guard let patch = dto.patch else {
                file.tooLarge = true
                return file
            }
            let old = file.oldPath ?? file.path
            let new = file.newPath ?? file.path
            let header = "diff --git a/\(old) b/\(new)\n"
                + "--- \(file.oldPath.map { "a/\($0)" } ?? "/dev/null")\n"
                + "+++ \(file.newPath.map { "b/\($0)" } ?? "/dev/null")\n"
            if let first = DiffParser.parse(header + patch).first {
                var f = first
                f.status = file.status
                if let prev = dto.previous_filename { f.oldPath = prev }
                return f
            }
            file.tooLarge = true
            return file
        }
    }

    // MARK: - Review threads (GraphQL, cursor-paginated)

    private func threadsQuery(after: String?) -> String {
        let afterClause = after.map { ", after: \"\($0)\"" } ?? ""
        return """
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100\(afterClause)) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved isOutdated path line originalLine diffSide startLine originalStartLine
                  comments(first: 100) {
                    nodes { id databaseId body author { login } createdAt }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
            }
          }
        }
        """
    }

    private func threadCommentsQuery(threadID: String, after: String) -> String {
        """
        query {
          node(id: "\(threadID)") {
            ... on ReviewThread {
              comments(first: 100, after: "\(after)") {
                nodes { id databaseId body author { login } createdAt }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }
        """
    }

    public func fetchThreads(_ ep: PREndpoint) throws -> [PRThread] {
        var threads: [PRThread] = []
        var after: String?
        repeat {
            let data: GQLThreadsData = try GH.runGraphQL(
                query: threadsQuery(after: after),
                variables: [
                    "owner": ep.owner,
                    "repo": ep.repo,
                    "number": String(ep.number),
                ]
            )
            let conn = data.repository.pullRequest.reviewThreads
            for node in conn.nodes {
                let comments = try fetchThreadComments(threadID: node.id, initial: node.comments)
                threads.append(PRThread(
                    id: node.id,
                    path: node.path,
                    line: node.line,
                    originalLine: node.originalLine,
                    side: node.diffSide ?? "RIGHT",
                    startLine: node.startLine,
                    startSide: node.startLine != nil ? (node.diffSide ?? "RIGHT") : nil,
                    isOutdated: node.isOutdated,
                    isResolved: node.isResolved,
                    comments: comments
                ))
            }
            after = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : nil
        } while after != nil
        return threads
    }

    private func fetchThreadComments(threadID: String, initial: GQLCommentConn) throws -> [PRComment] {
        var comments = initial.nodes.map { nodeToComment($0) }
        var cursor = initial.pageInfo.hasNextPage ? initial.pageInfo.endCursor : nil
        while let c = cursor {
            let data: GQLSingleThread = try GH.runGraphQL(
                query: threadCommentsQuery(threadID: threadID, after: c),
                variables: [:]
            )
            guard let conn = data.node?.comments else { break }
            comments.append(contentsOf: conn.nodes.map { nodeToComment($0) })
            cursor = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : nil
        }
        return comments
    }

    private func nodeToComment(_ n: GQLCommentNode) -> PRComment {
        PRComment(
            databaseId: n.databaseId,
            author: n.author?.login ?? "unknown",
            body: n.body,
            createdAt: parseGHDate(n.createdAt) ?? Date()
        )
    }

    public func fetchAll(_ ep: PREndpoint) throws -> FetchBundle {
        let pr = try fetchPRInfo(ep)
        let files = try fetchDiff(ep)
        let threads = try fetchThreads(ep)
        return FetchBundle(pr: pr, files: files, threads: threads)
    }

    // MARK: - Writes

    public func submitReview(
        _ ep: PREndpoint,
        commitID: String,
        body: String,
        event: String,
        drafts: [DraftComment]
    ) throws {
        let payload = PayloadBuilder.reviewPayload(
            commitID: commitID, body: body, event: event, drafts: drafts
        )
        let file = try PayloadBuilder.writeJSONToTemp(payload)
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = try GH.run([
            "api", "-X", "POST",
            "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/reviews",
            "--input", file,
        ])
    }

    public func replyToThread(_ ep: PREndpoint, commentID: Int, body: String) throws {
        struct Reply: Encodable { let body: String }
        let file = try PayloadBuilder.writeJSONToTemp(Reply(body: body))
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = try GH.run([
            "api", "-X", "POST",
            "repos/\(ep.owner)/\(ep.repo)/pulls/\(ep.number)/comments/\(commentID)/replies",
            "--input", file,
        ])
    }

    public func resolveThread(_ ep: PREndpoint, threadID: String, resolved: Bool) throws {
        // ResolveReviewThreadInput/UnresolveReviewThreadInput contain only
        // clientMutationId and threadId (verified against the GitHub schema).
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }"
        struct EmptyData: Decodable {}
        _ = try GH.runGraphQL(query: mutation, variables: ["id": threadID]) as EmptyData
    }
}
