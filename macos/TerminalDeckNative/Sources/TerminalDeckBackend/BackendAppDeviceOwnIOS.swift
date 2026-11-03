import Foundation
import TerminalDeckNativeCore

/// What Terminal Deck's own engine does with one device (28 Oct 2026). One per opened device; the session
/// (`BackendAppDeviceSession`) keeps the live picture and the open/close state around it.
public protocol BackendAppDeviceDriving: Sendable {
    /// The device's details for the panel and the tools; throws in plain words when it cannot be used now.
    func open() async throws -> NativeRPCValue
    /// The live picture, in the panel's packets, until the task is cancelled. Returns (or throws) when the device is gone.
    func pictures(_ send: @escaping @Sendable (Data) -> Void) async throws
    func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws
    func touch(phase: String, x: Double, y: Double) async throws
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Double) async throws
    func type(_ text: String) async throws
    func key(_ key: String, modifiers: [String]) async throws
    func button(_ name: String) async throws
    func rotate(to orientation: String) async throws
    func screenshot() async throws -> BackendAppDeviceScreenshot
    /// The app in front: `app` (bundle id or package) and `screen` (an activity, when there is one).
    func foreground() async throws -> NativeRPCValue
    func elementAt(x: Double, y: Double) async throws -> NativeRPCValue?
    /// `tree` (the panel's snapshot), `foreground` and `fallback` (why a richer source was not used, or "").
    func tree(scope: String) async throws -> NativeRPCValue
}

public enum BackendAppDeviceDrivers {
    /// The driver for a device id: `ios:<UDID>` or `android:<serial>`.
    public static func make(id: String, platform: BackendAppDevicePlatform, engine: BackendAppDeviceEngine) -> any BackendAppDeviceDriving {
        if id.hasPrefix("android:") { return BackendAppDeviceOwnAndroid(id: id, platform: platform) }
        return BackendAppDeviceOwnIOS(id: id, platform: platform, engine: engine)
    }

    /// A tool's answer as bytes (a picture), within its own limit plus the device grace. Nil with the reason otherwise.
    static func bytes(_ platform: BackendAppDevicePlatform, _ command: String, _ arguments: [String], input: Data? = nil,
                      timeoutMilliseconds: Int, limit: Int = 64 << 20) async -> (data: Data?, why: String) {
        let environment = platform.deviceEnvironment
        guard let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "/usr/bin:/bin") else {
            return (nil, "\((command as NSString).lastPathComponent) is not on this Mac.")
        }
        do {
            let outcome = try await BackendAppDeviceDeadline.run(within: Double(timeoutMilliseconds + BackendAppDeviceDeadline.commandGraceMilliseconds) / 1_000,
                                                                 "The device command \((command as NSString).lastPathComponent)") {
                try await NativeChild.run(.init(executable, arguments, environment: environment, cwd: platform.home), input: input,
                                          timeoutMilliseconds: timeoutMilliseconds, outputLimit: limit)
            }
            guard outcome.succeeded else {
                let words = outcome.errorsText.trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, words.isEmpty ? "The device command did not finish." : String(words.prefix(240)))
            }
            return (outcome.output, "")
        } catch { return (nil, error.localizedDescription) }
    }
}

/// An iOS Simulator, through Apple's tools and Terminal Deck's own helper:
///  - screen and input: the helper's direct path (`--sim-direct`, the panel's and the AI tools' way in), reached through
///    `BackendAppDeviceDirectInput`; long or non-US typing goes through the simulator's pasteboard (`simctl pbcopy`) and ⌘V;
///  - screenshots and the panel's fallback stills: `xcrun simctl io <udid> screenshot`;
///  - rotation, the element tree, the element at a point and the app in front: the helper (`--sim-rotate`, `--sim-ax`);
///    an app whose accessibility is still off is looked at once by Terminal Deck's own XCTest runner.
public struct BackendAppDeviceOwnIOS: BackendAppDeviceDriving {
    public let id: String
    public let udid: String
    let platform: BackendAppDevicePlatform
    let engine: BackendAppDeviceEngine
    let input: BackendAppDeviceDirectInput
    private let state = State()

    final class State: @unchecked Sendable {
        let lock = NSLock()
        /// App processes the XCTest runner has looked at already (by pid): once each.
        var looked: Set<Int> = []
        /// The simulator has been told to start every app with its accessibility on.
        var accessibilityOn = false
        /// When input last went to the simulator: the stills come quickly again.
        var inputAt = Date.distantPast
    }

