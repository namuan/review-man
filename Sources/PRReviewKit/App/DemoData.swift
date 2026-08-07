import Foundation

/// A self-contained sample PR so the whole review workflow can be exercised
/// offline (`pr-review --demo`). The diff and threads are deliberately small
/// but realistic. Note: context lines start with one leading space; added
/// lines start with '+'; no trailing-whitespace-only lines are used.
public struct DemoBundle {
    public let endpoint: PREndpoint
    public let pr: PRInfo
    public let files: [DiffFile]
    public let threads: [PRThread]
    public let drafts: [DraftComment]
    public let viewed: Set<String>

    public init(
        endpoint: PREndpoint,
        pr: PRInfo,
        files: [DiffFile],
        threads: [PRThread],
        drafts: [DraftComment],
        viewed: Set<String>
    ) {
        self.endpoint = endpoint
        self.pr = pr
        self.files = files
        self.threads = threads
        self.drafts = drafts
        self.viewed = viewed
    }
}

/// Load-test scale tiers for the offline demo. `.small` is the curated
/// hand-written sample; the synthetic tiers generate a monorepo-scale PR with
/// exactly `fileCount` files and `lineCount` changed lines so the whole
/// pipeline (parse → anchor validation → sidebar → row build → threads) can be
/// exercised against realistic large-PR shapes.
public enum DemoScale: Int, CaseIterable, CustomStringConvertible {
    /// Curated 4-file sample (the original demo). Fast onboarding.
    case small = 0
    /// 50 files / 10k changed lines — a busy feature PR.
    case medium = 1
    /// 250 files / 40k changed lines — a wide refactor / migration.
    case large = 2
    /// 800 files / 120k changed lines — a full monorepo migration.
    case xlarge = 3

    public var fileCount: Int {
        switch self {
        case .small: return 4
        case .medium: return 50
        case .large: return 250
        case .xlarge: return 800
        }
    }

    /// Total parsed diff lines (context + added + removed) across all files.
    public var lineCount: Int {
        switch self {
        case .small: return 31
        case .medium: return 10_000
        case .large: return 40_000
        case .xlarge: return 120_000
        }
    }

    /// PR number: unique per scale so windows/persistence never collide.
    public var number: Int {
        switch self {
        case .small: return 482
        case .medium: return 3_104
        case .large: return 18_277
        case .xlarge: return 92_640
        }
    }

    /// Deterministic fixture seed so the same scale always generates the same
    /// diff and threads.
    public var seed: UInt64 {
        switch self {
        case .small: return 0
        case .medium: return 7
        case .large: return 42
        case .xlarge: return 99
        }
    }

    public var description: String {
        switch self {
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        case .xlarge: return "xlarge"
        }
    }

    /// Parses a `--demo-scale` value; nil for unknown names.
    public static func parse(_ raw: String) -> DemoScale? {
        switch raw.lowercased() {
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "xlarge": return .xlarge
        default: return nil
        }
    }
}

public enum DemoData {

    public static let sampleDiff = """
    diff --git a/Sources/PRReview/App.swift b/Sources/PRReview/App.swift
    index 1111111..2222222 100644
    --- a/Sources/PRReview/App.swift
    +++ b/Sources/PRReview/App.swift
    @@ -1,10 +1,14 @@
     import Foundation
     public final class App {
         private let files: [DiffFile]
    +    private var cursor = 0
         public init(files: [DiffFile]) {
             self.files = files
         }
    -    public func run() {
    -        print("running")
    +    public func run() throws {
    +        let term = Terminal()
    +        term.enterRaw()
    +        defer { term.restore() }
    +        render()
         }
     }
    diff --git a/Sources/PRReview/Terminal.swift b/Sources/PRReview/Terminal.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/Sources/PRReview/Terminal.swift
    @@ -0,0 +1,7 @@
    +import Darwin
    +
    +public final class Terminal {
    +    public func enterRaw() {
    +        // enable raw mode
    +    }
    +}
    diff --git a/README.md b/README.md
    index 4444444..5555555 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,4 @@
     # PR Review
    +A terminal UI for reviewing GitHub pull requests.
     ## Usage
     Run `pr-review <url>`.
    diff --git a/docs/notes.md b/docs/design.md
    similarity index 90%
    rename from docs/notes.md
    rename to docs/design.md
    index 6666666..7777777 100644
    --- a/docs/notes.md
    +++ b/docs/design.md
    @@ -1,3 +1,3 @@
    -# Notes
    +# Design
     Draft ideas for the review UI.
     Keep it simple.
    """

