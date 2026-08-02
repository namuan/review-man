import XCTest
@testable import PRReviewKit

final class DiffParserTests: XCTestCase {

    func testParsesBasicHunkWithLineNumbers() {
        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -10,4 +10,5 @@ func foo() {
             context line
        -    old line
        +    new line
         }
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.path, "src/a.swift")
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.hunks.count, 1)
        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.oldStart, 10)
        XCTAssertEqual(hunk.oldCount, 4)
        XCTAssertEqual(hunk.newStart, 10)
        XCTAssertEqual(hunk.newCount, 5)
        XCTAssertEqual(hunk.context, "func foo() {")
        XCTAssertEqual(hunk.lines.count, 4)
        let context = hunk.lines[0]
        XCTAssertEqual(context.kind, .context)
        XCTAssertEqual(context.oldLine, 10)
        XCTAssertEqual(context.newLine, 10)
        let removed = hunk.lines[1]
        XCTAssertEqual(removed.kind, .removed)
        XCTAssertEqual(removed.oldLine, 11)
        XCTAssertNil(removed.newLine)
        let added = hunk.lines[2]
        XCTAssertEqual(added.kind, .added)
        XCTAssertNil(added.oldLine)
        XCTAssertEqual(added.newLine, 11)
    }

    func testHunkHeaderWithoutCounts() {
        let diff = """
        diff --git a/a.go b/a.go
        --- a/a.go
        +++ b/a.go
        @@ -5 +5,2 @@
         keep
        +add
        """
        let files = DiffParser.parse(diff)
        let hunk = files[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 5)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newStart, 5)
        XCTAssertEqual(hunk.newCount, 2)
        XCTAssertEqual(hunk.lines.count, 2)
    }

    func testNewAndDeletedFiles() {
        let diff = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        index 4444444..0000000
        --- a/Old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -gone1
        -gone2
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].status, .added)
        XCTAssertNil(files[0].oldPath)
        XCTAssertEqual(files[0].newPath, "New.swift")
        XCTAssertEqual(files[0].hunks[0].newStart, 1)
        XCTAssertEqual(files[1].status, .deleted)
        XCTAssertEqual(files[1].oldPath, "Old.swift")
        XCTAssertNil(files[1].newPath)
        XCTAssertEqual(files[1].hunks[0].oldStart, 1)
    }

    func testRename() {
        let diff = """
        diff --git a/docs/notes.md b/docs/design.md
        similarity index 90%
        rename from docs/notes.md
        rename to docs/design.md
        index 6666666..7777777 100644
        --- a/docs/notes.md
        +++ b/docs/design.md
        @@ -1,3 +1,3 @@
        -# Notes
        +# Design
         body
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].oldPath, "docs/notes.md")
        XCTAssertEqual(files[0].newPath, "docs/design.md")
    }

    func testBinaryFiles() {
        let diff = """
        diff --git a/image.png b/image.png
        index 111..222 100644
        Binary files a/image.png and b/image.png differ
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testNoNewlineMarkerDoesNotCorruptCounts() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +c
        -d
        +e
        \\
        """
        let files = DiffParser.parse(diff)
        let hunk = files[0].hunks[0]
        XCTAssertEqual(hunk.lines.count, 5)
        XCTAssertEqual(hunk.oldCount, 3)
        XCTAssertEqual(hunk.newCount, 3)
    }

    func testAdditionsAndDeletionsCounts() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,3 +1,4 @@
         a
        -b
        +c
        +d
         e
        """
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[0].deletions, 1)
    }

    func testEmptyDiff() {
        XCTAssertEqual(DiffParser.parse("").count, 0)
        XCTAssertEqual(DiffParser.parse("diff --git a/x b/x\n").count, 1)
    }

    func testTotalParserOnGarbage() {
        // Unknown/truncated input must never crash.
        let garbage = "this is not a diff\n@@ -1\n+added\ngarbage"
        let files = DiffParser.parse(garbage)
        XCTAssertTrue(files.isEmpty || !files[0].hunks.isEmpty)
    }

    func testParsesDemoDiff() {
        let files = DiffParser.parse(DemoData.sampleDiff)
        XCTAssertEqual(files.count, 4)
        let app = files[0]
        XCTAssertEqual(app.path, "Sources/PRReview/App.swift")
        XCTAssertEqual(app.additions, 6)
        XCTAssertEqual(app.deletions, 2)
        // line anchors used by demo threads
        // added "private var cursor = 0" is new line 4
        let newLine4 = app.hunks[0].lines.first { $0.newLine == 4 && $0.kind == .added }
        XCTAssertNotNil(newLine4)
        // removed "public func run() {" is old line 7
        let oldLine7 = app.hunks[0].lines.first { $0.oldLine == 7 && $0.kind == .removed }
        XCTAssertNotNil(oldLine7)
        // added "let term = Terminal()" is new line 9
        let newLine9 = app.hunks[0].lines.first { $0.newLine == 9 && $0.kind == .added }
        XCTAssertNotNil(newLine9)
    }
}
