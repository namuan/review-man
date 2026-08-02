import XCTest
@testable import PRReviewKit

final class RowBuilderTests: XCTestCase {

    private func makeFile() -> DiffFile {
        let diff = """
        diff --git a/Src.swift b/Src.swift
        --- a/Src.swift
        +++ b/Src.swift
        @@ -1,3 +1,4 @@
         keep1
        -old2
        +new2
        +new3
        """
        return DiffParser.parse(diff)[0]
    }

    func testLinesAndHunkHeadersInOrder() {
        let file = makeFile()
        let rows = RowBuilder.build(file: file, threads: [], drafts: [], outdatedExpanded: false)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0], .hunkHeader(hunkIndex: 0))
        XCTAssertEqual(rows[1], .line(hunkIndex: 0, lineIndex: 0))
        XCTAssertEqual(rows[2], .line(hunkIndex: 0, lineIndex: 1))
        XCTAssertEqual(rows[3], .line(hunkIndex: 0, lineIndex: 2))
        XCTAssertEqual(rows[4], .line(hunkIndex: 0, lineIndex: 3))
    }

    func testThreadAttachesAfterItsLine() {
        let file = makeFile()
        // new line 3 = added "new3"
        let thread = PRThread(
            id: "t1", path: "Src.swift", line: 3, originalLine: 3, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
        let rows = RowBuilder.build(file: file, threads: [thread], drafts: [], outdatedExpanded: false)
        let line3Idx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 3))!
        XCTAssertEqual(rows[line3Idx + 1], .thread(threadID: "t1"))
    }

    func testLeftThreadAnchorsOnOldLine() {
        let file = makeFile()
        // old line 2 = removed "old2"
        let thread = PRThread(
            id: "t2", path: "Src.swift", line: nil, originalLine: 2, side: "LEFT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
        let rows = RowBuilder.build(file: file, threads: [thread], drafts: [], outdatedExpanded: false)
        let removedIdx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 1))!
        XCTAssertEqual(rows[removedIdx + 1], .thread(threadID: "t2"))
    }

    func testOutdatedThreadsGoToHeaderSection() {
        let file = makeFile()
        let outdated = PRThread(
            id: "old", path: "Src.swift", line: nil, originalLine: 1, side: "LEFT",
            startLine: nil, startSide: nil, isOutdated: true, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "x", createdAt: Date())]
        )
        let collapsed = RowBuilder.build(file: file, threads: [outdated], drafts: [], outdatedExpanded: false)
        XCTAssertEqual(collapsed.first, .outdatedHeader)
        XCTAssertFalse(collapsed.contains(.thread(threadID: "old")))
        let expanded = RowBuilder.build(file: file, threads: [outdated], drafts: [], outdatedExpanded: true)
        XCTAssertTrue(expanded.contains(.thread(threadID: "old")))
    }

    func testDraftAttachesAndUnanchoredAppends() {
        let file = makeFile()
        let anchored = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "here")
        let orphan = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost")
        let rows = RowBuilder.build(file: file, threads: [], drafts: [anchored, orphan], outdatedExpanded: false)
        let added2Idx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 2))!
        XCTAssertEqual(rows[added2Idx + 1], .draft(draftID: anchored.id))
        XCTAssertEqual(rows.last, .draft(draftID: orphan.id))
    }

    func testEmptyFileYieldsEmptyRow() {
        var file = DiffFile()
        file.newPath = "x.txt"
        let rows = RowBuilder.build(file: file, threads: [], drafts: [], outdatedExpanded: false)
        XCTAssertEqual(rows, [.empty])
    }

    /// Orphaned drafts (isOrphaned) live in a dedicated trailing section and
    /// never attach after a diff line; normal drafts attach as before.
    func testOrphanedDraftsGoToDedicatedSection() {
        let file = makeFile()
        let anchored = DraftComment(path: "Src.swift", line: 2, side: "RIGHT", body: "here")
        let orphan = DraftComment(path: "Src.swift", line: 999, side: "RIGHT", body: "lost", isOrphaned: true)
        let rows = RowBuilder.build(file: file, threads: [], drafts: [anchored, orphan], outdatedExpanded: false)

        XCTAssertTrue(rows.contains(.orphanedHeader))
        let headerIdx = rows.firstIndex(of: .orphanedHeader)!
        XCTAssertEqual(rows[headerIdx + 1], .draft(draftID: orphan.id))
        XCTAssertEqual(rows.last, .draft(draftID: orphan.id))

        // The normal draft still attaches right after its anchor line.
        let added2Idx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 2))!
        XCTAssertEqual(rows[added2Idx + 1], .draft(draftID: anchored.id))
    }

    // MARK: - Anchor precedence (Phase 1 characterization)

    /// Active LEFT threads anchor to the original (old-side) line number,
    /// preferring it over the current line number.
    func testThreadAnchorUsesOriginalLineForActiveLeftThread() {
        let file = makeFile()
        let thread = PRThread(
            id: "t-left", path: "Src.swift", line: 99, originalLine: 2, side: "LEFT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
        XCTAssertEqual(RowBuilder.threadAnchor(thread), 2)
        let rows = RowBuilder.build(file: file, threads: [thread], drafts: [], outdatedExpanded: false)
        let removedIdx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 1))!
        XCTAssertEqual(rows[removedIdx + 1], .thread(threadID: "t-left"))
    }

    /// Active RIGHT threads anchor to the current (new-side) line number,
    /// preferring it over the original line number. The original line is set
    /// to a value absent from the diff so precedence is discriminating: if the
    /// anchor used originalLine, the thread would not attach after the line.
    func testThreadAnchorUsesCurrentLineForActiveRightThread() {
        let file = makeFile()
        let thread = PRThread(
            id: "t-right", path: "Src.swift", line: 3, originalLine: 99, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "hi", createdAt: Date())]
        )
        XCTAssertEqual(RowBuilder.threadAnchor(thread), 3)
        let rows = RowBuilder.build(file: file, threads: [thread], drafts: [], outdatedExpanded: false)
        let new3Idx = rows.firstIndex(of: .line(hunkIndex: 0, lineIndex: 3))!
        XCTAssertEqual(rows[new3Idx + 1], .thread(threadID: "t-right"))
    }

    /// Outdated threads always anchor to the original line number, regardless
    /// of side.
    func testThreadAnchorUsesOriginalLineForOutdatedThread() {
        let right = PRThread(
            id: "o1", path: "Src.swift", line: 5, originalLine: 2, side: "RIGHT",
            startLine: nil, startSide: nil, isOutdated: true, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "x", createdAt: Date())]
        )
        let left = PRThread(
            id: "o2", path: "Src.swift", line: nil, originalLine: 1, side: "LEFT",
            startLine: nil, startSide: nil, isOutdated: true, isResolved: false,
            comments: [PRComment(databaseId: 1, author: "a", body: "x", createdAt: Date())]
        )
        XCTAssertEqual(RowBuilder.threadAnchor(right), 2)
        XCTAssertEqual(RowBuilder.threadAnchor(left), 1)
    }
}
