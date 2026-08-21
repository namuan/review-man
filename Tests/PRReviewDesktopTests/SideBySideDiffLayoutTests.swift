import XCTest
@testable import PRReviewDesktop
@testable import PRReviewKit

final class SideBySideDiffLayoutTests: XCTestCase {
    func testPairsChangedRunsAndLeavesUnmatchedLinesBlank() throws {
        let file = try makeFile()
        let rows = SideBySideDiffLayout.rows(file: file, displayRows: displayRows(for: file))
        let pairs = rows.compactMap { row -> (Int?, Int?)? in
            guard case let .lines(_, oldLineIndex, newLineIndex) = row else { return nil }
            return (oldLineIndex, newLineIndex)
        }

        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].0, 0)
        XCTAssertEqual(pairs[0].1, 0)
        XCTAssertEqual(pairs[1].0, 1)
        XCTAssertEqual(pairs[1].1, 2)
        XCTAssertNil(pairs[2].0)
        XCTAssertEqual(pairs[2].1, 3)
    }

    func testKeepsAttachedCommentsBelowTheirPairedLine() throws {
        let file = try makeFile()
        var rows = displayRows(for: file)
        rows.insert(DiffDisplayRow(
            id: .thread(id: "thread-1"),
            filePath: file.path,
            row: .thread(threadID: "thread-1")
        ), at: 3)

        let sideRows = SideBySideDiffLayout.rows(file: file, displayRows: rows)
        let pairIndex = try XCTUnwrap(sideRows.firstIndex { row in
            if case .lines(_, 1, 2) = row { return true }
            return false
        })
        let commentIndex = try XCTUnwrap(sideRows.firstIndex { row in
            if case .supplementary(let displayRow) = row,
               case .thread(let id) = displayRow.row {
                return id == "thread-1"
            }
            return false
        })

        XCTAssertEqual(commentIndex, pairIndex + 1)
    }

    private func makeFile() throws -> DiffFile {
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
        return try XCTUnwrap(DiffParser.parse(text).first)
    }

    private func displayRows(for file: DiffFile) -> [DiffDisplayRow] {
        let hunk = file.hunks[0]
        return [
            DiffDisplayRow(
                id: .hunk(file: file.path, hunk: 0, oldStart: hunk.oldStart, newStart: hunk.newStart),
                filePath: file.path,
                row: .hunkHeader(hunkIndex: 0)
            )
        ] + hunk.lines.enumerated().map { lineIndex, line in
            DiffDisplayRow(
                id: .line(
                    file: file.path,
                    hunk: 0,
                    kind: line.kind,
                    old: line.oldLine,
                    new: line.newLine
                ),
                filePath: file.path,
                row: .line(hunkIndex: 0, lineIndex: lineIndex)
            )
        }
    }
}
