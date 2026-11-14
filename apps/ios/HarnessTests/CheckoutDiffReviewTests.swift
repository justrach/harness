import XCTest
@testable import Harness

final class CheckoutDiffReviewTests: XCTestCase {
    // MARK: - UnifiedDiffParser

    func testParsesMultiFilePatchWithLineNumbersAndCounts() {
        let patch = """
        diff --git a/src/alpha.rs b/src/alpha.rs
        index 1111111..2222222 100644
        --- a/src/alpha.rs
        +++ b/src/alpha.rs
        @@ -10,4 +10,5 @@ fn alpha() {
         let a = 1;
        -let b = 2;
        +let b = 3;
        +let c = 4;
         return a + b;
        diff --git a/src/beta.swift b/src/beta.swift
        index 3333333..4444444 100644
        --- a/src/beta.swift
        +++ b/src/beta.swift
        @@ -1,2 +1,1 @@
        -oldLine()
         keptLine()
        \\ No newline at end of file

        """

        let files = UnifiedDiffParser.parse(patch)
        XCTAssertEqual(files.count, 2)

        let alpha = files[0]
        XCTAssertEqual(alpha.path, "src/alpha.rs")
        XCTAssertEqual(alpha.additions, 2)
        XCTAssertEqual(alpha.deletions, 1)
        XCTAssertEqual(alpha.hunks?.count, 1)

        let alphaLines = alpha.hunks?[0].lines ?? []
        XCTAssertEqual(alphaLines.count, 5)
        XCTAssertEqual(alphaLines[0].kind, .context)
        XCTAssertEqual(alphaLines[0].oldNumber, 10)
        XCTAssertEqual(alphaLines[0].newNumber, 10)
        XCTAssertEqual(alphaLines[1].kind, .removed)
        XCTAssertEqual(alphaLines[1].oldNumber, 11)
        XCTAssertNil(alphaLines[1].newNumber)
        XCTAssertEqual(alphaLines[2].kind, .added)
        XCTAssertNil(alphaLines[2].oldNumber)
        XCTAssertEqual(alphaLines[2].newNumber, 11)
        XCTAssertEqual(alphaLines[3].kind, .added)
        XCTAssertNil(alphaLines[3].oldNumber)
        XCTAssertEqual(alphaLines[3].newNumber, 12)
        XCTAssertEqual(alphaLines[4].kind, .context)
        XCTAssertEqual(alphaLines[4].oldNumber, 12)
        XCTAssertEqual(alphaLines[4].newNumber, 13)

        let beta = files[1]
        XCTAssertEqual(beta.path, "src/beta.swift")
        XCTAssertEqual(beta.additions, 0)
        XCTAssertEqual(beta.deletions, 1)
        let betaLines = beta.hunks?[0].lines ?? []
        XCTAssertEqual(betaLines.map(\.kind), [.removed, .context])
        XCTAssertEqual(betaLines[0].oldNumber, 1)
        XCTAssertNil(betaLines[0].newNumber)
        XCTAssertEqual(betaLines[1].oldNumber, 2)
        XCTAssertEqual(betaLines[1].newNumber, 1)
    }

    func testParsesRenamesNewFilesDeletedFilesAndQuotedPaths() {
        let patch = """
        diff --git a/old/name.swift b/new/name.swift
        similarity index 100%
        rename from old/name.swift
        rename to new/name.swift
        diff --git "a/docs/my notes.md" "b/docs/my notes.md"
        new file mode 100644
        index 0000000..abcdef1
        --- /dev/null
        +++ "b/docs/my notes.md"
        @@ -0,0 +1,2 @@
        +# Title
        +Body
        diff --git a/legacy.txt b/legacy.txt
        deleted file mode 100644
        index 1234567..0000000
        --- a/legacy.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """

        let files = UnifiedDiffParser.parse(patch)
        XCTAssertEqual(files.map(\.path), ["new/name.swift", "docs/my notes.md", "legacy.txt"])

        XCTAssertEqual(files[0].hunks, [])
        XCTAssertEqual(files[0].additions, 0)
        XCTAssertEqual(files[0].deletions, 0)

        XCTAssertEqual(files[1].additions, 2)
        XCTAssertEqual(files[1].deletions, 0)
        XCTAssertEqual(files[1].hunks?.first?.lines.map(\.newNumber), [1, 2])
        XCTAssertEqual(files[1].hunks?.first?.lines.map(\.oldNumber), [nil, nil])

        XCTAssertEqual(files[2].additions, 0)
        XCTAssertEqual(files[2].deletions, 1)
        XCTAssertEqual(files[2].hunks?.first?.lines.map(\.oldNumber), [1])
        XCTAssertEqual(files[2].hunks?.first?.lines.map(\.newNumber), [nil])
    }

