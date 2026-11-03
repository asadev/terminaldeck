import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 31 Oct: the phone's Activity page (`activity`) and `system.activity`. The kernel reads run for real on this Mac
/// (they are cheap and read-only); the stream runs against a recording sender.
final class PHONEActivityTests: XCTestCase {
    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }

    private static func context(_ connection: UUID, level: BackendINT2PhoneAccessLevel = .look) -> BackendRemoteHostContext {
        .init(connectionID: connection, deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: .mine, unrestricted: false, folders: [], accounts: nil, drivesWindows: false), phoneAccess: level)
    }

    func testShapesCapabilityAndLookOnly() {
        XCTAssertNotNil(parse(#"{"t":"activity.watch","top":false}"#))
        XCTAssertNotNil(parse(#"{"t":"activity.unwatch"}"#))
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains(BackendPhoneActivity.capability), "or installFeatures refuses it")
        for level in BackendINT2PhoneAccessLevel.allCases { XCTAssertTrue(level.permits("activity.watch"), "\(level) may watch") }
    }

    func testAReadingHasEveryFigureAndASecondHasCPU() async throws {
        let reader = BackendSystemActivity(home: NSHomeDirectory(), sessions: { [.init(pid: getpid(), label: "Deck Dev · tests")] })
        let first = await reader.sample()
        XCTAssertTrue(first["cpu"]["total"] == .null, "no CPU before a second reading")
        XCTAssertGreaterThan(first["memory"]["total"].number ?? 0, 0)
        XCTAssertGreaterThan(first["memory"]["used"].number ?? 0, 0)
        XCTAssertTrue(["normal", "warn", "critical"].contains(first["memory"]["pressure"].string ?? ""))
        XCTAssertGreaterThan(first["disk"]["free"].number ?? 0, 0)
        XCTAssertEqual(first["load"].elements?.count, 3)
        // Burn a little CPU so the test process shows up by its session name.
        let until = Date().addingTimeInterval(0.4); var x = 0.0
        while Date() < until { x += sin(x) + 1 }
        XCTAssertGreaterThan(x, 0)
        let second = await reader.sample()
        let cpu = try XCTUnwrap(second["cpu"]["total"].number)
        XCTAssertTrue((0...100).contains(cpu))
        XCTAssertEqual(second["cpu"]["cores"].elements?.count, ProcessInfo.processInfo.activeProcessorCount)
        let names = (second["topCPU"].elements ?? []).compactMap { $0["name"].string } + (second["topMemory"].elements ?? []).compactMap { $0["name"].string }
        XCTAssertTrue(names.contains("Deck Dev · tests"), "this test's own process is grouped under its session: \(names)")
        XCTAssertLessThanOrEqual(second["topCPU"].elements?.count ?? 0, BackendSystemActivity.topCount)
        let lean = await reader.sample(top: false)
        XCTAssertTrue(lean["topCPU"] == .missing, "the Overview's glance skips the process table")
    }

    func testAppsAreNamedByTheirOutermostBundle() {
        XCTAssertEqual(BackendSystemActivity.appName(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(BackendSystemActivity.appName(path: "/Applications/Xcode.app/Contents/MacOS/Xcode"), "Xcode")
        XCTAssertNil(BackendSystemActivity.appName(path: "/usr/bin/swift-frontend"))
        let table: [BackendSystemActivity.Entry] = [.init(pid: 10, ppid: 1, uid: 0, birth: 0, name: "zsh"),
            .init(pid: 11, ppid: 10, uid: 0, birth: 0, name: "swift-build"), .init(pid: 12, ppid: 11, uid: 0, birth: 0, name: "swift-frontend")]
        let parent = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0.ppid) })
        XCTAssertEqual(BackendSystemActivity.groupName(12, table: table, parent: parent, roots: [10: "Deck Dev · build"]).0, "Deck Dev · build")
        XCTAssertEqual(BackendSystemActivity.groupName(12, table: table, parent: parent, roots: [:]).1, "process")
    }

    private final class Sent: @unchecked Sendable {
        let lock = NSLock(); var frames: [(UUID, BackendRemoteServerMessage)] = []
        func add(_ id: UUID, _ m: BackendRemoteServerMessage) { lock.lock(); frames.append((id, m)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    func testTheStreamRunsOnlyWhileSomeoneWatches() async throws {
        let sent = Sent()
        let stream = BackendPhoneActivity(reader: BackendSystemActivity(), beat: .milliseconds(100)) { id, m in sent.add(id, m) }
        let page = UUID(), overview = UUID()
        let first = try await stream.handle(try XCTUnwrap(parse(#"{"t":"activity.watch"}"#)), context: Self.context(page))
        XCTAssertEqual(first.first?.value["t"].string, "activity.sample", "the page is filled at once")
        _ = try await stream.handle(try XCTUnwrap(parse(#"{"t":"activity.watch","top":false}"#)), context: Self.context(overview))
        try await Task.sleep(for: .milliseconds(450))
        let frames = sent.lock.withLock { sent.frames }
        XCTAssertTrue(frames.contains { $0.0 == page && $0.1.value["topCPU"] != .missing })
        XCTAssertTrue(frames.contains { $0.0 == overview } && frames.filter { $0.0 == overview }.allSatisfy { $0.1.value["topCPU"] == .missing })
        _ = try await stream.handle(try XCTUnwrap(parse(#"{"t":"activity.unwatch"}"#)), context: Self.context(page))
        await stream.disconnected(overview)
        let watching = await stream.watching
        XCTAssertEqual(watching, 0)
        let stopped = sent.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(sent.count, stopped, "no reading once nobody watches")
    }
}
