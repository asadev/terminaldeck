import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Device annotation persistence")
struct BackendAppDeviceManagerTests {
    private let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    private func manager(_ root: URL) -> BackendAppDeviceManager {
        .init(locate: { .unavailable("fixture has no engine") }, platform: .init(environment: [:], home: root.path), picturesDirectory: { root })
    }
    @Test func savedRoundUsesActualPNGSizeAndMarksWhereItWasSent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppDevice-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root)
        let raw = BackendAppDeviceParsing.object([("id", .string("round-1")), ("where", BackendAppDeviceParsing.object([("name", .string("iPhone 17 Pro")), ("place", .string("iOS Simulator"))])), ("frame", BackendAppDeviceParsing.object([("width", .number(999)), ("height", .number(999))]))])
        let saved = try await manager.saveRound(png: .string(png), round: BackendAppDeviceParsing.round(raw))
        #expect(saved["width"].number == 1)
        #expect(saved["height"].number == 1)
        #expect(saved["path"].string?.hasSuffix("-annotated.png") == true)
        let path = try #require(saved["path"].string)
        #expect(path.hasPrefix(root.path + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: String(png.dropFirst("data:image/png;base64,".count))))
        await manager.markSent("round-1", sessionID: "s1", label: "shop · Session 1")
        let kept = await manager.annotationRounds()
        #expect(kept.count == 1)
        #expect(kept[0]["picture"]["width"].number == 1)
        #expect(kept[0]["sentTo"]["label"].string == "shop · Session 1")
    }
    @Test func untrustedPictureIsRefusedAndOnlyNewestTwentyRoundsAreKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppDevice-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root)
        do { _ = try await manager.saveRound(png: .string("data:image/png;base64,bm90IGEgcG5n"), round: .object([])); Issue.record("Expected invalid PNG refusal") }
        catch { #expect(error.localizedDescription == "That picture could not be read, so nothing was saved.") }
        let absent = await manager.annotationRounds(); #expect(absent.isEmpty)
        for i in 0..<25 {
            let raw = BackendAppDeviceParsing.object([("id", .string("r\(i)")), ("where", BackendAppDeviceParsing.object([("name", .string("fixture-\(i)"))]))])
            _ = try await manager.saveRound(png: .string(png), round: BackendAppDeviceParsing.round(raw))
        }
        let kept = await manager.annotationRounds()
        #expect(kept.count == 20)
        #expect(kept.first?["id"].string == "r24")
        #expect(kept.last?["id"].string == "r5")
    }
}
