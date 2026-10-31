import Foundation
import TerminalDeckNativeCore

/// An Android emulator or phone, through Google's own `adb` and the tools already on the device (nothing is pushed to
/// it): `screenrecord` for the live picture (the device's own hardware encoder, H.264), `input` for taps, swipes, keys,
/// buttons and text, `screencap` for screenshots, `uiautomator dump` for the element tree, `dumpsys` for the app in front
/// and `settings` for rotation. In the phone panel an emulator shows through the emulator's own gRPC instead
/// (`EmulatorDirectSource`); this is the way for phones, for the AI tools, and the panel's fallback.
public struct BackendAppDeviceOwnAndroid: BackendAppDeviceDriving {
    public let id: String
    public let serial: String
    let platform: BackendAppDevicePlatform
    private let state = State()

    final class State: @unchecked Sendable {
        let lock = NSLock()
        /// The size apps draw at with the screen upright, in pixels.
        var size: (width: Double, height: Double)?
        /// Quarter turns now (0 upright).
        var rotation = 0
    }

    /// `screenrecord` stops itself after this long (Android's own limit); the next one starts at once, and the panel
    /// keeps the last picture meanwhile.
    public static let segmentSeconds = 180
    public static let bitRate = 8_000_000

    public init(id: String, platform: BackendAppDevicePlatform) {
        self.id = id; self.serial = String(id.dropFirst("android:".count)); self.platform = platform
    }

    private var adb: String? { platform.tool("platform-tools/adb") }
    private func adbOrFail() throws -> String {
        guard let adb else { throw BackendAppSessionError("adb is not installed on this Mac (Android SDK Platform Tools).") }
        return adb
    }
    private func shell(_ arguments: [String], timeout: Int = 15_000) async throws -> BackendAppSessionCommandResult {
        let adb = try adbOrFail()
        return await platform.run(adb, ["-s", serial, "shell"] + arguments, timeout)
    }
    private func input(_ arguments: [String], timeout: Int = 15_000) async throws {
        let out = try await shell(["input"] + arguments, timeout: timeout)
        guard out.ok else { throw BackendAppSessionError("The device did not take that input: " + Self.firstLine(out.stderr + out.stdout)) }
    }

    public func open() async throws -> NativeRPCValue {
        let adb = try adbOrFail()
        let stateOut = await platform.run(adb, ["-s", serial, "get-state"], 8_000)
        let word = stateOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stateOut.ok, word == "device" else {
            if stateOut.stderr.contains("unauthorized") { throw BackendAppSessionError("Unlock the phone and allow this computer when it asks.") }
            throw BackendAppSessionError(stateOut.stderr.contains("not found") ? "That device is not connected." : "The device is not answering. Reconnect it, or restart the emulator.")
        }
        try await measure()
        let model = (try? await shell(["getprop", "ro.product.model"], timeout: 5_000))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let density = BackendAppDeviceAndroidParsing.density((try? await shell(["wm", "density"], timeout: 5_000))?.stdout ?? "") ?? 160
        let size = state.lock.withLock { state.size } ?? (0, 0)
        let emulator = serial.hasPrefix("emulator-")
        return BackendAppDeviceParsing.object([("id", .string(id)), ("name", .string(model.isEmpty ? serial : model)), ("platform", .string("android")),
            ("kind", .string(emulator ? "emulator" : "physical")),
            ("pointWidth", .number(size.0 * 160 / Double(density))), ("pointHeight", .number(size.1 * 160 / Double(density))),
            ("buttons", .array(BackendAppDeviceAndroidParsing.buttons.map(NativeRPCValue.string))),
            ("keys", .array(BackendAppDeviceAndroidParsing.keyNames.map(NativeRPCValue.string))),
            ("text", .string("ascii")), ("canRotate", .bool(true)), ("rawTouch", .bool(false))])
    }

    /// Reads the screen's size and turn now.
    private func measure() async throws {
        let sizeOut = try await shell(["wm", "size"], timeout: 5_000)
        let rotationOut = try await shell(["dumpsys", "input"], timeout: 8_000)
        state.lock.withLock {
            if let size = BackendAppDeviceAndroidParsing.size(sizeOut.stdout) { state.size = (Double(size.width), Double(size.height)) }
            state.rotation = BackendAppDeviceAndroidParsing.rotation(rotationOut.stdout) ?? state.rotation
        }
    }

