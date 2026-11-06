import Foundation
import ImageIO
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private let markdownPixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!

@Test func backendChatMarkdownImagesResolvesConfinedFilesAndRejectsEscapesAndSymlinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try markdownPixel.write(to: root.appendingPathComponent("chart.png"))
    try markdownPixel.write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"), withDestinationURL: outside)
    let result = try await BackendChatMarkdownImages.resolve("![plot](chart.png) ![outside](\(outside.path)) ![link](escape.png)", folder: root.path)
    #expect(result.contains("![plot](data:image/png;base64,"))
    #expect(result.contains("![outside]()") && result.contains("![link]()"))
    #expect(throws: (any Error).self) { try BackendChatMarkdownImages.file("../" + outside.lastPathComponent, folder: root.path) }
    #expect(throws: (any Error).self) { try BackendChatMarkdownImages.file(".env", folder: root.path) }
}

@Test func backendChatMarkdownImagesResolvesHTTPAndBoundsTheWholeDocument() async throws {
    let source = (0..<10).map { "![\($0)](http://example.test/\($0).png)" }.joined(separator: "\n")
    let result = try await BackendChatMarkdownImages.resolve(source, folder: nil, fetch: { url in
        #expect(url.scheme == "http")
        return markdownPixel
    })
    #expect(result.components(separatedBy: "data:image/png;base64,").count - 1 == 8)
    #expect(result.contains("![8]()") && result.contains("![9]()"))
    #expect(result.utf8.count < BackendChatMarkdownImages.maximumEncoded + 1024)
    let tooLarge = try await BackendChatMarkdownImages.resolve("![large](http://example.test/x)", folder: nil,
        fetch: { _ in Data(repeating: 0, count: BackendChatMarkdownImages.maximumInput + 1) })
    #expect(tooLarge == "![large]()")
}

private actor MarkdownImageAccess {
    var checks = 0
    func check() throws {
        checks += 1
        if checks == 2 { throw NativeRPCError(code: "access-denied", message: "The device grant changed.") }
    }
}
@Test func backendChatMarkdownImagesRechecksDeviceGrantAfterTheFetch() async throws {
    let access = MarkdownImageAccess()
    do {
        _ = try await BackendChatMarkdownImages.resolve("![x](http://example.test/x)", folder: nil,
            fetch: { _ in markdownPixel }, access: { try await access.check() })
        Issue.record("Revoked device received an image.")
    } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
    #expect(await access.checks == 2)
}

@Test func backendChatMarkdownImagesUsesParserRangesAndPreservesUnicodeAndCode() {
    let source = "🙂 ![nested **label**](plot.png)\n\n`![code](secret.png)`\n\n![reference][plot]\n\n[plot]: plot.png\n"
    let references = ChatMarkdownImages.references(source)
    #expect(references.count == 2)
    #expect(references.allSatisfy { $0.source == "plot.png" })
    let result = ChatMarkdownImages.replacing(source, references: references, sources: ["plot.png": "data:image/png;base64,AA=="])
    #expect(result.hasPrefix("🙂 ![nested label](data:image/png;base64,AA==)"))
    #expect(result.contains("`![code](secret.png)`"))
    #expect(result.contains("![reference](data:image/png;base64,AA==)"))
}

@Test func backendChatMarkdownImagesPhoneDocumentCarriesRasterInTextAndBlocks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try markdownPixel.write(to: root.appendingPathComponent("plot.png"))
    let folder = root.path
    let service = BackendChatMCPApps(read: { _ in
        .init(rows: HootChatProjection.rows([HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .claude,
            record: .text(.message, id: "m", "![plot](plot.png)"))]), project: folder, provider: "claude")
    }, servers: { _ in [] }, inventory: { _, _, _, _ in .null }, resource: { _, _, _, _ in .null },
        call: { _, _, _, _ in .null }, consent: { _, _, _ in false }, openLink: { _ in false })
    let page = try await service.phoneDocument(session: "s", rowID: "t:m", owner: "phone")
    #expect(page["app"]["text"].string?.contains("data:image/png;base64,") == true)
    #expect(page["app"]["blocks"].elements?.first?["source"].string?.hasPrefix("data:image/png;base64,") == true)
}

@Test func backendChatMarkdownImagesRepeatedSourcesStayWithinAggregateBudget() async throws {
    let text = (0..<100).map { "![image \($0)](http://example.test/repeated.png)" }.joined(separator: "\n")
    let result = try await BackendChatMarkdownImages.resolve(text, folder: nil, fetch: { _ in markdownPixel })
    #expect(result.components(separatedBy: "data:image/png;base64,").count - 1 == 8)
    #expect(result.contains("![image 8]()"))
    #expect(result.utf8.count <= BackendChatMarkdownImages.maximumEncoded + text.utf8.count)
}