    public static let buttons = ["home", "lock", "volume-up", "volume-down", "action"]
    public static let keys = ["delete", "return", "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"]
    /// Stills for the panel while the direct screen is not showing it: this often while the screen changes (or just after
    /// input), slowing to every second and then every two while it stays the same (Reviewer 28 Oct 2026: CPU).
    public static let stillEveryMilliseconds = 350
    public static func stillInterval(unchanged: Int) -> Int { unchanged < 3 ? stillEveryMilliseconds : unchanged < 6 ? 1_000 : 2_000 }

    public init(id: String, platform: BackendAppDevicePlatform, engine: BackendAppDeviceEngine, input: BackendAppDeviceDirectInput = .shared) {
        self.id = id; self.udid = String(id.dropFirst("ios:".count)).uppercased(); self.platform = platform; self.engine = engine; self.input = input
    }

    public func open() async throws -> NativeRPCValue {
        guard UUID(uuidString: udid) != nil else { throw BackendAppSessionError("That is not a simulator id.") }
        guard let sim = platform.diskSimulators().first(where: { $0.udid == udid }) else { throw BackendAppSessionError("That simulator is no longer on this Mac.") }
        guard sim.state == "ready" else {
            throw BackendAppSessionError(sim.state == "booting" ? "The simulator is still starting. Try again in a moment." : "The simulator is not running. Start it first.")
        }
        let size = await Self.points(udid: udid, platform: platform) ?? (0, 0)
        return BackendAppDeviceParsing.object([("id", .string(id)), ("name", .string(sim.name)), ("platform", .string("ios")), ("kind", .string("simulator")),
            ("pointWidth", .number(size.0)), ("pointHeight", .number(size.1)),
            ("buttons", .array(Self.buttons.map(NativeRPCValue.string))), ("keys", .array(Self.keys.map(NativeRPCValue.string))),
            ("text", .string("unicode")), ("canRotate", .bool(true)), ("rawTouch", .bool(true))])
    }

    // MARK: Picture

