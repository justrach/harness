import ImageIO
import Loro
import UIKit
import XCTest
@testable import Harness

@MainActor
final class GeneratedImageTests: XCTestCase {
    private var fields: [String: Any] {
        ["id": "image-1", "kind": "image", "path": "/uploads/generated.png",
         "name": "generated.png", "mimeType": "image/png"]
    }

    func testImagePartDecodesFromSyncedDocumentAndSurvivesJSONRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let value = LoroValue.fromJSON(try JSONSerialization.jsonObject(with: data))
        let part = try XCTUnwrap(SessionStore.partFrom(value))
        XCTAssertEqual(part.id, "image-1")
        guard case .image(_, let reference) = part else { return XCTFail("image part") }
        XCTAssertEqual(reference.path, "/uploads/generated.png")
        XCTAssertEqual(reference.name, "generated.png")
        XCTAssertEqual(reference.mimeType, "image/png")
    }

    func testMalformedImagesBecomeVisibleErrors() {
        for (key, replacement) in [("path", "relative.png"), ("path", ""),
                                   ("name", ""), ("mimeType", "image/svg+xml"), ("mimeType", "")] {
            var value = fields
            value[key] = replacement
            guard case .error(let id, let message, let reauth)? = SessionStore.partFrom(.fromJSON(value)) else {
                XCTFail("malformed \(key) must not silently disappear")
                continue
            }
            XCTAssertEqual(id, "image-1")
            XCTAssertEqual(message, "Generated image unavailable")
            XCTAssertNil(reauth)
        }
    }

    func testNativeVisualProjectionPreservesMixedPartsAndScript() throws {
        let value: [String: Any] = ["id": "reply", "role": "assistant", "parts": [
            ["id": "before", "kind": "text", "text": "Before"],
            ["id": "v", "kind": "visual", "title": "Overview",
             "script": "error('must not run or display')", "text": "must not display"],
            ["id": "unknown", "kind": "future", "text": "hidden"],
            ["id": "bad", "kind": "visual", "title": "  "],
            ["id": "after", "kind": "text", "text": "After"]
        ]]
        let entry = try XCTUnwrap(SessionStore.entryFrom(.fromJSON(value)))
        XCTAssertEqual(entry.parts, [
            .text(id: "before", text: "Before"),
            .visual(id: "v", title: "Overview", script: "error('must not run or display')"),
            .text(id: "after", text: "After")
        ])
    }

    func testNativeVisualProjectionRequiresABoundedNonblankTitleAndDefaultsMissingScript() {
        let invalid: [Any] = [NSNull(), 42, "", " \n\t", String(repeating: "界", count: 201),
                              String(repeating: "e\u{301}", count: 101)]
        for title in invalid {
            XCTAssertNil(SessionStore.partFrom(.fromJSON(["id": "v", "kind": "visual", "title": title])))
        }
        XCTAssertNil(SessionStore.partFrom(.fromJSON(["id": "v", "kind": "visual"])))
        for title in [String(repeating: "界", count: 200), String(repeating: "😀", count: 200),
                      String(repeating: "e\u{301}", count: 100)] {
            // Projection accepts a missing script and counts Unicode scalars, not grapheme clusters.
            XCTAssertEqual(SessionStore.partFrom(.fromJSON(["id": "v", "kind": "visual", "title": title])),
                           .visual(id: "v", title: title, script: ""))
        }
    }

    private func rows(_ entry: MessageEntry) -> [TranscriptRow] {
        var parsers: [String: IncrementalMarkdownParser] = [:]
        var completed: [String: CompletedParse] = [:]
        return TranscriptRowBuilder.rows(entries: [entry], pendingSends: [],
                                         parsers: &parsers, completed: &completed)
    }

    func testImageRowsPreserveOrderOwnerIdentityAndMetadataCorrections() throws {
        let image = try XCTUnwrap(SessionStore.partFrom(.fromJSON(fields)))
        var entry = MessageEntry(id: "reply", role: .assistant,
            parts: [.text(id: "before", text: "Before"), image,
                    .text(id: "after", text: "After")],
            createdAt: 100, deviceId: "owner", status: .streaming, continuationOf: nil)
        let original = rows(entry)
        XCTAssertEqual(original.count, 3)
        XCTAssertEqual(original[1].id, "reply#image-1")
        guard case .generatedImage(let owner, let reference) = original[1].kind else {
            return XCTFail("generated image row")
        }
        XCTAssertEqual(owner, "owner")
        XCTAssertEqual(reference.path, "/uploads/generated.png")
        entry.status = .complete
        XCTAssertEqual(rows(entry).map(\.id), original.map(\.id))
        entry.deviceId = "other"
        XCTAssertNotEqual(rows(entry)[1].version, original[1].version)
        entry.deviceId = "owner"
        var corrected = reference
        corrected.path = "/uploads/corrected.png"
        entry.parts[1] = .image(id: image.id, reference: corrected)
        XCTAssertNotEqual(rows(entry)[1].version, original[1].version)
        entry.parts = [image]
        let onlyImage = rows(entry)
        XCTAssertTrue(onlyImage[0].turnStart)
        XCTAssertEqual(onlyImage[0].timestamp, 100)
    }

    func testRemoteOwnerPrecedesHostWithoutDuplicates() {
        XCTAssertEqual(GeneratedImageView.devices(owner: "owner", host: "host"), ["owner", "host"])
        XCTAssertEqual(GeneratedImageView.devices(owner: "host", host: "host"), ["host"])
        XCTAssertEqual(GeneratedImageView.devices(owner: "", host: "host"), ["host"])
        XCTAssertEqual(GeneratedImageView.devices(owner: "", host: ""), [])
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format)
            .pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
    }

    func testDecoderBoundsDimensionsAndMemoryAndVerifiesActualFormat() throws {
        let data = png(width: 3072, height: 1024)
        let loaded = try XCTUnwrap(AttachmentImageCache.decodeGeneratedImage(data, mimeType: "image/png"))
        XCTAssertEqual(loaded.image.size.width, 2048)
        XCTAssertEqual(loaded.image.size.width / loaded.image.size.height, 3, accuracy: 0.01)
        XCTAssertLessThanOrEqual(loaded.bytes, 2048 * 2048 * 4)
        XCTAssertNil(AttachmentImageCache.decodeGeneratedImage(data, mimeType: "image/jpeg"))
        XCTAssertNil(AttachmentImageCache.decodeGeneratedImage(Data("not an image".utf8), mimeType: "image/png"))
        XCTAssertNil(AttachmentImageCache.decodeGeneratedImage(png(width: 4097, height: 1), mimeType: "image/png"))
        XCTAssertNil(AttachmentImageCache.decodeGeneratedImage(
            Data(count: AttachmentImageCache.generatedMaxBytes + 1), mimeType: "image/png"))
    }

    func testGeneratedCacheCannotReuseAnUnvalidatedAttachment() {
        let cache = AttachmentImageCache()
        let data = png(width: 64, height: 48)
        cache.seed(deviceId: "owner", path: "/image", name: "image", data: data)
        guard case .loading = cache.snapshot(deviceId: "owner", path: "/image", expectedMimeType: "image/png") else {
            return XCTFail("generated policy requires a separate validated cache entry")
        }
        cache.seed(deviceId: "owner", path: "/image", name: "image", data: data, expectedMimeType: "image/png")
        guard case .loaded = cache.snapshot(deviceId: "owner", path: "/image", expectedMimeType: "image/png") else {
            return XCTFail("validated image should be cached")
        }
        guard case .loading = cache.snapshot(deviceId: "other", path: "/image", expectedMimeType: "image/png") else {
            return XCTFail("cache must stay scoped to the owning device")
        }
    }
}