    // MARK: - Selection invariants

    func testSelectionIncludeExpandAndCrossFileReset() {
        let initial = DiffLineSelection.line(12, in: "a.swift")
        XCTAssertFalse(initial.isRange)
        XCTAssertEqual(initial.label, "a.swift:12")

        // Expanding below and above shifts only the nearest edge.
        let expandedDown = initial.including(15, in: "a.swift")
        XCTAssertEqual(expandedDown, DiffLineSelection(path: "a.swift", startLine: 12, endLine: 15))
        XCTAssertTrue(expandedDown.isRange)
        XCTAssertEqual(expandedDown.label, "a.swift:12-15")

        let expandedUp = expandedDown.including(9, in: "a.swift")
        XCTAssertEqual(expandedUp, DiffLineSelection(path: "a.swift", startLine: 9, endLine: 15))

        // Inside current bounds leaves the selection unchanged.
        XCTAssertEqual(expandedUp.including(12, in: "a.swift"), expandedUp)

        // Different file resets to a single-line selection in that file.
        let otherFile = expandedUp.including(4, in: "b.swift")
        XCTAssertEqual(otherFile, DiffLineSelection.line(4, in: "b.swift"))
    }

    func testSelectionExcludeTrimsEdgesOnlyAndClearsSingleLine() {
        let range = DiffLineSelection(path: "a.swift", startLine: 10, endLine: 14)

        // Interior line or other file is a no-op.
        XCTAssertEqual(range.excluding(12, in: "a.swift"), range)
        XCTAssertEqual(range.excluding(10, in: "other.swift"), range)

        // Lower and upper edges trim by one.
        let trimmedStart = range.excluding(10, in: "a.swift")
        XCTAssertEqual(trimmedStart, DiffLineSelection(path: "a.swift", startLine: 11, endLine: 14))
        let trimmedEnd = trimmedStart?.excluding(14, in: "a.swift")
        XCTAssertEqual(trimmedEnd, DiffLineSelection(path: "a.swift", startLine: 11, endLine: 13))

        // Single-line selection untaps to nil.
        XCTAssertNil(DiffLineSelection.line(7, in: "a.swift").excluding(7, in: "a.swift"))
    }

    // MARK: - Batched markdown prompt + draft store

    func testBatchedReviewPromptFormatsScopesAndQuotedLines() {
        let first = DiffReviewComment(
            selection: DiffLineSelection(path: "Sources/Foo.swift", startLine: 42, endLine: 44),
            note: "  Guard against nil here.  ",
            quotedLines: ["-let x = y!", "+guard let x = y else { return }"]
        )
        let second = DiffReviewComment(
            selection: .line(18, in: "README.md"),
            note: "Fix typo",
            quotedLines: ["+Helo world"]
        )

        let single = DiffReviewPrompt.prompt(comments: [first], mode: .turn)
        XCTAssertEqual(
            single,
            """
            Please address 1 review comment on this turn's changes:

            1. Sources/Foo.swift:42-44
               > -let x = y!
               > +guard let x = y else { return }
               Guard against nil here.

            """
        )

        let multi = DiffReviewPrompt.prompt(comments: [first, second], mode: .branch)
        XCTAssertTrue(multi.hasPrefix("Please address 2 review comments on the branch's changes:\n"))
        XCTAssertTrue(multi.contains("2. README.md:18\n   > +Helo world\n   Fix typo\n"))

        let workingTree = DiffReviewPrompt.prompt(comments: [second], mode: .workingTree)
        XCTAssertTrue(workingTree.hasPrefix("Please address 1 review comment on the working tree:\n"))
    }

