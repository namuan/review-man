import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

/// The change canvas groups files into folder islands before laying them out
/// as a map. These tests pin the grouping rules: real folders become islands,
/// folders holding a single changed file merge into a parent island, root
/// files share one island, and the island list is deterministic regardless of
/// input order.
final class CanvasIslandTests: XCTestCase {

    private func file(_ path: String, additions: Int = 1, deletions: Int = 1) -> DiffFile {
        var diffFile = DiffFile()
        diffFile.newPath = path
        var hunk = DiffHunk(
            oldStart: 1,
            oldCount: additions + deletions,
            newStart: 1,
            newCount: additions + deletions,
            context: "",
            lines: []
        )
        var lines: [DiffLine] = []
        for index in 0..<additions {
            lines.append(DiffLine(kind: .added, content: "a\(index)", oldLine: nil, newLine: index + 1))
        }
        for index in 0..<deletions {
            lines.append(DiffLine(kind: .removed, content: "d\(index)", oldLine: index + 1, newLine: nil))
        }
        hunk.lines = lines
        diffFile.hunks = [hunk]
        return diffFile
    }

    func testGroupsFilesByFolder() {
        let islands = CanvasIsland.makeIslands(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Models.swift"),
            file("Sources/App/ReviewController.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("Tests/AppTests/ModelTests.swift"),
            file("README.md"),
        ])
        // Biggest islands first, then alphabetical.
        XCTAssertEqual(islands.map(\.path), ["Sources/App", "Tests/AppTests", ""])
        XCTAssertEqual(islands.map(\.fileCount), [3, 2, 1])
    }

    func testSingletonFolderPromotesToParent() {
        let islands = CanvasIsland.makeIslands(from: [
            file("src/mod/x.swift"),
            file("src/mod/y.swift"),
            file("src/lib/z.swift"),
            file("src/lib/w.swift"),
            file("tests/run.swift"),
        ])
        // tests/ has one file, so it merges into the root island.
        XCTAssertEqual(islands.map(\.path), ["src/lib", "src/mod", ""])
        XCTAssertEqual(islands.map(\.fileCount), [2, 2, 1])
    }

    func testDeepSingletonCollapsesToRoot() {
        let islands = CanvasIsland.makeIslands(from: [
            file("a/b/c/deep/file.swift"),
            file("README.md"),
        ])
        XCTAssertEqual(islands.count, 1)
        XCTAssertEqual(islands.first?.path, "")
        XCTAssertEqual(islands.first?.fileCount, 2)
    }

    func testRootFilesShareOneIsland() {
        let islands = CanvasIsland.makeIslands(from: [
            file("LICENSE"),
            file("README.md"),
            file("Makefile"),
        ])
        XCTAssertEqual(islands.count, 1)
        XCTAssertEqual(islands.first?.path, "")
        XCTAssertEqual(islands.first?.name, "Root")
    }

    func testFilesInsideIslandAreSortedByPath() {
        let islands = CanvasIsland.makeIslands(from: [
            file("Sources/App/z-last.swift"),
            file("Sources/App/a-first.swift"),
            file("Sources/App/m-middle.swift"),
        ])
        XCTAssertEqual(
            islands.first?.files.map(\.path),
            ["Sources/App/a-first.swift", "Sources/App/m-middle.swift", "Sources/App/z-last.swift"]
        )
    }

    func testMetricsAggregateAcrossIslandFiles() {
        let islands = CanvasIsland.makeIslands(from: [
            file("Sources/App/One.swift", additions: 3, deletions: 2),
            file("Sources/App/Two.swift", additions: 5, deletions: 0),
        ])
        let island = try? XCTUnwrap(islands.first)
        XCTAssertEqual(island?.additions, 8)
        XCTAssertEqual(island?.deletions, 2)
        XCTAssertEqual(island?.lineCount, 10)
    }

    func testIslandListIsDeterministicAcrossInputOrder() {
        let forward = [
            file("Sources/App/Engine.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
            file("Sources/App/Models.swift"),
        ]
        let reversed = Array(forward.reversed())
        let a = CanvasIsland.makeIslands(from: forward)
        let b = CanvasIsland.makeIslands(from: reversed)
        XCTAssertEqual(a, b)
        // Tests/AppTests holds a single file, so it merges into the root.
        // Both islands have two files; equal size sorts by path ("" first).
        XCTAssertEqual(a.map(\.path), ["", "Sources/App"])
        XCTAssertEqual(a.map(\.fileCount), [2, 2])
    }

    func testSmallDemoBundleMapsToTwoIslands() {
        let bundle = DemoData.makeDemoBundle(scale: .small)
        let islands = CanvasIsland.makeIslands(from: bundle.files)
        // Sources/PRReview hosts two files; docs is a singleton that merges
        // into the root island with README.md. Both islands have two files,
        // so the equal-size tie sorts by path ("" first).
        XCTAssertEqual(islands.map(\.path), ["", "Sources/PRReview"])
        XCTAssertEqual(islands.map(\.fileCount), [2, 2])
        XCTAssertEqual(
            islands[0].files.map(\.path).sorted(),
            ["README.md", "docs/design.md"]
        )
        XCTAssertEqual(
            islands[1].files.map(\.path).sorted(),
            ["Sources/PRReview/App.swift", "Sources/PRReview/Terminal.swift"]
        )
    }
}