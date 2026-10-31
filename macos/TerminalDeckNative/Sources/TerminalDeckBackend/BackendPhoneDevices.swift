import CoreGraphics
import Foundation
import ImageIO
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// Asad, 31 Oct 2026: "having simulator and emulator control from mobile app and streaming with annotate with full
// screen view kind of experience well organized". The remote `sims` capability: a paired phone lists this Mac's iOS
// Simulators and Android emulators, starts and stops them, watches one live (pictures pushed as they change, paced by
// the phone's acks so a slow connection gets fewer, smaller pictures instead of a queue), drives it (tap, swipe, type,
// keys, buttons, rotate), and annotates a still (marks drawn here on the full-size picture, then sent to an agent chat
// or Hoot the way the Mac's own Annotate sends it).
//
// Every call answers at once: work that takes a while (a boot, a shot being drawn on and delivered, input reaching the
// device) runs beside the connection and reports by a push, because a phone's frames are read one after another and a
// slow answer would hold the pictures back.

/// One picture of a device's screen as it crosses to the phone.
public struct BackendPhoneDeviceFrame: Sendable, Equatable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public init(jpeg: Data, width: Int, height: Int) { self.jpeg = jpeg; self.width = width; self.height = height }
}

/// A device's live screen for one phone viewer.
public protocol BackendPhoneDeviceStream: AnyObject, Sendable {
    /// The next picture the device drew since the last one this stream gave, at most `maxWidth` pixels wide, as a JPEG
    /// of at most `maxBytes`. Waits until there is one; nil once the stream ended (see `endReason`).
    func next(maxWidth: Int, quality: Int, maxBytes: Int) async -> BackendPhoneDeviceFrame?
    /// Why the stream ended, in plain words.
    func endReason() async -> String
    func stop() async
}

/// What a phone sends to a device.
public enum BackendPhoneDeviceInput: Sendable, Equatable {
    case tap(x: Double, y: Double, holdMilliseconds: Double?)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, milliseconds: Double)
    case type(String)
    case key(String)
    case button(String)
    case rotate
    /// A secondary click (this Mac: a long press on the phone).
    case secondaryTap(x: Double, y: Double)
    /// Scroll by a share of the picture (two fingers on the phone): dx, dy from -1 to 1.
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    /// A key with modifiers (command, option, control, shift), or a letter or digit for a shortcut.
    case shortcut(String, modifiers: [String])
    /// Another Mac's real mouse (31 Oct, Mac to Mac): move, press, release or drag a button where the pointer is.
    case mouse(phase: String, button: String, x: Double, y: Double, clicks: Int)
    /// Another Mac's real key, by its key code (US layout positions), pressed or released, with modifiers.
    case keyCode(Int, down: Bool, modifiers: [String])
}

/// One phone watching this Mac's screen, for the Mac's indicator and its tools.
public struct BackendPhoneMacViewer: Sendable, Equatable {
    public var phone: String
    public var display: String
    /// The phone sent a click or a key in the last 15 seconds.
    public var controlling: Bool
    public init(phone: String, display: String, controlling: Bool) { self.phone = phone; self.display = display; self.controlling = controlling }
}

/// A still with the phone's marks drawn on it, ready to send.
public struct BackendPhoneDeviceAnnotation: Sendable {
    public var deviceID: String
    public var deviceName: String
    public var platform: String
    public var kind: String
    /// The full-size PNG with the marks on it.
    public var png: Data
    public var width: Int
    public var height: Int
    public var note: String
    /// "hoot" or a session id the phone sees.
    public var to: String
}

