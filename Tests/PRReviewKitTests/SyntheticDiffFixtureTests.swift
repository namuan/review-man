import XCTest
import PRReviewKit
@testable import PRReviewBenchmarkSupport

final class SyntheticDiffFixtureTests: XCTestCase {

    /// Every fixture parses to exactly its requested number of DiffLine values
    /// with multiple files and hunks.
    func testFixtureParsesToExactLineCount() throws {
        for count in [10_000, 50_000, 100_000] {
            let text = SyntheticDiffFixture.make(lineCount: count)
            let files = try SyntheticDiffFixture.verifyAndParse(text, expectedLineCount: count)
            XCTAssertGreaterThan(files.count, 1, "\(count): expected multiple files")
            let hunks = files.reduce(0) { $0 + $1.hunks.count }
            XCTAssertGreaterThan(hunks, 2, "\(count): expected multiple hunks")
        }
    }

    /// The generator is deterministic: same seed → byte-identical text.
    func testFixtureIsDeterministic() {
        let a = SyntheticDiffFixture.make(lineCount: 10_000, seed: 7)
        let b = SyntheticDiffFixture.make(lineCount: 10_000, seed: 7)
        XCTAssertEqual(a, b)
        let c = SyntheticDiffFixture.make(lineCount: 10_000, seed: 8)
        XCTAssertNotEqual(a, c)
    }

    /// The diff contains a realistic mix of context, added, and removed lines,
    /// and both line-number sides are populated.
    func testFixtureHasMixedLineKindsAndBothSides() throws {
        let text = SyntheticDiffFixture.make(lineCount: 50_000, seed: 99)
        let files = try SyntheticDiffFixture.verifyAndParse(text, expectedLineCount: 50_000)
        let lines = files.flatMap { $0.hunks.flatMap { $0.lines } }

        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        let context = lines.filter { $0.kind == .context }.count
        XCTAssertGreaterThan(added, 5_000)
        XCTAssertGreaterThan(removed, 5_000)
        XCTAssertGreaterThan(context, 20_000)
        XCTAssertTrue(lines.contains { $0.oldLine != nil }, "expected old-side line numbers")
        XCTAssertTrue(lines.contains { $0.newLine != nil }, "expected new-side line numbers")
    }

    /// Long lines (for horizontal-scroll exercise) are present but not
    /// pathological.
    func testFixtureContainsLongLines() throws {
        let text = SyntheticDiffFixture.make(lineCount: 50_000, seed: 3)
        let files = try SyntheticDiffFixture.verifyAndParse(text, expectedLineCount: 50_000)
        let longest = files.flatMap { $0.hunks.flatMap { $0.lines } }
            .map { $0.content.count }
            .max() ?? 0
        XCTAssertGreaterThan(longest, 1_000, "expected at least one long source line")
        XCTAssertLessThan(longest, 10_000, "long lines must stay bounded")
    }

    /// Row building over the generated rows stays within a loose budget (no
    /// timing assertion — just a sanity check that row building is linear-ish).
    func testRowBuildProducesPlausibleRowCount() throws {
        let text = SyntheticDiffFixture.make(lineCount: 10_000, seed: 5)
        let files = try SyntheticDiffFixture.verifyAndParse(text, expectedLineCount: 10_000)
        let rowCount = files.reduce(0) { count, file in
            count + RowBuilder.build(file: file, threads: [], drafts: [], outdatedExpanded: true).count
        }
        // 10,000 diff lines + hunk headers + empty states.
        XCTAssertGreaterThan(rowCount, 10_000)
        XCTAssertLessThan(rowCount, 12_000)
    }
}
