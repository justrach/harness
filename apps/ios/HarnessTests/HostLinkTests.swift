import XCTest
@testable import Harness

final class HostLinkTests: XCTestCase {
    private func classify(_ raw: String, cwd: String? = "/Users/me/project") -> HostLink? {
        HostLink.classify(try! XCTUnwrap(URL(string: raw)), cwd: cwd)
    }

    func testWebMailAndAppLinksStayWithTheSystem() {
        XCTAssertNil(classify("https://example.com/docs"))
        XCTAssertNil(classify("http://192.168.1.20:3000"))
        XCTAssertNil(classify("mailto:me@example.com"))
        XCTAssertNil(classify("harness://open/chat/abc?workspace=x"))
    }

    func testLoopbackPagesOpenTheHostSheet() {
        for raw in ["http://localhost:5173/play", "http://127.0.0.1:8080", "http://0.0.0.0:3000",
                    "http://[::1]:4000/", "https://app.localhost/"] {
            guard case .loopback(let url)? = classify(raw)?.kind else { return XCTFail(raw) }
            XCTAssertEqual(url.absoluteString, raw)
        }
    }

    func testWindowsDrivePathWithSpacesIsAHostFile() throws {
        // URL(string:) percent-encodes the spaces and reads `I` as a scheme.
        let link = try XCTUnwrap(classify("D:/My Projects/demo/playback.html"))
        XCTAssertEqual(link.kind, .file(path: "D:/My Projects/demo/playback.html"))
        XCTAssertNil(link.imagePath, "a Windows path can't be read as a POSIX image")
        XCTAssertEqual(link.copyText, "D:/My Projects/demo/playback.html")
    }

    func testPosixFileAndRelativePathsAreHostFiles() throws {
        XCTAssertEqual(classify("/Users/me/project/README.md")?.kind,
                       .file(path: "/Users/me/project/README.md"))
        XCTAssertEqual(classify("file:///Users/me/My%20Notes.md")?.kind,
                       .file(path: "/Users/me/My Notes.md"))
        XCTAssertEqual(classify("src/main.rs:42")?.kind, .file(path: "src/main.rs"))
        XCTAssertEqual(classify("src/main.rs#L10")?.kind, .file(path: "src/main.rs"))
        XCTAssertNil(classify("#section"), "an in-page anchor has no file")
    }

    func testImageLinksResolveAReadablePath() {
        XCTAssertEqual(classify("/tmp/out/render.png")?.imagePath, "/tmp/out/render.png")
        XCTAssertEqual(classify("./assets/hero.webp")?.imagePath, "/Users/me/project/assets/hero.webp")
        XCTAssertEqual(classify("assets/hero.JPG")?.imagePath, "/Users/me/project/assets/hero.JPG")
        XCTAssertNil(classify("assets/hero.png", cwd: nil)?.imagePath)
        XCTAssertNil(classify("/Users/me/notes.md")?.imagePath)
    }
}
