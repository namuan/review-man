import XCTest
@testable import PRReviewKit

final class WordDiffTests: XCTestCase {

    func testEmphasisOnChangedWord() {
        let (old, new) = WordDiff.emphasisRanges(old: "public func run() {", new: "public func run() throws {")
        // The old text is entirely covered by common prefix + suffix, so no range.
        XCTAssertNil(old)
        // Only the middle "throws" changed in the new text.
        XCTAssertEqual(new, 18..<25)
    }

    func testIdenticalTextHasNoEmphasis() {
        let (old, new) = WordDiff.emphasisRanges(old: "same", new: "same")
        XCTAssertNil(old)
        XCTAssertNil(new)
    }

    func testCommonPrefixAndSuffix() {
        let (old, new) = WordDiff.emphasisRanges(old: "let x = 1;", new: "let x = 2;")
        XCTAssertEqual(old, 8..<9)
        XCTAssertEqual(new, 8..<9)
    }

    func testFullReplacement() {
        let (old, new) = WordDiff.emphasisRanges(old: "abc", new: "xyz")
        XCTAssertEqual(old, 0..<3)
        XCTAssertEqual(new, 0..<3)
    }

    func testApplyEmphasisPairsRemovedAndAddedRuns() {
        var file = DiffFile()
        file.hunks.append(DiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
            context: "",
            lines: [
                DiffLine(kind: .removed, content: "print(\"old\")", oldLine: 1, newLine: nil),
                DiffLine(kind: .added, content: "print(\"new\")", oldLine: nil, newLine: 1),
            ]
        ))
        WordDiff.applyEmphasis(&file)
        XCTAssertNotNil(file.hunks[0].lines[0].emphasis)
        XCTAssertNotNil(file.hunks[0].lines[1].emphasis)
    }

    func testDegradesOnVeryLongLines() {
        let longA = String(repeating: "a", count: 5000)
        let longB = String(repeating: "b", count: 5000)
        // Must not hang or crash; ranges stay within the 1000-char cap.
        let (old, new) = WordDiff.emphasisRanges(old: longA, new: longB)
        XCTAssertNotNil(old)
        XCTAssertNotNil(new)
    }
}
