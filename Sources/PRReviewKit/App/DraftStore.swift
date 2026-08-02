import Foundation

/// Persists local state (draft comments, viewed-file marks) per PR + head SHA
/// so typed reviews survive crashes and restarts.
public enum DraftStore {

    private static var baseURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/pr-review")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func key(_ ep: PREndpoint, sha: String) -> String {
        let safe = "\(ep.owner)_\(ep.repo)_\(ep.number)_\(sha)"
            .replacingOccurrences(of: "/", with: "_")
        return safe
    }

    private static func draftsURL(_ ep: PREndpoint, sha: String) -> URL? {
        baseURL?.appendingPathComponent("drafts-\(key(ep, sha: sha)).json")
    }

    private static func viewedURL(_ ep: PREndpoint, sha: String) -> URL? {
        baseURL?.appendingPathComponent("viewed-\(key(ep, sha: sha)).json")
    }

    public static func loadDrafts(_ ep: PREndpoint, sha: String) -> [DraftComment] {
        guard let url = draftsURL(ep, sha: sha), let data = try? Data(contentsOf: url) else {
            return []
        }
        struct DTO: Decodable {
            let id: UUID
            let path: String
            let line: Int
            let side: String
            let body: String
            let createdAt: Date
            let startLine: Int?
            let startSide: String?
        }
        guard let dtos = try? JSONDecoder().decode([DTO].self, from: data) else { return [] }
        return dtos.map { DraftComment(
            id: $0.id, path: $0.path, line: $0.line, side: $0.side,
            body: $0.body, createdAt: $0.createdAt, startLine: $0.startLine, startSide: $0.startSide
        ) }
    }

    public static func saveDrafts(_ drafts: [DraftComment], _ ep: PREndpoint, sha: String) {
        guard let url = draftsURL(ep, sha: sha) else { return }
        struct DTO: Encodable {
            let id: UUID
            let path: String
            let line: Int
            let side: String
            let body: String
            let createdAt: Date
            let startLine: Int?
            let startSide: String?
        }
        let dtos = drafts.map { DTO(
            id: $0.id, path: $0.path, line: $0.line, side: $0.side,
            body: $0.body, createdAt: $0.createdAt, startLine: $0.startLine, startSide: $0.startSide
        ) }
        if let data = try? JSONEncoder().encode(dtos) {
            try? data.write(to: url)
        }
    }

    public static func loadViewed(_ ep: PREndpoint, sha: String) -> Set<String> {
        guard let url = viewedURL(ep, sha: sha), let data = try? Data(contentsOf: url) else {
            return []
        }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    public static func saveViewed(_ viewed: Set<String>, _ ep: PREndpoint, sha: String) {
        guard let url = viewedURL(ep, sha: sha) else { return }
        if let data = try? JSONEncoder().encode(Array(viewed)) {
            try? data.write(to: url)
        }
    }
}
