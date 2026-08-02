import Foundation
import PRReviewKit
import PRReviewBenchmarkSupport

/// Release-mode headless benchmark for the Phase 4 large-diff acceptance
/// targets. Usage:
///   swift build -c release
///   .build/release/PRReviewBench --fixture 50000 --runs 3
/// Options: --fixture N, --runs N, --format text|json, --json-out PATH.
private struct Options {
    var fixture = 50_000
    var runs = 3
    var format = "text"
    var jsonOut: String?
}

private func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--fixture":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { o.fixture = v }
            else { fail("--fixture requires a positive integer") }
        case "--runs":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { o.runs = v }
            else { fail("--runs requires a positive integer") }
        case "--format":
            i += 1
            if i < args.count, args[i] == "text" || args[i] == "json" { o.format = args[i] }
            else { fail("--format must be text or json") }
        case "--json-out":
            i += 1
            if i < args.count, !args[i].isEmpty { o.jsonOut = args[i] }
            else { fail("--json-out requires a path") }
        case "--help", "-h":
            print("""
            PRReviewBench — Phase 4 large-diff benchmark

            Usage: PRReviewBench [--fixture N] [--runs N] [--format text|json] [--json-out PATH]
              --fixture N    parsed line count (default 50000)
              --runs N       repeated measurements (default 3)
              --format       text (default) or json
              --json-out     also write the JSON report to PATH
            """)
            exit(0)
        default:
            fail("unknown option \(args[i])")
        }
        i += 1
    }
    return o
}

private func fail(_ message: String) -> Never {
    fputs("PRReviewBench: \(message)\n", stderr)
    exit(2)
}

private struct Stage {
    let name: String
    let median: Double
    let p95: Double
    let max: Double
}

private struct RunResult {
    var parse: [Double] = []
    var rowBuild: [Double] = []
    var tokenizeViewport: [Double] = []
    var tokenizeAll: [Double] = []
}

private func summarize(_ samples: [Double]) -> (median: Double, p95: Double, max: Double) {
    guard !samples.isEmpty else { return (0, 0, 0) }
    let sorted = samples.sorted()
    let mid = sorted.count / 2
    let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    return (median, p95, sorted.last!)
}

@main
struct PRReviewBench {
    static func main() {
        let options = parseOptions(CommandLine.arguments)
        let lineCount = options.fixture

        var machine = ""
        if let sysctl = shell(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]) { machine = sysctl }
        let version = ProcessInfo.processInfo.operatingSystemVersionString

        // Generation (once) + footprint before any parsing/row work.
        let (genTime, text) = Measurement.time {
            SyntheticDiffFixture.make(lineCount: lineCount)
        }
        let footprintAfterGeneration = Measurement.physicalFootprintBytes()

        var results = RunResult()
        var totalRows = 0
        var fileCount = 0
        var hunkCount = 0
        var parsedLines = 0
        var tokenCount = 0

        for run in 0..<options.runs {
            let (parseTime, files) = Measurement.time {
                DiffParser.parse(text)
            }
            parsedLines = files.reduce(0) { $0 + $1.lineCount }
            fileCount = files.count
            hunkCount = files.reduce(0) { $0 + $1.hunks.count }

            let (rowTime, rowsBuilt) = Measurement.time {
                files.reduce(0) { count, file in
                    count + RowBuilder.build(file: file, threads: [], drafts: [], outdatedExpanded: true).count
                }
            }
            totalRows = rowsBuilt

            // Syntax highlighting: initial viewport (first 200 diff lines) and
            // an explicit eager-all diagnostic.
            let viewportLines = files.flatMap { $0.hunks.flatMap { $0.lines } }.prefix(200)
            let (vpTime, _) = Measurement.time {
                viewportLines.map { Highlighter.tokenize($0.content, Highlighter.language(for: files.first?.path ?? "")) }
            }
            let (allTime, allTokens) = Measurement.time {
                files.flatMap { file in
                    file.hunks.flatMap { $0.lines }.map { Highlighter.tokenize($0.content, Highlighter.language(for: file.path)) }
                }
            }
            tokenCount = allTokens.reduce(0) { $0 + $1.count }
            results.parse.append(parseTime)
            results.rowBuild.append(rowTime)
            results.tokenizeViewport.append(vpTime)
            results.tokenizeAll.append(allTime)
            _ = rowsBuilt
        }
        let footprintAfterWork = Measurement.physicalFootprintBytes()

        let stages = [
            Stage(name: "parse (incl. word diff)", median: summarize(results.parse).median,
                  p95: summarize(results.parse).p95, max: summarize(results.parse).max),
            Stage(name: "row build", median: summarize(results.rowBuild).median,
                  p95: summarize(results.rowBuild).p95, max: summarize(results.rowBuild).max),
            Stage(name: "highlight viewport (200 lines)", median: summarize(results.tokenizeViewport).median,
                  p95: summarize(results.tokenizeViewport).p95, max: summarize(results.tokenizeViewport).max),
            Stage(name: "highlight all lines (diagnostic)", median: summarize(results.tokenizeAll).median,
                  p95: summarize(results.tokenizeAll).p95, max: summarize(results.tokenizeAll).max),
        ]

        let summary: [String: Any] = [
            "machine": machine,
            "os": version,
            "fixtureLines": lineCount,
            "rawDiffBytes": text.utf8.count,
            "generationSeconds": genTime,
            "parsedFiles": fileCount,
            "parsedHunks": hunkCount,
            "parsedLines": parsedLines,
            "totalDisplayRows": totalRows,
            "tokenCount": tokenCount,
            "footprintMiBAfterGeneration": Measurement.miB(footprintAfterGeneration),
            "footprintMiBAfterWork": Measurement.miB(footprintAfterWork),
            "stages": Dictionary(uniqueKeysWithValues: stages.map { ($0.name, ["median_s": $0.median, "p95_s": $0.p95, "max_s": $0.max]) }),
        ]

        if let path = options.jsonOut {
            let jsonData = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            do {
                try jsonData.write(to: URL(fileURLWithPath: path))
            } catch {
                fputs("PRReviewBench: could not write \(path): \(error)\n", stderr)
                exit(2)
            }
        }

        if options.format == "json" {
            let jsonData = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            print(String(data: jsonData, encoding: .utf8)!)
        } else {
            print("PRReviewBench — \(lineCount)-line fixture")
            print("machine: \(machine) · \(version)")
            print("raw diff: \(text.utf8.count) bytes · generation: \(String(format: "%.3f", genTime))s")
            print("parsed: \(parsedLines) lines · \(hunkCount) hunks · \(fileCount) files · \(totalRows) display rows · \(tokenCount) tokens")
            print("footprint: \(String(format: "%.1f", Measurement.miB(footprintAfterGeneration))) MiB after generation · \(String(format: "%.1f", Measurement.miB(footprintAfterWork))) MiB after work")
            print("")
            print("\(pad("stage", 34))\(pad("median", 10))\(pad("p95", 10))\(pad("max", 10))")
            for s in stages {
                print("\(pad(s.name, 34))\(String(format: "%9.3fs", s.median))\(String(format: "%9.3fs", s.p95))\(String(format: "%9.3fs", s.max))")
            }
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func shell(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