    @MainActor
    func testDraftStoreTracksCommentsPerChat() {
        let store = DiffReviewDraftStore()
        let c1 = DiffReviewComment(selection: .line(5, in: "a.rs"), note: "Rename", quotedLines: ["+let x = 1;"])
        let c2 = DiffReviewComment(selection: .line(9, in: "b.rs"), note: "Drop", quotedLines: ["-old();"])

        store.add(c1, for: "chat-1")
        store.add(c2, for: "chat-2")
        XCTAssertEqual(store.comments(for: "chat-1"), [c1])
        XCTAssertEqual(store.comments(for: "chat-2"), [c2])

        store.update(note: "Rename variable", for: c1.id, chatId: "chat-1")
        XCTAssertEqual(store.comments(for: "chat-1").first?.note, "Rename variable")

        store.remove(id: c1.id, chatId: "chat-1")
        XCTAssertTrue(store.comments(for: "chat-1").isEmpty)
        XCTAssertEqual(store.comments(for: "chat-2"), [c2])

        store.clear(chatId: "chat-2")
        XCTAssertTrue(store.comments(for: "chat-2").isEmpty)
    }

    // MARK: - Wire JSON decoding

    func testDecodesGetCheckoutDiffWirePayloadAndFallsBackWhenTruncated() throws {
        let json = """
        {
          "checkoutId": "chk-42",
          "deviceId": "dev-mac",
          "cwd": "/Users/dev/project",
          "patch": "diff --git a/a.swift b/a.swift\\n--- a/a.swift\\n+++ b/a.swift\\n@@ -1,1 +1,2 @@\\n let a = 1\\n+let b = 2\\n",
          "files": [
            {
              "path": "a.swift",
              "status": "modified",
              "additions": 1,
              "deletions": 0
            },
            {
              "path": "new/name.png",
              "oldPath": "old/name.png",
              "status": "renamed",
              "additions": 0,
              "deletions": 0,
              "binary": true
            }
          ],
          "additions": 1,
          "deletions": 0,
          "truncated": false,
          "checksum": "abc123",
          "updatedAt": "2026-04-01T12:34:56Z"
        }
        """

        let snapshot = try JSONDecoder().decode(CheckoutDiffSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.checkoutId, "chk-42")
        XCTAssertEqual(snapshot.deviceId, "dev-mac")
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertFalse(snapshot.files[0].binary)
        XCTAssertEqual(snapshot.files[1].oldPath, "old/name.png")
        XCTAssertTrue(snapshot.files[1].binary)
        XCTAssertFalse(snapshot.truncated)

        let parsed = snapshot.parsedFiles
        XCTAssertEqual(parsed.map(\.path), ["a.swift"])
        XCTAssertEqual(parsed.first?.additions, 1)
        XCTAssertEqual(parsed.first?.hunks?.first?.lines.last?.newNumber, 2)

        // When patch is empty (truncated or binary-only), parsedFiles falls back to summaries.
        let truncatedSnapshot = CheckoutDiffSnapshot(
            checkoutId: "chk-42",
            deviceId: "dev-mac",
            cwd: "/Users/dev/project",
            patch: "",
            files: snapshot.files,
            additions: 1,
            deletions: 0,
            truncated: true,
            checksum: "def456",
            updatedAt: "2026-04-01T12:35:00Z"
        )
        let fallback = truncatedSnapshot.parsedFiles
        XCTAssertEqual(fallback.count, 2)
        XCTAssertEqual(fallback[0].path, "a.swift")
        XCTAssertEqual(fallback[0].additions, 1)
        XCTAssertEqual(fallback[1].path, "new/name.png")
        XCTAssertNil(fallback[1].additions)
        XCTAssertNil(fallback[1].deletions)
    }
}