public actor BackendPhoneDevices {
    public static let capability = "sims"
    public static let messages: Set<String> = ["sims.list", "sims.power", "sims.watch", "sims.unwatch", "sims.ack", "sims.input",
                                               "sims.shot", "sims.annotate"]
    /// The JPEG bytes one pushed picture may carry (it is base64 inside a frame the relay carries up to 96 KiB).
    public static let frameBudget = 60_000
    /// This Mac's screen is mostly text: a picture may be larger and crosses in parts of at most `partChars`.
    public static let macFrameBudget = 320_000
    public static let partChars = 80_000
    static func isMac(_ id: String) -> Bool { id.hasPrefix("mac:") }
    /// What a phone that is not Full control is told when it tries to click or type on this Mac.
    public static let macControlRefused = "Only a phone with Full control can click and type on this Mac. Change this phone's access on the Mac (Devices)."
    /// Who may WATCH this Mac's screen (Reviewer, 31 Oct): the safe default is Work or Full control, never Look only.
    /// One switch: Asad may still choose to let Look-only phones watch (add `.look`).
    public static let macWatchLevels: Set<BackendINT2PhoneAccessLevel> = [.work, .full]
    public static let macWatchRefused = "Watching this Mac's screen needs Work or Full control. Change this phone's access on the Mac (Devices)."
    /// The level check for watching or taking a still of this Mac; a Mac without levels admits only the person's own device.
    static func mayWatchMac(_ context: BackendRemoteHostContext) -> Bool {
        context.phoneAccess.map { macWatchLevels.contains($0) } ?? (context.kind == .mine)
    }
    /// Pictures one viewer may have on the way at once; the next waits for an ack.
    public static let inFlight = 2
    /// A picture never acked is given up on after this long, so a lost ack never stops the stream.
    static let lostAfter = 2_000.0
    /// At most this many devices one connection watches at once.
    public static let maxWatches = 2
    public static let maxRows = 120

    /// What this adapter uses, as closures, so it is tested without the app.
    public struct Source: Sendable {
        /// The device list (`BackendAppDeviceManager.list`).
        public var list: @Sendable () async -> NativeRPCValue
        /// Start (true) or shut down (false); answers `{ok, id?, message?}`.
        public var power: @Sendable (String, Bool) async throws -> NativeRPCValue
        /// The device's live screen; the row is its list row.
        public var stream: @Sendable (String, NativeRPCValue) async throws -> any BackendPhoneDeviceStream
        public var input: @Sendable (String, BackendPhoneDeviceInput) async throws -> Void
        public var shot: @Sendable (String) async throws -> BackendAppDeviceScreenshot
        /// Sends an annotated still to Hoot or a session; answers what to say ("Sent to Hoot.").
        public var deliver: @Sendable (BackendPhoneDeviceAnnotation) async throws -> String
        /// The sessions this connection sees now.
        public var visibleSessions: @Sendable (BackendRemoteHostContext) async throws -> Set<String>
        /// Pushes one frame to a connection.
        public var send: @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
        public var clock: @Sendable () -> Double
        /// This Mac's own screens (31 Oct, "This Mac"): rows with ids `mac:<display>`, listed first.
        public var macRows: @Sendable () async -> [NativeRPCValue]
        /// A paired phone's name, for the Mac's indicator.
        public var phoneName: @Sendable (BackendRemoteHostContext) async -> String
        /// Who watches this Mac's screen now, whenever that changes (the Mac's indicator).
        public var macViewers: @Sendable ([BackendPhoneMacViewer]) async -> Void
        public init(list: @escaping @Sendable () async -> NativeRPCValue,
                    power: @escaping @Sendable (String, Bool) async throws -> NativeRPCValue,
                    stream: @escaping @Sendable (String, NativeRPCValue) async throws -> any BackendPhoneDeviceStream,
                    input: @escaping @Sendable (String, BackendPhoneDeviceInput) async throws -> Void,
                    shot: @escaping @Sendable (String) async throws -> BackendAppDeviceScreenshot,
                    deliver: @escaping @Sendable (BackendPhoneDeviceAnnotation) async throws -> String,
                    visibleSessions: @escaping @Sendable (BackendRemoteHostContext) async throws -> Set<String>,
                    send: @escaping @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void,
                    clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                    macRows: @escaping @Sendable () async -> [NativeRPCValue] = { [] },
                    phoneName: @escaping @Sendable (BackendRemoteHostContext) async -> String = { _ in "A phone" },
                    macViewers: @escaping @Sendable ([BackendPhoneMacViewer]) async -> Void = { _ in }) {
            self.macRows = macRows; self.phoneName = phoneName; self.macViewers = macViewers
            self.list = list; self.power = power; self.stream = stream; self.input = input; self.shot = shot
            self.deliver = deliver; self.visibleSessions = visibleSessions; self.send = send; self.clock = clock
        }
    }

    /// One phone watching one device.
    struct WatchKey: Hashable, Sendable { let connection: UUID; let device: String }
    struct Watch {
        var wantedWidth: Int
        var wantedQuality: Int
        var fps: Int
        /// What the pictures go out at now (lowered while acks come slowly, raised again when they come quickly).
        var width: Int
        var quality: Int
        var stream: (any BackendPhoneDeviceStream)?
        var pump: Task<Void, Never>?
        var seq = 0
        var sentAt: [Int: Double] = [:]
        var smoothed: Double?
        var sinceTune = 0
        var lastSent: Double = 0
        var waiter: (token: UUID, resume: CheckedContinuation<Void, Never>)?
        var started: Double
        var frames = 0
        var bytes = 0
        var name: String
        var deviceName: String
        var controlledAt: Double = 0
        /// This Mac: the bits a second the pictures may use (start 2.5 Mbit/s, between 0.5 and 8), and the rate the
        /// phone asked for (lowered to 15 while the connection is slow).
        var bitrate: Double = BackendPhoneDevices.macBitrate.start
        var wantedFPS = 0
        var mac = false
        var lastBytes = 0
    }
    /// This Mac's picture budget in bits a second (Macky study, learning 3: start 2.5 Mbps, floor 0.5, ceiling 8).
    static let macBitrate = (start: 2_500_000.0, floor: 500_000.0, ceiling: 8_000_000.0)

    /// The bytes one picture of this Mac may take: a quarter second of the bitrate, between 60 KB and `macFrameBudget`.
    /// Pictures are whole JPEGs (not video), so the bitrate is kept by spacing them out (`plan`), never by blurring text.
    static func macBudget(_ watch: Watch) -> Int {
        min(macFrameBudget, max(frameBudget, Int(watch.bitrate / 8 / 4)))
    }
    struct Still: Sendable { let device: String; let png: Data; let width: Int; let height: Int; let at: Double }

    private let source: Source
    private var watches: [WatchKey: Watch] = [:]
    private var stills: [String: Still] = [:]
    private var inputs: [String: Task<Void, Never>] = [:]
    /// Mouse buttons (with where they went down) and key codes another Mac holds down on this Mac, per connection and
    /// display (Reviewer, 31 Oct): when its view ends for any reason, they are let go, so nothing stays pressed here.
    struct Held: Sendable { var buttons: [String: (x: Double, y: Double)] = [:]; var keys: Set<Int> = []; var at = (x: 0.5, y: 0.5) }
    private var held: [WatchKey: Held] = [:]

    public init(source: Source) { self.source = source }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: Self.capability, messageTypes: Self.messages, policy: .ownerOnly) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Devices on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    // MARK: Messages

    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        switch message.type {
        case "sims.list":
            let rid = try message["rid"].requireString("request", nonempty: true)
            return [try await rows(rid: rid, context: context)]
        case "sims.power":
            let rid = try message["rid"].requireString("request", nonempty: true), id = try deviceID(message["id"])
            let on = message["on"].bool == true
            let connection = context.connectionID, source = self.source
            Task {
                do {
                    let answer = try await source.power(id, on)
                    if answer["ok"].bool == false {
                        throw NativeRPCError(code: "unavailable", message: answer["message"].string ?? (on ? "The device did not start." : "The device did not shut down."))
                    }
                    var reply = try await self.rows(rid: rid, context: context)
                    if on, let started = answer["id"].string, !started.isEmpty {
                        reply = try .init(.simsRows, fields: (reply.value.fields ?? []).filter { $0.key != "t" } + [.init("started", .string(started))])
                    }
                    try await source.send(connection, reply)
                } catch {
                    try? await source.send(connection, Self.refusal(rid: rid, error))
                }
            }
            return []
        case "sims.watch":
            if Self.isMac(try deviceID(message["id"])), !Self.mayWatchMac(context) {
                throw NativeRPCError(code: "access-denied", message: Self.macWatchRefused)
            }
            return try await watch(message, context: context)
        case "sims.unwatch":
            await stopWatch(.init(connection: context.connectionID, device: try deviceID(message["id"])))
            return []
        case "sims.ack":
            ack(.init(connection: context.connectionID, device: try deviceID(message["id"])), seq: Int(message["seq"].number ?? -1))
            return []
        case "sims.input":
            try await input(message, context: context)
            return []
        case "sims.shot":
            let rid = try message["rid"].requireString("request", nonempty: true), id = try deviceID(message["id"])
            if Self.isMac(id), !Self.mayWatchMac(context) { throw NativeRPCError(code: "access-denied", message: Self.macWatchRefused) }
            return [try await shot(rid: rid, id: id)]
        case "sims.annotate":
            try await annotate(message, context: context)
            return []
        default:
            throw NativeRPCError.invalidArguments("Unknown device operation.")
        }
    }

    func deviceID(_ value: NativeRPCValue) throws -> String {
        // This Mac's displays (`mac:<display number>`), or a device this app listed.
        if let id = value.string, id.range(of: #"^mac:[0-9]{1,10}$"#, options: .regularExpression) != nil { return id }
        return try BackendAppDeviceChannels.deviceID(value)
    }

    static func refusal(rid: String, _ error: Error) -> BackendRemoteServerMessage {
        let words = (error as? NativeRPCError)?.message ?? (error as? BackendAppSessionError)?.localizedDescription ?? error.localizedDescription
        return (try? BackendRemoteServerMessage(.error, fields: [.init("code", .string("unavailable")),
            .init("message", .string(String(words.prefix(400)))), .init("rid", .string(rid))]))
            ?? (try! BackendRemoteServerMessage.error(code: "unavailable", message: "That did not work."))
    }

    // MARK: The list

    /// The device list as the phone draws it: iPhone/iPad Simulators and Android emulators (a cable phone is listed
    /// too, so the list matches the Mac's), running ones first.
    func rows(rid: String?, context: BackendRemoteHostContext) async throws -> BackendRemoteServerMessage {
        let value = await source.list()
        let watched = Set(watches.keys.filter { $0.connection == context.connectionID }.map(\.device))
        // This Mac first, as the Mac sends them (each display), then the devices.
        var mac: [NativeRPCValue] = []
        for row in await source.macRows().prefix(8) {
            guard let id = row["id"].string, Self.isMac(id) else { continue }
            mac.append(row.setting("watching", .bool(watched.contains(id))))
        }
        var rows: [NativeRPCValue] = []
        for device in value["devices"].elements ?? [] {
            guard let id = device["id"].string, let name = device["name"].string,
                  let platform = device["platform"].string, ["ios", "android"].contains(platform) else { continue }
            let state = device["state"].string ?? "unknown"
            rows.append(.object([.init("id", .string(id)), .init("name", .string(String(name.prefix(120)))),
                .init("platform", .string(platform)), .init("kind", .string(device["kind"].string ?? "simulator")),
                .init("state", .string(state)), .init("runtime", .string(String((device["runtime"].string ?? "").prefix(60)))),
                .init("canStart", .bool(device["canBoot"].bool == true)), .init("canStop", .bool(device["canShutDown"].bool == true)),
                .init("canRotate", .bool(device["canRotate"].bool == true)),
                .init("buttons", .array(Array((device["buttons"].elements ?? []).prefix(12)))),
                .init("watching", .bool(watched.contains(id))),
                .init("note", .string(String((device["note"].string ?? "").prefix(200))))]))
        }
        rows = mac + Self.ordered(rows)
        if rows.count > Self.maxRows { rows = Array(rows.prefix(Self.maxRows)) }
        var fields: [NativeRPCValue.Field] = [.init("devices", .array(rows))]
        if let rid { fields.insert(.init("rid", .string(rid)), at: 0) }
        if value["available"].bool == false, let reason = value["reason"].string, !reason.isEmpty {
            fields.append(.init("note", .string(String(reason.prefix(400)))))
        }
        return try .init(.simsRows, fields: fields)
    }

    /// Running first, then starting, then the rest; each group by name.
    static func ordered(_ rows: [NativeRPCValue]) -> [NativeRPCValue] {
        func rank(_ row: NativeRPCValue) -> Int {
            switch row["state"].string { case "ready": 0; case "booting": 1; default: 2 }
        }
        return rows.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return ($0["name"].string ?? "").localizedStandardCompare($1["name"].string ?? "") == .orderedAscending
        }
    }

    // MARK: Watching

    func watch(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let id = try deviceID(message["id"])
        let width = Int(min(2560, max(160, message["maxWidth"].number ?? 720)))
        let quality = Int(min(90, max(10, message["quality"].number ?? 60)))
        // This Mac: 30 a second by default (Macky study: 15/30/60, default 30); a simulator 15.
        let fps = Int(min(Self.isMac(id) ? 60 : 24, max(1, message["fps"].number ?? (Self.isMac(id) ? 30 : 15))))
        let key = WatchKey(connection: context.connectionID, device: id)
        if var current = watches[key] {
            // Again from the same phone: the new size and quality, nothing restarted.
            current.wantedWidth = width; current.wantedQuality = quality; current.fps = fps; current.wantedFPS = fps
            current.width = width; current.quality = quality; current.smoothed = nil; current.sinceTune = 0
            watches[key] = current
            return [try state(id, "live", note: "")]
        }
        guard watches.keys.filter({ $0.connection == context.connectionID }).count < Self.maxWatches else {
            throw NativeRPCError(code: "unavailable", message: "This phone already watches two devices. Close one first.")
        }
        let candidates = Self.isMac(id) ? await source.macRows() : (await source.list()["devices"].elements ?? [])
        guard let row = candidates.first(where: { $0["id"].string == id }) else {
            throw NativeRPCError(code: "unavailable", message: "That device is no longer on this Mac. Pull to refresh the list.")
        }
        guard row["state"].string == "ready" else {
            throw NativeRPCError(code: "unavailable", message: "Start the device first; it is not running.")
        }
        let name = row["name"].string ?? id
        let phone = await source.phoneName(context)
        guard watches[key] == nil else { return [try state(id, "live", note: "")] }
        watches[key] = Watch(wantedWidth: width, wantedQuality: quality, fps: fps, width: width, quality: quality,
                             started: source.clock(), name: phone, deviceName: name)
        if Self.isMac(id) { watches[key]?.mac = true; watches[key]?.wantedFPS = fps }
        if Self.isMac(id) { await reportMac() }
        let source = self.source
        let pump = Task { [weak self] in
            do {
                let stream = try await source.stream(id, row)
                guard let self, await self.opened(key, stream) else { await stream.stop(); return }
                try? await source.send(key.connection, try self.state(id, "live", note: ""))
                await self.pump(key, stream)
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                let words = (error as? NativeRPCError)?.message ?? error.localizedDescription
                await self.ended(key, why: words)
            }
        }
        watches[key]?.pump = pump
        return [try state(id, "opening", note: "")]
    }

    nonisolated func state(_ id: String, _ state: String, note: String) throws -> BackendRemoteServerMessage {
        try .init(.simsState, fields: [.init("id", .string(id)), .init("state", .string(state)), .init("note", .string(String(note.prefix(400))))])
    }

    private func opened(_ key: WatchKey, _ stream: any BackendPhoneDeviceStream) -> Bool {
        guard watches[key] != nil else { return false }
        watches[key]?.stream = stream
        return true
    }

    /// The stream ended by itself (or never opened): the phone is told, the watch forgotten.
    private func ended(_ key: WatchKey, why: String) async {
        guard let watch = watches.removeValue(forKey: key) else { return }
        watch.waiter?.resume.resume()
        await watch.stream?.stop()
        try? await source.send(key.connection, try state(key.device, "ended", note: why.isEmpty ? "The device stopped." : why))
        if Self.isMac(key.device) { releaseHeld(key); await reportMac() }
    }

    func stopWatch(_ key: WatchKey) async {
        guard let watch = watches.removeValue(forKey: key) else { return }
        watch.pump?.cancel()
        watch.waiter?.resume.resume()
        await watch.stream?.stop()
        if Self.isMac(key.device) { releaseHeld(key); await reportMac() }
    }

    /// Who watches this Mac's screen now.
    public func macViewers() -> [BackendPhoneMacViewer] {
        let now = source.clock()
        return watches.filter { Self.isMac($0.key.device) }.sorted { $0.value.started < $1.value.started }.map { key, watch in
            BackendPhoneMacViewer(phone: watch.name, display: watch.deviceName, controlling: now - watch.controlledAt < 15_000)
        }
    }

    private func reportMac() async { await source.macViewers(macViewers()) }

    /// Stop on the Mac: every phone watching this Mac's screen is let go and told so.
    public func stopMac(why: String = "Stopped on the Mac.") async {
        for key in watches.keys where Self.isMac(key.device) {
            guard let watch = watches.removeValue(forKey: key) else { continue }
            watch.pump?.cancel()
            watch.waiter?.resume.resume()
            await watch.stream?.stop()
            try? await source.send(key.connection, try state(key.device, "ended", note: why))
            releaseHeld(key)
        }
        await reportMac()
    }

    /// The connection closed: everything it watched stops.
    public func connectionClosed(_ connection: UUID) async {
        for key in watches.keys where key.connection == connection { await stopWatch(key) }
        // Held without a watch (the watch ended first): let go too.
        for key in held.keys where key.connection == connection { releaseHeld(key) }
    }

    /// The pictures for one viewer: when the device draws something new, at most `fps` a second and `inFlight` unacked.
    private func pump(_ key: WatchKey, _ stream: any BackendPhoneDeviceStream) async {
        while !Task.isCancelled {
            await room(key)
            guard !Task.isCancelled, let plan = plan(key) else { return }
            let wait = plan.next - source.clock()
            if wait > 1 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            guard !Task.isCancelled, watches[key] != nil else { return }
            let budget = watches[key].map { $0.mac ? Self.macBudget($0) : Self.frameBudget } ?? Self.frameBudget
            guard let frame = await stream.next(maxWidth: plan.width, quality: plan.quality, maxBytes: budget) else {
                await ended(key, why: await stream.endReason())
                return
            }
            guard !Task.isCancelled, let messages = sent(key, frame) else { return }
            do { for message in messages { try await source.send(key.connection, message) } }
            catch { await stopWatch(key); return }
        }
    }

    struct Plan { let width: Int; let quality: Int; let next: Double }
    func plan(_ key: WatchKey) -> Plan? {
        guard let watch = watches[key] else { return nil }
        // This Mac: never faster than the bitrate allows for the last picture's size (the rate follows the connection).
        let spacing = watch.mac ? max(1_000 / Double(watch.fps), Double(watch.lastBytes) * 8_000 / watch.bitrate) : 1_000 / Double(watch.fps)
        return Plan(width: watch.width, quality: watch.quality, next: watch.lastSent + spacing)
    }

    /// Waits until fewer than `inFlight` pictures are unacked; a picture unacked for `lostAfter` no longer counts.
    private func room(_ key: WatchKey) async {
        while let watch = watches[key], !Task.isCancelled {
            let now = source.clock()
            let lost = watch.sentAt.filter { now - $0.value > Self.lostAfter }.map(\.key)
            for seq in lost { watches[key]?.sentAt[seq] = nil }
            if (watches[key]?.sentAt.count ?? 0) < Self.inFlight { return }
            let token = UUID()
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                watches[key]?.waiter?.resume.resume()
                watches[key]?.waiter = (token, resume)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self?.wake(key, token: token)
                }
            }
        }
    }

    private func wake(_ key: WatchKey, token: UUID?) {
        guard let waiter = watches[key]?.waiter, token == nil || waiter.token == token else { return }
        watches[key]?.waiter = nil
        waiter.resume.resume()
    }

    private func sent(_ key: WatchKey, _ frame: BackendPhoneDeviceFrame) -> [BackendRemoteServerMessage]? {
        guard var watch = watches[key] else { return nil }
        watch.seq += 1
        let now = source.clock()
        watch.sentAt[watch.seq] = now; watch.lastSent = now; watch.frames += 1; watch.bytes += frame.jpeg.count; watch.lastBytes = frame.jpeg.count
        watches[key] = watch
        return Self.frames(id: key.device, seq: watch.seq, frame)
    }

    /// One picture as `sims.frame`s: whole when it fits, else in parts (`part` from 0, `parts`) that the phone joins
    /// before it draws and acks.
    static func frames(id: String, seq: Int, _ frame: BackendPhoneDeviceFrame) -> [BackendRemoteServerMessage] {
        let text = Array(frame.jpeg.base64EncodedString().utf8)
        var pieces: [String] = []
        var start = 0
        repeat {
            let end = min(text.count, start + partChars)
            pieces.append(String(decoding: text[start..<end], as: UTF8.self))
            start = end
        } while start < text.count
        return pieces.enumerated().compactMap { index, piece in
            var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("seq", .number(Double(seq))),
                .init("w", .number(Double(frame.width))), .init("h", .number(Double(frame.height))), .init("data", .string(piece))]
            if pieces.count > 1 { fields += [.init("part", .number(Double(index))), .init("parts", .number(Double(pieces.count)))] }
            return try? .init(.simsFrame, fields: fields)
        }
    }

    /// The phone drew a picture: room for the next, and the connection's speed is read off how long it took.
    func ack(_ key: WatchKey, seq: Int) {
        guard var watch = watches[key], let sentAt = watch.sentAt.removeValue(forKey: seq) else { return }
        let took = source.clock() - sentAt
        watch.smoothed = watch.smoothed.map { $0 * 0.7 + took * 0.3 } ?? took
        watch.sinceTune += 1
        Self.tune(&watch)
        watches[key] = watch
        wake(key, token: nil)
    }

    /// Slower than a third of a second a picture: smaller and plainer pictures; quicker than 0.15 s for a while: back
    /// toward what the phone asked for.
    static func tune(_ watch: inout Watch) {
        guard let smoothed = watch.smoothed, watch.sinceTune >= 4 else { return }
        if watch.mac {
            // This Mac keeps its resolution (text must stay sharp): the bitrate and, when slow, the rate move instead.
            if smoothed > 330 {
                watch.bitrate = max(macBitrate.floor, watch.bitrate * 0.7)
                if watch.bitrate < 1_500_000 { watch.fps = min(watch.fps, 15) }
                watch.sinceTune = 0
            } else if smoothed < 150, watch.sinceTune >= 10 {
                watch.bitrate = min(macBitrate.ceiling, watch.bitrate * 1.2)
                if watch.bitrate >= 1_500_000 { watch.fps = max(watch.fps, watch.wantedFPS) }
                watch.sinceTune = 0
            }
            return
        }
        if smoothed > 330 {
            let quality = max(25, watch.quality - 10), width = max(240, Int(Double(watch.width) * 0.85))
            if quality != watch.quality || width != watch.width { watch.quality = quality; watch.width = width; watch.sinceTune = 0 }
        } else if smoothed < 150, watch.sinceTune >= 10 {
            let quality = min(watch.wantedQuality, watch.quality + 5), width = min(watch.wantedWidth, Int(Double(watch.width) * 1.12) + 1)
            if quality != watch.quality || width != watch.width { watch.quality = quality; watch.width = width; watch.sinceTune = 0 }
        }
    }

    /// For devices.phone_watch: what paired phones watch now.
    public func watching() -> NativeRPCValue {
        let now = source.clock()
        return .array(watches.sorted { $0.value.started < $1.value.started }.map { key, watch in
            let seconds = max(0.001, (now - watch.started) / 1_000)
            return .object([.init("device", .string(key.device)), .init("deviceName", .string(watch.deviceName)),
                .init("phone", .string(watch.name)), .init("live", .bool(watch.stream != nil)),
                .init("seconds", .number((seconds * 10).rounded() / 10)),
                .init("framesPerSecond", .number((Double(watch.frames) / seconds * 10).rounded() / 10)),
                .init("width", .number(Double(watch.width))), .init("quality", .number(Double(watch.quality))),
                .init("megabitsPerSecond", .number(watch.mac ? (watch.bitrate / 100_000).rounded() / 10 : 0))])
        })
    }

    // MARK: Input

    /// Input goes to the device in the order it came, one at a time per device; a refusal comes back with its rid.
    func input(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws {
        let rid = message["rid"].string ?? "", id = try deviceID(message["id"])
        let mac = Self.isMac(id)
        // This Mac: only the owner's phone at Full control clicks and types; Look and Work only watch.
        if mac {
            guard context.phoneAccess == .full else { throw NativeRPCError(code: "access-denied", message: Self.macControlRefused) }
            var began = false
            for key in watches.keys where key.device == id && key.connection == context.connectionID {
                if source.clock() - (watches[key]?.controlledAt ?? 0) >= 15_000 { began = true }
                watches[key]?.controlledAt = source.clock()
            }
            // The Mac's card turns to "controlling" at the first click or key.
            if began { await reportMac() }
        }
        let what = try Self.input(message, mac: mac)
        if mac { note(what, key: WatchKey(connection: context.connectionID, device: id)) }
        let previous = inputs[id], source = self.source, connection = context.connectionID
        inputs[id] = Task {
            await previous?.value
            do {
                try await BackendAppDeviceDeadline.run(within: 30, "Sending to the device") { try await source.input(id, what) }
            } catch {
                if !rid.isEmpty { try? await source.send(connection, Self.refusal(rid: rid, error)) }
            }
        }
    }

    /// Keeps what another Mac holds down on this one.
    private func note(_ input: BackendPhoneDeviceInput, key: WatchKey) {
        var state = held[key] ?? Held()
        switch input {
        case let .mouse(phase, button, x, y, _):
            state.at = (x, y)
            if phase == "down" { state.buttons[button] = (x, y) } else if phase == "up" { state.buttons[button] = nil }
        case let .keyCode(code, down, _):
            if down { state.keys.insert(code) } else { state.keys.remove(code) }
        default:
            return
        }
        held[key] = state.buttons.isEmpty && state.keys.isEmpty ? nil : state
    }

    /// The view of `key` ended: every button and key it still holds is released on this Mac, in order after its input.
    private func releaseHeld(_ key: WatchKey) {
        guard let state = held.removeValue(forKey: key) else { return }
        let releases: [BackendPhoneDeviceInput] = state.buttons.keys.sorted().map { .mouse(phase: "up", button: $0, x: state.at.x, y: state.at.y, clicks: 1) }
            + state.keys.sorted().map { .keyCode($0, down: false, modifiers: []) }
        let previous = inputs[key.device], source = self.source, id = key.device
        inputs[id] = Task {
            await previous?.value
            for release in releases { try? await BackendAppDeviceDeadline.run(within: 10, "Letting go of a key") { try await source.input(id, release) } }
        }
    }

    static func input(_ message: BackendRemoteClientMessage, mac: Bool = false) throws -> BackendPhoneDeviceInput {
        func unit(_ key: String) throws -> Double {
            guard let value = message[key].number, value.isFinite else { throw NativeRPCError.invalidArguments("A position must be a number.") }
            return min(max(value, 0), 1)
        }
        switch message["do"].string {
        case "tap":
            if message["right"].bool == true { return .secondaryTap(x: try unit("x"), y: try unit("y")) }
            return .tap(x: try unit("x"), y: try unit("y"), holdMilliseconds: message["hold"].number.map { min(max($0, 0), 5_000) })
        case "scroll":
            func delta(_ key: String) -> Double { min(max(message[key].number ?? 0, -1), 1) }
            return .scroll(x: try unit("x"), y: try unit("y"), dx: delta("dx"), dy: delta("dy"))
        case "mouse":
            guard mac else { throw NativeRPCError.invalidArguments("A mouse is for a Mac's screen.") }
            guard let phase = message["phase"].string, Self.mousePhases.contains(phase),
                  let button = message["button"].string, Self.mouseButtons.contains(button) else { throw NativeRPCError.invalidArguments("A mouse moves, presses, releases or drags left, right or middle.") }
            return .mouse(phase: phase, button: button, x: try unit("x"), y: try unit("y"), clicks: Int(min(max(message["clicks"].number ?? 1, 1), 3)))
        case "keycode":
            guard mac else { throw NativeRPCError.invalidArguments("Key codes are for a Mac's screen.") }
            guard let code = message["code"].number, code.rounded() == code, (0...127).contains(code), let down = message["down"].bool else {
                throw NativeRPCError.invalidArguments("A key code is a whole number from 0 to 127.")
            }
            let modifiers = (message["mods"].elements ?? []).compactMap(\.string).filter { Self.modifiers.contains($0) || $0 == "fn" }
            return .keyCode(Int(code), down: down, modifiers: modifiers)
        case "swipe":
            return .swipe(fromX: try unit("x"), fromY: try unit("y"), toX: try unit("x2"), toY: try unit("y2"),
                          milliseconds: min(max(message["ms"].number ?? 300, 50), 5_000))
        case "type":
            guard let text = message["text"].string, !text.isEmpty, text.utf16.count <= 2_000 else { throw NativeRPCError.invalidArguments("Text to type must be a short string.") }
            return .type(text)
        case "key":
            let modifiers = (message["mods"].elements ?? []).compactMap(\.string).filter { Self.modifiers.contains($0) }
            if mac {
                guard let key = message["key"].string, Self.macKeys.contains(key) || key.range(of: #"^[a-z0-9]$"#, options: .regularExpression) != nil else {
                    throw NativeRPCError.invalidArguments("That key is not one this Mac can be sent.")
                }
                return .shortcut(key, modifiers: modifiers)
            }
            guard let key = message["key"].string, Self.keys.contains(key) else { throw NativeRPCError.invalidArguments("That key is not one a device can be sent.") }
            return modifiers.isEmpty ? .key(key) : .shortcut(key, modifiers: modifiers)
        case "button":
            guard let button = message["button"].string, Self.buttons.contains(button) else { throw NativeRPCError.invalidArguments("That is not a hardware button.") }
            return .button(button)
        case "rotate": return .rotate
        default: throw NativeRPCError.invalidArguments("Tap, swipe, type, key, button or rotate.")
        }
    }
    public static let keys = ["delete", "return", "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"]
    public static let buttons = ["home", "back", "overview", "lock", "volume-up", "volume-down", "action"]
    public static let mousePhases = ["move", "down", "up", "drag"]
    public static let mouseButtons = ["left", "right", "middle"]
    public static let modifiers = ["command", "option", "control", "shift"]
    /// The named keys this Mac takes from a phone, besides a letter or a digit for a shortcut.
    public static let macKeys = ["return", "enter", "tab", "escape", "delete", "forward-delete", "space", "arrow-up", "arrow-down",
                                 "arrow-left", "arrow-right", "home", "end", "page-up", "page-down"]

    // MARK: Annotate

    /// A full-size still kept for annotating, and a picture of it small enough to cross.
    func shot(rid: String, id: String) async throws -> BackendRemoteServerMessage {
        let shot = try await source.shot(id)
        guard let image = Self.image(shot.png) else { throw NativeRPCError(code: "unavailable", message: "The screenshot could not be read.") }
        let wide = Self.isMac(id) ? 1_600 : 1_080
        guard let preview = Self.encode(image, maxWidth: wide, quality: 75, maxBytes: Self.frameBudget) else {
            throw NativeRPCError(code: "unavailable", message: "The screenshot could not be made small enough to send.")
        }
        let token = Self.token()
        let now = source.clock()
        stills = stills.filter { now - $0.value.at < 15 * 60_000 }
        if stills.count >= 8, let oldest = stills.min(by: { $0.value.at < $1.value.at })?.key { stills[oldest] = nil }
        stills[token] = Still(device: id, png: shot.png, width: image.width, height: image.height, at: now)
        return try .init(.simsShot, fields: [.init("rid", .string(rid)), .init("id", .string(id)), .init("shot", .string(token)),
            .init("w", .number(Double(image.width))), .init("h", .number(Double(image.height))),
            .init("data", .string(preview.jpeg.base64EncodedString()))])
    }

    static func token() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    func annotate(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws {
        let rid = try message["rid"].requireString("request", nonempty: true), id = try deviceID(message["id"])
        let token = try message["shot"].requireString("shot", nonempty: true)
        let note = (message["note"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let to = try message["to"].requireString("destination", nonempty: true)
        guard let still = stills[token], still.device == id else {
            throw NativeRPCError(code: "unavailable", message: "That screenshot is no longer on this Mac. Take it again.")
        }
        if to != "hoot" {
            guard try await source.visibleSessions(context).contains(to) else {
                throw NativeRPCError(code: "unknown-session", message: "That chat is no longer open on this Mac. Choose another.")
            }
        }
        let marks = Self.marks(message["marks"])
        let rows = Self.isMac(id) ? await source.macRows() : (await source.list()["devices"].elements ?? [])
        let row = rows.first { $0["id"].string == id }
        let source = self.source, connection = context.connectionID
        Task {
            do {
                guard let png = Self.drawn(still.png, marks: marks) else { throw NativeRPCError(code: "unavailable", message: "The marks could not be drawn.") }
                let said = try await source.deliver(.init(deviceID: id, deviceName: row?["name"].string ?? "", platform: row?["platform"].string ?? "ios",
                    kind: row?["kind"].string ?? "simulator", png: png, width: still.width, height: still.height, note: note, to: to))
                try await source.send(connection, try .init(.simsSent, fields: [.init("rid", .string(rid)), .init("ok", .bool(true)), .init("message", .string(said))]))
            } catch {
                let words = (error as? NativeRPCError)?.message ?? error.localizedDescription
                try? await source.send(connection, try .init(.simsSent, fields: [.init("rid", .string(rid)), .init("ok", .bool(false)),
                    .init("message", .string(String(words.prefix(400))))]))
            }
        }
    }

    /// One freehand line: its colour and its points (0…1 across and down the picture).
    public struct Mark: Sendable, Equatable {
        public var colour: Int
        public var points: [CGPoint]
        public init(colour: Int, points: [CGPoint]) { self.colour = colour; self.points = points }
    }

    static func marks(_ value: NativeRPCValue) -> [Mark] {
        (value.elements ?? []).compactMap { mark -> Mark? in
            let raw = (mark["p"].elements ?? []).compactMap(\.number)
            guard raw.count >= 2 else { return nil }
            var points: [CGPoint] = []
            var index = 0
            while index + 1 < raw.count {
                points.append(CGPoint(x: min(max(raw[index], 0), 1), y: min(max(raw[index + 1], 0), 1)))
                index += 2
            }
            return Mark(colour: Int(mark["c"].number ?? 0), points: points)
        }
    }

    /// The marks' colours, as the phone's pens: red, yellow, green, blue, white.
    static let pens: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.23, 0.19), (1, 0.8, 0), (0.2, 0.78, 0.35), (0.04, 0.52, 1), (1, 1, 1)]

    /// The still with the marks drawn on it, as a PNG.
    public static func drawn(_ png: Data, marks: [Mark]) -> Data? {
        guard let image = image(png) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round); context.setLineJoin(.round)
        let line = max(3, CGFloat(min(width, height)) * 0.012)
        for mark in marks {
            let pen = pens[min(max(mark.colour, 0), pens.count - 1)]
            let path = CGMutablePath()
            let points = mark.points.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            guard let first = points.first else { continue }
            path.move(to: first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y)) }
            for point in points.dropFirst() { path.addLine(to: point) }
            // A dark edge under the colour, so a mark reads on any screen.
            context.addPath(path); context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)); context.setLineWidth(line * 1.5); context.strokePath()
            context.addPath(path); context.setStrokeColor(CGColor(red: pen.0, green: pen.1, blue: pen.2, alpha: 1)); context.setLineWidth(line); context.strokePath()
        }
        guard let marked = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, marked, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Pictures

    public static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The picture at most `maxWidth` wide (never taller than 2.4 times that), as a JPEG within `maxBytes`: plainer,
    /// then smaller, until it fits.
    public static func encode(_ image: CGImage, maxWidth: Int, quality: Int, maxBytes: Int) -> BackendPhoneDeviceFrame? {
        var width = min(image.width, maxWidth)
        if image.height > 0, image.width > 0 {
            let tallest = Double(maxWidth) * 2.4
            if Double(width) * Double(image.height) / Double(image.width) > tallest { width = Int(tallest * Double(image.width) / Double(image.height)) }
        }
        var quality = Double(min(max(quality, 10), 95)) / 100
        for _ in 0..<12 {
            let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
            if let jpeg = jpeg(image, width: max(1, width), height: height, quality: quality) {
                if jpeg.count <= maxBytes { return .init(jpeg: jpeg, width: max(1, width), height: height) }
                if quality > 0.35 { quality -= 0.15 } else { width = Int(Double(width) * 0.8) }
            } else { return nil }
        }
        return nil
    }

    static func jpeg(_ image: CGImage, width: Int, height: Int, quality: Double) -> Data? {
        var picture = image
        if width != image.width || height != image.height {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            picture = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A device's screen from screenshots, for a device with no direct screen (a cable phone, or when the direct path
/// failed): a new picture when the screen changed, at most every `interval`, sooner after input.
public actor BackendPhoneDeviceStillStream: BackendPhoneDeviceStream {
    private let capture: @Sendable () async throws -> Data
    private let interval: UInt64
    private var last = Data()
    private var stopped = false
    private var why = ""

    public init(interval milliseconds: Int = 200, capture: @escaping @Sendable () async throws -> Data) {
        self.capture = capture; interval = UInt64(milliseconds) * 1_000_000
    }

    public func next(maxWidth: Int, quality: Int, maxBytes: Int) async -> BackendPhoneDeviceFrame? {
        var failures = 0
        while !stopped, !Task.isCancelled {
            do {
                let data = try await capture()
                failures = 0
                if data != last, let image = BackendPhoneDevices.image(data),
                   let frame = BackendPhoneDevices.encode(image, maxWidth: maxWidth, quality: quality, maxBytes: maxBytes) {
                    last = data
                    return frame
                }
            } catch {
                failures += 1
                if failures >= 3 { why = (error as? BackendAppSessionError)?.localizedDescription ?? error.localizedDescription; stopped = true; return nil }
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        return nil
    }

    public func endReason() -> String { why.isEmpty ? "The device stopped." : why }
    public func stop() { stopped = true }
}

extension BackendPhoneDevices {
    /// What keeps `sims` serving: the adapter and its place on the endpoint (the endpoint holds the adapter weakly).
    public final class Installation: Sendable {
        public let devices: BackendPhoneDevices
        private let lease: NativeRPCSubscription
        init(devices: BackendPhoneDevices, lease: NativeRPCSubscription) { self.devices = devices; self.lease = lease }
        public func stop() async { await lease.cancelAndWait() }
    }

    /// Puts `sims` on the endpoint (before any phone connects); keep what this returns.
    public static func install(on endpoint: BackendRemoteHost, source: Source, ownerID: String = "native.phone-devices") async throws -> Installation {
        let devices = BackendPhoneDevices(source: source)
        let lease = try await endpoint.installFeatures(ownerID: ownerID, features: [await devices.feature()],
                                                       connectionClosed: { [weak devices] id in await devices?.connectionClosed(id) })
        return Installation(devices: devices, lease: lease)
    }
}

extension BackendRemoteProtocol {
    /// The `sims` frames' shapes (BackendPhoneDevices).
    static func parseSims(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        guard r.type.hasPrefix("sims.") else { return nil }
        func device() throws -> String {
            let id = try r.text("id", reason: "\(r.type) without a device", bytes: 128)
            guard id.range(of: #"^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$|^mac:[0-9]{1,10}$"#, options: .regularExpression) != nil else { throw r.bad("\(r.type) with an unusable device") }
            return id
        }
        func rid() throws -> String { try r.id("rid", reason: "\(r.type) without a request id") }
        func unit(_ key: String) throws -> NativeRPCValue { .number(min(max(try r.finite(key, reason: "\(r.type) with an unusable \(key)"), 0), 1)) }
        var m = r.base
        switch r.type {
        case "sims.list": return m.setting("rid", .string(try rid()))
        case "sims.power":
            return m.setting("rid", .string(try rid())).setting("id", .string(try device())).setting("on", .bool(try r.boolean("on", reason: "sims.power without on")))
        case "sims.watch":
            m = m.setting("id", .string(try device()))
                .setting("maxWidth", .number(min(2560, max(160, floor(try r.finite("maxWidth", reason: "sims.watch without a width") + 0.5)))))
                .setting("quality", .number(min(90, max(10, floor(try r.finite("quality", reason: "sims.watch without a quality") + 0.5)))))
            // This Mac may go to 60 a second (the phone asks 30); a simulator or emulator stays at most 24 (Reviewer, 31 Oct).
            let mac = BackendPhoneDevices.isMac(m["id"].string ?? "")
            try r.optional("fps", into: &m) { .number(min(mac ? 60 : 24, max(1, floor(try r.finite("fps", reason: "sims.watch with an unusable fps"))))) }
            try r.optional("rid", into: &m) { .string(try rid()) }
            return m
        case "sims.unwatch": return m.setting("id", .string(try device()))
        case "sims.ack":
            return m.setting("id", .string(try device())).setting("seq", .number(try r.whole("seq", 0, Double(Int32.max), reason: "sims.ack without a sequence number")))
        case "sims.input":
            m = m.setting("id", .string(try device())).setting("do", .string(try r.named("do", allowed: ["tap", "swipe", "type", "key", "button", "rotate", "scroll", "mouse", "keycode"], reason: "sims.input without a usable kind")))
            try r.optional("rid", into: &m) { .string(try rid()) }
            switch r["do"].string {
            case "tap":
                m = m.setting("x", try unit("x")).setting("y", try unit("y"))
                try r.optional("hold", into: &m) { .number(min(5_000, max(0, try r.finite("hold", reason: "sims.input with an unusable hold")))) }
                try r.optional("right", into: &m) { .bool(try r.boolean("right", reason: "sims.input with an unusable right")) }
            case "mouse":
                m = m.setting("x", try unit("x")).setting("y", try unit("y"))
                    .setting("phase", .string(try r.named("phase", allowed: BackendPhoneDevices.mousePhases, reason: "sims.input mouse without a usable phase")))
                    .setting("button", .string(try r.named("button", allowed: BackendPhoneDevices.mouseButtons, reason: "sims.input mouse without a usable button")))
                try r.optional("clicks", into: &m) { .number(try r.whole("clicks", 1, 3, reason: "sims.input mouse with unusable clicks")) }
            case "keycode":
                m = m.setting("code", .number(try r.whole("code", 0, 127, reason: "sims.input without a usable key code")))
                    .setting("down", .bool(try r.boolean("down", reason: "sims.input key code without down")))
                if let mods = r["mods"].elements {
                    let names = mods.compactMap(\.string)
                    guard names.count == mods.count, names.count <= 5, names.allSatisfy({ BackendPhoneDevices.modifiers.contains($0) || $0 == "fn" }) else { throw r.bad("sims.input with unknown modifiers") }
                    m = m.setting("mods", .array(names.map(NativeRPCValue.string)))
                }
            case "scroll":
                m = m.setting("x", try unit("x")).setting("y", try unit("y"))
                for key in ["dx", "dy"] { m = m.setting(key, .number(min(max(try r.finite(key, reason: "sims.input scroll without \(key)"), -1), 1))) }
            case "swipe":
                m = m.setting("x", try unit("x")).setting("y", try unit("y")).setting("x2", try unit("x2")).setting("y2", try unit("y2"))
                try r.optional("ms", into: &m) { .number(min(5_000, max(50, try r.finite("ms", reason: "sims.input with an unusable duration")))) }
            case "type": m = m.setting("text", .string(try r.text("text", reason: "sims.input without text", units: 2_000, oversize: "sims.input text larger than 2000 characters")))
            case "key":
                let key = try r.text("key", reason: "sims.input without a key", bytes: 16)
                guard key.range(of: #"^[a-z0-9-]{1,16}$"#, options: .regularExpression) != nil else { throw r.bad("sims.input with an unknown key") }
                m = m.setting("key", .string(key))
                if let mods = r["mods"].elements {
                    let names = mods.compactMap(\.string)
                    guard names.count == mods.count, names.count <= 4, names.allSatisfy(BackendPhoneDevices.modifiers.contains) else { throw r.bad("sims.input with unknown modifiers") }
                    m = m.setting("mods", .array(names.map(NativeRPCValue.string)))
                }
            case "button": m = m.setting("button", .string(try r.named("button", allowed: BackendPhoneDevices.buttons, reason: "sims.input with an unknown button")))
            default: break
            }
            return m
        case "sims.shot": return m.setting("rid", .string(try rid())).setting("id", .string(try device()))
        case "sims.annotate":
            let shot = try r.text("shot", reason: "sims.annotate without a shot", bytes: 64)
            guard shot.range(of: #"^[0-9a-f]{8,64}$"#, options: .regularExpression) != nil else { throw r.bad("sims.annotate with an unusable shot") }
            let to = try r.text("to", reason: "sims.annotate without a destination", bytes: 128)
            guard to == "hoot" || to.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil else { throw r.bad("sims.annotate with an unusable destination") }
            let note = r["note"] == .missing ? "" : try r.text("note", reason: "sims.annotate with an unusable note", allowEmpty: true, units: 4_000, oversize: "sims.annotate note larger than 4000 characters")
            guard let raw = r["marks"].elements, raw.count <= 80 else { throw r.bad("sims.annotate without marks (up to 80)") }
            var total = 0
            let marks = try raw.map { mark -> NativeRPCValue in
                guard mark.fields != nil, let points = mark["p"].elements, points.count >= 2, points.count % 2 == 0,
                      points.allSatisfy({ $0.number?.isFinite == true }) else { throw r.bad("sims.annotate with an unusable mark") }
                total += points.count / 2
                let colour = min(7, max(0, (mark["c"].number ?? 0).rounded()))
                return .object([.init("c", .number(colour)), .init("p", .array(points.map { NativeRPCValue.number(min(max($0.number!, 0), 1)) }))])
            }
            guard total <= 4_000 else { throw r.large("sims.annotate with more than 4000 points") }
            return m.setting("rid", .string(try rid())).setting("id", .string(try device())).setting("shot", .string(shot))
                .setting("to", .string(to)).setting("note", .string(note)).setting("marks", .array(marks))
        default:
            return nil
        }
    }
}
