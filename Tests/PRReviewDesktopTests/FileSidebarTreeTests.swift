import XCTest
@testable import PRReviewDesktop

final class FileSidebarTreeTests: XCTestCase {

    func testBuildsNaturallySortedFolderHierarchyWithFoldersFirst() throws {
        let tree = FileSidebarTreeNode.build(from: [
            item("README.md"),
            item("Sources/App.swift"),
            item("Sources/Views/ChangeCanvasView.swift"),
            item("Tests/AppTests.swift")
        ])

        XCTAssertEqual(tree.map(\.name), ["Sources", "Tests", "README.md"])

        let sources = try XCTUnwrap(tree.first(where: { $0.path == "Sources" }))
        XCTAssertEqual(sources.fileCount, 2)
        XCTAssertEqual(sources.children.map(\.name), ["Views", "App.swift"])
        XCTAssertEqual(sources.children.first?.children.map(\.name), ["ChangeCanvasView.swift"])
    }

    func testFilteredItemsProduceOnlyTheirContainingFoldersAndCounts() throws {
        let tree = FileSidebarTreeNode.build(from: [
            item("Sources/Views/FileSidebarView.swift"),
            item("Sources/Views/ReviewWindowView.swift")
        ])

        let sources = try XCTUnwrap(tree.first)
        let views = try XCTUnwrap(sources.children.first)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(sources.fileCount, 2)
        XCTAssertEqual(views.name, "Views")
        XCTAssertEqual(views.fileCount, 2)
        XCTAssertEqual(views.children.map(\.name), ["FileSidebarView.swift", "ReviewWindowView.swift"])
    }

    private func item(_ path: String) -> FileSidebarItem {
        FileSidebarItem(
            path: path,
            oldPath: nil,
            statusLetter: "M",
            additions: 1,
            deletions: 1,
            isBinary: false,
            tooLarge: false,
            threadCount: 0,
            isViewed: false
        )
    }
}
