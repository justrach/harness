import Foundation
import XCTest
@testable import Harness

final class ComposerMentionsAndQuestionsTests: XCTestCase {

    // MARK: - MentionIndex.activeQuery

    func testActiveQueryAtStartOfText() throws {
        let emptyAt = try XCTUnwrap(MentionIndex.activeQuery(in: "@", cursor: 1))
        XCTAssertEqual(emptyAt.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(emptyAt.query, "")

        let hit = try XCTUnwrap(MentionIndex.activeQuery(in: "@Composer", cursor: 9))
        XCTAssertEqual(hit.range, NSRange(location: 0, length: 9))
        XCTAssertEqual(hit.query, "Composer")
    }

    func testActiveQueryAfterSpaceAndNewline() throws {
        let afterSpace = try XCTUnwrap(MentionIndex.activeQuery(in: "check @FileMentions", cursor: 19))
        XCTAssertEqual(afterSpace.range, NSRange(location: 6, length: 13))
        XCTAssertEqual(afterSpace.query, "FileMentions")

        let afterNewline = try XCTUnwrap(MentionIndex.activeQuery(in: "first line\n@docs", cursor: 16))
        XCTAssertEqual(afterNewline.range, NSRange(location: 11, length: 5))
        XCTAssertEqual(afterNewline.query, "docs")
    }

    func testActiveQueryIgnoresEmails() {
        XCTAssertNil(MentionIndex.activeQuery(in: "foo@bar", cursor: 7))
        XCTAssertNil(MentionIndex.activeQuery(in: "contact dev@harness.sh", cursor: 22))
        XCTAssertNil(MentionIndex.activeQuery(in: "user+tag@example.com", cursor: 12))
    }

    func testActiveQueryMidWordCursor() throws {
        let text = "inspect @Compo before sending"
        let mid = try XCTUnwrap(MentionIndex.activeQuery(in: text, cursor: 14))
        XCTAssertEqual(mid.range, NSRange(location: 8, length: 6))
        XCTAssertEqual(mid.query, "Compo")

        // Cursor after the space terminates the active mention query.
        XCTAssertNil(MentionIndex.activeQuery(in: text, cursor: 15))
    }

    // MARK: - Collision Disambiguation & Wire Encoding

    func testBasenameCollisionDisambiguationAndEncode() {
        let fileA = WorkspaceFileCandidate(path: "a/Config.swift", kind: .file)
        let fileB = WorkspaceFileCandidate(path: "b/Config.swift", kind: .file)
        let unique = WorkspaceFileCandidate(path: "apps/ios/Harness/Composer/ComposerView.swift", kind: .file)
        let folder = WorkspaceFileCandidate(path: "apps/ios", kind: .directory)

        var index = MentionIndex(candidates: [fileA, fileB, unique, folder])
        let tokenA = index.token(for: fileA)
        let tokenB = index.token(for: fileB)
        let tokenUnique = index.token(for: unique)
        let tokenFolder = index.token(for: folder)

        XCTAssertEqual(tokenA, "@a/Config.swift")
        XCTAssertEqual(tokenB, "@b/Config.swift")
        XCTAssertEqual(tokenUnique, "@ComposerView.swift")
        XCTAssertEqual(tokenFolder, "@ios")

        let draft = "Compare \(tokenA) and \(tokenB) in \(tokenFolder), email dev@harness.sh or @unknown"
        let encoded = index.encode(draft)
        XCTAssertEqual(
            encoded,
            "Compare [Config.swift](harness-file:a/Config.swift) and [Config.swift](harness-file:b/Config.swift) in [ios](harness-file:apps/ios/), email dev@harness.sh or @unknown"
        )
    }

    func testDeepBasenameCollisionWalksUpParents() {
        let deepA = WorkspaceFileCandidate(path: "x/shared/Config.swift", kind: .file)
        let deepB = WorkspaceFileCandidate(path: "y/shared/Config.swift", kind: .file)

        var index = MentionIndex(candidates: [deepA, deepB])
        XCTAssertEqual(index.token(for: deepA), "@x/shared/Config.swift")
        XCTAssertEqual(index.token(for: deepB), "@y/shared/Config.swift")
    }

    // MARK: - Non-Image + Image Attachment Trailers

    func testFileAndImageTrailersDoNotRegressImageParsing() throws {
        let imagePaths = ["/tmp/photo-1.jpg", "/tmp/shot-2.png"]
        let filePaths = ["/tmp/main.swift", "/tmp/notes.pdf"]

        let combined = withAttachments(
            text: withFileAttachments(text: "Please check these", paths: filePaths),
            paths: imagePaths
        )

        let parsedImages = parseUserMessageImages(combined)
        XCTAssertEqual(parsedImages.attachments.map(\.path), imagePaths)
        XCTAssertFalse(parsedImages.text.contains("photo-1.jpg"))
        XCTAssertTrue(parsedImages.text.contains("Please check these"))

        let parsedFiles = parseUserMessageFiles(parsedImages.text)
        XCTAssertEqual(parsedFiles.files.map(\.path), filePaths)
        XCTAssertEqual(parsedFiles.files.map(\.name), ["main.swift", "notes.pdf"])
        XCTAssertEqual(parsedFiles.text, "Please check these")

        // File-only message normalizes sentinel body cleanly.
        let fileOnly = withFileAttachments(text: "", paths: ["/tmp/spec.md"])
        let parsedFileOnly = parseUserMessageFiles(fileOnly)
        XCTAssertEqual(parsedFileOnly.text, "")
        XCTAssertEqual(parsedFileOnly.files.map(\.path), ["/tmp/spec.md"])
        XCTAssertTrue(parseUserMessageImages(fileOnly).attachments.isEmpty)
    }

    func testPickedAttachmentClassifierSeparatesImagesAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-attach-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let codeURL = dir.appendingPathComponent("Sample.swift")
        try Data("struct Sample {}\n".utf8).write(to: codeURL)

        let imgURL = dir.appendingPathComponent("pixel.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let png = renderer.pngData { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try png.write(to: imgURL)

        let result = PickedAttachmentClassifier.classify(urls: [codeURL, imgURL])
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.files.map(\.name), ["Sample.swift"])
        XCTAssertEqual(result.images.count, 1)
    }

    // MARK: - Question Dismiss Command Serialization

    func testDismissInputCommandSerialization() throws {
        let params = AppModel.dismissInputRequestParams(chatId: "chat-1", requestId: "req-42")
        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["chatId"] as? String, "chat-1")
        let command = try XCTUnwrap(json["command"] as? [String: Any])
        XCTAssertEqual(command["kind"] as? String, "dismissInput")
        XCTAssertEqual(command["requestId"] as? String, "req-42")
    }
}
