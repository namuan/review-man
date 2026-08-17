import XCTest
@testable import PRReviewDesktop
@testable import PRReviewKit

final class AppKitDiffLayoutTests: XCTestCase {

    func testPositionsRowsUsingConfiguredHeights() {
        let (file, rows) = makeRows()
        let metrics = AppKitDiffLayoutMetrics(
            lineHeight: 10,
            hunkHeight: 20,
            commentHeight: 30,
            statusHeight: 15,
            characterWidth: 7,
            minimumContentWidth: 100
        )
        let layout = AppKitDiffLayout(file: file, rows: rows, metrics: metrics)

        XCTAssertEqual(layout.rows.map(\.originY), [0, 20, 30, 60, 70])
        XCTAssertEqual(layout.rows.map(\.height), [20, 10, 30, 10, 15])
        XCTAssertEqual(layout.contentHeight, 85)
        XCTAssertGreaterThanOrEqual(layout.contentWidth, 100)
    }

    func testRowHeightOverridesShiftFollowingRows() {
        let (file, rows) = makeRows()
        let layout = AppKitDiffLayout(
            file: file,
            rows: rows,
            rowHeightOverrides: [rows[2].id: 100]
        )

        XCTAssertEqual(layout.row(for: rows[2].id)?.height, 100)
        XCTAssertEqual(layout.row(for: rows[3].id)?.originY, 142)
        XCTAssertEqual(layout.contentHeight, 184)
    }

    func testRowLookupUsesHalfOpenBoundaries() {
        let (file, rows) = makeRows()
        let layout = AppKitDiffLayout(file: file, rows: rows)

        XCTAssertEqual(layout.row(atY: 0)?.id, rows[0].id)
        XCTAssertEqual(layout.row(atY: 24)?.id, rows[1].id)
        XCTAssertEqual(layout.row(atY: 42)?.id, rows[2].id)
        XCTAssertEqual(layout.frame(for: rows[2].id)?.origin.y, 42)
        XCTAssertNil(layout.row(atY: layout.contentHeight))
        XCTAssertNil(layout.row(atY: -1))
    }

    func testVisibleRangeIncludesOnlyIntersectingRowsAndOverscan() {
        let (file, rows) = makeRows()
        let metrics = AppKitDiffLayoutMetrics(
            lineHeight: 10,
            hunkHeight: 20,
            commentHeight: 30,
            statusHeight: 15
        )
        let layout = AppKitDiffLayout(file: file, rows: rows, metrics: metrics)

        XCTAssertEqual(Array(layout.visibleRange(in: CGRect(x: 0, y: 30, width: 400, height: 30))), [2])
        XCTAssertEqual(Array(layout.visibleRange(in: CGRect(x: 0, y: 60, width: 400, height: 10), overscan: 40)), [1, 2, 3, 4])
        XCTAssertEqual(layout.visibleRange(in: .zero), 0..<0)
    }

    func testScrollOriginClampsToDocumentBounds() {
        let (file, rows) = makeRows()
        let metrics = AppKitDiffLayoutMetrics(
            lineHeight: 10,
            hunkHeight: 20,
            commentHeight: 30,
            statusHeight: 15
        )
        let layout = AppKitDiffLayout(file: file, rows: rows, metrics: metrics)
        let lastID = try! XCTUnwrap(rows.last?.id)

        XCTAssertEqual(layout.rowIndex(for: lastID), rows.count - 1)
        XCTAssertEqual(layout.scrollOrigin(for: lastID, viewportHeight: 40, alignment: 1), 45)
        XCTAssertEqual(layout.scrollOrigin(for: lastID, viewportHeight: 500), 0)
        XCTAssertNil(layout.scrollOrigin(for: .empty(file: "missing.swift"), viewportHeight: 40))
    }

    func testEmptyLayoutHasNoVisibleRows() {
        var file = DiffFile()
        file.newPath = "Empty.swift"
        let layout = AppKitDiffLayout(file: file, rows: [])

        XCTAssertEqual(layout.contentHeight, 0)
        XCTAssertEqual(layout.visibleRange(in: CGRect(x: 0, y: 0, width: 400, height: 400)), 0..<0)
        XCTAssertNil(layout.row(atY: 0))
    }

    private func makeRows() -> (DiffFile, [DiffDisplayRow]) {
        let text = """
        diff --git a/Test.swift b/Test.swift
        --- a/Test.swift
        +++ b/Test.swift
        @@ -1,2 +1,3 @@
         let before = 1
        -let old = 2
        +let new = 3
        +let extra = 4
        """
        let file = try! XCTUnwrap(DiffParser.parse(text).first)
        let hunk = file.hunks[0]
        let lines = hunk.lines
        let hunkID = DiffRowID.hunk(
            file: file.path,
            hunk: 0,
            oldStart: hunk.oldStart,
            newStart: hunk.newStart
        )
        var rows = [DiffDisplayRow(
            id: hunkID,
            filePath: file.path,
            row: .hunkHeader(hunkIndex: 0)
        )]
        rows.append(DiffDisplayRow(
            id: DiffRowID.line(
                file: file.path,
                hunk: 0,
                kind: lines[0].kind,
                old: lines[0].oldLine,
                new: lines[0].newLine
            ),
            filePath: file.path,
            row: .line(hunkIndex: 0, lineIndex: 0)
        ))
        rows.append(DiffDisplayRow(
            id: .thread(id: "thread-1"),
            filePath: file.path,
            row: .thread(threadID: "thread-1")
        ))
        rows.append(DiffDisplayRow(
            id: DiffRowID.line(
                file: file.path,
                hunk: 0,
                kind: lines[1].kind,
                old: lines[1].oldLine,
                new: lines[1].newLine
            ),
            filePath: file.path,
            row: .line(hunkIndex: 0, lineIndex: 1)
        ))
        rows.append(DiffDisplayRow(
            id: .empty(file: file.path),
            filePath: file.path,
            row: .empty
        ))
        return (file, rows)
    }
}
