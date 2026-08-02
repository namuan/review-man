import Foundation

/// Local review state (drafts + viewed marks) for the current head SHA.
public struct ReviewLocalState {
    public var headSHA: String
    public var drafts: [DraftComment]
    public var viewed: Set<String>

    public init(headSHA: String, drafts: [DraftComment], viewed: Set<String>) {
        self.headSHA = headSHA
        self.drafts = drafts
        self.viewed = viewed
    }
}

/// The result of a refresh with head-SHA migration.
public struct RefreshResult {
    public let bundle: FetchBundle
    public let localState: ReviewLocalState
    public let message: String

    public init(bundle: FetchBundle, localState: ReviewLocalState, message: String) {
        self.bundle = bundle
        self.localState = localState
        self.message = message
    }
}

/// A submitted draft snapshot, so callers can remove exactly the drafts that
/// were sent (not drafts created or edited while submission was in flight).
public struct SubmittedDraftSnapshot {
    public let drafts: [DraftComment]
    public init(drafts: [DraftComment]) {
        self.drafts = drafts
    }
}

/// The result of a successful submission.
public struct SubmitResult {
    public let submitted: SubmittedDraftSnapshot
    public init(submitted: SubmittedDraftSnapshot) {
        self.submitted = submitted
    }
}

/// Neutral review operations shared by the legacy TUI controller and the
/// desktop store. Semantic operations only: no SwiftUI, no terminal input, no
/// task ownership, no banners.
public struct ReviewOperations {

    public let service: GitHubServing
    public let persistence: any ReviewPersisting

    public init(service: GitHubServing, persistence: any ReviewPersisting) {
        self.service = service
        self.persistence = persistence
    }

    // MARK: - Refresh + head-SHA migration

    /// Convenience: fetches the bundle, then migrates local state.
    public func refresh(endpoint: PREndpoint, current: ReviewLocalState) async throws -> RefreshResult {
        let bundle = try await service.fetchAll(endpoint)
        return try await migrate(bundle: bundle, endpoint: endpoint, current: current)
    }

    /// Migrates local state for an already-fetched bundle (the TUI fetches in
    /// its fetch lane; the desktop store may fetch separately and call this).
    /// Contract: 1. First load → restore persisted state for the fetched head.
    /// 2. Same head → keep in-memory drafts/viewed. 3. Changed head → save the
    /// old-head state first. 4. Copy old drafts only when the new-head file is
    /// missing (never overwrite an existing, even empty, new-head file).
    /// 5. Reset + persist new-head viewed marks. 6. Revalidate drafts against
    /// the fetched files. Any persistence failure throws without a partial
    /// result.
    public func migrate(
        bundle: FetchBundle,
        endpoint: PREndpoint,
        current: ReviewLocalState
    ) async throws -> RefreshResult {
        let newSHA = bundle.pr.headRefOid
        let oldSHA = current.headSHA

        if oldSHA.isEmpty {
            // First load: restore persisted state for the fetched head.
            let drafts: [DraftComment]
            switch try await persistence.loadDraftState(for: endpoint, headSHA: newSHA) {
            case .missing: drafts = []
            case .present(let existing): drafts = existing
            }
            let viewed = try await persistence.loadViewed(for: endpoint, headSHA: newSHA)
            let validated = DraftAnchorValidator.revalidated(drafts, against: bundle.files)
            return RefreshResult(
                bundle: bundle,
                localState: ReviewLocalState(headSHA: newSHA, drafts: validated, viewed: viewed),
                message: "Refreshed."
            )
        }

        if oldSHA == newSHA {
            let validated = DraftAnchorValidator.revalidated(current.drafts, against: bundle.files)
            return RefreshResult(
                bundle: bundle,
                localState: ReviewLocalState(headSHA: newSHA, drafts: validated, viewed: current.viewed),
                message: "Refreshed."
            )
        }

        // Head changed: preserve the old-head state before anything else.
        try await persistence.saveDrafts(current.drafts, for: endpoint, headSHA: oldSHA)
        try await persistence.saveViewed(current.viewed, for: endpoint, headSHA: oldSHA)

        let state = try await persistence.loadDraftState(for: endpoint, headSHA: newSHA)
        var drafts: [DraftComment]
        var copied = false
        switch state {
        case .present(let existing):
            drafts = existing
        case .missing:
            drafts = current.drafts
            copied = true
            try await persistence.saveDrafts(drafts, for: endpoint, headSHA: newSHA)
        }
        try await persistence.saveViewed([], for: endpoint, headSHA: newSHA)

        let validated = DraftAnchorValidator.revalidated(drafts, against: bundle.files)
        let orphanCount = validated.filter { $0.isOrphaned }.count
        let message: String
        if copied && orphanCount > 0 {
            message = "Head changed. Drafts migrated; \(orphanCount) need reattachment."
        } else if copied {
            message = "Head changed. Drafts migrated to the new head."
        } else if orphanCount > 0 {
            message = "Head changed. Loaded new-head drafts; \(orphanCount) need reattachment."
        } else {
            message = "Head changed. Loaded new-head drafts."
        }
        return RefreshResult(
            bundle: bundle,
            localState: ReviewLocalState(headSHA: newSHA, drafts: validated, viewed: []),
            message: message
        )
    }

    // MARK: - Persistence

    public func saveDrafts(_ drafts: [DraftComment], endpoint: PREndpoint, headSHA: String) async throws {
        try await persistence.saveDrafts(drafts, for: endpoint, headSHA: headSHA)
    }

    public func saveViewed(_ viewed: Set<String>, endpoint: PREndpoint, headSHA: String) async throws {
        try await persistence.saveViewed(viewed, for: endpoint, headSHA: headSHA)
    }

    // MARK: - Submit

    /// Submits only non-orphaned drafts. The returned snapshot identifies the
    /// exact drafts that were sent; callers remove only drafts still equal to
    /// that snapshot afterwards.
    public func submit(
        endpoint: PREndpoint,
        headSHA: String,
        body: String,
        event: ReviewEvent,
        drafts: [DraftComment]
    ) async throws -> SubmitResult {
        let submittable = drafts.filter { !$0.isOrphaned }
        try await service.submitReview(
            endpoint, commitID: headSHA, body: body,
            event: event.apiValue, drafts: submittable
        )
        return SubmitResult(submitted: SubmittedDraftSnapshot(drafts: submittable))
    }

    // MARK: - Threads

    public func reply(endpoint: PREndpoint, commentID: Int, body: String) async throws {
        try await service.replyToThread(endpoint, commentID: commentID, body: body)
    }

    public func setResolved(endpoint: PREndpoint, threadID: String, resolved: Bool) async throws {
        try await service.resolveThread(endpoint, threadID: threadID, resolved: resolved)
    }
}
