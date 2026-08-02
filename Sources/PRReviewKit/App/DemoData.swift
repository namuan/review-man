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

    /// The offline demo PR, returned as plain data (no app model).
    public static func makeDemoBundle() -> DemoBundle {
        DemoBundle(
            endpoint: PREndpoint(owner: "octocat", repo: "demo-repo", number: 482),
            pr: PRInfo(
                number: 482,
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
                url: "https://github.com/octocat/demo-repo/pull/482"
            ),
            files: DiffParser.parse(sampleDiff),
            threads: sampleThreads,
            drafts: [],
            viewed: ["README.md"]
        )
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
