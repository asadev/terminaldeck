import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 9 Nov (the device list took 7-13 s on Asad's Mac, seven asked at once): one listing for every caller, kept a few
/// seconds, read again when this Mac's devices change; only real device changes count as one.
@Suite("Device list kept between asks")
struct DeviceListCacheTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test func sevenAsksAtOnceListOnceAndAChangeReadsAgain() async throws {
        let reads = Count()
        let sources = BackendAppDeviceInventorySources(
            engineDevices: { [] },
            diskSimulators: {
                reads.add()
                try? await Task.sleep(nanoseconds: 200_000_000)
                return [BackendAppDeviceDiskSimulator(udid: "11111111-2222-3333-4444-555555555555", name: "iPhone", runtime: "", state: "ready")]
            },
            avds: { [] }, avdName: { _ in "" })
        let engine = BackendAppDeviceEngine(helper: "/x/TerminalDeckNativeHelper", dataFolder: "/fixture/data")
        let manager = BackendAppDeviceManager(locate: { .available(engine) }, platform: .init(environment: [:], home: "/fixture"),
                                              picturesDirectory: { URL(fileURLWithPath: "/fixture") }, sources: sources)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<7 { group.addTask { (await manager.list()["devices"].elements ?? []).count } }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 1, count: 7))
        #expect(reads.value == 1, "seven asks at once: one listing")
        _ = await manager.list()
        #expect(reads.value == 1, "asked again within \(BackendAppDeviceManager.listFresh) s: kept")
        await manager.devicesChanged()
        #expect((await manager.list()["devices"].elements ?? []).count == 1)
        #expect(reads.value == 2, "a change: read again")
    }

    @Test func onlyDeviceChangesCount() {
        let roots = BackendAppDeviceListWatch.Roots(home: "/Users/a")
        let sims = "/Users/a/Library/Developer/CoreSimulator/Devices"
        #expect(BackendAppDeviceListWatch.matters(sims + "/", roots: roots), "a simulator added or removed")
        #expect(BackendAppDeviceListWatch.matters(sims + "/11111111-2222-3333-4444-555555555555/", roots: roots), "its device.plist replaced")
        #expect(!BackendAppDeviceListWatch.matters(sims + "/11111111-2222-3333-4444-555555555555/data/Library/Caches/", roots: roots), "an app writing inside it")
        #expect(BackendAppDeviceListWatch.matters("/Users/a/.android/avd", roots: roots), "an emulator added or removed")
        #expect(!BackendAppDeviceListWatch.matters("/Users/a/.android/avd/Pixel_8.avd", roots: roots), "a running emulator writing its disk")
        #expect(BackendAppDeviceListWatch.matters("/Users/a/Library/Caches/TemporaryItems/avd/running/", roots: roots), "an emulator starting or ending")
        #expect(BackendAppDeviceListWatch.matters("/Users/a/Library/Caches/TemporaryItems/avd", roots: roots), "the running folder appearing")
        #expect(!BackendAppDeviceListWatch.matters("/Users/a/Library/Caches/TemporaryItems", roots: roots))
    }
}