    /// The offline demo PR, returned as plain data (no app model). `.small`
    /// is the curated hand-written sample; larger scales synthesize a
    /// monorepo-scale diff with truthful PR stats and spread-out threads.
    public static func makeDemoBundle(scale: DemoScale = .small) -> DemoBundle {
        let endpoint = PREndpoint(owner: "octocat", repo: "demo-repo", number: scale.number)
        if scale == .small {
            return DemoBundle(
                endpoint: endpoint,
                pr: PRInfo(
                    number: scale.number,
                    title: "Add terminal UI skeleton for PR review",
                    body: "Implements the raw-mode terminal layer, a diff parser and a demo\nmode so reviewers can iterate without network access.",
                    author: "octocat",
                    state: "OPEN",
                    isDraft: false,
                    headRefOid: "0123456789abcdef",
                    headRefName: "tui-skeleton",
                    baseRefName: "main",
                    additions: 25,
                    deletions: 6,
                    changedFiles: 4,
                    reviewDecision: "CHANGES_REQUESTED",
                    url: "https://github.com/octocat/demo-repo/pull/\(scale.number)"
                ),
                files: DiffParser.parse(sampleDiff),
                threads: sampleThreads,
                drafts: [],
                viewed: ["README.md"]
            )
        }
        return makeSyntheticBundle(scale: scale, endpoint: endpoint)
    }

    /// Builds a deterministic synthetic load-test PR at `scale`.
    /// PR stats (additions/deletions/changedFiles) are computed from the
    /// parsed fixture so the header always matches the diff. Threads are
    /// anchored on real added lines and spread across files.
    private static func makeSyntheticBundle(scale: DemoScale, endpoint: PREndpoint) -> DemoBundle {
        let text = SyntheticDiffFixture.make(
            fileCount: scale.fileCount,
            lineCount: scale.lineCount,
            seed: scale.seed
        )
        return makeSyntheticBundle(
            files: DiffParser.parse(text),
            number: scale.number,
            headRefOid: String(format: "d3m0%02x", scale.rawValue),
            headRefName: "load-test-\(scale)",
            title: syntheticTitle(scale: scale),
            seed: scale.seed,
            endpoint: endpoint
        )
    }

    /// Custom-size load-test PR: `files` files with `lines` total changed
    /// lines, deterministic from the counts. Useful for probing sizes between
    /// (or beyond) the named tiers.
    public static func makeDemoBundle(files: Int, lines: Int, seed: UInt64 = 0xC0FFEE) -> DemoBundle {
        precondition(files > 0 && lines > 0, "custom demo needs positive file/line counts")
        let text = SyntheticDiffFixture.make(fileCount: files, lineCount: lines, seed: seed)
        let parsed = DiffParser.parse(text)
        let number = (files * 7 + lines) % 900_000 + 1000
        return makeSyntheticBundle(
            files: parsed,
            number: number,
            headRefOid: String(format: "d3m0custom%06x", seed),
            headRefName: "load-test-custom",
            title: syntheticTitle(scale: nil),
            seed: seed,
            endpoint: PREndpoint(owner: "octocat", repo: "demo-repo", number: number)
        )
    }

    /// Shared assembly for synthetic bundles: computes truthful PR stats from
    /// the parsed files and spreads threads across them.
    private static func makeSyntheticBundle(
        files: [DiffFile],
        number: Int,
        headRefOid: String,
        headRefName: String,
        title: String,
        seed: UInt64,
        endpoint: PREndpoint
    ) -> DemoBundle {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let threads = syntheticThreads(seed: seed, files: files)
        let body = "Synthetic load-test PR: \(files.count) files, \(additions) additions, \(deletions) deletions."

        return DemoBundle(
            endpoint: endpoint,
            pr: PRInfo(
                number: number,
                title: title,
                body: body,
                author: "octocat",
                state: "OPEN",
                isDraft: false,
                headRefOid: headRefOid,
                headRefName: headRefName,
                baseRefName: "main",
                additions: additions,
                deletions: deletions,
                changedFiles: files.count,
                reviewDecision: "CHANGES_REQUESTED",
                url: "https://github.com/octocat/demo-repo/pull/\(number)"
            ),
            files: files,
            threads: threads,
            drafts: [],
            viewed: Set(files.prefix(min(10, files.count)).map(\.path))
        )
    }

