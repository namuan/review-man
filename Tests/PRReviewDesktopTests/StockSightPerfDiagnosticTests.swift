import XCTest
import SwiftUI
@testable import PRReviewKit
@testable import PRReviewDesktop

/// TEMPORARY diagnostic (delete after use): processes lines with progress
/// written to /tmp/diag_progress.log so a hang can be attributed to a line.
final class StockSightPerfDiagnosticTests: XCTestCase {

    private func log(_ s: String) {
        let line = s + "\n"
        if let data = line.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: "/tmp/diag_progress.log") {
                FileManager.default.createFile(atPath: "/tmp/diag_progress.log", contents: nil)
            }
            let fh = FileHandle(forWritingAtPath: "/tmp/diag_progress.log")
            fh?.seekToEndOfFile()
            fh?.write(data)
            try? fh?.close()
        }
    }

    override func setUp() {
        try? FileManager.default.removeItem(atPath: "/tmp/diag_progress.log")
    }

    func testAllLines() throws {
        let url = URL(fileURLWithPath: "/tmp/pr19.diff")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing /tmp/pr19.diff")
        }
        let diffText = try String(contentsOf: url, encoding: .utf8)
        log("start parse (diff chars=\(diffText.count))")
        let files = DiffParser.parse(diffText)
        let palette = SemanticTheme.palette(for: .light, increasedContrast: false)
        log("parsed files=\(files.count)")

        var lineNo = 0
        var slowCount = 0
        for file in files {
            let languageID = Highlighter.languageID(for: file.path)
            let language = languageID.flatMap { Highlighter.language(forID: $0) }
            for hunk in file.hunks {
                for line in hunk.lines {
                    lineNo += 1
                    guard lineNo >= 2350, lineNo <= 2750 else { continue }
                    log("BEFORE line=\(lineNo) file=\(file.path) hunkStart=\(hunk.newStart) len=\(line.content.count)")
                    let start = CFAbsoluteTimeGetCurrent()
                    let tokens = Highlighter.tokenize(line.content, language)
                    log("TOKENDONE line=\(lineNo) tokens=\(tokens.count)")
                    _ = DiffAttributedStringBuilder.build(
                        line: line,
                        tokens: tokens,
                        palette: palette
                    )
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    log("AFTER line=\(lineNo) ms=\(String(format: "%.1f", ms))")
                }
            }
            log("done file=\(file.path) totalLines=\(lineNo)")
        }
        log("ALL DONE lineNo=\(lineNo) slow=\(slowCount)")
        XCTAssertGreaterThan(lineNo, 0)
    }

    func testLongLinesOnly() throws {
        let url = URL(fileURLWithPath: "/tmp/pr19.diff")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing /tmp/pr19.diff")
        }
        let diffText = try String(contentsOf: url, encoding: .utf8)
        let files = DiffParser.parse(diffText)
        let palette = SemanticTheme.palette(for: .light, increasedContrast: false)
        for file in files {
            let languageID = Highlighter.languageID(for: file.path)
            let language = languageID.flatMap { Highlighter.language(forID: $0) }
            for (hi, hunk) in file.hunks.enumerated() {
                for (li, line) in hunk.lines.enumerated() {
                    guard line.content.count > 200 else { continue }
                    log("LONG file=\(file.path) hunk=\(hi) li=\(li) len=\(line.content.count) kind=\(line.kind)")
                    _ = DiffAttributedStringBuilder.build(
                        line: line,
                        tokens: Highlighter.tokenize(line.content, language),
                        palette: palette
                    )
                    log("LONG ok file=\(file.path) hunk=\(hi) li=\(li)")
                }
            }
        }
        log("LONG ALL DONE")
        XCTAssertGreaterThan(files.count, 0)
    }
}