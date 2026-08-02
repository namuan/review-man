import XCTest
@testable import PRReviewKit

/// In-memory ReviewPersisting double for controller tests: observes every save
/// and can inject failures. Distinguishes missing from saved (even empty) draft
/// state, mirroring the production repository contract.
final class InMemoryReviewPersistence: ReviewPersisting {

    private let lock = NSLock()
    private var draftsByKey: [String: [DraftComment]] = [:]
    private var presentDraftFiles = Set<String>()
    private var viewedByKey: [String: Set<String>] = [:]
    /// When set, every operation throws it.
    var failure: Error?

    private func key(_ endpoint: PREndpoint, _ sha: String) -> String {
        "\(endpoint.owner)/\(endpoint.repo)#\(endpoint.number)@\(sha)"
    }

    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState {
        if let failure { throw failure }
        let k = key(endpoint, headSHA)
        if presentDraftFiles.contains(k) {
            return .present(draftsByKey[k] ?? [])
        }
        return .missing
    }

    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws {
        if let failure { throw failure }
        let k = key(endpoint, headSHA)
        lock.lock()
        draftsByKey[k] = drafts
        presentDraftFiles.insert(k)
        lock.unlock()
    }

    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String> {
        if let failure { throw failure }
        return viewedByKey[key(endpoint, headSHA)] ?? []
    }

    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws {
        if let failure { throw failure }
        lock.lock()
        viewedByKey[key(endpoint, headSHA)] = viewed
        lock.unlock()
    }

    // MARK: - Test observations

    func savedDrafts(for endpoint: PREndpoint, sha: String) -> [DraftComment]? {
        lock.lock()
        defer { lock.unlock() }
        return draftsByKey[key(endpoint, sha)]
    }

    func savedViewed(for endpoint: PREndpoint, sha: String) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return viewedByKey[key(endpoint, sha)]
    }
}
