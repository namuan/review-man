import Foundation

/// Deterministic synthetic unified-diff generator shared by the benchmark,
/// the SwiftUI spike, the demo, and tests. Produces realistic multi-file,
/// multi-hunk diffs that parse to exactly the requested number of `DiffLine`
/// values.
public enum SyntheticDiffFixture {

    /// Realistic path mix so highlighting and row building see varied
    /// languages. Cycles through these across files.
    public static let paths = [
        "Sources/App/Engine.swift",
        "Sources/App/Models.swift",
        "Sources/App/ReviewController.swift",
        "src/ui/panel.ts",
        "src/util/format.ts",
        "lib/core.py",
        "config/settings.json",
        "README.md",
        "scripts/build.sh",
    ]

    /// Generates unified-diff text. `lineCount` is the number of parsed
    /// `DiffLine` values (context + added + removed) across all files. The
    /// file count is derived from the line count (capped at `paths.count`),
    /// matching the original benchmark fixture shape.
    public static func make(
        lineCount: Int,
        seed: UInt64 = 42,
        targetLinesPerHunk: Int = 120
    ) -> String {
        let fileCount = min(paths.count, max(2, lineCount / 20000) + 1)
        return make(fileCount: fileCount, lineCount: lineCount, seed: seed, targetLinesPerHunk: targetLinesPerHunk)
    }

    /// Generates a unified diff with exactly `fileCount` files whose parsed
    /// `DiffLine` values (context + added + removed) total exactly
    /// `lineCount`. File paths are unique at any scale: the first
    /// `paths.count` files use the realistic mix, larger PRs cycle through
    /// generated module paths so a load-test demo can represent a large
    /// monorepo migration without repeating a path.
    public static func make(
        fileCount: Int,
        lineCount: Int,
        seed: UInt64 = 42,
        targetLinesPerHunk: Int = 120
    ) -> String {
        precondition(lineCount > 0, "lineCount must be positive")
        precondition(fileCount > 0, "fileCount must be positive")
        var rng = SplitMix64(seed: seed)
        var lines: [String] = []
        lines.reserveCapacity(lineCount + lineCount / 8)

        var remaining = lineCount
        for fi in 0..<fileCount {
            let isLast = fi == fileCount - 1
            let budget = isLast ? remaining : remaining / (fileCount - fi)
            remaining -= budget
            let path = path(for: fi)
            appendFile(path: path, budget: budget, rng: &rng, targetLinesPerHunk: targetLinesPerHunk, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Deterministic path for file index `fi`: the curated realistic mix for
    /// the first files, then generated module paths with an index suffix so
    /// paths stay unique beyond `paths.count`.
    public static func path(for fi: Int) -> String {
        if fi < paths.count { return paths[fi] }
        let module = ["Engine", "Store", "Pipeline", "Renderer", "Sync", "Telemetry"][fi % 6]
        let area = ["core", "ui", "lib", "services"][(fi / 6) % 4]
        let ext = ["swift", "ts", "py", "json", "md", "sh"][(fi / 24) % 6]
        return "Sources/\(module)/\(area)/\(module)\(fi).\(ext)"
    }

    /// Deterministic 8-bit FNV-1a hash of the path (Swift's `hashValue` is
    /// randomized per process and would break byte-identical fixtures).
    private static func contextToken(for path: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return String(format: "%02x", hash & 0xff)
    }

    private static func appendFile(
        path: String,
        budget: Int,
        rng: inout SplitMix64,
        targetLinesPerHunk: Int,
        into lines: inout [String]
    ) {
        var oldLn = 0
        var newLn = 0
        var emitted = 0
        let token = contextToken(for: path)
        lines.append("diff --git a/\(path) b/\(path)")
        lines.append("--- a/\(path)")
        lines.append("+++ b/\(path)")

        while emitted < budget {
            // Vary hunk size slightly for realism.
            let variation = Int(rng.next() % 21) - 10   // -10 ... +10
            let hunkSize = min(max(20, targetLinesPerHunk + variation), budget - emitted)
            let startOld = oldLn + 1
            let startNew = newLn + 1
            var oldCount = 0
            var newCount = 0
            var lastWasRemoved = false
            let globalBase = emitted

            lines.append("@@ -\(startOld),\(hunkSize) +\(startNew),\(hunkSize) @@ func\(token)")
            for i in 0..<hunkSize {
                let globalIndex = globalBase + i
                let roll = rng.next() % 100
                let kind: Character
                if lastWasRemoved && roll % 2 == 0 {
                    kind = "+"     // removed/addition pairs exercise WordDiff
                } else if roll < 60 {
                    kind = " "
                } else if roll < 80 {
                    kind = "-"
                } else {
                    kind = "+"
                }
                lastWasRemoved = (kind == "-")

                let longLine = globalIndex % 5000 == 0
                let text = makeLineText(globalIndex, longLine: longLine, rng: &rng)
                lines.append("\(kind)\(text)")
                switch kind {
                case "-": oldLn += 1; oldCount += 1
                case "+": newLn += 1; newCount += 1
                default: oldLn += 1; newLn += 1; oldCount += 1; newCount += 1
                }
                emitted += 1
            }
            // Correct the hunk header counts (they differ when add/remove counts differ).
            lines[lines.count - 1 - hunkSize] = "@@ -\(startOld),\(oldCount) +\(startNew),\(newCount) @@ func\(token)"
        }
    }

    private static func makeLineText(_ index: Int, longLine: Bool, rng: inout SplitMix64) -> String {
        if longLine {
            // One long line per ~5000 lines (per file): ~3.1k-5.4k characters.
            let repeats = 60 + Int(rng.next() % 40)   // 60-99 × ~55 chars
            return String(repeating: "value\(index % 7) = transform(argument\(index % 13), options: .extended); ", count: repeats)
        }
        let indent = ["", "  ", "    ", "      ", "        "][Int(rng.next() % 5)]
        let name = ["item", "result", "payload", "session", "entry"][Int(rng.next() % 5)]
        return "\(indent)let \(name)\(index % 97) = compute(\(name)\(index % 53), flag: \(index % 2 == 0))  // \(index)"
    }

    /// Parses the fixture and asserts the exact parsed line count; returns the
    /// parsed files (and throws on mismatch) for tests and tooling.
    public static func verifyAndParse(_ text: String, expectedLineCount: Int) throws -> [DiffFile] {
        let files = DiffParser.parse(text)
        let actual = files.reduce(0) { $0 + $1.lineCount }
        guard actual == expectedLineCount else {
            throw FixtureError.mismatch(expected: expectedLineCount, actual: actual)
        }
        return files
    }

    public enum FixtureError: Error, CustomStringConvertible {
        case mismatch(expected: Int, actual: Int)
        public var description: String {
            switch self {
            case .mismatch(let expected, let actual):
                return "fixture parsed to \(actual) lines, expected \(expected)"
            }
        }
    }
}

/// Small deterministic PRNG (SplitMix64).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) {
        self.state = seed
    }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
