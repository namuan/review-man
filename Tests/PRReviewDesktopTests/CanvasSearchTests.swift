import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

final class CanvasSearchTests: XCTestCase {

    private func file(_ path: String) -> DiffFile {
        var diffFile = DiffFile()
        diffFile.newPath = path
        return diffFile
    }

    func testMatchesFoldersAndFilesByNameOrPath() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/SearchIndex.swift"),
            file("Tests/SearchIndexTests.swift"),
            file("README.md"),
        ])

        XCTAssertEqual(
            CanvasSearch.results(for: "search", in: tree).map(\.id),
            [
                "file:Sources/App/SearchIndex.swift",
                "file:Tests/SearchIndexTests.swift",
            ]
        )
        XCTAssertEqual(
            CanvasSearch.results(for: "sources/app", in: tree).map(\.id),
            ["folder:Sources/App", "file:Sources/App/SearchIndex.swift"]
        )
    }

    func testEmptyOrWhitespaceQueryDoesNotSelectAnything() {
        let tree = CanvasTree.build(from: [file("Sources/App.swift")])

        XCTAssertTrue(CanvasSearch.results(for: "", in: tree).isEmpty)
        XCTAssertTrue(CanvasSearch.results(for: "   ", in: tree).isEmpty)
    }

    func testAncestorsRevealNestedSearchResult() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Views/Home.swift"),
            file("README.md"),
        ])

        XCTAssertEqual(
            tree.ancestorFolderIDs(of: "file:Sources/App/Views/Home.swift"),
            ["folder:", "folder:Sources", "folder:Sources/App", "folder:Sources/App/Views"]
        )
        XCTAssertEqual(tree.ancestorFolderIDs(of: "folder:Sources/App"), ["folder:", "folder:Sources"])
    }
}
