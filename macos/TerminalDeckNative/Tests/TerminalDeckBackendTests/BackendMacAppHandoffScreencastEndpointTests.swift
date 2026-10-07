import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendMacAppHandoffEndpointGrant { var allowed = true; func read() -> Bool { allowed }; func revoke() { allowed = false } }
final class BackendMacAppHandoffScreencastEndpointTests: XCTestCase {
    private func context(_ id: UUID = UUID()) -> BackendRemoteHostContext {
        .init(connectionID: id, deviceID: "device", kind: .mine, address: "fixture", peerPublicKey: nil, claimedCapabilities: ["watch"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: true))
    }
    func testNativeHostFeatureKeepsWatchAndWindowGrantTogether() {
        let rig = BackendMacAppHandoffCastRig.make(), endpoint = BackendMacAppHandoffScreencastEndpoint(router: rig.router, hooks: .init(granted: { _ in true }, emit: { _, _ in })), feature = endpoint.feature()
        BackendMacAppHandoffEqual(feature.capability, "watch"); BackendMacAppHandoffEqual(feature.policy, .windowGrant)
        BackendMacAppHandoffEqual(feature.messageTypes, ["browser.watch", "browser.unwatch", "browser.frame.ack", "browser.input", "browser.surfaces", "browser.handover.take", "browser.handover.done"])
    }
    func testNativeEndpointForwardsFeatureToActualRouter() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(), endpoint = BackendMacAppHandoffScreencastEndpoint(router: rig.router, hooks: .init(granted: { _ in true }, emit: { _, frame in await sink.emit(frame.value) })), feature = endpoint.feature(), ctx = context()
        let before = try await feature.handle(.init(BackendMacAppHandoffObject(["t": .string("browser.surfaces")])), ctx)
        BackendMacAppHandoffEqual(before.first?.value["t"], .string("browser.surfaces.rows")); BackendMacAppHandoffEqual(before.first?.value["surfaces"].elements?.first?["live"], .bool(false))
        let after = try await feature.handle(.init(BackendMacAppHandoffObject(["t": .string("browser.watch"), "window": .string(rig.window), "maxWidth": .number(800), "quality": .number(50)])), ctx), frames = await sink.value()
        BackendMacAppHandoffEqual(frames.count, 1); BackendMacAppHandoffEqual(frames[0]["t"], .string("browser.frame")); BackendMacAppHandoffEqual(after.first?.value["t"], .string("browser.handover.state")); await rig.close()
    }
    func testConnectionCloseCallbackReachesDropWatcher() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(), endpoint = BackendMacAppHandoffScreencastEndpoint(router: rig.router, hooks: .init(granted: { _ in true }, emit: { _, frame in await sink.emit(frame.value) })), ctx = context()
        _ = try await endpoint.feature().handle(.init(BackendMacAppHandoffObject(["t": .string("browser.watch"), "window": .string(rig.window), "maxWidth": .number(800), "quality": .number(50)])), ctx)
        try await endpoint.closed(ctx.connectionID); await rig.watch.invalidate()
        let rows = await rig.router.surfaces(), frames = await sink.value(); BackendMacAppHandoffEqual(rows[0]["live"], .bool(false)); BackendMacAppHandoffEqual(frames.count, 1); await rig.close()
    }
    func testGrantRevokedBeforeFrameStopsFurtherPixels() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(), grant = BackendMacAppHandoffEndpointGrant(), endpoint = BackendMacAppHandoffScreencastEndpoint(router: rig.router, hooks: .init(granted: { _ in await grant.read() }, emit: { _, frame in await sink.emit(frame.value) })), ctx = context()
        _ = try await endpoint.feature().handle(.init(BackendMacAppHandoffObject(["t": .string("browser.watch"), "window": .string(rig.window), "maxWidth": .number(800), "quality": .number(50)])), ctx)
        await grant.revoke(); await rig.state.move(60); await rig.watch.invalidate()
        _ = try await endpoint.feature().handle(.init(BackendMacAppHandoffObject(["t": .string("browser.frame.ack"), "window": .string(rig.window), "seq": .number(1)])), ctx)
        let frames = await sink.value(), rows = await rig.router.surfaces(); BackendMacAppHandoffEqual(frames.count, 1); BackendMacAppHandoffEqual(rows[0]["live"], .bool(false)); await rig.close()
    }
}
