import Foundation

/// Distinguishes "no state file for this PR + head" from an intentionally
/// saved (possibly empty) state. Required before deciding whether old-head
/// drafts should be copied forward to a new head.
public enum PersistedDraftState {
    case missing
    case present([DraftComment])
}

/// Local state (draft comments, viewed-file marks) persistence contract.
/// Asynchronous so implementations can serialize access across windows and
/// report failures without blocking the UI.
public protocol ReviewPersisting {
    /// Loads draft state, distinguishing a missing file from a saved state.
    func loadDraftState(for endpoint: PREndpoint, headSHA: String) async throws -> PersistedDraftState
    func saveDrafts(_ drafts: [DraftComment], for endpoint: PREndpoint, headSHA: String) async throws
    func loadViewed(for endpoint: PREndpoint, headSHA: String) async throws -> Set<String>
    func saveViewed(_ viewed: Set<String>, for endpoint: PREndpoint, headSHA: String) async throws
}

public extension ReviewPersisting {
    /// Convenience: drafts for callers that treat a missing file as empty.
    func loadDrafts(for endpoint: PREndpoint, headSHA: String) async throws -> [DraftComment] {
        switch try await loadDraftState(for: endpoint, headSHA: headSHA) {
        case .missing:
            return []
        case .present(let drafts):
            return drafts
        }
    }
}
