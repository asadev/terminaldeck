import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Terminal Deck's own device engine (28 Oct 2026): what Apple's and Google's tools print, read into the panel's and the
/// tools' shapes, and the session around a driver. The third-party engine it replaces is gone from code and bundle.
@Suite("Own device engine")
struct BackendAppDeviceOwnEngineTests {
    // MARK: screenrecord's H.264

    private let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
    private let pps = Data([0x68, 0xEB, 0xE3, 0xCB])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x33])
    private let slice = Data([0x41, 0x9A, 0x02, 0x10])
    private func annexB(_ units: [Data], long: Bool = true) -> Data {
        units.reduce(into: Data()) { out, unit in out.append(contentsOf: long ? [0, 0, 0, 1] : [0, 0, 1]); out.append(unit) }
    }

    @Test func unitsAreCutAtStartCodesAcrossAnyChunking() {
        let stream = annexB([sps, pps, idr]) + annexB([slice], long: false)
        for size in [1, 2, 3, 5, 7, stream.count] {
            var splitter = BackendAppDeviceAnnexB(), found: [Data] = []
            var at = 0
            while at < stream.count { found += splitter.push(stream.subdata(in: at..<min(at + size, stream.count))); at += size }
            found += splitter.flush()
            #expect(found == [sps, pps, idr, slice], "chunks of \(size)")
        }
    }

    @Test func theLastPictureArrivesWhenTheStreamPauses() {
        var splitter = BackendAppDeviceAnnexB()
        #expect(splitter.push(annexB([sps, pps, idr])) == [sps, pps])
        #expect(splitter.flush() == [idr])
        #expect(splitter.flush() == [])
    }

    @Test func configurationPrecedesTheFirstPictureAndAgainAfterAResend() throws {
        var packets = BackendAppDeviceH264Packets()
        #expect(packets.push(slice, microseconds: 1) == [])            // nothing decodable before a configuration
        #expect(packets.push(sps, microseconds: 2) == [])
        #expect(packets.push(pps, microseconds: 3) == [])
        let first = packets.push(idr, microseconds: 1_000)
        #expect(first.count == 2)
        #expect(first[0].first == 0x10)
        let config = try #require(AVCConfiguration(avcC: Data(first[0].dropFirst())))
        #expect(config.sequenceParameterSets == [sps]); #expect(config.pictureParameterSets == [pps]); #expect(config.nalLengthSize == 4)
        guard case let .picture(stamp, key, body)? = ScreenPacket(first[1]) else { Issue.record("not a picture"); return }
        #expect(stamp == 1_000); #expect(key)
        #expect(body == Data([0, 0, 0, UInt8(idr.count)]) + idr)
        let next = packets.push(slice, microseconds: 2_000)
        #expect(next.count == 1)
        if case let .picture(_, key, _)? = ScreenPacket(next[0]) { #expect(!key) } else { Issue.record("not a picture") }
        packets.resend()
        #expect(packets.push(idr, microseconds: 3_000).first?.first == 0x10)
    }

    // MARK: adb

    @Test func adbDevicesBecomeRowsWithTheirStates() throws {
        let rows = BackendAppDeviceAndroidParsing.devices("""
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:3
        R5CT20ABC              unauthorized usb:1-1 transport_id:4
        192.168.1.7:5555       offline product:x model:Pixel_8 device:shiba transport_id:5
        * daemon started successfully

        """)
        #expect(rows.map(\.serial) == ["emulator-5554", "R5CT20ABC", "192.168.1.7:5555"])
        let emulator = try #require(BackendAppDeviceInventoryParsing.engineDevice(BackendAppDeviceAndroidParsing.row(rows[0])))
        #expect(emulator["kind"].string == "emulator"); #expect(emulator["state"].string == "ready"); #expect(emulator["available"].bool == true)
        #expect(emulator["canRotate"].bool == true); #expect(emulator["text"].string == "ascii")
        #expect(emulator["buttons"].elements?.contains(.string("back")) == true)
        let phone = try #require(BackendAppDeviceInventoryParsing.engineDevice(BackendAppDeviceAndroidParsing.row(rows[1])))
        #expect(phone["kind"].string == "physical"); #expect(phone["state"].string == "unauthorized"); #expect(phone["canShutDown"].bool == false)
        let wifi = try #require(BackendAppDeviceInventoryParsing.engineDevice(BackendAppDeviceAndroidParsing.row(rows[2])))
        #expect(wifi["name"].string == "Pixel 8"); #expect(wifi["state"].string == "offline")
    }

    @Test func screenSizeDensityAndTurnAreRead() {
        #expect(BackendAppDeviceAndroidParsing.size("Physical size: 1080x2400\n").map { [$0.width, $0.height] } == [1080, 2400])
        #expect(BackendAppDeviceAndroidParsing.size("Physical size: 1080x2400\nOverride size: 720x1600\n").map { [$0.width, $0.height] } == [720, 1600])
        #expect(BackendAppDeviceAndroidParsing.size("nothing") == nil)
        #expect(BackendAppDeviceAndroidParsing.density("Physical density: 420\n") == 420)
        #expect(BackendAppDeviceAndroidParsing.density("Physical density: 420\nOverride density: 320") == 320)
        #expect(BackendAppDeviceAndroidParsing.rotation("    SurfaceOrientation: 1\n") == 1)
        #expect(BackendAppDeviceAndroidParsing.rotation("mCurrentRotation=ROTATION_270 mLastOrientation=0") == 3)
        #expect(BackendAppDeviceAndroidParsing.rotation("mCurrentRotation=2") == 2)
        #expect(BackendAppDeviceAndroidParsing.rotation("") == nil)
    }

    @Test func theAppInFrontIsReadFromDumpsys() {
        let activities = "  topResumedActivity=ActivityRecord{1f2 u0 com.android.settings/.Settings t12}\n"
        #expect(BackendAppDeviceAndroidParsing.foreground(activities).map { [$0.package, $0.activity] } == ["com.android.settings", "com.android.settings.Settings"])
        let window = "  mCurrentFocus=Window{9a u0 com.google.android.apps.maps/com.google.android.maps.MapsActivity}"
        #expect(BackendAppDeviceAndroidParsing.foreground(window).map { [$0.package, $0.activity] } == ["com.google.android.apps.maps", "com.google.android.maps.MapsActivity"])
        #expect(BackendAppDeviceAndroidParsing.foreground("nothing here") == nil)
    }

    @Test func keysButtonsTextAndTurnsMapToAndroidsOwn() {
        #expect(BackendAppDeviceAndroidParsing.keyArguments("return", modifiers: []) == ["keyevent", "66"])
        #expect(BackendAppDeviceAndroidParsing.keyArguments("arrow-left", modifiers: ["shift"]) == ["keycombination", "59", "21"])
        #expect(BackendAppDeviceAndroidParsing.keyArguments("select-all", modifiers: []) == ["keycombination", "113", "29"])
        #expect(BackendAppDeviceAndroidParsing.keyArguments("return", modifiers: ["hyper"]) == nil)
        #expect(BackendAppDeviceAndroidParsing.keyArguments("volume-up", modifiers: []) == nil)
        #expect(BackendAppDeviceAndroidParsing.buttons.map { BackendAppDeviceAndroidParsing.buttonKeycode($0)! } == [3, 4, 187, 26, 24, 25])
        #expect(BackendAppDeviceAndroidParsing.typedText("hello world") == "'hello%sworld'")
        #expect(BackendAppDeviceAndroidParsing.typedText("it's 100%") == "'it'\\''s%s100\\%'")
        #expect(BackendAppDeviceAndroidParsing.typedText("caf\u{E9}") == nil)
        #expect(BackendAppDeviceAndroidParsing.typedText("") == nil)
        #expect(["portrait", "landscape-left", "portrait-upside-down", "landscape-right"].map { BackendAppDeviceAndroidParsing.userRotation($0)! } == [0, 1, 2, 3])
        #expect(BackendAppDeviceAndroidParsing.userRotation("sideways") == nil)
    }

    @Test func uiautomatorDumpBecomesTheTreeAndAnswersAPoint() throws {
        let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.x" content-desc="" enabled="true" focused="false" password="false" bounds="[0,0][1080,2400]"><node index="0" text="Sign in" resource-id="com.x:id/signin" class="android.widget.Button" package="com.x" content-desc="" enabled="true" focused="false" password="false" bounds="[90,1200][990,1320]" /><node index="1" text="hunter2" resource-id="com.x:id/pass" class="android.widget.EditText" package="com.x" content-desc="Password" enabled="true" focused="true" password="true" bounds="[90,1000][990,1100]" /></node></hierarchy>UI hierchary dumped to: /dev/tty
        """
        let raw = try #require(BackendAppDeviceAndroidParsing.snapshot(xml, now: "2026-10-28T00:00:00Z"))
        let snapshot = try #require(BackendAppDeviceParsing.snapshot(raw))
        #expect(snapshot["source"].string == "android-uiautomator"); #expect(snapshot["nodeCount"].number == 3)
        let tree = try #require(DeviceTree(json: snapshot.foundation))
        let button = try #require(BackendDeckToolsMachinesDeviceRules.find(tree.root, .init(name: "Sign in", identifier: nil, role: "button", partial: false)).first)
        #expect(button.identifier == "com.x:id/signin")
        let centre = try #require(DeviceTreeQuery.centre(of: button))
        #expect(abs(centre.x - 0.5) < 0.001); #expect(abs(centre.y - 0.525) < 0.001)
        #expect(!String(decoding: try snapshot.encodedJSON(), as: UTF8.self).contains("hunter2"))   // a password field's text never leaves
        let hit = try #require(BackendAppDeviceAndroidParsing.element(at: 0.5, 0.44, in: raw))
        #expect(hit["label"].string == "Password"); #expect(hit["valueRedacted"].bool == true); #expect(hit["children"] == .missing)
        #expect(BackendAppDeviceAndroidParsing.snapshot("ERROR: could not get idle state.") == nil)
    }

    // MARK: iOS

    @Test func theHelpersTreeIsReadAndAThinOneSaysSo() throws {
        let full = #"{"source":"ios-accessibility","capturedAt":"t","app":{"pid":12,"bundleId":"dev.terminaldeck.ios"},"root":{"ref":"e1","role":"AXApplication","label":"Terminal Deck","frame":{"normalized":{"x":0,"y":0,"width":1,"height":1}},"children":[{"ref":"e2","role":"AXButton","label":"Menu","identifier":"chat.menu","frame":{"normalized":{"x":0.04,"y":0.08,"width":0.1,"height":0.05}}}]},"stats":{"nodeCount":2,"truncated":false,"quality":"full"}}"#
        let read = BackendAppDeviceIOSParsing.tree(full)
        #expect(!read.degraded); #expect(read.app["bundleId"].string == "dev.terminaldeck.ios")
        #expect(read.snapshot?["nodeCount"].number == 2)
        let off = BackendAppDeviceIOSParsing.tree(#"{"error":"The app in front does not describe itself yet (its accessibility is off).","app":{"pid":768,"bundleId":"com.apple.mobilesafari"}}"#)
        #expect(off.degraded); #expect(off.snapshot == nil); #expect(off.app["pid"].number == 768); #expect(off.error.contains("accessibility is off"))
        #expect(BackendAppDeviceIOSParsing.tree("not json").degraded)
    }

    /// iOS's accessibility joins a row's texts into one label; finding one of them by its whole name still finds the row
    /// (the XCTest tree listed the texts as children, which a find matched).
    @Test func aWholePartOfAJoinedLabelIsAWholeName() throws {
        let raw = BackendAppDeviceIOSParsing.tree(#"{"source":"ios-accessibility","capturedAt":"t","app":{},"root":{"ref":"e1","role":"AXApplication","frame":{"normalized":{"x":0,"y":0,"width":1,"height":1}},"children":[{"ref":"e2","role":"AXButton","label":"iMatch, 1 running","identifier":"projects.row.iMatch","frame":{"normalized":{"x":0.04,"y":0.14,"width":0.92,"height":0.066}}},{"ref":"e3","role":"AXButton","label":"Deck Dev, 1 running","frame":{"normalized":{"x":0.04,"y":0.21,"width":0.92,"height":0.066}}}]},"stats":{"nodeCount":3,"truncated":false,"quality":"full"}}"#)
        let snapshot = try #require(raw.snapshot)
        let tree = try #require(DeviceTree(json: snapshot.foundation))
        let found = BackendDeckToolsMachinesDeviceRules.find(tree.root, .init(name: "imatch", identifier: nil, role: nil, partial: false))
        #expect(found.map(\.identifier) == ["projects.row.iMatch"])
        #expect(BackendDeckToolsMachinesDeviceRules.find(tree.root, .init(name: "1 running", identifier: nil, role: nil, partial: false)).count == 2)
        #expect(BackendDeckToolsMachinesDeviceRules.find(tree.root, .init(name: "1 run", identifier: nil, role: nil, partial: false)).isEmpty)
    }

    // MARK: scope, applied once in the tool layer for every platform (Reviewer 28 Oct 2026)

    private func node(_ ref: String, _ role: String, _ label: String? = nil, y: Double, height: Double = 0.06, actionable: Bool? = nil,
                      hidden: Bool? = nil, children: [DeviceNode] = []) -> DeviceNode {
        var made = DeviceNode(ref: ref, role: role, label: label, hidden: hidden, frame: NormRect(x: 0.05, y: y, width: 0.9, height: height), children: children)
        made.actionable = actionable
        return made
    }
    /// An iOS screen: a list with two rows on screen, one scrolled away below, a heading, and a hidden button.
    private var iosScreen: DeviceNode {
        DeviceNode(ref: "app", role: "AXApplication", label: "Settings", frame: NormRect(x: 0, y: 0, width: 1, height: 1), children: [
            node("h", "AXHeading", "Settings", y: 0.1),
            node("list", "AXGroup", y: 0, height: 1.6, children: [
                node("r1", "AXButton", "General", y: 0.3, children: [node("t1", "AXStaticText", "General", y: 0.31, height: 0.03)]),
                node("r2", "AXButton", "Camera", y: 0.4),
                node("r3", "AXButton", "Screen Time", y: 1.2),
            ]),
            node("gone", "AXButton", "Hidden", y: 0.5, hidden: true),
        ])
    }
    /// An Android screen: actionable comes from uiautomator's own clickable/scrollable, whatever the class.
    private var androidScreen: DeviceNode {
        DeviceNode(ref: "a0", role: "hierarchy", frame: NormRect(x: 0, y: 0, width: 1, height: 1), children: [
            node("frame", "android.widget.FrameLayout", y: 0, height: 1, actionable: false, children: [
                node("scroll", "androidx.recyclerview.widget.RecyclerView", y: 0.1, height: 0.8, actionable: true, children: [
                    node("row", "android.widget.LinearLayout", "Wi-Fi", y: 0.2, actionable: true, children: [node("txt", "android.widget.TextView", "Wi-Fi", y: 0.21, actionable: false)]),
                    node("below", "android.widget.LinearLayout", "Battery", y: 1.3, actionable: true),
                ]),
                node("label", "android.widget.TextView", "Settings", y: 0.05, actionable: false),
            ]),
        ])
    }
    private func refs(_ root: DeviceNode) -> [String] { DeviceTreeQuery.flatten(root).map(\.ref) }

    @Test func scopeFullKeepsEverything() {
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "full")) == refs(iosScreen))
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(androidScreen, "full")) == refs(androidScreen))
    }

    @Test func scopeVisibleDropsHiddenAndScrolledAway() {
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "visible")) == ["app", "h", "list", "r1", "t1", "r2"])
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(androidScreen, "visible")) == ["a0", "frame", "scroll", "row", "txt", "label"])
    }

    @Test func scopeInteractiveKeepsWhatAFingerActsOn() {
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "interactive")) == ["app", "r1", "r2"])
        #expect(refs(BackendDeckToolsMachinesDeviceRules.scoped(androidScreen, "interactive")) == ["a0", "scroll", "row"])
        let rows = BackendDeckToolsMachinesDeviceRules.listElements(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "interactive"), limit: 50).rows
        #expect(rows.map { $0["name"].string ?? "" } == ["Settings", "General", "Camera"])
    }

    @Test func findHonoursTheScope() {
        let query = BackendDeckToolsMachinesDeviceRules.Selector(name: "Screen Time", identifier: nil, role: nil, partial: false)
        #expect(BackendDeckToolsMachinesDeviceRules.find(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "visible"), query).isEmpty)
        let far = BackendDeckToolsMachinesDeviceRules.find(BackendDeckToolsMachinesDeviceRules.scoped(iosScreen, "full"), query, shownOnly: false)
        #expect(far.map(\.ref) == ["r3"])
        #expect(BackendDeckToolsMachinesDeviceRules.element(far[0])["offScreen"].bool == true)
    }

    @Test func androidDumpSaysWhatAFingerActsOn() throws {
        let xml = #"<?xml version='1.0' ?><hierarchy rotation="0"><node class="android.widget.FrameLayout" clickable="false" bounds="[0,0][1080,2400]"><node class="android.widget.LinearLayout" clickable="true" text="" content-desc="Wi-Fi" bounds="[0,200][1080,320]" /><node class="android.widget.EditText" clickable="false" text="" bounds="[0,400][1080,500]" /></node></hierarchy>"#
        let raw = try #require(BackendAppDeviceAndroidParsing.snapshot(xml))
        let snapshot = try #require(BackendAppDeviceParsing.snapshot(raw))
        let tree = try #require(DeviceTree(json: snapshot.foundation))
        #expect(DeviceTreeQuery.flatten(tree.root).map { $0.actionable } == [nil, false, true, true])
    }

    @Test func stillsSlowDownWhileTheScreenStaysTheSame() {
        #expect((0...8).map(BackendAppDeviceOwnIOS.stillInterval) == [350, 350, 350, 1_000, 1_000, 1_000, 2_000, 2_000, 2_000])
    }

    @Test func noToolPromisesReactNativeComponents() throws {
        let catalogue = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckBackend/BackendDeckToolsMachinesCatalogue.swift"), encoding: .utf8)
        #expect(!catalogue.contains("names each element’s component and source file"))
        #expect(!catalogue.contains("React Native app in development"))
    }

    @Test func pictureSizesAndScreenPointsAreRead() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png.append(contentsOf: [0, 0, 0x04, 0xB6, 0, 0, 0x0A, 0x3E])
        #expect(BackendAppDeviceIOSParsing.pngSize(png).map { [$0.width, $0.height] } == [1206, 2622])
        #expect(BackendAppDeviceIOSParsing.pngSize(Data("GIF89a".utf8)) == nil)
        #expect(BackendAppDeviceIOSParsing.points(profile: ["mainScreenWidth": 1206, "mainScreenHeight": 2622, "mainScreenScale": 3]).map { [$0.width, $0.height] } == [402, 874])
        #expect(BackendAppDeviceIOSParsing.points(profile: [:]) == nil)
        let capabilities: [String: Any] = ["capabilities": ["displays": [["screenID": 2, "width": 720, "height": 480, "scale": 1], ["screenID": 1, "width": 1206, "height": 2622, "scale": 3]]]]
        #expect(BackendAppDeviceIOSParsing.points(capabilities: capabilities).map { [$0.width, $0.height] } == [402, 874])
        #expect(BackendAppDeviceIOSParsing.points(capabilities: [:]) == nil)
    }

    @Test func theTreeRunnerIsOurSourceBuiltPerXcode() {
        let sources = BackendAppDeviceOwnTreeRunner.sources
        #expect(Set(sources.keys) == ["DeviceTreeRunner.xcodeproj/project.pbxproj", "DeviceTreeRunner.xcodeproj/xcshareddata/xcschemes/DeviceTreeRunner.xcscheme", "DeviceTree.swift"])
        #expect(sources["DeviceTreeRunner.xcodeproj/project.pbxproj"]?.contains("com.apple.product-type.bundle.ui-testing") == true)
        #expect(sources["DeviceTree.swift"]?.contains("XCUIApplication(bundleIdentifier: bundle).snapshot()") == true)
        let root = URL(fileURLWithPath: "/data/devices/tree-runner")
        #expect(BackendAppDeviceOwnTreeRunner.folder(root: root, xcode: "Xcode 27.1") == BackendAppDeviceOwnTreeRunner.folder(root: root, xcode: "Xcode 27.1"))
        #expect(BackendAppDeviceOwnTreeRunner.folder(root: root, xcode: "Xcode 27.1") != BackendAppDeviceOwnTreeRunner.folder(root: root, xcode: "Xcode 27.2"))
    }

    // MARK: The session around a driver

    @Test func oneOpenIsSharedAndThePictureEndsAsAClose() async throws {
        let driver = FakeDriver()
        let session = BackendAppDeviceSession(engine: .init(helper: nil, dataFolder: nil), id: "android:emulator-5554",
                                              platform: .init(environment: [:], home: "/fixture"), driver: driver)
        async let one = session.open(), two = session.open()
        _ = try await (one, two)
        #expect(driver.opens == 1)
        var events = session.events.makeAsyncIterator()
        try await session.setPreview(true)
        for _ in 0..<400 where !driver.streaming { try await Task.sleep(for: .milliseconds(5)) }
        #expect(driver.streaming)
        driver.send(Data([0x10, 1, 2])); driver.send(Data([0x11, 3]))
        guard case .screen(let first)? = await events.next(), case .screen(let second)? = await events.next() else { Issue.record("no pictures"); return }
        #expect(first == Data([0x10, 1, 2])); #expect(second == Data([0x11, 3]))
        #expect(await session.screenConfiguration() == Data([0x10, 1, 2]))
        #expect(try await session.rotate(to: nil) == "landscape-left")
        #expect(try await session.rotate(to: nil) == "portrait")
        #expect(driver.turns == ["landscape-left", "portrait"])
        driver.end()
        guard case .closed(let reason)? = await events.next() else { Issue.record("no close"); return }
        #expect(reason == "The device went away.")
        #expect(await session.isOpen() == false)
    }

    // MARK: Nothing of the old engine is left

    /// Guard (Asad 28 Oct 2026: "remove it completely"): no trace of the bundled third-party device engine in the app's
    /// source or its build scripts.
    @Test func noThirdPartyDeviceEngineNameInSourceOrBuildScripts() throws {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let banned = "sim" + "view"
        var looked = 0
        let roots = [macos.appendingPathComponent("TerminalDeckNative/Sources"), macos.appendingPathComponent("build-app.sh"), macos.appendingPathComponent("dev/devloop.sh")]
        for root in roots {
            let files: [URL]
            if root.hasDirectoryPath || root.pathExtension.isEmpty, let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                files = walker.compactMap { $0 as? URL }.filter { ["swift", "m", "h", "c"].contains($0.pathExtension) }
            } else { files = [root] }
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                looked += 1
                #expect(!text.lowercased().contains(banned), "\(file.path) still names the old engine")
            }
        }
        #expect(looked > 100)
    }
}

private final class FakeDriver: BackendAppDeviceDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0, rotations: [String] = []
    private var sink: (@Sendable (Data) -> Void)?
    private var finish: CheckedContinuation<Void, Never>?
    var opens: Int { lock.withLock { opened } }
    var turns: [String] { lock.withLock { rotations } }
    var streaming: Bool { lock.withLock { sink != nil } }
    func send(_ packet: Data) { lock.withLock { sink }?(packet) }
    func end() { let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { finish = nil }; return finish }; waiting?.resume() }

    func open() async throws -> NativeRPCValue {
        lock.withLock { opened += 1 }
        try await Task.sleep(for: .milliseconds(30))
        return BackendAppDeviceParsing.object([("id", .string("android:emulator-5554")), ("platform", .string("android"))])
    }
    func pictures(_ send: @escaping @Sendable (Data) -> Void) async throws {
        await withCheckedContinuation { continuation in lock.withLock { sink = send; finish = continuation } }
    }
    func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws {}
    func touch(phase: String, x: Double, y: Double) async throws {}
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Double) async throws {}
    func type(_ text: String) async throws {}
    func key(_ key: String, modifiers: [String]) async throws {}
    func button(_ name: String) async throws {}
    func rotate(to orientation: String) async throws { lock.withLock { rotations.append(orientation) } }
    func screenshot() async throws -> BackendAppDeviceScreenshot { .init(png: Data(), width: 0, height: 0) }
    func foreground() async throws -> NativeRPCValue { .object([]) }
    func elementAt(x: Double, y: Double) async throws -> NativeRPCValue? { nil }
    func tree(scope: String) async throws -> NativeRPCValue { .object([]) }
}

/// Live, only when asked (`TD_LIVE_OWN_DEVICES=<simulator UDID>`, `TD_LIVE_HELPER=<TerminalDeckNativeHelper>`): the own
/// engine against a booted simulator. It reads, takes stills and turns the device and back; it starts and stops nothing.
@Suite("Own device engine, live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["TD_LIVE_OWN_DEVICES"] != nil))
struct BackendAppDeviceOwnEngineLiveTests {
    @Test func aBootedSimulatorThroughTheOwnEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        let udid = try #require(env["TD_LIVE_OWN_DEVICES"])
        let platform = BackendAppDevicePlatform(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()], home: NSHomeDirectory())
        let data = URL(fileURLWithPath: env["TD_LIVE_DATA"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("td-own-devices-live").path)
        let session = BackendAppDeviceSession(engine: .init(helper: env["TD_LIVE_HELPER"], dataFolder: data.path), id: "ios:" + udid, platform: platform)
        var started = Date()
        let info = try await session.open()
        print("LIVE open \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(info["name"].compact) \(info["pointWidth"].compact)x\(info["pointHeight"].compact) buttons \(info["buttons"].compact)")
        #expect((info["pointWidth"].number ?? 0) > 0)
        started = Date()
        let shot = try await session.screenshot()
        print("LIVE screenshot \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(Int(shot.width))x\(Int(shot.height)), \(shot.png.count) bytes")
        #expect(shot.width > 0 && shot.height > 0)
        started = Date()
        let front = try await session.foreground()
        print("LIVE foreground \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(front.compact)")
        #expect(!(front["app"].string ?? "").isEmpty)
        started = Date()
        let tree = try await session.tree(scope: "visible")
        let parsed = try #require(DeviceTree(json: tree["tree"].foundation))
        let nodes = DeviceTreeQuery.flatten(parsed.root)
        print("LIVE tree \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(nodes.count) nodes from \(tree["tree"]["source"].compact), fallback \(tree["fallback"].compact)")
        for node in nodes.prefix(12) { print("LIVE   \(node.role ?? "") \"\(DeviceTreeQuery.nodeName(node))\" \(node.identifier ?? "")") }
        #expect(nodes.count > 1)
        if let named = nodes.first(where: { !DeviceTreeQuery.nodeName($0).isEmpty && $0.role != "AXApplication" }), let centre = DeviceTreeQuery.centre(of: named) {
            let hit = try await session.elementAt(x: centre.x, y: centre.y)
            print("LIVE element at \(centre): \(hit?.compact ?? "none")")
            #expect(hit != nil)
        }
        var events = session.events.makeAsyncIterator()
        try await session.setPreview(true)
        guard case .screen(let still)? = await events.next() else { Issue.record("no still"); return }
        print("LIVE still: kind \(still.first.map { String(format: "0x%02x", $0) } ?? "-"), \(still.count) bytes")
        #expect(still.first == 0x12)
        try await session.setPreview(false)
        #expect(try await session.rotate(to: "landscape-left") == "landscape-left")
        try await Task.sleep(for: .seconds(1))
        #expect(try await session.rotate(to: "portrait") == "portrait")
        await session.close()
    }
}
