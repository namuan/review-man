import Foundation
import PRReviewKit
import PRReviewDesktop
import PRReviewBenchmarkSupport

/// Release-mode headless benchmark for the large-diff acceptance targets.
/// Usage:
///   swift build -c release
///   .build/release/PRReviewBench --fixture 50000 --files 250 --runs 3
/// Options: --fixture N (total parsed lines), --files N (file count; default
/// derives from the line count), --runs N, --format text|json, --json-out PATH.
private struct Options {
    var fixture = 50_000
    var files = 0      // 0 = derive from the line count (legacy shape)
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
        case "--files":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { o.files = v }
            else { fail("--files requires a positive integer") }
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
            PRReviewBench — large-diff benchmark

            Usage: PRReviewBench [--fixture N] [--files N] [--runs N] [--format text|json] [--json-out PATH]
              --fixture N    total parsed line count (default 50000)
              --files N      file count (default: derived from the line count)
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
    var cacheColdViewport: [Double] = []
    var cacheWarmViewport: [Double] = []
    var cacheHitRatio: [Double] = []
    var presentationBuild: [Double] = []
    var viewedToggles: [Double] = []
    var draftMutations: [Double] = []
    var resolveToggles: [Double] = []
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
            if options.files > 0 {
                SyntheticDiffFixture.make(fileCount: options.files, lineCount: lineCount)
            } else {
                SyntheticDiffFixture.make(lineCount: lineCount)
            }
        }
        let footprintAfterGeneration = Measurement.physicalFootprintBytes()

        var results = RunResult()
        var totalRows = 0
        var fileCount = 0
        var hunkCount = 0
        var parsedLines = 0
        var tokenCount = 0

        for _ in 0..<options.runs {
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

            // Rendered-line cache diagnostics: cold viewport (all misses) vs
            // the same viewport again (all hits) — the file-switch hot path.
            let cache = DiffLineCache()
            let langID = Highlighter.languageID(for: files.first?.path ?? "")
            let palette = SemanticTheme.light
            let viewport = Array(files.flatMap { $0.hunks.flatMap { $0.lines } }.prefix(200))
            let (coldTime, _) = Measurement.time {
                for l in viewport {
                    _ = cache.attributedString(for: l, languageID: langID, palette: palette, isDark: false, highContrast: false)
                }
            }
            let (warmTime, _) = Measurement.time {
                for l in viewport {
                    _ = cache.attributedString(for: l, languageID: langID, palette: palette, isDark: false, highContrast: false)
                }
            }
            let total = cache.hitCount + cache.missCount
            results.cacheColdViewport.append(coldTime)
            results.cacheWarmViewport.append(warmTime)
            results.cacheHitRatio.append(total > 0 ? Double(cache.hitCount) / Double(total) : 0)

            // Local-mutation scaling: incremental updates must cost far less
            // than the full presentation build (they rebuild only the affected
            // file's rows). 200 toggles / 100 draft mutations / 100 resolves.
            var threads: [PRThread] = []
            var drafts: [DraftComment] = []
            let mutationFiles = files.prefix(20)
            for (i, f) in mutationFiles.enumerated() {
                threads.append(PRThread(
                    id: "bench-t-\(i)", path: f.path, line: 1, originalLine: 1, side: "RIGHT",
                    startLine: nil, startSide: nil, isOutdated: false, isResolved: false,
                    comments: [PRComment(databaseId: i, author: "a", body: "x", createdAt: Date())]
                ))
                drafts.append(DraftComment(path: f.path, line: 1, side: "RIGHT", body: "d"))
            }
            let (presentationTime, presentation) = Measurement.time {
                ReviewPresentation(
                    endpoint: nil, pr: nil, files: files, threads: threads,
                    drafts: drafts, viewed: []
                )
            }
            let (viewedTime, _) = Measurement.time {
                var p = presentation
                var viewed = Set<String>()
                for f in files.prefix(200) {
                    viewed.insert(f.path)
                    p = p.withViewed(viewed)
                }
                _ = p
            }
            let (draftTime, _) = Measurement.time {
                var p = presentation
                var ds = drafts
                for i in 0..<100 {
                    ds.append(DraftComment(path: mutationFiles[i % 20].path, line: 1, side: "RIGHT", body: "m\(i)"))
                    p = p.withDrafts(ds)
                }
                _ = p
            }
            let (resolveTime, _) = Measurement.time {
                var p = presentation
                for i in 0..<100 {
                    var t = threads[i % threads.count]
                    t.isResolved = !t.isResolved
                    p = p.withThread(t)
                }
                _ = p
            }
            results.presentationBuild.append(presentationTime)
            results.viewedToggles.append(viewedTime)
            results.draftMutations.append(draftTime)
            results.resolveToggles.append(resolveTime)
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
            Stage(name: "line cache: cold viewport", median: summarize(results.cacheColdViewport).median,
                  p95: summarize(results.cacheColdViewport).p95, max: summarize(results.cacheColdViewport).max),
            Stage(name: "line cache: warm viewport", median: summarize(results.cacheWarmViewport).median,
                  p95: summarize(results.cacheWarmViewport).p95, max: summarize(results.cacheWarmViewport).max),
            Stage(name: "presentation build (full)", median: summarize(results.presentationBuild).median,
                  p95: summarize(results.presentationBuild).p95, max: summarize(results.presentationBuild).max),
            Stage(name: "200 viewed toggles (incremental)", median: summarize(results.viewedToggles).median,
                  p95: summarize(results.viewedToggles).p95, max: summarize(results.viewedToggles).max),
            Stage(name: "100 draft mutations (incremental)", median: summarize(results.draftMutations).median,
                  p95: summarize(results.draftMutations).p95, max: summarize(results.draftMutations).max),
            Stage(name: "100 resolve toggles (incremental)", median: summarize(results.resolveToggles).median,
                  p95: summarize(results.resolveToggles).p95, max: summarize(results.resolveToggles).max),
        ]
        let cacheHitRatio = results.cacheHitRatio.last ?? 0

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
            "cacheHitRatio": cacheHitRatio,
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
            print("PRReviewBench — \(options.files > 0 ? "\(lineCount)-line / \(options.files)-file fixture" : "\(lineCount)-line fixture")")
            print("machine: \(machine) · \(version)")
            print("raw diff: \(text.utf8.count) bytes · generation: \(String(format: "%.3f", genTime))s")
            print("parsed: \(parsedLines) lines · \(hunkCount) hunks · \(fileCount) files · \(totalRows) display rows · \(tokenCount) tokens")
            print("line cache hit ratio: \(String(format: "%.1f", cacheHitRatio * 100))% on the warm viewport")
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
