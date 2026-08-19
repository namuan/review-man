import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

/// The canvas renders a left-to-right folder tree. These tests pin the tree
/// builder (real directory nesting, pre-order flattening, parent/depth
/// bookkeeping) and the pure placement geometry: one column per depth, no
/// overlapping frames, parents centered over children, and a board that
/// contains every node with margin.
final class CanvasTreeTests: XCTestCase {

    private func file(_ path: String) -> DiffFile {
        var diffFile = DiffFile()
        diffFile.newPath = path
        return diffFile
    }

    // MARK: - Tree building

    func testBuildReflectsRealNesting() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
        ])
        // Root, Sources, App, Views, Tests, AppTests.
        XCTAssertEqual(tree.folderCount, 6)
        XCTAssertEqual(tree.fileCount, 4)
        // Pre-order: each folder's subfolder subtrees, then its direct files.
        XCTAssertEqual(tree.nodes.map(\.name), [
            "Root", "Sources", "App", "Views", "Home.swift",
            "Engine.swift", "Tests", "AppTests", "EngineTests.swift", "README.md",
        ])
        XCTAssertEqual(tree.nodes.map(\.isFolder), [
            true, true, true, true, false, false, true, true, false, false,
        ])
    }

    func testParentsAndDepthsFollowPreOrder() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("README.md"),
        ])
        // Root, Sources, App, Views, Home.swift, Engine.swift, README.md
        XCTAssertEqual(tree.depths, [0, 1, 2, 3, 4, 3, 1])
        XCTAssertEqual(tree.parents, [nil, 0, 1, 2, 3, 2, 0])
        // Root counts all; App counts Engine + Views' Home; Views counts Home.
        XCTAssertEqual(tree.subtreeFileCounts, [3, 2, 2, 1, 1, 1, 1])
    }

    func testFilesSortedWithinFolder() {
        let tree = CanvasTree.build(from: [
            file("Sources/z-last.swift"),
            file("Sources/a-first.swift"),
            file("Sources/m-middle.swift"),
        ])
        XCTAssertEqual(tree.nodes.map(\.name), ["Root", "Sources", "a-first.swift", "m-middle.swift", "z-last.swift"])
    }

    func testEmptyBuildHasOnlyRoot() {
        let tree = CanvasTree.build(from: [])
        XCTAssertEqual(tree.nodes.map(\.name), ["Root"])
        XCTAssertEqual(tree.fileCount, 0)
        XCTAssertEqual(tree.subtreeFileCounts, [0])
    }

    func testHidingFolderDescendantsRetainsFolderAndItsTotal() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
        ])
        guard let sources = tree.nodes.first(where: { $0.path == "Sources" }) else {
            return XCTFail("Expected Sources folder")
        }
        let collapsed = tree.hidingDescendants(of: [sources.id])

        XCTAssertEqual(collapsed.nodes.map(\.name), [
            "Root", "Sources", "Tests", "AppTests", "EngineTests.swift", "README.md",
        ])
        XCTAssertEqual(collapsed.parents, [nil, 0, 0, 2, 3, 0])
        XCTAssertEqual(collapsed.depths, [0, 1, 1, 2, 3, 1])
        XCTAssertEqual(collapsed.subtreeFileCounts, [4, 2, 1, 1, 1, 1])
    }

    func testDescendantFolderIDsExcludeTheRequestedFolder() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("README.md"),
        ])
        guard let sources = tree.nodes.first(where: { $0.path == "Sources" }) else {
            return XCTFail("Expected Sources folder")
        }

        let childFolderIDs = tree.childFolderIDs(of: sources.id)
        XCTAssertEqual(childFolderIDs, ["folder:Sources/App"])

        let descendantIDs = tree.descendantFolderIDs(of: sources.id)
        XCTAssertEqual(
            descendantIDs,
            ["folder:Sources/App", "folder:Sources/App/Views"]
        )

        let oneLevel = tree.hidingDescendants(of: childFolderIDs)
        XCTAssertEqual(oneLevel.nodes.map(\.name), ["Root", "Sources", "App", "README.md"])
    }

    func testHidingRootDescendantsLeavesOnlyRoot() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("README.md"),
        ])
        let collapsed = tree.hidingDescendants(of: [tree.nodes[0].id])

        XCTAssertEqual(collapsed.nodes.map(\.name), ["Root"])
        XCTAssertEqual(collapsed.parents, [nil])
        XCTAssertEqual(collapsed.depths, [0])
        XCTAssertEqual(collapsed.subtreeFileCounts, [2])
    }

    // MARK: - Keyboard navigation

    func testKeyboardNavigationFollowsHierarchyAndVisualOrder() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("README.md"),
        ])
        let treePlan = plan(tree: tree)

        XCTAssertEqual(
            CanvasNodeNavigator.nextNodeID(
                from: tree.nodes[2].id,
                direction: .left,
                tree: tree,
                plan: treePlan
            ),
            tree.nodes[1].id
        )
        XCTAssertEqual(
            CanvasNodeNavigator.nextNodeID(
                from: tree.nodes[1].id,
                direction: .right,
                tree: tree,
                plan: treePlan
            ),
            tree.nodes[2].id
        )

        let flatTree = CanvasTree.build(from: [
            file("Sources/Alpha.swift"),
            file("Sources/Beta.swift"),
        ])
        let flatPlan = plan(tree: flatTree)
        XCTAssertEqual(
            CanvasNodeNavigator.nextNodeID(
                from: flatTree.nodes[2].id,
                direction: .down,
                tree: flatTree,
                plan: flatPlan
            ),
            flatTree.nodes[3].id
        )
        XCTAssertEqual(
            CanvasNodeNavigator.nextNodeID(
                from: flatTree.nodes[3].id,
                direction: .up,
                tree: flatTree,
                plan: flatPlan
            ),
            flatTree.nodes[2].id
        )
    }

    func testKeyboardNavigationMovesVerticallyAcrossDepthColumns() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("README.md"),
        ])
        let treePlan = plan(tree: tree)

        // The root has no same-depth peer, but Down must still leave it.
        let nextNodeID = CanvasNodeNavigator.nextNodeID(
            from: tree.nodes[0].id,
            direction: .down,
            tree: tree,
            plan: treePlan
        )

        XCTAssertNotNil(nextNodeID)
        XCTAssertNotEqual(nextNodeID, tree.nodes[0].id)
    }

    // MARK: - Plan geometry

    private func plan(
        tree: CanvasTree,
        columnGap: CGFloat = 48,
        rowGap: CGFloat = 24,
        padding: CGFloat = 40
    ) -> TreePlan {
        let sizes = tree.nodes.map { node in
            node.isFolder
                ? CGSize(width: 190, height: 54)
                : CGSize(width: 250, height: 50)
        }
        return TreePlan.compute(
            sizes: sizes,
            depths: tree.depths,
            parents: tree.parents,
            columnGap: columnGap,
            rowGap: rowGap,
            padding: padding
        )
    }

    func testDepthColumnsGrowLeftToRight() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
        ])
        let plan = plan(tree: tree)
        // Root at column 0, then a column per depth level.
        XCTAssertLessThan(plan.frames[0].minX, plan.frames[1].minX)
        XCTAssertLessThan(plan.frames[1].minX, plan.frames[2].minX)
        XCTAssertLessThan(plan.frames[2].minX, plan.frames[3].minX)
        // Same-depth nodes share a column (root's direct files).
        XCTAssertEqual(plan.frames[1].minX, plan.frames[4].minX)
    }

    func testNoFramesOverlap() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("Sources/App/Views/Detail.swift"),
            file("Sources/App/Models/Item.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
        ])
        let plan = plan(tree: tree)
        for i in 0..<plan.frames.count {
            for j in (i + 1)..<plan.frames.count {
                XCTAssertFalse(
                    plan.frames[i].intersects(plan.frames[j].insetBy(dx: 0.5, dy: 0.5)),
                    "frames \(i) and \(j) overlap: \(plan.frames[i]) vs \(plan.frames[j])"
                )
            }
        }
    }

    func testSiblingFramesUseRowGap() {
        let tree = CanvasTree.build(from: [
            file("First.swift"),
            file("Second.swift"),
        ])
        let plan = plan(tree: tree)

        XCTAssertEqual(plan.frames[1].maxY + 24, plan.frames[2].minY, accuracy: 0.001)
    }

    func testParentCenteredOverChildren() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("Sources/App/Views/Detail.swift"),
        ])
        let plan = plan(tree: tree)
        // "App" is node 2; its children are "Views" (3) and Engine (6). The
        // folder chip should straddle the vertical span of its children.
        let parent = plan.frames[2]
        let firstChild = plan.frames[3]
        let lastChild = plan.frames[6]
        let spanMin = min(firstChild.midY, lastChild.midY)
        let spanMax = max(firstChild.midY, lastChild.midY)
        XCTAssertGreaterThanOrEqual(parent.midY, spanMin - 1)
        XCTAssertLessThanOrEqual(parent.midY, spanMax + 1)
    }

    func testLinksMatchParents() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Tests/AppTests/EngineTests.swift"),
        ])
        let plan = plan(tree: tree)
        XCTAssertEqual(
            plan.links.map { [$0.parent, $0.child] },
            [[0, 1], [1, 2], [2, 3], [0, 4], [4, 5], [5, 6]]
        )
        for link in plan.links {
            // Parent column is left of the child column.
            XCTAssertLessThan(plan.frames[link.parent].maxX, plan.frames[link.child].minX)
        }
    }

    func testBoardContainsEveryNodeWithPadding() {
        let tree = CanvasTree.build(from: [
            file("Sources/App/Engine.swift"),
            file("Sources/App/Views/Home.swift"),
            file("Tests/AppTests/EngineTests.swift"),
            file("README.md"),
        ])
        let plan = plan(tree: tree)
        let pad: CGFloat = 40
        for frame in plan.frames {
            XCTAssertGreaterThanOrEqual(frame.minX, pad - 0.5)
            XCTAssertGreaterThanOrEqual(frame.minY, pad - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, plan.boardSize.width - pad + 0.5)
            XCTAssertLessThanOrEqual(frame.maxY, plan.boardSize.height - pad + 0.5)
        }
    }
}