    /// One picture of the screen from simctl, through a private file (Xcode 27's simctl writes "-" as a file named "-"
    /// in the working folder, not to its output, whatever its help says).
    private func picture(type: String, timeout: Int) async -> (data: Data?, why: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("td-screen-\(UUID().uuidString).\(type)")
        defer { try? FileManager.default.removeItem(at: file) }
        let out = await platform.run("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", "--type=" + type, file.path], timeout)
        guard out.ok, let data = try? Data(contentsOf: file), !data.isEmpty else {
            let words = out.stderr.components(separatedBy: "\n").last { !$0.isEmpty && !$0.hasPrefix("Note:") } ?? ""
            return (nil, words.isEmpty ? "simctl gave no picture" : String(words.prefix(200)))
        }
        return (data, "")
    }

    /// Stills while the panel's direct screen is not live (it ended, or has not started yet): JPEGs from simctl, sent
    /// only when the screen changed.
    public func pictures(_ send: @escaping @Sendable (Data) -> Void) async throws {
        var last = Data(), failures = 0, unchanged = 0
        while !Task.isCancelled {
            let started = Date()
            let shot = await picture(type: "jpeg", timeout: 15_000)
            if let jpeg = shot.data, !jpeg.isEmpty {
                failures = 0
                if jpeg != last { last = jpeg; unchanged = 0; var packet = Data([0x12]); packet.append(jpeg); send(packet) } else { unchanged += 1 }
            } else {
                failures += 1
                if failures >= 3, platform.diskSimulators().first(where: { $0.udid == udid })?.state != "ready" { return }
            }
            // Wait out the interval, but take the next still at once after input (checked every 50 ms, no process run).
            let wait = Self.stillInterval(unchanged: unchanged)
            while !Task.isCancelled {
                let spent = Int(Date().timeIntervalSince(started) * 1_000)
                if state.lock.withLock({ state.inputAt > started }) { unchanged = 0; if spent >= 60 { break } }
                if spent >= wait { break }
                try await Task.sleep(for: .milliseconds(min(50, max(10, wait - spent))))
            }
        }
    }

    // MARK: Input

    private func direct(_ what: DeviceInput, modifiers: [String] = []) async throws -> Bool {
        state.lock.withLock { state.inputAt = Date() }
        return try await input.send(id, what, modifiers: modifiers)
    }
    private var noWay: BackendAppSessionError {
        BackendAppSessionError("Terminal Deck's simulator helper could not reach this simulator, so nothing was sent. Open it in the phone panel once, or shut it down and start it again.")
    }

    public func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws {
        guard try await direct(.tap(x: x, y: y, holdMs: holdMilliseconds)) else { throw noWay }
    }
    public func touch(phase: String, x: Double, y: Double) async throws {
        guard try await direct(.touch(phase: phase, x: x, y: y)) else { throw noWay }
    }
    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Double) async throws {
        guard try await direct(.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: durationMilliseconds)) else { throw noWay }
    }
    /// Short US-keyboard text goes key by key through the helper; anything else (accents, emoji, Urdu, a long paste)
    /// through the simulator's pasteboard and ⌘V, so any text arrives whole.
    public func type(_ text: String) async throws {
        guard !text.isEmpty else { return }
        if try await direct(.type(text)) { return }
        let copied = await BackendAppDeviceDrivers.bytes(platform, "/usr/bin/xcrun", ["simctl", "pbcopy", udid], input: Data(text.utf8), timeoutMilliseconds: 15_000)
        guard copied.data != nil else { throw BackendAppSessionError("The text could not be put on the simulator's pasteboard (\(copied.why)). Nothing was typed.") }
        guard try await direct(.key("paste")) else { throw noWay }
    }
    public func key(_ key: String, modifiers: [String]) async throws {
        guard try await direct(.key(key), modifiers: modifiers) else { throw noWay }
    }
    public func button(_ name: String) async throws {
        guard try await direct(.button(name)) else { throw noWay }
    }

    // MARK: Helper answers

    private func helper(_ arguments: [String], timeout: Int = 40_000) async throws -> String {
        guard let path = engine.helper else { throw BackendAppSessionError("This copy of Terminal Deck has no simulator helper, so it cannot read or turn this simulator.") }
        let out = await platform.run(path, arguments, timeout)
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw BackendAppSessionError(out.stderr.isEmpty ? "The simulator helper gave no answer." : String(out.stderr.prefix(240))) }
        return text
    }

    public func rotate(to orientation: String) async throws {
        let answer = try await helper(["--sim-rotate", udid, orientation], timeout: 20_000)
        if answer.hasPrefix("error ") { throw BackendAppSessionError("The simulator would not turn: " + answer.dropFirst(6) + ".") }
    }

    public func screenshot() async throws -> BackendAppDeviceScreenshot {
        let shot = await picture(type: "png", timeout: 20_000)
        guard let png = shot.data, let size = BackendAppDeviceIOSParsing.pngSize(png) else {
            throw BackendAppSessionError("The screenshot did not arrive (\(shot.why.isEmpty ? "no picture" : shot.why)).")
        }
        return .init(png: png, width: size.width, height: size.height)
    }

    public func foreground() async throws -> NativeRPCValue {
        let raw = (try? NativeRPCValue.parseJSON(Data(try await helper(["--sim-ax", udid, "front"]).utf8))) ?? .null
        return BackendAppDeviceParsing.object([("app", .string(raw["app"]["bundleId"].string ?? "")), ("screen", .string(""))])
    }

    public func elementAt(x: Double, y: Double) async throws -> NativeRPCValue? {
        let text = try await helper(["--sim-ax", udid, "point", String(format: "%.5f", x), String(format: "%.5f", y)])
        guard let raw = try? NativeRPCValue.parseJSON(Data(text.utf8)) else { return nil }
        if raw["error"].string != nil, try await lookOnce(raw["app"]) {
            let again = try await helper(["--sim-ax", udid, "point", String(format: "%.5f", x), String(format: "%.5f", y)])
            return (try? NativeRPCValue.parseJSON(Data(again.utf8))).flatMap { BackendAppDeviceParsing.readNode($0["element"]) }
        }
        return BackendAppDeviceParsing.readNode(raw["element"])
    }

    public func tree(scope: String) async throws -> NativeRPCValue {
        await turnAccessibilityOn()
        var answer = BackendAppDeviceIOSParsing.tree(try await helper(["--sim-ax", udid, "tree", "1500"]))
        var fallback = ""
        if answer.degraded {
            // The app in front has its accessibility off (it was running before anything asked): Terminal Deck's own
            // XCTest runner looks at it once, which turns it on, and its snapshot stands in if the translation still
            // says nothing.
            var looked: NativeRPCValue?
            if let bundle = answer.app["bundleId"].string, let pid = answer.app["pid"].number, claim(Int(pid)) {
                do { looked = try await BackendAppDeviceOwnTreeRunner.shared(dataFolder: dataFolder).snapshot(udid: udid, bundleID: bundle, platform: platform) }
                catch { fallback = error.localizedDescription }
                await turnAccessibilityOn(again: true)   // an XCTest session puts the simulator's accessibility settings back when it ends
                let again = BackendAppDeviceIOSParsing.tree(try await helper(["--sim-ax", udid, "tree", "1500"]))
                if !again.degraded || again.snapshot != nil && looked == nil { answer = again }
                else if let looked { answer = (looked, false, "", answer.app) }
            }
        }
        guard let tree = answer.snapshot else { throw BackendAppSessionError(answer.error.isEmpty ? "This screen did not describe itself." : answer.error) }
        let front = BackendAppDeviceParsing.object([("app", .string(answer.app["bundleId"].string ?? "")), ("screen", .string(""))])
        return BackendAppDeviceParsing.object([("tree", tree), ("foreground", front), ("fallback", .string(fallback))])
    }

    private var dataFolder: String {
        engine.dataFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-devices").path
    }

    /// True the first time an app process is to be looked at by the runner.
    private func claim(_ pid: Int) -> Bool { state.lock.withLock { state.looked.insert(pid).inserted } }

    /// An answer that named an app with no accessibility yet: look at it once with the runner. True when it did.
    private func lookOnce(_ app: NativeRPCValue) async throws -> Bool {
        guard let bundle = app["bundleId"].string, let pid = app["pid"].number, claim(Int(pid)) else { return false }
        _ = try? await BackendAppDeviceOwnTreeRunner.shared(dataFolder: dataFolder).snapshot(udid: udid, bundleID: bundle, platform: platform)
        await turnAccessibilityOn(again: true)
        return true
    }

    /// Apps this simulator starts from now on start with their accessibility on (iOS's own setting, the one every
    /// assistive feature turns on), so their trees read at once without the runner. Set the first time a simulator's
    /// tree is read, and again after the runner: an XCTest session puts the setting back as it found it when it ends
    /// (measured 28 Oct 2026).
    private func turnAccessibilityOn(again: Bool = false) async {
        let first = state.lock.withLock { () -> Bool in defer { state.accessibilityOn = true }; return !state.accessibilityOn }
        guard first || again else { return }
        _ = await platform.run("/usr/bin/xcrun", ["simctl", "spawn", udid, "defaults", "write", "com.apple.Accessibility", "ApplicationAccessibilityEnabled", "-bool", "true"], 15_000)
    }

    // MARK: Screen size

    private static let sizes = SizeCache()
    final class SizeCache: @unchecked Sendable {
        let lock = NSLock()
        var byType: [String: (Double, Double)] = [:]
        var bundles: [String: String]?
    }

    /// The simulator's screen in points, from its device type's own profile.
    static func points(udid: String, platform: BackendAppDevicePlatform) async -> (Double, Double)? {
        let plist = URL(fileURLWithPath: platform.home).appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
        guard let data = try? Data(contentsOf: plist),
              let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let type = record["deviceType"] as? String else { return nil }
        if let known = sizes.lock.withLock({ sizes.byType[type] }) { return known }
        var bundles = sizes.lock.withLock { sizes.bundles }
        if bundles == nil {
            let out = await platform.run("/usr/bin/xcrun", ["simctl", "list", "devicetypes", "-j"], 20_000)
            if out.ok, let raw = try? NativeRPCValue.parseJSON(Data(out.stdout.utf8)) {
                var found: [String: String] = [:]
                for row in raw["devicetypes"].elements ?? [] {
                    if let identifier = row["identifier"].string, let path = row["bundlePath"].string { found[identifier] = path }
                }
                bundles = found
                sizes.lock.withLock { sizes.bundles = found }
            }
        }
        guard let bundle = bundles?[type] else { return nil }
        func read(_ name: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources/" + name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        guard let size = read("profile.plist").flatMap(BackendAppDeviceIOSParsing.points(profile:))
                ?? read("capabilities.plist").flatMap(BackendAppDeviceIOSParsing.points(capabilities:)) else { return nil }
        sizes.lock.withLock { sizes.byType[type] = (size.width, size.height) }
        return (size.width, size.height)
    }
}
