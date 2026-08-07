import Foundation
import PRReviewKit

/// Read-only load sequence for a review window: resolve, fetch, restore local
/// state, revalidate drafts, and build the presentation. Extracted so both the
/// demo and real paths share one implementation (and so Phase 6 can extend it
/// with the head-SHA migration shared with the TUI controller).
public struct ReviewSessionLoader {

    public let service: GitHubServing
    public let persistence: ReviewPersisting

    public init(service: GitHubServing, persistence: ReviewPersisting) {
        self.service = service
        self.persistence = persistence
    }

    /// Loads the built-in demo PR at the given scale (or custom file/line
    /// counts). Generation, parsing, draft revalidation, AND presentation
    /// assembly (rows, indexes, sidebar aggregation) all run off the main
    /// actor, so even a load-test-scale demo never freezes the window.
    public func loadDemo(scale: DemoScale = .small, files: Int? = nil, lines: Int? = nil) async throws -> ReviewPresentation {
        let presentation = await Task.detached(priority: .userInitiated) {
            let demo: DemoBundle
            if let files, let lines {
                demo = DemoData.makeDemoBundle(files: files, lines: lines)
            } else {
                demo = DemoData.makeDemoBundle(scale: scale)
            }
            let drafts = DraftAnchorValidator.revalidated(demo.drafts, against: demo.files)
            return ReviewPresentation(
                endpoint: demo.endpoint,
                pr: demo.pr,
                files: demo.files,
                threads: demo.threads,
                drafts: drafts,
                viewed: demo.viewed
            )
        }.value
        return presentation
    }

    /// Loads a qualified reference (full URL or `owner/repo#number`). Bare
    /// numbers are rejected: their resolution depends on the process current
    /// directory, which is unreliable for Finder-launched windows.
    public func load(reference: String) async throws -> ReviewPresentation {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoadError.invalidReference
        }
        let looksBare = trimmed.allSatisfy { $0.isNumber }
        guard !looksBare else {
            throw LoadError.bareNumberNotSupported
        }

        try await service.ensureAvailable()
        let endpoint = try await service.resolveEndpoint(from: trimmed)
        let bundle = try await service.fetchAll(endpoint)

        let drafts = try await persistence.loadDrafts(for: endpoint, headSHA: bundle.pr.headRefOid)
        let viewed = try await persistence.loadViewed(for: endpoint, headSHA: bundle.pr.headRefOid)

        // Draft revalidation + presentation assembly happen off the main actor;
        // only the completed immutable snapshot is handed back.
        let presentation = await Task.detached(priority: .userInitiated) {
            let validated = DraftAnchorValidator.revalidated(drafts, against: bundle.files)
            return ReviewPresentation(
                endpoint: endpoint,
                pr: bundle.pr,
                files: bundle.files,
                threads: bundle.threads,
                drafts: validated,
                viewed: viewed
            )
        }.value
        return presentation
    }

    public enum LoadError: Error, LocalizedError {
        case invalidReference
        case bareNumberNotSupported

        public var errorDescription: String? {
            switch self {
            case .invalidReference:
                return "Enter a full GitHub PR URL or owner/repo#number."
            case .bareNumberNotSupported:
                return "Bare numbers work from the terminal launcher (which knows the repository); use a full URL or owner/repo#number here."
            }
        }
    }
}
