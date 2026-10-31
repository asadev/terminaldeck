import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BrowserInternalsTests: XCTestCase {
    @MainActor
    func testPartitionsAndSessionSlotRetirement() throws {
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(BackendBrowserProfile.profileID(fromPartition: BackendBrowserProfile.partition(for: id)), id)
        XCTAssertEqual(BackendBrowserProfile.partition(for: ""), BackendBrowserProfile.partition(for: "default"))
        XCTAssertNil(BackendBrowserProfile.profileID(fromPartition: "persist:terminaldeck-browser-invalid"))
        let bindings = BackendBrowserBindings()
        let session = BrowserDriverSession(sessionId: "agent", machineId: "local")
        bindings.sessionStarted(session)
        let slot = "session:" + BrowserBindings.key(session)
        bindings.setOwnTab(slot, "tab")
        bindings.setOwnTab("own", "person-tab")
        bindings.sessionExited(session)
        XCTAssertNil(bindings.ownTab(slot))
        XCTAssertEqual(bindings.ownTab("own"), "person-tab")
    }

    func testStoredBlocksDoNotBreakMetadataCaptureAndFulfillmentIsRefused() async throws {
        let rig = try Rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        _ = try await rig.store.setConfig("default", patch: .object([.init("requests", .object([.init("image", .string("block"))]))]))
        let answer = try await rig.network.invoke(.object([.init("action", .string("start")), .init("capture", .bool(true))]), caller: rig.caller)
        XCTAssertEqual(answer["armed"].bool, true)
        _ = try await rig.network.invoke(.object([.init("action", .string("stop"))]), caller: rig.caller)
        for action in ["fulfill", "cheap"] {
            do {
                _ = try await rig.store.setConfig("default", patch: .object([.init("requests", .object([.init("image", .string(action))]))]))
                XCTFail("Unsupported fulfillment was stored")
            } catch {}
        }
        do {
            _ = try await rig.network.invoke(.object([.init("action", .string("start")), .init("rules", .object([.init("image", .string("block"))]))]), caller: rig.caller)
            XCTFail("Explicit interception was silently accepted")
        } catch {}
    }

    func testFailedCloseStillRemovesTheWatchedTab() async throws {
        let rig = try Rig(), fail = FailureSwitch()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let denied = NativeRPCError(code: "fixture", message: "Unused hook")
        let assets = BackendBrowserScrapingAssets(store: rig.store, hooks: .init(
            resolveProfile: { _, _ in throw denied }, fetch: { _, _, _, _, _ in throw denied },
            probe: { _, _, _, _ in throw denied }, directory: { _, _ in throw denied }, file: { _, _ in throw denied },
            authorize: { _, _, _, _, _ in }))
        let manager = BackendWebKitProfileArming(store: rig.store, network: rig.network, assets: assets, hooks: .init(
            authorize: { _, _, _, _, _ in }, baton: { _ in .unclaimed }, networkArguments: { _ in .object([]) },
            applyRules: { _, _, _ in }, removeRules: { _ in if await fail.enabled { throw denied } },
            recordBlock: { _, _, _, _, _ in nil }, safeText: { _, _, _ in "" }, changed: { _, _ in }))
        let token = try await manager.watch(target: rig.target, caller: rig.caller)
        await fail.enable()
        do { try await manager.close(token); XCTFail("Cleanup failure disappeared") } catch {}
        do { _ = try await manager.status(token); XCTFail("Closed tab is still retained") } catch {}
        await fail.disable()
        let replacement = try await manager.watch(target: rig.target, caller: rig.caller)
        try await manager.close(replacement)
    }

    private actor FailureSwitch {
        var enabled = false
        func enable() { enabled = true }
        func disable() { enabled = false }
    }
    private struct Rig {
        let root: URL
        let store: BackendBrowserScrapingStore
        let network: BackendBrowserNetworkCapture
        let target: BackendBrowserCaptureTarget
        let caller = BackendBrowserScrapingCaller.native(.init(caller: .nativeApp, ownerID: "fixture"))
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-internals-" + UUID().uuidString)
            store = BackendBrowserScrapingStore(dataRoot: root, changed: { _ in })
            let target = BackendBrowserCaptureTarget(tabID: "tab", profileID: "default", pageURL: URL(string: "https://example.invalid/")!, title: "Fixture")
            self.target = target
            let finish = BackendBrowserCaptureFinish(pageURL: target.pageURL.absoluteString, title: target.title, tabClosed: false)
            network = BackendBrowserNetworkCapture(store: store, hooks: .init(target: { _, _ in target },
                observe: { _, _, _ in .init(stop: { finish }, retire: { finish }, diagnostics: { .null }) },
                authorize: { _, _, _, _, _ in }))
        }
    }
}
