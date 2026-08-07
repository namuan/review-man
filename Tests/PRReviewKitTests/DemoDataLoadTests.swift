import XCTest
import PRReviewKit

/// Load-test coverage for the offline demo: synthetic monorepo-scale PRs must
/// have exact file/line counts, truthful PR stats, and threads that anchor on
/// real added lines so the review UI never shows an unanchored thread.
final class DemoDataLoadTests: XCTestCase {

    func testSmallScaleUnchanged() {
        let bundle = DemoData.makeDemoBundle(scale: .small)
        XCTAssertEqual(bundle.files.count, 4)
        XCTAssertEqual(bundle.pr.additions, 25)
        XCTAssertEqual(bundle.pr.deletions, 6)
        XCTAssertEqual(bundle.pr.changedFiles, 4)
        XCTAssertEqual(bundle.threads.count, 2)
        XCTAssertEqual(bundle.endpoint.number, 482)
        XCTAssertEqual(bundle.viewed, ["README.md"])
    }

    func testSyntheticScalesProduceExactFileCounts() {
        for scale in [DemoScale.medium, .large, .xlarge] {
            let bundle = DemoData.makeDemoBundle(scale: scale)
            XCTAssertEqual(bundle.files.count, scale.fileCount, "\(scale): file count")
            let total = bundle.files.reduce(0) { $0 + $1.lineCount }
            XCTAssertEqual(total, scale.lineCount, "\(scale): line count")
        }
    }

    func testSyntheticPRStatsMatchParsedDiff() {
        let bundle = DemoData.makeDemoBundle(scale: .large)
        let additions = bundle.files.reduce(0) { $0 + $1.additions }
        let deletions = bundle.files.reduce(0) { $0 + $1.deletions }
        XCTAssertEqual(bundle.pr.additions, additions)
        XCTAssertEqual(bundle.pr.deletions, deletions)
        XCTAssertEqual(bundle.pr.changedFiles, bundle.files.count)
        XCTAssertGreaterThan(additions, 0)
        XCTAssertGreaterThan(deletions, 0)
    }

    func testThreadsAnchorOnRealAddedLines() {
        for scale in [DemoScale.medium, .large] {
            let bundle = DemoData.makeDemoBundle(scale: scale)
            XCTAssertGreaterThan(bundle.threads.count, 0, "\(scale): expected threads")
            for thread in bundle.threads {
                guard let file = bundle.files.first(where: { $0.path == thread.path }) else {
                    XCTFail("\(scale): thread \(thread.id) references missing file \(thread.path)")
                    continue
                }
                let lines = file.hunks.flatMap(\.lines)
                XCTAssertTrue(
                    lines.contains { $0.kind == .added && $0.newLine == thread.line },
                    "\(scale): thread \(thread.id) anchor \(thread.path):\(thread.line ?? -1) is not an added line"
                )
            }
        }
    }

    func testCustomSizeBundle() {
        let bundle = DemoData.makeDemoBundle(files: 120, lines: 24_000)
        XCTAssertEqual(bundle.files.count, 120)
        XCTAssertEqual(bundle.files.reduce(0) { $0 + $1.lineCount }, 24_000)
        XCTAssertEqual(bundle.pr.changedFiles, 120)
    }

    func testDemoScaleParsing() {
        XCTAssertEqual(DemoScale.parse("small"), .small)
        XCTAssertEqual(DemoScale.parse("large"), .large)
        XCTAssertEqual(DemoScale.parse("XLARGE"), .xlarge)
        XCTAssertNil(DemoScale.parse("huge"))
    }

    func testSyntheticBundlesAreDeterministic() {
        let a = DemoData.makeDemoBundle(scale: .large)
        let b = DemoData.makeDemoBundle(scale: .large)
        XCTAssertEqual(a.files, b.files)
        XCTAssertEqual(a.threads, b.threads)
        XCTAssertEqual(a.pr.number, b.pr.number)
    }
}