    private static func syntheticTitle(scale: DemoScale?) -> String {
        guard let scale else {
            return "Custom load-test PR (synthetic)"
        }
        switch scale {
        case .small:
            return "Add terminal UI skeleton for PR review"
        case .medium:
            return "Migrate session state to the shared store (load-test demo)"
        case .large:
            return "Split the monolith into modules (load-test demo)"
        case .xlarge:
            return "Monorepo migration: extract 800 packages (load-test demo)"
        }
    }

    /// Deterministic threads anchored on real added lines, roughly one per 20
    /// files (capped so the sidebar/thread list stays readable). Each thread
    /// has 1–3 comments with rotating synthetic authors.
    private static func syntheticThreads(seed: UInt64, files: [DiffFile]) -> [PRThread] {
        var rng = SplitMix64(seed: seed &+ 0x5EED)
        let count = min(40, max(1, files.count / 20))
        let authors = ["maintainer-jane", "core-chen", "dev-lee", "infra-ada"]
        let reviewerNotes = [
            "This looks fine once the edge cases are covered.",
            "Could we split this into smaller helpers?",
            "Naming nit: consider a clearer identifier here.",
            "Please add a test for this branch.",
            "LGTM — matches the module split we discussed.",
            "The comment on line 4 still applies.",
        ]
        let resolutionNotes = [
            "Done — extracted the helper and added the test.",
            "Agreed, renamed to something clearer.",
            "Covered by the new suite in this PR.",
        ]

        var threads: [PRThread] = []
        var placed = Set<String>()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<count {
            // Deterministically pick a file and one of its added lines.
            let fi = Int(rng.next() % UInt64(files.count))
            let file = files[fi]
            guard let anchor = addedLine(in: file, rng: &rng), let newLine = anchor.newLine else { continue }
            let key = "\(file.path):\(newLine)"
            guard !placed.contains(key) else { continue }
            placed.insert(key)

            let commentCount = 1 + Int(rng.next() % 3)
            var comments: [PRComment] = []
            for c in 0..<commentCount {
                let author = authors[Int(rng.next() % UInt64(authors.count))]
                let note = c == 0
                    ? reviewerNotes[Int(rng.next() % UInt64(reviewerNotes.count))]
                    : resolutionNotes[Int(rng.next() % UInt64(resolutionNotes.count))]
                comments.append(PRComment(
                    databaseId: 90_000 + i * 10 + c,
                    author: author,
                    body: note,
                    createdAt: base.addingTimeInterval(Double(i * 3600 + c * 900))
                ))
            }
            threads.append(PRThread(
                id: "load-thread-\(String(format: "%x", seed))-\(i)",
                path: file.path,
                line: newLine,
                originalLine: newLine,
                side: "RIGHT",
                startLine: nil,
                startSide: nil,
                isOutdated: false,
                isResolved: i % 5 == 0,
                comments: comments
            ))
        }
        return threads
    }

    /// The first added line (newLine present) in `file`, or nil if the file
    /// has no additions.
    private static func addedLine(in file: DiffFile, rng: inout SplitMix64) -> DiffLine? {
        let all = file.hunks.flatMap(\.lines)
        let added = all.filter { $0.kind == .added && $0.newLine != nil }
        guard !added.isEmpty else { return nil }
        return added[Int(rng.next() % UInt64(added.count))]
    }

    static let sampleThreads: [PRThread] = {
        let d1 = parseGHDate("2026-07-30T10:12:00Z") ?? Date()
        let d2 = parseGHDate("2026-07-30T14:30:00Z") ?? Date()
        let d3 = parseGHDate("2026-07-31T09:05:00Z") ?? Date()

        let t1 = PRThread(
            id: "demo-thread-1",
            path: "Sources/PRReview/App.swift",
            line: 9,
            originalLine: 9,
            side: "RIGHT",
            startLine: nil,
            startSide: nil,
            isOutdated: false,
            isResolved: false,
            comments: [
                PRComment(databaseId: 9001, author: "maintainer-jane", body: "Terminal setup should be wrapped so the terminal is always restored, even when render() throws.", createdAt: d1),
                PRComment(databaseId: 9002, author: "octocat", body: "Good point — switched to defer so restore() always runs.", createdAt: d2),
            ]
        )
        let t2 = PRThread(
            id: "demo-thread-2",
            path: "Sources/PRReview/App.swift",
            line: nil,
            originalLine: 7,
            side: "LEFT",
            startLine: nil,
            startSide: nil,
            isOutdated: true,
            isResolved: false,
            comments: [
                PRComment(databaseId: 9003, author: "maintainer-jane", body: "run() can now throw — have all call sites been updated?", createdAt: d3),
            ]
        )
        return [t1, t2]
    }()
}
