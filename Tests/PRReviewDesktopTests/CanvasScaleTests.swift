import XCTest
@testable import PRReviewKit
@testable import PRReviewDesktop

/// The canvas chooses a rendering tier from the PR's size so `make demo`-scale
/// PRs stay interactive. These tests pin the tiers to the demo scale table:
/// small/medium render full patch cards, large and xlarge collapse to
/// file-name cards.
final class CanvasScaleTests: XCTestCase {

    private func makeFiles(count: Int, linesPerFile: Int) -> [DiffFile] {
        (0..<count).map { fileIndex in
            var file = DiffFile()
            var hunk = DiffHunk(
                oldStart: 1, oldCount: linesPerFile,
                newStart: 1, newCount: linesPerFile,
                context: "", lines: []
            )
            hunk.lines = (0..<linesPerFile).map { lineIndex in
                let kind: DiffLine.Kind = lineIndex % 3 == 0 ? .added : (lineIndex % 3 == 1 ? .removed : .context)
                return DiffLine(
                    kind: kind,
                    content: "line \(fileIndex)-\(lineIndex)",
                    oldLine: lineIndex + 1,
                    newLine: lineIndex + 1
                )
            }
            file.hunks = [hunk]
            return file
        }
    }

    func testSmallDemoStaysFull() {
        // 4 files / 31 lines (the curated sample).
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 4, linesPerFile: 8)), .full)
    }

    func testMediumDemoStaysFull() {
        // 50 files / 10k lines — under both condensed thresholds.
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 50, linesPerFile: 200)), .full)
    }

    func testLargeDemoBecomesCondensed() {
        // 250 files / 40k lines — the `make demo` default.
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 250, linesPerFile: 160)), .condensed)
    }

    func testXLargeDemoBecomesSummary() {
        // 800 files / 120k lines.
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 800, linesPerFile: 150)), .summary)
    }

    func testManySmallFilesCondense() {
        // File count alone can trigger degradation even with small diffs.
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 100, linesPerFile: 10)), .condensed)
    }

    func testLineCountAloneTriggersCondensed() {
        // A few files but a huge patch also degrades.
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 10, linesPerFile: 2_000)), .condensed)
    }

    func testLineCountAloneTriggersSummary() {
        XCTAssertEqual(CanvasScale.forFiles(makeFiles(count: 100, linesPerFile: 1_000)), .summary)
    }

    func testEmptyFilesStaysFull() {
        XCTAssertEqual(CanvasScale.forFiles([]), .full)
    }
}
