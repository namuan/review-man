import Foundation
import PRReviewKit

/// A render-ready row for the side-by-side diff. Adjacent deletion/addition
/// runs are paired by position; unmatched lines retain an empty opposite cell.
enum SideBySideDiffRow: Identifiable {
    case hunk(hunkIndex: Int)
    case lines(hunkIndex: Int, oldLineIndex: Int?, newLineIndex: Int?)
    case supplementary(DiffDisplayRow)

    var id: String {
        switch self {
        case .hunk(let hunkIndex):
            return "hunk-\(hunkIndex)"
        case .lines(let hunkIndex, let oldLineIndex, let newLineIndex):
            return "lines-\(hunkIndex)-\(oldLineIndex ?? -1)-\(newLineIndex ?? -1)"
        case .supplementary(let row):
            return "supplementary-\(row.id)"
        }
    }
}

enum SideBySideDiffLayout {
    static func rows(file: DiffFile, displayRows: [DiffDisplayRow]) -> [SideBySideDiffRow] {
        let attachments = attachmentsByLine(displayRows)
        var result: [SideBySideDiffRow] = attachments.leading.map(SideBySideDiffRow.supplementary)

        for (hunkIndex, hunk) in file.hunks.enumerated() {
            result.append(.hunk(hunkIndex: hunkIndex))
            var lineIndex = 0
            while lineIndex < hunk.lines.count {
                let line = hunk.lines[lineIndex]
                if line.kind == .context {
                    result.append(.lines(
                        hunkIndex: hunkIndex,
                        oldLineIndex: lineIndex,
                        newLineIndex: lineIndex
                    ))
                    appendAttachments(
                        for: [(hunkIndex, lineIndex)],
                        from: attachments.byLine,
                        to: &result
                    )
                    lineIndex += 1
                    continue
                }

                let runStart = lineIndex
                while lineIndex < hunk.lines.count, hunk.lines[lineIndex].kind != .context {
                    lineIndex += 1
                }
                let run = Array(runStart..<lineIndex)
                let oldLines = run.filter { hunk.lines[$0].kind == .removed }
                let newLines = run.filter { hunk.lines[$0].kind == .added }
                for offset in 0..<max(oldLines.count, newLines.count) {
                    let oldLineIndex = oldLines.indices.contains(offset) ? oldLines[offset] : nil
                    let newLineIndex = newLines.indices.contains(offset) ? newLines[offset] : nil
                    result.append(.lines(
                        hunkIndex: hunkIndex,
                        oldLineIndex: oldLineIndex,
                        newLineIndex: newLineIndex
                    ))
                    appendAttachments(
                        for: [oldLineIndex, newLineIndex].compactMap { lineIndex in
                            lineIndex.map { (hunkIndex, $0) }
                        },
                        from: attachments.byLine,
                        to: &result
                    )
                }
            }
        }

        result.append(contentsOf: attachments.trailing.map(SideBySideDiffRow.supplementary))
        return result
    }

    static func minimumColumnWidth(for file: DiffFile) -> CGFloat {
        let maximumCharacters = file.hunks.reduce(0) { maximum, hunk in
            max(maximum, hunk.lines.reduce(0) { max($0, $1.content.count) })
        }
        return max(320, 52 + CGFloat(maximumCharacters) * 7.2 + 24)
    }

    private static func appendAttachments(
        for linePositions: [(Int, Int)],
        from attachments: [LinePosition: [DiffDisplayRow]],
        to rows: inout [SideBySideDiffRow]
    ) {
        var seen: Set<LinePosition> = []
        for position in linePositions where seen.insert(LinePosition(position)).inserted {
            rows.append(contentsOf: (attachments[LinePosition(position)] ?? []).map(SideBySideDiffRow.supplementary))
        }
    }

    private static func attachmentsByLine(_ displayRows: [DiffDisplayRow]) -> Attachments {
        var leading: [DiffDisplayRow] = []
        var trailing: [DiffDisplayRow] = []
        var byLine: [LinePosition: [DiffDisplayRow]] = [:]
        var activeLine: LinePosition?
        var hasStartedDiff = false

        for displayRow in displayRows {
            switch displayRow.row {
            case .hunkHeader:
                activeLine = nil
                hasStartedDiff = true
            case .line(let hunkIndex, let lineIndex):
                activeLine = LinePosition(hunkIndex, lineIndex)
                hasStartedDiff = true
            case .thread, .draft:
                if let activeLine {
                    byLine[activeLine, default: []].append(displayRow)
                } else if hasStartedDiff {
                    trailing.append(displayRow)
                } else {
                    leading.append(displayRow)
                }
            case .outdatedHeader, .orphanedHeader, .empty:
                if hasStartedDiff {
                    trailing.append(displayRow)
                } else {
                    leading.append(displayRow)
                }
            }
        }
        return Attachments(leading: leading, byLine: byLine, trailing: trailing)
    }

    private struct Attachments {
        let leading: [DiffDisplayRow]
        let byLine: [LinePosition: [DiffDisplayRow]]
        let trailing: [DiffDisplayRow]
    }

    private struct LinePosition: Hashable {
        let hunkIndex: Int
        let lineIndex: Int

        init(_ hunkIndex: Int, _ lineIndex: Int) {
            self.hunkIndex = hunkIndex
            self.lineIndex = lineIndex
        }

        init(_ tuple: (Int, Int)) {
            self.init(tuple.0, tuple.1)
        }
    }
}