    /// A point (0...1 of the picture as it is shown, turned with the screen) in the pixels `input` takes.
    private func pixels(_ x: Double, _ y: Double) async throws -> (Int, Int) {
        if state.lock.withLock({ state.size }) == nil { try await measure() }
        let (size, turn) = state.lock.withLock { (state.size ?? (1080, 2400), state.rotation) }
        let wide = turn % 2 == 1
        let width = wide ? size.height : size.width, height = wide ? size.width : size.height
        func clamp(_ v: Double) -> Double { min(max(v.isFinite ? v : 0, 0), 1) }
        return (Int((clamp(x) * (width - 1)).rounded()), Int((clamp(y) * (height - 1)).rounded()))
    }

    // MARK: Picture

    public func pictures(_ send: @escaping @Sendable (Data) -> Void) async throws {
        let adb = try adbOrFail()
        let packets = PacketState()
        while !Task.isCancelled {
            let started = Date()
            packets.restart()
            let ended = await screenrecord(adb: adb, packets: packets, send: send)
            if Task.isCancelled { return }
            // A segment that ran its course starts again at once; one that failed straight away means the device went.
            if Date().timeIntervalSince(started) < 2 {
                let check = await platform.run(adb, ["-s", serial, "get-state"], 5_000)
                if check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "device" { throw BackendAppSessionError(ended.isEmpty ? "The device went away." : ended) }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    final class PacketState: @unchecked Sendable {
        let lock = NSLock()
        var splitter = BackendAppDeviceAnnexB()
        var packets = BackendAppDeviceH264Packets()
        var flush: DispatchWorkItem?
        let start = Date()
        func restart() { lock.withLock { splitter = BackendAppDeviceAnnexB(); packets.resend() } }
        var micros: UInt64 { UInt64(max(0, Date().timeIntervalSince(start)) * 1_000_000) }
    }

    /// One `screenrecord` run, until it ends (its time limit, the device, or the task being cancelled). Returns its last words.
    private func screenrecord(adb: String, packets: PacketState, send: @escaping @Sendable (Data) -> Void) async -> String {
        let environment = platform.deviceEnvironment
        let errors = ErrorTail()
        let queue = DispatchQueue(label: "terminaldeck.devices.screenrecord", qos: .userInteractive)
        let deliver: @Sendable ([Data]) -> Void = { units in
            let now = packets.micros
            for unit in units { for packet in packets.lock.withLock({ packets.packets.push(unit, microseconds: now) }) { send(packet) } }
        }
        let child: NativeChild
        do {
            child = try NativeChild.start(.init(adb, ["-s", serial, "exec-out", "screenrecord", "--output-format=h264",
                                                      "--bit-rate", String(Self.bitRate), "--time-limit", String(Self.segmentSeconds), "-"],
                                                environment: environment, cwd: platform.home), queue: queue,
                output: { data in
                    let units = packets.lock.withLock { packets.splitter.push(data) }
                    deliver(units)
                    // A picture is complete when the stream pauses after it (a still screen sends nothing more).
                    let flush = DispatchWorkItem {
                        let rest = packets.lock.withLock { packets.splitter.flush() }
                        deliver(rest)
                    }
                    packets.lock.withLock { packets.flush?.cancel(); packets.flush = flush }
                    queue.asyncAfter(deadline: .now() + .milliseconds(12), execute: flush)
                },
                errors: { errors.remember($0) })
        } catch { return error.localizedDescription }
        await withTaskCancellationHandler {
            _ = await child.exited()
        } onCancel: { child.terminate(grace: .milliseconds(500)) }
        return errors.text
    }

    final class ErrorTail: @unchecked Sendable {
        private let lock = NSLock(); private var words = ""
        func remember(_ data: Data) { lock.withLock { words = String((words + String(decoding: data, as: UTF8.self)).suffix(400)) } }
        var text: String { lock.withLock { words.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    // MARK: Input

    public func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws {
        let (px, py) = try await pixels(x, y)
        if let hold = holdMilliseconds, hold >= 400 {
            try await input(["swipe", String(px), String(py), String(px), String(py), String(Int(hold))], timeout: 15_000 + Int(hold))
        } else {
            try await input(["tap", String(px), String(py)])
        }
    }

    public func touch(phase: String, x: Double, y: Double) async throws {
        let action: String
        switch phase { case "down": action = "DOWN"; case "move": action = "MOVE"; case "up": action = "UP"; case "cancel": action = "CANCEL"; default: return }
        let (px, py) = try await pixels(x, y)
        try await input(["motionevent", action, String(px), String(py)])
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Double) async throws {
        let (ax, ay) = try await pixels(fromX, fromY), (bx, by) = try await pixels(toX, toY)
        let ms = Int(min(max(durationMilliseconds, 50), 5_000))
        try await input(["swipe", String(ax), String(ay), String(bx), String(by), String(ms)], timeout: 15_000 + ms)
    }

    public func type(_ text: String) async throws {
        guard !text.isEmpty else { return }
        guard let typed = BackendAppDeviceAndroidParsing.typedText(text) else {
            throw BackendAppSessionError("Android's input tool types plain letters, digits and symbols only, and this text has other characters (accents, emoji or other scripts). Nothing was typed.")
        }
        try await input(["text", typed], timeout: 30_000)
    }

    public func key(_ key: String, modifiers: [String]) async throws {
        guard let arguments = BackendAppDeviceAndroidParsing.keyArguments(key, modifiers: modifiers) else {
            throw BackendAppSessionError("This device has no \(key) key\(modifiers.isEmpty ? "" : " with those modifiers"). Nothing was pressed.")
        }
        try await input(arguments)
    }

    public func button(_ name: String) async throws {
        guard let code = BackendAppDeviceAndroidParsing.buttonKeycode(name) else { throw BackendAppSessionError("This device has no \(name) button.") }
        try await input(["keyevent", String(code)])
    }

    public func rotate(to orientation: String) async throws {
        guard let turn = BackendAppDeviceAndroidParsing.userRotation(orientation) else { throw BackendAppSessionError("Turn it portrait, landscape-left, landscape-right or portrait-upside-down.") }
        let lock = try await shell(["settings", "put", "system", "accelerometer_rotation", "0"])
        let turned = try await shell(["settings", "put", "system", "user_rotation", String(turn)])
        guard lock.ok, turned.ok else { throw BackendAppSessionError("The device would not turn: " + Self.firstLine(turned.stderr + lock.stderr)) }
        state.lock.withLock { state.rotation = turn }
    }

    // MARK: Reading

    public func screenshot() async throws -> BackendAppDeviceScreenshot {
        let adb = try adbOrFail()
        let shot = await BackendAppDeviceDrivers.bytes(platform, adb, ["-s", serial, "exec-out", "screencap", "-p"], timeoutMilliseconds: 20_000)
        guard let png = shot.data, let size = BackendAppDeviceIOSParsing.pngSize(png) else {
            throw BackendAppSessionError("The screenshot did not arrive (\(shot.why.isEmpty ? "no picture" : shot.why)).")
        }
        return .init(png: png, width: size.width, height: size.height)
    }

    public func foreground() async throws -> NativeRPCValue {
        var found = BackendAppDeviceAndroidParsing.foreground((try await shell(["dumpsys", "activity", "activities"], timeout: 10_000)).stdout)
        if found == nil { found = BackendAppDeviceAndroidParsing.foreground((try await shell(["dumpsys", "window"], timeout: 10_000)).stdout) }
        return BackendAppDeviceParsing.object([("app", .string(found?.package ?? "")), ("screen", .string(found?.activity ?? ""))])
    }

    private func dump() async throws -> NativeRPCValue {
        let adb = try adbOrFail()
        var out = await platform.run(adb, ["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"], 30_000)
        if BackendAppDeviceAndroidParsing.snapshot(out.stdout) == nil {
            out = await platform.run(adb, ["-s", serial, "shell", "uiautomator dump /data/local/tmp/td-ui.xml >/dev/null && cat /data/local/tmp/td-ui.xml && rm -f /data/local/tmp/td-ui.xml"], 30_000)
        }
        guard let raw = BackendAppDeviceAndroidParsing.snapshot(out.stdout) else {
            throw BackendAppSessionError("The screen did not describe itself (uiautomator: \(Self.firstLine(out.stderr + out.stdout))).")
        }
        return raw
    }

    public func elementAt(x: Double, y: Double) async throws -> NativeRPCValue? {
        guard let element = BackendAppDeviceAndroidParsing.element(at: x, y, in: try await dump()) else { return nil }
        return BackendAppDeviceParsing.readNode(element)
    }

    public func tree(scope: String) async throws -> NativeRPCValue {
        let raw = try await dump()
        guard let tree = BackendAppDeviceParsing.snapshot(raw) else { throw BackendAppSessionError("This screen did not describe itself.") }
        return BackendAppDeviceParsing.object([("tree", tree), ("foreground", try await foreground()), ("fallback", .string(""))])
    }

    static func firstLine(_ text: String) -> String {
        String((text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "no reason given").prefix(200))
    }
}
