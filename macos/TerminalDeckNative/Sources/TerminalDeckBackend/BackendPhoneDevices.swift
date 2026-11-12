import CoreGraphics
import CoreVideo
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
// 3 Nov (m5-direct-only; Asad: "remove old relay completely"): the live screen is hardware H.264 on the connection's
// direct link only (`sims.video`, contract §6/§11.7). The JPEG pictures, patches and the relay video are gone; a watch
// without a link is refused, and a screen that cannot be encoded ends the watch.
//
// Every call answers at once: work that takes a while (a boot, a shot being drawn on and delivered, input reaching the
// device) runs beside the connection and reports by a push, because a phone's frames are read one after another and a
// slow answer would hold the pictures back.

/// A small still picture of a device's screen (Annotate's `sims.shot` preview).
public struct BackendPhoneDeviceFrame: Sendable, Equatable {
    /// The picture's bytes: JPEG, or PNG for a small sharp patch of text (phones decode either).
    public var jpeg: Data
    public var width: Int
    public var height: Int
    /// A patch (1 Nov): drawn at (x, y) on the whole picture of `fullWidth` × `fullHeight` the phone keeps. nil x: the
    /// whole picture (`fullWidth`, when set, is its full size; `width` may be smaller while the screen moves).
    public var x: Int?
    public var y: Int?
    public var fullWidth = 0
    public var fullHeight = 0
    /// Full quality (the still picture once the screen stopped moving, or a small change sent sharp at once).
    public var sharp = false
    public init(jpeg: Data, width: Int, height: Int) { self.jpeg = jpeg; self.width = width; self.height = height }
}

/// A device's live screen for one phone viewer.
public protocol BackendPhoneDeviceStream: AnyObject, Sendable {
    /// Why the stream ended, in plain words.
    func endReason() async -> String
    func isStarting() async -> Bool
    func stop() async
    func drawsPointer(_ phone: Bool) async
    /// Item 61: the newest picture as raw pixels for the hardware video encoder, waiting at most `seconds` (0: answer
    /// now). `.unsupported`: this screen cannot be shown on a phone.
    func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer
}

extension BackendPhoneDeviceStream {
    public func isStarting() async -> Bool { false }
    /// Round 3: the phone draws this Mac's pointer itself, so the pictures leave it out (a stream that cannot, ignores it).
    public func drawsPointer(_ phone: Bool) async {}
    public func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer { .unsupported }
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
    /// The phone as a trackpad (1 Nov, Asad: "the whole screen is my trackpad"): move this Mac's pointer by a share of
    /// the display from where it is (clamped to the display); `held`: the left button is down (a drag).
    case pointer(dx: Double, dy: Double, held: Bool)
    /// Item 60: the pointer to a place, 0…1 across and down the display, exactly where the phone draws it.
    case pointerTo(x: Double, y: Double, held: Bool)
    /// A click where the pointer is: a whole click (`phase` nil; two quick ones are a double click), or the button
    /// pressed ("down") or let go ("up") for a drag.
    case click(button: String, phase: String?)
    /// Scroll where the pointer is, by a share of the display (two fingers on the trackpad).
    case wheel(dx: Double, dy: Double)
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
    /// The elements the person picked, in order (#1 first), on the still (devices-fix, 31 Oct: Annotate with
    /// inspection). Empty: a drawing only.
    public var picks: [BackendPhoneDeviceElement] = []
    /// The app and screen in front when the still was taken, when the device said.
    public var app: String = ""
    public var screen: String = ""
    public init(deviceID: String, deviceName: String, platform: String, kind: String, png: Data, width: Int, height: Int, note: String, to: String,
                picks: [BackendPhoneDeviceElement] = [], app: String = "", screen: String = "") {
        self.deviceID = deviceID; self.deviceName = deviceName; self.platform = platform; self.kind = kind; self.png = png
        self.width = width; self.height = height; self.note = note; self.to = to; self.picks = picks; self.app = app; self.screen = screen
    }
}

/// One element on a device's screen (or this Mac's), as the phone's Annotate offers it to pick: what it is and where,
/// 0…1 across and down the still.
public struct BackendPhoneDeviceElement: Sendable, Equatable {
    public var role: String
    public var name: String
    public var identifier: String
    public var component: String
    public var x: Double, y: Double, width: Double, height: Double
    public init(role: String, name: String, identifier: String = "", component: String = "", x: Double, y: Double, width: Double, height: Double) {
        self.role = role; self.name = name; self.identifier = identifier; self.component = component
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var wire: NativeRPCValue {
        func unit(_ value: Double) -> NativeRPCValue { .number((min(max(value, 0), 1) * 10_000).rounded() / 10_000) }
        var fields: [NativeRPCValue.Field] = [.init("r", .string(String(role.prefix(40)))), .init("n", .string(String(name.prefix(120)))),
                                        .init("x", unit(x)), .init("y", unit(y)), .init("w", unit(width)), .init("h", unit(height))]
        if !identifier.isEmpty { fields.append(.init("i", .string(String(identifier.prefix(120))))) }
        return .object(fields)
    }
}

/// What can be picked on a still: the elements (reading order, at most `BackendPhoneDevices.mostElements`), the app
/// and screen in front, and why there are none when there are none ("Turn on Accessibility…").
public struct BackendPhoneDeviceInspection: Sendable, Equatable {
    public var elements: [BackendPhoneDeviceElement]
    public var app: String
    public var screen: String
    public var note: String
    public init(elements: [BackendPhoneDeviceElement] = [], app: String = "", screen: String = "", note: String = "") {
        self.elements = elements; self.app = app; self.screen = screen; self.note = note
    }
}

public actor BackendPhoneDevices {
    public static let capability = "sims"
    public static let messages: Set<String> = ["sims.list", "sims.power", "sims.watch", "sims.unwatch", "sims.ack", "sims.input",
                                               "sims.shot", "sims.annotate", "sims.key", "sims.unlock"]
    /// Recording a simulator or emulator from the phone (round 3), offered as its own capability.
    public static let recordCapability = "sims.record"
    /// 9 Nov: a finger on a simulator or emulator as it moves (`sims.touch`, its own capability so a phone sends it only
    /// to a Mac that takes it): `{"t":"sims.touch","id":<device>,"phase":"down"|"move"|"up"|"cancel","x":0…1,"y":0…1,
    /// "n":<optional move number>}`, never answered.
    public static let touchCapability = "sims.touch"
    public static let touchPhases = ["down", "move", "up", "cancel"]
    /// A finger put down this close to the screen's edge and moving inward starts AT the edge (the device's own edge
    /// gestures need it: home, notifications, Back), as the phones did for swipes.
    static let edgeBand = 0.04
    /// The JPEG bytes Annotate's still preview may carry.
    public static let frameBudget = 60_000
    /// A video frame larger than this crosses in parts (`part`, `parts`).
    public static let partChars = 80_000
    /// Both phones refuse a frame in more parts than this (iPhone `SimsWire`, Android `SimsVideo.usable`): such a frame is
    /// never sent (Reviewer M2, 2 Nov).
    public static let mostParts = 64
    /// The still frame crosses in smaller parts, one at a time at the link's pace, so a new picture can overtake it after
    /// at most one part (Reviewer M1, 2 Nov): 32 000 characters ≈ 24 KB ≈ 50 ms at 4 Mbit/s.
    public static let stillPartChars = 32_000
    /// Encoded moving frames that failed in a row before the watch ends (Reviewer S2; no picture fallback since 3 Nov).
    static let videoFailuresBeforeEnd = 3
    /// What a phone hears when it asks for a screen without the direct link (§11.7).
    public static let needsLink = "Screens need the direct link to your Mac."
    /// What a phone hears when this Mac cannot encode the screen.
    public static let cannotShow = "This screen can't be shown on the phone right now."
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
    static func mayWakeMac(_ context: BackendRemoteHostContext) -> Bool {
        context.phoneAccess.map { $0 == .full } ?? (context.kind == .mine)
    }
    /// A frame never acked is given up on after this long, so a lost ack never stops the stream.
    static let lostAfter = 4_000.0
    /// The screen counts as still after this long without a new picture; then the sharp still goes (1 Nov).
    public static let stillAfter = 0.3
    /// Video frames that may be on the way at once (bytes permitting).
    public static let inFlightVideo = 24
    /// M5: after a keyframe on `td.rel` the next frame waits for its ack at most this long (ms).
    static let keyGate = 1_000.0
    /// M5: a delta on `td.rt` not acked after this long (ms) was given up on the way (the channel retries 150 ms).
    static let movingLostAfter = 1_000.0
    /// M5: this many deltas given up on `td.rt` within `lossyWindow` ms make the watch send everything on `td.rel`.
    static let lossyAfter = 3
    static let lossyWindow = 10_000.0
    /// 9 Nov (Asad: "streaming simulator … too slow … but mac screen streaming is good and fast"): a simulator or
    /// emulator goes at this Mac's pace. The phones still ask 15 a second for a device (their JPEG-era default); the
    /// video is paced by the link anyway (`room`, the pacer), so the rate is only a ceiling: a device gets at least
    /// `devicePace` and at most `mostPace`, the same as this Mac's screen.
    public static let devicePace = 30
    public static let mostPace = 60
    /// 9 Nov: a watch opens on the device row the phone's last list read (if it is this fresh, ms) instead of reading
    /// the whole list again (16 s to open on 9 Nov, while the list took 7-13 s; this Mac's own rows are instant).
    static let freshRow = 20_000.0
    /// At most this many devices one connection watches at once.
    public static let maxWatches = 2
    public static let maxRows = 120
    /// At most this many elements are offered to pick on one still, and at most `mostPicks` picked.
    public static let mostElements = 250
    public static let mostPicks = 30

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
        /// The elements on screen now, for Annotate's Pick (the device's element tree; this Mac's accessibility).
        public var inspect: @Sendable (String) async -> BackendPhoneDeviceInspection
        /// Round 3: posts one input on this Mac at once, on the caller's thread (no answer awaited, no main thread);
        /// answers a refusal in words, or nil. Without it, input takes the device way (`input`).
        public var macPost: (@Sendable (String, BackendPhoneDeviceInput) -> String?)? = nil
        /// Locked-screen input crosses the private helper asynchronously and retains the ordinary refusal path.
        public var macInputAsyncWhen: @Sendable () -> Bool = { false }
        public var macState: (@Sendable () async -> String?)? = nil
        public var macControlNow: (@Sendable (UUID) async -> Bool)? = nil
        /// A transient password for macOS's own focused secure field. Never retained as input history or held keys.
        public var macSignIn: (@Sendable (String, String) async throws -> Void)? = nil
        /// Round 3: where this Mac's pointer is on a display (0…1), and its shape, for a phone that draws it itself.
        public var pointer: (@Sendable (String) -> BackendPhoneDevicePointer?)? = nil
        /// Round 3 (#24): the Mac's Settings switch "Phones may view and control this Mac's screen", and the words
        /// a phone hears when it is off.
        public var macAllowed: @Sendable () -> Bool = { true }
        public var macRefusal = "This Mac does not let phones view or control its screen."
        /// Round 3 (#26): records a simulator or emulator ("start", "stop" sends it and answers what to say, "cancel").
        public var record: (@Sendable (BackendPhoneDeviceRecordStep) async throws -> String)? = nil
        /// Which sessions each device is attached to (device id → session ids; item 45, the phones' session header).
        public var attachedSessions: @Sendable () async -> [String: [String]]
        /// stream step 2 (dc2): one message onto the connection's link (`BackendRemoteHost.sendDirect`): nil when that
        /// connection has not moved onto a link (send it the usual way), true sent, false dropped (the moving channel is full).
        public var direct: (@Sendable (UUID, Data, BackendLinkLane) async -> Bool?)? = nil
        /// M5: how the connection's link carries video now (`BackendRemoteHost.linkVideo`): nil when it has not moved.
        public var linkVideo: (@Sendable (UUID) async -> BackendLinkVideo?)? = nil
        /// 9 Nov: one finger step (device, phase "down"/"move"/"up", x, y) straight onto the device's direct input;
        /// false when it cannot go that way now (the gesture is then replayed as a tap or a swipe through `input`).
        /// Without it `sims.touch` is not offered.
        public var touch: (@Sendable (String, String, Double, Double) async -> Bool)? = nil
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
                    macViewers: @escaping @Sendable ([BackendPhoneMacViewer]) async -> Void = { _ in },
                    inspect: @escaping @Sendable (String) async -> BackendPhoneDeviceInspection = { _ in .init() },
                    attachedSessions: @escaping @Sendable () async -> [String: [String]] = { [:] }) {
            self.macRows = macRows; self.phoneName = phoneName; self.macViewers = macViewers; self.inspect = inspect
            self.attachedSessions = attachedSessions
            self.list = list; self.power = power; self.stream = stream; self.input = input; self.shot = shot
            self.deliver = deliver; self.visibleSessions = visibleSessions; self.send = send; self.clock = clock
        }
    }

    /// One phone watching one device.
    struct WatchKey: Hashable, Sendable { let connection: UUID; let device: String }
    struct Watch {
        var fps: Int
        var stream: (any BackendPhoneDeviceStream)?
        var pump: Task<Void, Never>?
        var seq = 0
        var sentAt: [Int: Double] = [:]
        var lastSent: Double = 0
        var waiter: (token: UUID, resume: CheckedContinuation<Void, Never>)?
        var started: Double
        var frames = 0
        var bytes = 0
        var name: String
        var deviceName: String
        var controlledAt: Double = 0
        var mac = false
        /// The pace of this watch's video on its link (acks against the link's own round trip).
        var pacer = BackendPhoneScreenPacer()
        var sentBytes: [Int: Int] = [:]
        var sharpFrames = 0
        /// Round 3: the phone draws the pointer (`sims.pointer`), and the task telling it where the pointer is.
        var cursor = false
        var pointerTask: Task<Void, Never>?
        /// Round 3 (#26): this phone is recording the device.
        var recording = false
        /// Item 61: the encoder while the video runs; a phone asked again (a keyframe is owed even on a still screen).
        var videoEncoder: BackendPhoneVideoEncoder?
        var videoResend = false
        var videoFrames = 0
        var videoBytes = 0
        /// The still frames on the way (Reviewer M1): they never count in the moving pictures' in-flight bound, so the
        /// first change after a pause goes at once instead of waiting until a large still has crossed and been acked.
        var stillSeqs: Set<Int> = []
        /// stream step 2: this watch's frames go on the connection's link (the first one there asked for a keyframe),
        /// how many went there, and how many the full moving channel dropped.
        var linked = false
        /// When this watch last asked for a keyframe (`sims.key`, at most one every 250 ms).
        var lastKeyAsk = -Double.infinity
        var linkFrames = 0
        var linkDropped = 0
        /// M5: the keyframe that went on `td.rel` and is not acked yet: nothing more goes until it is (or `keyGate`).
        var keyGate: Int?
        /// M5: the deltas that went on `td.rt` and are not acked yet (a lost one breaks the phone's chain), and how many
        /// were never acked.
        var movingSeqs: Set<Int> = []
        var linkLost = 0
        /// M5: when deltas were lost on `td.rt` lately; past `lossyAfter` of them this watch sends every frame on
        /// `td.rel` (paced by acks and the queue, nothing given up) for the rest of the watch.
        var lostAt: [Double] = []
        var reliableVideo = false
        /// M5: every frame of this watch goes on one reliable channel now (over TCP, or `reliableVideo`), and the moving
        /// frames acked in the last two seconds (when, bytes): what the link delivers while they queue up.
        var oneChannel = false
        var delivered: [(at: Double, bytes: Int)] = []
        /// M5: the last frame had to wait for the link's queue (the encoder makes more than the link carries).
        var backlogged = false
    }
    struct Still: Sendable {
        let device: String; let png: Data; let width: Int; let height: Int; let at: Double
        /// What Pick offers on it, once read (`sims.elements`).
        var inspection = BackendPhoneDeviceInspection()
    }

    let source: Source
    var watches: [WatchKey: Watch] = [:]
    private var stills: [String: Still] = [:]
    private var inputs: [String: Task<Void, Never>] = [:]
    private(set) var pendingInputs: [String: Int] = [:]
    private var signIns: [WatchKey: BackendMacSignInAttempt] = [:]
    /// Mouse buttons (with where they went down) and key codes another Mac holds down on this Mac, per connection and
    /// display (Reviewer, 31 Oct): when its view ends for any reason, they are let go, so nothing stays pressed here.
    struct Held: Sendable { var buttons: [String: (x: Double, y: Double)] = [:]; var keys: Set<Int> = []; var at = (x: 0.5, y: 0.5) }
    private var held: [WatchKey: Held] = [:]
    /// 9 Nov: each phone's finger on each device: the steps waiting (a move waiting behind another is replaced by the
    /// newer one, so a slow device never falls behind the finger), and the finger now down.
    struct TouchStep: Sendable, Equatable { var phase: String; var x: Double; var y: Double }
    struct Finger: Sendable {
        var direct: Bool
        var downX: Double, downY: Double, at: Double
        var lastX: Double, lastY: Double
        /// Put down near an edge: sent once the first move shows which way it goes (`edgeBand`).
        var held: Bool
    }
    struct TouchLane: Sendable { var queue: [TouchStep] = []; var draining = false; var finger: Finger? }
    private var touches: [WatchKey: TouchLane] = [:]
    /// Round 3: each phone's input to this Mac, applied as it arrives (`BackendMacInputLane`).
    private var lanes: [WatchKey: BackendMacInputLane] = [:]
    /// Elements read ahead for a simulator a phone opened (round 3, #26): Pick is ready when Annotate opens.
    private var warmed: Set<String> = []
    /// The device rows the last list read, and when (`freshRow`).
    private var listed: (at: Double, rows: [NativeRPCValue])?

    public init(source: Source) { self.source = source }

    /// `sims.record` as its own capability (Reviewer M6): offered only when this Mac can record.
    /// `sims.touch` as its own capability: offered only when this Mac can put a finger on its devices.
    public func touchFeature() -> BackendRemoteHostFeature {
        .init(capability: Self.touchCapability, messageTypes: [Self.touchCapability], policy: .ownerOnly) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Devices on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

    public func recordFeature() -> BackendRemoteHostFeature {
        .init(capability: Self.recordCapability, messageTypes: [Self.recordCapability], policy: .ownerOnly) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Devices on the phone stopped.") }
            return try await self.handle(message, context: context)
        }
    }

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
            if Self.isMac(try deviceID(message["id"])), !source.macAllowed() {
                throw NativeRPCError(code: "access-denied", message: source.macRefusal)
            }
            // §11.7: the screen is H.264 on the link, or nothing (no pictures, no relay video).
            guard (message["video"].elements ?? []).contains(where: { $0.string == "h264" }),
                  await source.linkVideo?(context.connectionID) != nil else {
                throw NativeRPCError(code: "unavailable", message: Self.needsLink)
            }
            return try await watch(message, context: context)
        case "sims.key":
            // A keyframe, please (stream step 2: the viewer lost a frame on the link, or its decoder started over).
            let key = WatchKey(connection: context.connectionID, device: try deviceID(message["id"]))
            // At most one every 250 ms per watch (Security N4): a keyframe costs a whole picture.
            let now = source.clock()
            guard let last = watches[key]?.lastKeyAsk, now - last >= 250 else { return [] }
            watches[key]?.lastKeyAsk = now
            let encoder = watches[key]?.videoEncoder
            encoder?.requestKey()
            if encoder != nil { watches[key]?.videoResend = true }
            return []
        case "sims.unwatch":
            await stopWatch(.init(connection: context.connectionID, device: try deviceID(message["id"])))
            return []
        case "sims.ack":
            ack(.init(connection: context.connectionID, device: try deviceID(message["id"])), seq: Int(message["seq"].number ?? -1))
            return []
        case "sims.unlock":
            let id = try deviceID(message["id"])
            guard Self.isMac(id), source.macAllowed(), context.kind == .mine,
                  context.phoneAccess == nil || context.phoneAccess == .full,
                  watches[WatchKey(connection: context.connectionID, device: id)] != nil,
                  let signIn = source.macSignIn, let password = message["password"].string,
                  !password.isEmpty, password.utf16.count <= 2_000 else {
                throw NativeRPCError(code: "unauthorized", message: "Sign-in needs your own device with Full control and an open Mac screen.")
            }
            let key = WatchKey(connection: context.connectionID, device: id)
            let attempt = BackendMacSignInAttempt.current ?? BackendMacSignInAttempt()
            guard pendingInputs[id, default: 0] == 0, !signIns.keys.contains(where: { $0.device == id }),
                  lanes.filter({ $0.key.device == id }).values.allSatisfy({ $0.isIdle }) else { throw BackendMacSignInAttempt.failure }
            try attempt.check()
            signIns[key] = attempt
            defer { signIns[key] = nil; attempt.cancel() }
            if let control = source.macControlNow, !(await control(context.connectionID)) {
                throw NativeRPCError(code: "unauthorized", message: "Sign-in needs your own device with Full control.")
            }
            try attempt.check()
            guard watches[key] != nil, source.macAllowed() else { throw BackendMacSignInAttempt.failure }
            try await BackendMacSignInAttempt.$current.withValue(attempt) { try await signIn(id, password) }
            return [try .init(.simsSent, fields: [.init("rid", message["rid"]), .init("ok", .bool(true)),
                .init("message", .string("Password sent. Check your Mac's screen."))])]
        case "sims.input":
            try await input(message, context: context)
            return []
        case "sims.touch":
            touch(message, context: context)
            return []
        case "sims.shot":
            let rid = try message["rid"].requireString("request", nonempty: true), id = try deviceID(message["id"])
            if Self.isMac(id), !Self.mayWatchMac(context) { throw NativeRPCError(code: "access-denied", message: Self.macWatchRefused) }
            if Self.isMac(id), !source.macAllowed() { throw NativeRPCError(code: "access-denied", message: source.macRefusal) }
            let answer = try await MacScreenAvailability.$mayWake.withValue(Self.mayWakeMac(context)) {
                try await shot(rid: rid, id: id)
            }
            // A phone with Pick asks for the elements too: they follow in their own frame (a still is near the size
            // limit already), read beside the connection so the still is never held back by a slow element tree.
            if message["inspect"].bool == true, let token = answer.value["shot"].string {
                let source = self.source, connection = context.connectionID
                Task { [weak self] in
                    let inspection = await source.inspect(id)
                    guard let self, let frame = await self.inspected(rid: rid, id: id, token: token, inspection) else { return }
                    try? await source.send(connection, frame)
                }
            }
            return [answer]
        case "sims.record":
            try await record(message, context: context)
            return []
        case "sims.annotate":
            try await annotate(message, context: context)
            return []
        default:
            throw NativeRPCError.invalidArguments("Unknown device operation.")
        }
    }

    func deviceID(_ value: NativeRPCValue) throws -> String {
        // UUIDs survive a reboot; numeric ids remain accepted for older phones.
        if let id = value.string, MacDisplaySelection.isValidID(id) { return id }
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
        listed = (source.clock(), value["devices"].elements ?? [])
        let watched = Set(watches.keys.filter { $0.connection == context.connectionID }.map(\.device))
        // This Mac first, as the Mac sends them (each display), then the devices.
        var mac: [NativeRPCValue] = []
        for row in await source.macRows().prefix(8) {
            guard let id = row["id"].string, Self.isMac(id) else { continue }
            mac.append(row.setting("watching", .bool(watched.contains(id))))
        }
        // Which of this phone's sessions each device is attached to (item 45): only sessions the phone can see.
        let attached = await source.attachedSessions()
        let visible = (try? await source.visibleSessions(context)) ?? []
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
                .init("sessions", .array((attached[id] ?? []).filter { visible.contains($0) }.prefix(8).map { .string($0) })),
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
        // This Mac: 30 a second by default (Macky study: 15/30/60, default 30). 9 Nov: a simulator or emulator the
        // same (at least `devicePace`, whatever older phones ask).
        let asked = message["fps"].number ?? Double(Self.devicePace)
        let fps = Int(min(Double(Self.mostPace), max(Self.isMac(id) ? 1 : Double(Self.devicePace), asked)))
        let key = WatchKey(connection: context.connectionID, device: id)
        if var current = watches[key] {
            // Again from the same phone: nothing restarted. Item 61: a phone asking again lost its decoder's state: a
            // keyframe, even on a still screen.
            current.fps = fps
            current.videoEncoder?.requestKey(); current.videoResend = current.videoEncoder != nil
            watches[key] = current
            return [try state(id, "live", note: "")]
        }
        guard watches.keys.filter({ $0.connection == context.connectionID }).count < Self.maxWatches else {
            throw NativeRPCError(code: "unavailable", message: "This phone already watches two devices. Close one first.")
        }
        let candidates = Self.isMac(id) ? await source.macRows() : await deviceRows(for: id)
        guard let row = candidates.first(where: { $0["id"].string == id })
                ?? (MacDisplaySelection.isValidID(id) ? candidates.first(where: { $0["main"].bool == true }) ?? candidates.first : nil) else {
            throw NativeRPCError(code: "unavailable", message: "That device is no longer on this Mac. Pull to refresh the list.")
        }
        guard row["state"].string == "ready" else {
            throw NativeRPCError(code: "unavailable", message: "Start the device first; it is not running.")
        }
        let name = row["name"].string ?? id
        let phone = await source.phoneName(context)
        guard watches[key] == nil else { return [try state(id, "live", note: "")] }
        watches[key] = Watch(fps: fps, started: source.clock(), name: phone, deviceName: name)
        if Self.isMac(id) { watches[key]?.mac = true }
        let cursor = Self.isMac(id) && message["cursor"].bool == true && source.pointer != nil
        watches[key]?.cursor = cursor
        if cursor { watches[key]?.pointerTask = reportPointer(key) }
        if !Self.isMac(id) { warm(id) }
        if Self.isMac(id) { await reportMac() }
        let source = self.source
        let pump = Task { [weak self] in
            do {
                let stream = try await MacScreenAvailability.$mayWake.withValue(Self.mayWakeMac(context)) {
                    try await MacScreenAvailability.$progress.withValue({ note in
                        try? await source.send(key.connection, try BackendRemoteServerMessage(.simsState, fields: [.init("id", .string(id)), .init("state", .string("opening")), .init("note", .string(note))]))
                    }) {
                        try await source.stream(id, row)
                    }
                }
                guard let self, await self.opened(key, stream) else { await stream.stop(); return }
                if cursor { await stream.drawsPointer(true) }
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

    /// The rows a device watch looks in: the last list's, when it is fresh and shows the device running (the phone
    /// opens a device from the list it just read), else the list read now.
    private func deviceRows(for id: String) async -> [NativeRPCValue] {
        if let listed, source.clock() - listed.at < Self.freshRow,
           listed.rows.contains(where: { $0["id"].string == id && $0["state"].string == "ready" }) { return listed.rows }
        let rows = await source.list()["devices"].elements ?? []
        listed = (source.clock(), rows)
        return rows
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
        signIns[key]?.cancel()
        guard let watch = watches.removeValue(forKey: key) else { return }
        watch.waiter?.resume.resume()
        watch.pointerTask?.cancel()
        if watch.recording { discardRecording(key, watch) }
        await watch.stream?.stop()
        try? await source.send(key.connection, try state(key.device, "ended", note: why.isEmpty ? "The device stopped." : why))
        if Self.isMac(key.device) { releaseHeld(key); await reportMac() }
    }

    func stopWatch(_ key: WatchKey) async {
        signIns[key]?.cancel()
        guard let watch = watches.removeValue(forKey: key) else { return }
        watch.pump?.cancel()
        watch.waiter?.resume.resume()
        watch.pointerTask?.cancel()
        if watch.recording { discardRecording(key, watch) }
        await watch.stream?.stop()
        if Self.isMac(key.device) { releaseHeld(key); await reportMac() }
    }

    /// A text field on this Mac took (true) or lost (false) the keyboard focus: every phone watching this Mac is told,
    /// so its keyboard comes up where the person clicked (1 Nov, Asad: "keyboard will come wherever we click").
    /// Only phones that clicked or typed in the last 15 s (the card's "controlling" window, Reviewer 1 Nov): the
    /// person at the Mac clicking into a field must not pop the keyboard on a phone that only watches.
    public func macFocus(text: Bool) async {
        let now = source.clock()
        for key in watches.keys where Self.isMac(key.device) && now - (watches[key]?.controlledAt ?? 0) < 15_000 {
            if let message = try? BackendRemoteServerMessage(.simsFocus, fields: [.init("id", .string(key.device)), .init("text", .bool(text))]) {
                try? await source.send(key.connection, message)
            }
        }
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
        for attempt in signIns.values { attempt.cancel() }
        for key in watches.keys where Self.isMac(key.device) {
            guard let watch = watches.removeValue(forKey: key) else { continue }
            watch.pump?.cancel()
            watch.waiter?.resume.resume()
            watch.pointerTask?.cancel()
            await watch.stream?.stop()
            try? await source.send(key.connection, try state(key.device, "ended", note: why))
            releaseHeld(key)
        }
        await reportMac()
    }

    /// Every watch stops (the feature is going away).
    public func stopAll() async {
        for key in Array(touches.keys) { liftFinger(key) }
        for key in Array(watches.keys) { await stopWatch(key) }
        for key in Array(held.keys) { releaseHeld(key) }
    }

    /// The connection closed: everything it watched stops.
    public func connectionClosed(_ connection: UUID) async {
        // A finger still down on a device from this phone is lifted there.
        for key in touches.keys where key.connection == connection { liftFinger(key) }
        for key in watches.keys where key.connection == connection { await stopWatch(key) }
        // Held without a watch (the watch ended first): let go too.
        for key in held.keys where key.connection == connection { releaseHeld(key) }
        for key in lanes.keys where key.connection == connection { lanes[key] = nil }
    }

    /// The screen for one viewer: hardware H.264 on the link (item 61), or the watch ends.
    private func pump(_ key: WatchKey, _ stream: any BackendPhoneDeviceStream) async {
        if Self.isMac(key.device), let control = source.macControlNow,
           let phase = await source.macState?(), ["locked", "signing-in"].contains(phase), !(await control(key.connection)) {
            await ended(key, why: "The lock screen needs your own device with Full control.")
            return
        }
        let first = await stream.pixels(within: 2)
        if case .unsupported = first { await ended(key, why: Self.cannotShow); return }
        await pumpVideo(key, stream, first: first)
    }

    /// Item 61 (Asad: "only the changed part updates … when I move something it shows after some time"): every new
    /// picture of the screen goes as hardware H.264 the moment the link has room (paced like the raw path, at most `fps`
    /// a second); once nothing new came for `stillAfter`, ONE full-quality keyframe of the last picture (capped in size and
    /// sent part by part, so the next change overtakes it — Reviewer M1/M2); then nothing until the screen changes. A
    /// phone asking again gets a keyframe at once, even on a still screen. An encoder that keeps failing ends the watch
    /// (Reviewer S2; no pictures since 3 Nov).
    private func pumpVideo(_ key: WatchKey, _ stream: any BackendPhoneDeviceStream, first: BackendPhoneDevicePixelsAnswer) async {
        var pending: BackendPhoneDevicePixels?
        var last: BackendPhoneDevicePixels?
        var owesStill = false
        var lastMacState: String?
        // Pictures VideoToolbox gave nothing for, while it has never given anything at all (a real-time encoder also
        // drops a frame now and then on purpose, which is not a failure).
        var failures = 0, produced = false
        // A picture the encoder dropped is tried once more at once (slow typing: there may be no next picture for a while).
        var retried: CVPixelBuffer?
        switch first {
        case .pixels(let pixels): pending = pixels
        case .ended: await ended(key, why: await stream.endReason()); return
        default: break
        }
        guard let watch = watches[key] else { return }
        let encoder = BackendPhoneVideoEncoder(bitrate: watch.pacer.bitrate, fps: watch.fps)
        watches[key]?.videoEncoder = encoder
        defer { encoder.invalidate() }
        while !Task.isCancelled, watches[key] != nil {
            if Self.isMac(key.device), let state = await source.macState?() {
                if state == MacReach.State.locked.rawValue || state == MacReach.State.signingIn.rawValue {
                    if let control = source.macControlNow, !(await control(key.connection)) {
                        await ended(key, why: "The lock screen needs your own device with Full control.")
                        return
                    }
                }
                if state != lastMacState, let phase = MacReach.State(rawValue: state) {
                    lastMacState = state
                    try? await source.send(key.connection, .init(.simsState, fields: [.init("id", .string(key.device)),
                        .init("state", .string(state)), .init("note", .string(phase.words))]))
                }
            }
            if watches[key]?.videoResend == true, pending == nil, let cached = last {
                watches[key]?.videoResend = false
                encoder.requestKey()
                // M5: asked while the screen moves (a frame lost on the way), the next moving picture is the keyframe:
                // about 0.4 s of the link, not a sharp still several times that size.
                if case .pixels(let pixels) = await stream.pixels(within: 0) { pending = pixels; continue }
                if await stream.isStarting() { last = nil; owesStill = false; encoder.requestKey(); continue }
                // A phone asked again on a still screen: the last picture as a keyframe.
                switch await sendStill(key, encoder, cached, stream: stream) {
                case .gone: return
                case .overtaken(let pixels): pending = pixels
                case .sent: owesStill = false
                }
                continue
            }
            if pending == nil {
                switch await stream.pixels(within: owesStill ? Self.stillAfter : 1) {
                case .pixels(let pixels): pending = pixels
                case .unchanged:
                    if await stream.isStarting() { last = nil; owesStill = false; encoder.requestKey(); continue }
                    guard owesStill, let last else { continue }
                    await room(key)
                    guard !Task.isCancelled, watches[key] != nil else { return }
                    if case .pixels(let pixels) = await stream.pixels(within: 0) { pending = pixels; continue }
                    owesStill = false
                    switch await sendStill(key, encoder, last, stream: stream) {
                    case .gone: return
                    case .overtaken(let pixels): pending = pixels
                    case .sent: break
                    }
                    continue
                case .ended, .unsupported:
                    await ended(key, why: await stream.endReason()); return
                }
            }
            await room(key)
            guard !Task.isCancelled, let plan = plan(key) else { return }
            let wait = plan.next - source.clock()
            if wait > 1 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            guard !Task.isCancelled, let pace = watches[key]?.pacer else { return }
            // The newest picture by now.
            if case .pixels(let pixels) = await stream.pixels(within: 0) { pending = pixels }
            guard let pixels = pending else { continue }
            pending = nil
            watches[key]?.videoResend = false
            encoder.setBitrate(max(1_000_000, pace.bitrate))
            guard let frame = await encoder.motion(pixels.buffer) else {
                if retried !== pixels.buffer { retried = pixels.buffer; pending = pixels; encoder.requestKey(); continue }
                if !produced { failures += 1 }
                if !produced, failures >= Self.videoFailuresBeforeEnd {
                    // VideoToolbox cannot encode here (a virtual machine, an odd pixel format): said plainly, no pictures.
                    encoder.invalidate()
                    watches[key]?.videoEncoder = nil
                    await ended(key, why: Self.cannotShow)
                    return
                }
                encoder.requestKey()
                continue
            }
            produced = true
            last = pixels
            owesStill = true
            if !(await pushVideo(key, frame, capturedAt: pixels.capturedAt)) { return }
        }
    }

    enum StillOutcome { case sent, overtaken(BackendPhoneDevicePixels), gone }

    /// The still frame of `pixels`: at most about two link-seconds and never more than `stillHardCap` (Reviewer M2), sent
    /// part by part at the link's pace; a new picture before the last part abandons it (the phone drops a frame whose
    /// parts did not all come) and is handed back to go at once (Reviewer M1). The next moving frame is a keyframe.
    private func sendStill(_ key: WatchKey, _ encoder: BackendPhoneVideoEncoder, _ pixels: BackendPhoneDevicePixels,
                           stream: any BackendPhoneDeviceStream) async -> StillOutcome {
        guard let pace = watches[key]?.pacer else { return .gone }
        let budget = Self.stillBudget(bitrate: pace.bitrate)
        guard let frame = await encoder.stillFrame(pixels.buffer, maxBytes: budget) else { return .sent }
        guard var watch = watches[key] else { return .gone }
        let messages = Self.videoMessages(id: key.device, seq: watch.seq + 1, frame, capturedAt: pixels.capturedAt, partChars: Self.stillPartChars)
        guard !messages.isEmpty else { return .sent }
        watch.seq += 1
        let seq = watch.seq, now = source.clock(), bytes = frame.data.count
        watch.sentAt[seq] = now; watch.sentBytes[seq] = bytes; watch.stillSeqs.insert(seq)
        watch.frames += 1; watch.bytes += bytes; watch.videoFrames += 1; watch.videoBytes += bytes; watch.sharpFrames += 1
        watches[key] = watch
        for (index, message) in messages.enumerated() {
            if index > 0 {
                // One part's time on the link at the believed bitrate, watching for a new picture meanwhile.
                let chars = Double(messages[index - 1].value["data"].string?.utf8.count ?? 0)
                // At the moving pictures' rate (what the link is believed to carry): faster would queue parts on the link
                // ahead of the next change's first frame (seen 2 Nov at twice the rate).
                let seconds = chars * 0.75 * 8 / max(500_000, watches[key]?.pacer.bitrate ?? pace.bitrate)
                if case .pixels(let newer) = await stream.pixels(within: seconds) {
                    watches[key]?.sentAt[seq] = nil; watches[key]?.sentBytes[seq] = nil; watches[key]?.stillSeqs.remove(seq)
                    return .overtaken(newer)
                }
                guard !Task.isCancelled, watches[key] != nil else { return .gone }
                // M5: on the link, never more than about one part waiting on `td.rel`: the still then crosses at the
                // link's own pace (on a slow or lossy path that can be far below the believed bitrate), and a keyframe
                // that follows it waits behind one part at most, not the whole picture (measured 2 Nov, 2 % loss
                // through TURN: a still queued whole starved the moving frames until they expired unseen).
                let waitUntil = source.clock() + 10_000
                while let video = await source.linkVideo?(key.connection), video.queuedStill > UInt64(Self.stillPartChars),
                      source.clock() < waitUntil {
                    if case .pixels(let newer) = await stream.pixels(within: 0.01) {
                        watches[key]?.sentAt[seq] = nil; watches[key]?.sentBytes[seq] = nil; watches[key]?.stillSeqs.remove(seq)
                        return .overtaken(newer)
                    }
                    guard !Task.isCancelled, watches[key] != nil else { return .gone }
                }
            }
            // The still's own channel on the link: it must arrive whole.
            do { try await deliver(key, message, lane: .still) } catch { await stopWatch(key); return .gone }
        }
        return .sent
    }

    /// The bytes one still frame may take: about one second of the link (it crosses in about a second), at least 300 KB,
    /// at most `stillHardCap`.
    static func stillBudget(bitrate: Double) -> Int {
        min(BackendPhoneVideoEncoder.stillHardCap, max(300_000, Int(bitrate / 8)))
    }

    /// Sends one encoded moving picture (in parts when large); false when the connection is gone. A frame the phones
    /// could not join (more than `mostParts` parts) is never sent: the next one is a keyframe instead (Reviewer M2).
    private func pushVideo(_ key: WatchKey, _ frame: BackendPhoneVideoEncoder.Frame, capturedAt: Double) async -> Bool {
        guard var watch = watches[key] else { return false }
        let messages = Self.videoMessages(id: key.device, seq: watch.seq + 1, frame, capturedAt: capturedAt)
        guard !messages.isEmpty else { watch.videoEncoder?.requestKey(); return true }
        watch.seq += 1
        let now = source.clock(), bytes = frame.data.count
        watch.sentAt[watch.seq] = now; watch.lastSent = now; watch.sentBytes[watch.seq] = bytes
        watch.frames += 1; watch.bytes += bytes; watch.videoFrames += 1; watch.videoBytes += bytes
        watches[key] = watch
        // On the link (M5): deltas on `td.rt`, which gives up after 150 ms (a late delta is worthless; a lost one makes
        // the phone ask for a keyframe); keyframes on `td.rel`, so a keyframe is never given up on a lossy or slow path
        // (measured 2 Nov through TURN with 2 % loss: a keyframe given up on `td.rt` left the picture stopped for good).
        // The two channels keep no order between them, so after a keyframe nothing more goes until the phone acked it
        // (`keyGate`): a delta can then never overtake its keyframe (2 Nov: 39 asks in 4 s without that). Over TCP, and
        // for a watch that keeps losing deltas (`reliableVideo`), every frame goes on `td.rel`: one order, nothing to
        // wait for, nothing given up. A frame is never split across two channels.
        let video = await source.linkVideo?(key.connection)
        let split = video != nil && video?.reliableOnly == false && !watch.reliableVideo   // deltas on td.rt, keyframes on td.rel
        var onLink = false
        do { for message in messages { onLink = try await deliver(key, message, lane: frame.key || !split ? .still : .moving) } }
        catch { await stopWatch(key); return false }
        if onLink, split {
            if frame.key { watches[key]?.keyGate = watch.seq } else { watches[key]?.movingSeqs.insert(watch.seq) }
        }
        watches[key]?.oneChannel = onLink && !split
        return true
    }

    /// One video message to the phone (contract §6/§11.7): on the connection's link only (moving frames on `td.rt`,
    /// keyframes and the still on `td.rel`; a moving frame the full channel cannot take is dropped and the phone asks for
    /// a keyframe). Never over the relay: a connection without a link throws and the watch stops.
    /// True when it went on (or was dropped on) the link.
    @discardableResult
    func deliver(_ key: WatchKey, _ message: BackendRemoteServerMessage, lane: BackendLinkLane) async throws -> Bool {
        guard let direct = source.direct, let text = try? BackendRemoteProtocol.serialize(message),
              let sent = await direct(key.connection, Data(text.utf8), lane) else {
            throw NativeRPCError(code: "unavailable", message: Self.needsLink)
        }
        if sent { watches[key]?.linkFrames += 1 } else { watches[key]?.linkDropped += 1 }
        if watches[key]?.linked == false {
            watches[key]?.linked = true
            watches[key]?.videoEncoder?.requestKey()
        }
        return true
    }

    /// For tests: the most pictures a second a watch of `device` may send.
    func pace(_ device: String) -> Int? { watches.first { $0.key.device == device }?.value.fps }

    /// For tests and the measurement: the frames every watch sent on its link and dropped there, and the pace now.
    func linkCounts() -> (sent: Int, dropped: Int, bitrate: Double, watches: Int, unacked: Int, lost: Int) {
        (watches.values.reduce(0) { $0 + $1.linkFrames }, watches.values.reduce(0) { $0 + $1.linkDropped },
         watches.values.first?.pacer.bitrate ?? 0, watches.count, watches.values.reduce(0) { $0 + $1.sentAt.count },
         watches.values.reduce(0) { $0 + $1.linkLost })
    }

    /// One encoded picture as `sims.video` messages: whole when it fits, else in parts (`part`, `parts`); none at all when
    /// it would need more than `mostParts` parts (no phone could join it).
    static func videoMessages(id: String, seq: Int, _ frame: BackendPhoneVideoEncoder.Frame, capturedAt: Double,
                              partChars: Int = BackendPhoneDevices.partChars) -> [BackendRemoteServerMessage] {
        let text = Array(frame.data.base64EncodedString().utf8)
        guard (text.count + partChars - 1) / partChars <= mostParts else { return [] }
        var pieces: [String] = []
        var start = 0
        repeat {
            let end = min(text.count, start + partChars)
            pieces.append(String(decoding: text[start..<end], as: UTF8.self))
            start = end
        } while start < text.count
        return pieces.enumerated().compactMap { index, piece in
            var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("seq", .number(Double(seq))),
                .init("w", .number(Double(frame.width))), .init("h", .number(Double(frame.height))), .init("data", .string(piece)),
                .init("ct", .number(capturedAt.rounded()))]
            if pieces.count > 1 { fields += [.init("part", .number(Double(index))), .init("parts", .number(Double(pieces.count)))] }
            if frame.key {
                fields.append(.init("key", .bool(true)))
                if let sps = frame.sps { fields.append(.init("sps", .string(sps.base64EncodedString()))) }
                if let pps = frame.pps { fields.append(.init("pps", .string(pps.base64EncodedString()))) }
            }
            if frame.still { fields.append(.init("still", .bool(true))) }
            return try? .init(.simsVideo, fields: fields)
        }
    }

    /// Round 3: encoding a picture (tens of ms for a Retina screen) runs off this actor, so a phone's input, an ack or
    /// a watch is never queued behind it.
    nonisolated static func offActor<T: Sendable>(_ work: @Sendable () -> T) async -> T { work() }

    struct Plan { let next: Double }
    /// Video (item 61): the encoder keeps to the bitrate, so frames are spaced by the frame rate only.
    func plan(_ key: WatchKey) -> Plan? {
        guard let watch = watches[key] else { return nil }
        return Plan(next: watch.lastSent + 1_000 / Double(watch.fps))
    }

    /// Waits until few enough frames are unacked (a frame unacked for `lostAfter` no longer counts).
    /// On the link (M5) also until the phone acked the last keyframe (`keyGate`) and while more than about 100 ms of
    /// the bitrate waits on the channel the moving frames take: a frame is then held before it is made, never made and
    /// left to expire in a queue (which the phone would only see as a gap, if a later frame got through at all).
    private func room(_ key: WatchKey) async {
        var waitedForQueue = false
        while let watch = watches[key], !Task.isCancelled {
            let now = source.clock()
            // M5: deltas `td.rt` gave up on never come back acked, and a slow path may let none through at all, so the
            // phone never sees a gap to ask about (measured 2 Nov, 5 % loss through TURN: one frame shown in 8 s, no ask).
            // The host notices instead: step the bitrate down and send a keyframe (on `td.rel`, which always arrives).
            let gone = watch.movingSeqs.filter { watch.sentAt[$0] == nil }
            if !gone.isEmpty { watches[key]?.movingSeqs.subtract(gone) }
            let lostMoving = watch.movingSeqs.filter { watch.sentAt[$0].map { now - $0 > Self.movingLostAfter } ?? false }
            if !lostMoving.isEmpty {
                for seq in lostMoving { watches[key]?.movingSeqs.remove(seq); watches[key]?.sentAt[seq] = nil; watches[key]?.sentBytes[seq] = nil }
                watches[key]?.linkLost += lostMoving.count
                watches[key]?.pacer.lost(now: now)
                watches[key]?.videoEncoder?.requestKey()
                // A path that keeps losing deltas (measured 2 Nov, 2-5 % loss through TURN: most deltas larger than the
                // 150 ms the channel retries, so most never arrived) gets the reliable way, which measured 30 a second
                // over TCP: a lost packet is sent again instead of costing the frame and a keyframe.
                let recent = (watch.lostAt + Array(repeating: now, count: lostMoving.count)).filter { now - $0 < Self.lossyWindow }
                watches[key]?.lostAt = recent
                if recent.count >= Self.lossyAfter, !watch.reliableVideo {
                    watches[key]?.reliableVideo = true
                    BackendRemoteRelayClient.note("link: video for \(key.device) goes the reliable way (\(recent.count) frames lost on td.rt)")
                }
                continue
            }
            if let gate = watch.keyGate {
                if let sent = watch.sentAt[gate], now - sent < Self.keyGate { await waitForAck(key); continue }
                watches[key]?.keyGate = nil
            }
            if watch.videoEncoder != nil, let video = await source.linkVideo?(key.connection) {
                let backlog = video.reliableOnly || watch.reliableVideo ? video.queuedStill : video.queuedMoving
                if backlog > UInt64(max(16_000, watch.pacer.bitrate / 8 * 0.1)) {
                    waitedForQueue = true
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                watches[key]?.backlogged = waitedForQueue
            }
            let lost = watch.sentAt.filter { now - $0.value > Self.lostAfter }.map(\.key)
            for seq in lost { watches[key]?.sentAt[seq] = nil; watches[key]?.sentBytes[seq] = nil; watches[key]?.stillSeqs.remove(seq) }
            if let now = watches[key] {
                // A few frames and the link's worth of bytes on the way (one at least), up to `inFlightVideo` (item 61).
                // The still frame on the way does not count (Reviewer M1): moving pictures may go while it crosses.
                let moving = now.sentAt.keys.filter { !now.stillSeqs.contains($0) }
                let bytes = moving.reduce(0) { $0 + (now.sentBytes[$1] ?? 0) }
                if moving.isEmpty || (moving.count < Self.inFlightVideo && bytes < now.pacer.inFlightBytes) { return }
            }
            await waitForAck(key)
        }
    }

    /// Until the next ack (or half a second).
    private func waitForAck(_ key: WatchKey, longest: UInt64 = 500_000_000) async {
        let token = UUID()
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            watches[key]?.waiter?.resume.resume()
            watches[key]?.waiter = (token, resume)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: longest)
                await self?.wake(key, token: token)
            }
        }
    }

    private func wake(_ key: WatchKey, token: UUID?) {
        guard let waiter = watches[key]?.waiter, token == nil || waiter.token == token else { return }
        watches[key]?.waiter = nil
        waiter.resume.resume()
    }

    /// The phone drew a picture: room for the next, and the connection's speed is read off how long it took.
    func ack(_ key: WatchKey, seq: Int) {
        guard var watch = watches[key], let sentAt = watch.sentAt.removeValue(forKey: seq) else { return }
        watch.movingSeqs.remove(seq)
        let now = source.clock(), took = now - sentAt
        let bytes = watch.sentBytes.removeValue(forKey: seq) ?? 0
        // A still frame's parts are spaced out on purpose (`sendStill`): its ack time says nothing about the link.
        if watch.stillSeqs.remove(seq) != nil { watches[key] = watch; wake(key, token: nil); return }
        watch.pacer.acked(took: took, bytes: bytes, now: now)
        if watch.oneChannel, watch.videoEncoder != nil {
            // M5, one reliable channel (over TCP, or a lossy path): frames that queue up (acked well after the link's own
            // round trip) mean the encoder makes more than the link delivers, and then each frame only grows (the
            // encoder spends the bitrate over the longer wait), so the picture rate falls instead of the quality
            // (measured 3 Nov, 2 % loss: 2.4 frames a second of 107 KB each). Cap the bitrate at 80 % of what was
            // actually delivered in the last two seconds, so frames drain faster than they are made.
            watch.delivered.append((now, bytes))
            watch.delivered.removeAll { now - $0.at > 2_000 }
            // Only while the link is the limit (the last frame waited for its queue): otherwise the delivered rate is just
            // what the picture needed, and capping to it would walk the bitrate down for nothing.
            if watch.backlogged, let first = watch.delivered.first, now - first.at >= 500, took > (watch.pacer.base ?? 0) + 250 {
                let rate = Double(watch.delivered.reduce(0) { $0 + $1.bytes }) * 8_000 / (now - first.at)
                watch.pacer.cap(rate * 0.8, now: now)
            }
        }
        watches[key] = watch
        wake(key, token: nil)
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
                .init("megabitsPerSecond", .number((watch.pacer.bitrate / 100_000).rounded() / 10)),
                .init("sharpPictures", .number(Double(watch.sharpFrames)))])
        })
    }

    // MARK: Touch (9 Nov)

    /// Asad (9 Nov): "when i use it it moves slow" — a drag went to the device only when the finger lifted, and was then
    /// replayed over its own length. `sims.touch` puts the finger on the device as it moves: down, the moves, up, each
    /// onto the device's direct input (the helper the Mac's panel uses) the moment it comes, in order, a waiting move
    /// replaced by the newer one. When the direct input cannot take the finger (the direct screen has not shown yet, or
    /// the device's touchscreen does not take fingers that way), the gesture is kept and, when the finger lifts, sent
    /// the old way: a tap (held as long as the finger was) or a swipe.
    /// Never answered, never refused on the wire (a refusal without a request id would be taken as the answer to the
    /// phone's oldest waiting read): what cannot be used is noted here only.
    func touch(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) {
        guard let id = try? deviceID(message["id"]), !Self.isMac(id), let phase = message["phase"].string, Self.touchPhases.contains(phase),
              let x = message["x"].number, let y = message["y"].number, x.isFinite, y.isFinite else {
            BackendRemoteRelayClient.note("sims.touch: a finger step that cannot be used was left out")
            return
        }
        let key = WatchKey(connection: context.connectionID, device: id)
        let step = TouchStep(phase: phase == "cancel" ? "up" : phase, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        var lane = touches[key] ?? TouchLane()
        if step.phase == "move", lane.queue.last?.phase == "move" { lane.queue[lane.queue.count - 1] = step } else { lane.queue.append(step) }
        let start = !lane.draining
        lane.draining = true
        touches[key] = lane
        if start { Task { await self.drainTouches(key) } }
    }

    private func drainTouches(_ key: WatchKey) async {
        while let step = touches[key]?.queue.first {
            touches[key]?.queue.removeFirst()
            await applyTouch(key, step)
        }
        touches[key]?.draining = false
        if let lane = touches[key], lane.queue.isEmpty, lane.finger == nil { touches[key] = nil }
    }

    private func applyTouch(_ key: WatchKey, _ step: TouchStep) async {
        let now = source.clock()
        switch step.phase {
        case "down":
            // A finger already down (its up was lost) is lifted first.
            if touches[key]?.finger != nil { await endFinger(key, at: nil) }
            var finger = Finger(direct: false, downX: step.x, downY: step.y, at: now, lastX: step.x, lastY: step.y, held: false)
            if Self.nearEdge(step.x, step.y) { finger.held = true } else { finger.direct = await sendTouch(key.device, "down", step.x, step.y) }
            // The phone went while the finger went down: it is lifted again.
            guard touches[key] != nil else { if finger.direct { _ = await sendTouch(key.device, "up", step.x, step.y) }; return }
            touches[key]?.finger = finger
        case "move":
            guard var finger = touches[key]?.finger else { return }   // a move without a down: nothing to move
            if finger.held {
                // The first move shows the way: inward from the edge starts at the edge.
                let (x, y) = Self.edgeSnapped(fromX: finger.downX, fromY: finger.downY, toX: step.x, toY: step.y)
                finger.downX = x; finger.downY = y; finger.held = false
                finger.direct = await sendTouch(key.device, "down", x, y)
                guard touches[key] != nil else { if finger.direct { _ = await sendTouch(key.device, "up", x, y) }; return }
            }
            finger.lastX = step.x; finger.lastY = step.y
            touches[key]?.finger = finger
            if finger.direct { _ = await sendTouch(key.device, "move", step.x, step.y) }
        default:
            await endFinger(key, at: (step.x, step.y))
        }
    }

    /// The finger lifts at `at` (nil: where it last was).
    private func endFinger(_ key: WatchKey, at: (Double, Double)?) async {
        guard var finger = touches[key]?.finger else { return }
        touches[key]?.finger = nil
        let (x, y) = at ?? (finger.lastX, finger.lastY)
        if finger.held {
            // Put down near the edge and lifted without moving: a touch where it was.
            finger.held = false
            finger.direct = await sendTouch(key.device, "down", finger.downX, finger.downY)
        }
        if finger.direct { _ = await sendTouch(key.device, "up", x, y); return }
        let what = Self.replay(finger, upX: x, upY: y, now: source.clock())
        let previous = inputs[key.device], source = self.source, id = key.device
        pendingInputs[id, default: 0] += 1
        inputs[id] = Task {
            defer { self.pendingInputs[id, default: 1] -= 1 }
            await previous?.value
            do { try await BackendAppDeviceDeadline.run(within: 30, "Sending to the device") { try await source.input(id, what) } }
            catch { BackendRemoteRelayClient.note("sims.touch: \(id) gesture not sent: \((error as? NativeRPCError)?.message ?? error.localizedDescription)") }
        }
    }

    /// A finger still down when its phone goes (or the feature stops) is lifted on the device.
    private func liftFinger(_ key: WatchKey) {
        guard let finger = touches.removeValue(forKey: key)?.finger, finger.direct, !finger.held else { return }
        let touch = source.touch, id = key.device
        Task { _ = await touch?(id, "up", finger.lastX, finger.lastY) }
    }

    private func sendTouch(_ id: String, _ phase: String, _ x: Double, _ y: Double) async -> Bool {
        guard let touch = source.touch else { return false }
        return await touch(id, phase, x, y)
    }

    static func nearEdge(_ x: Double, _ y: Double) -> Bool {
        x <= edgeBand || x >= 1 - edgeBand || y <= edgeBand || y >= 1 - edgeBand
    }

    /// Where a finger put down at (fromX, fromY) starts when it moves to (toX, toY): at the edge it is near when it
    /// moves away from that edge.
    static func edgeSnapped(fromX: Double, fromY: Double, toX: Double, toY: Double) -> (Double, Double) {
        var x = fromX, y = fromY
        if fromY >= 1 - edgeBand, toY < fromY { y = 1 }
        if fromY <= edgeBand, toY > fromY { y = 0 }
        if fromX <= edgeBand, toX > fromX { x = 0 }
        if fromX >= 1 - edgeBand, toX < fromX { x = 1 }
        return (x, y)
    }

    /// A gesture the direct input could not take, as the old inputs: a tap (held as long as the finger was, from half
    /// a second) when it hardly moved, else a swipe over the time it took.
    static func replay(_ finger: Finger, upX: Double, upY: Double, now: Double) -> BackendPhoneDeviceInput {
        let held = max(0, now - finger.at)
        if abs(upX - finger.downX) < 0.02, abs(upY - finger.downY) < 0.02 {
            return .tap(x: finger.downX, y: finger.downY, holdMilliseconds: held >= 450 ? min(held, 3_000) : nil)
        }
        let (x, y) = edgeSnapped(fromX: finger.downX, fromY: finger.downY, toX: upX, toY: upY)
        return .swipe(fromX: x, fromY: y, toX: upX, toY: upY, milliseconds: min(max(held, 120), 1_500))
    }

    // MARK: Input

    /// Input goes to the device in the order it came, one at a time per device; a refusal comes back with its rid.
    func input(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws {
        let rid = message["rid"].string ?? ""
        do { try await inputNow(message, rid: rid, context: context) }
        catch {
            // Round 3 (#23): input without a request id (the trackpad's moves, clicks and scrolls) is never answered,
            // so a refusal of it is never said over the picture; it is noted here only.
            guard rid.isEmpty else { throw error }
        }
    }

    private func inputNow(_ message: BackendRemoteClientMessage, rid: String, context: BackendRemoteHostContext) async throws {
        let id = try deviceID(message["id"])
        let mac = Self.isMac(id)
        if mac, !source.macAllowed() { throw NativeRPCError(code: "access-denied", message: source.macRefusal) }
        // This Mac: only the owner's phone at Full control clicks and types; Look and Work only watch.
        if mac {
            guard context.phoneAccess == .full || context.phoneAccess == nil && context.kind == .mine else { throw NativeRPCError(code: "access-denied", message: Self.macControlRefused) }
            var began = false
            for key in watches.keys where key.device == id && key.connection == context.connectionID {
                if source.clock() - (watches[key]?.controlledAt ?? 0) >= 15_000 { began = true }
                watches[key]?.controlledAt = source.clock()
            }
            // Who controls this Mac changed: said in the background, never before the input is applied.
            if began { Task { await self.reportMac() } }
        }
        guard !signIns.keys.contains(where: { $0.device == id }) else { throw BackendMacSignInAttempt.failure }
        let what = try Self.input(message, mac: mac)
        if mac { note(what, key: WatchKey(connection: context.connectionID, device: id)) }
        // Round 3: this Mac's input is applied the moment it arrives, on its own queue, in order (a pointer move waits
        // for no answer, no picture and no main thread); only a drag-swipe of an older phone still takes the long way.
        if mac, !source.macInputAsyncWhen(), let lane = lane(WatchKey(connection: context.connectionID, device: id)) {
            if case .swipe = what {} else {
                let source = self.source, connection = context.connectionID
                let refused: @Sendable (String) -> Void = { words in
                    guard !rid.isEmpty else { return }
                    Task { try? await source.send(connection, Self.refusal(rid: rid, NativeRPCError(code: "unavailable", message: words))) }
                }
                if case let .pointer(dx, dy, held) = what {
                    lane.pointer(.by(dx: dx, dy: dy), held: held, n: Int(message["n"].number ?? 0), refused: refused)
                } else if case let .pointerTo(x, y, held) = what {
                    lane.pointer(.to(x: x, y: y), held: held, n: Int(message["n"].number ?? 0), refused: refused)
                } else {
                    lane.send(what, refused: refused)
                }
                return
            }
        }
        let previous = inputs[id], source = self.source, connection = context.connectionID
        pendingInputs[id, default: 0] += 1
        inputs[id] = Task {
            defer { self.pendingInputs[id, default: 1] -= 1 }
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
        case let .click(button, phase?):
            // A trackpad drag: the button stays down until "up" (let go on any end of the view).
            // (-1, -1): held at the pointer, so it is let go there too.
            if phase == "down" { state.buttons[button] = (-1, -1) } else { state.buttons[button] = nil }
        default:
            return
        }
        held[key] = state.buttons.isEmpty && state.keys.isEmpty ? nil : state
    }

    /// The view of `key` ended: every button and key it still holds is released on this Mac, in order after its input.
    private func releaseHeld(_ key: WatchKey) {
        // The lane goes with the view whether or not anything is held (Reviewer M2: else one lane and its queue stayed
        // behind for every phone connection).
        let lane = lanes.removeValue(forKey: key)
        guard let state = held.removeValue(forKey: key) else { return }
        let releases: [BackendPhoneDeviceInput] = state.buttons.sorted { $0.key < $1.key }.map { button, at in
            at.x < 0 ? .click(button: button, phase: "up") : .mouse(phase: "up", button: button, x: state.at.x, y: state.at.y, clicks: 1)
        }
            + state.keys.sorted().map { .keyCode($0, down: false, modifiers: []) }

        if let lane {
            for release in releases { lane.send(release, refused: { _ in }) }
            return
        }
        let previous = inputs[key.device], source = self.source, id = key.device
        pendingInputs[id, default: 0] += 1
        inputs[id] = Task {
            defer { self.pendingInputs[id, default: 1] -= 1 }
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
        case "pointer":
            // The trackpad model (1 Nov): a share of the display, from where the pointer is.
            guard mac else { throw NativeRPCError.invalidArguments("A pointer is for a Mac's screen.") }
            func delta(_ key: String) -> Double { min(max(message[key].number ?? 0, -1), 1) }
            // Item 60: a phone that draws the pointer sends the place too; that is what counts (no drift).
            if let x = message["x"].number, let y = message["y"].number, x.isFinite, y.isFinite {
                return .pointerTo(x: min(max(x, 0), 1), y: min(max(y, 0), 1), held: message["held"].bool == true)
            }
            return .pointer(dx: delta("dx"), dy: delta("dy"), held: message["held"].bool == true)
        case "click":
            guard mac else { throw NativeRPCError.invalidArguments("A click at the pointer is for a Mac's screen.") }
            guard let button = message["button"].string, Self.mouseButtons.contains(button) else { throw NativeRPCError.invalidArguments("A click is left, right or middle.") }
            let phase = message["phase"].string
            guard phase == nil || phase == "down" || phase == "up" else { throw NativeRPCError.invalidArguments("A click is pressed, let go, or both.") }
            return .click(button: button, phase: phase)
        case "wheel":
            guard mac else { throw NativeRPCError.invalidArguments("A wheel is for a Mac's screen.") }
            func delta(_ key: String) -> Double { min(max(message[key].number ?? 0, -1), 1) }
            return .wheel(dx: delta("dx"), dy: delta("dy"))
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
                                 // The key bar's Fn page (1 Nov).
                                 + (1...12).map { "f\($0)" }

    // MARK: This Mac's pointer and input (round 3)

    /// The lane of one phone's input to this Mac (made on first use; nil without the direct way).
    private func lane(_ key: WatchKey) -> BackendMacInputLane? {
        if let lane = lanes[key] { return lane }
        guard let post = source.macPost else { return nil }
        let id = key.device
        let lane = BackendMacInputLane(label: id) { input in post(id, input) }
        lanes[key] = lane
        return lane
    }

    /// Tells a phone that draws the pointer itself where it is: when it moved (by the phone or by the person at the
    /// Mac), at most 60 a second, with the last phone move applied and the pointer's shape when that changed. Nothing is
    /// sent while it stays put.
    private func reportPointer(_ key: WatchKey) -> Task<Void, Never>? {
        guard let read = source.pointer else { return nil }
        let lane = self.lane(key), send = source.send, id = key.device, connection = key.connection
        return Task.detached(priority: .high) {
            var last: (x: Double, y: Double, n: Int, on: Bool)?
            var shape = -1
            while !Task.isCancelled {
                if let now = read(id) {
                    let n = lane?.applied ?? 0
                    let changed = last.map { $0.x != now.x || $0.y != now.y || $0.n != n || $0.on != now.onDisplay } ?? true
                    let newShape = now.shape.map { $0.token != shape } ?? false
                    if changed || newShape {
                        func unit(_ value: Double) -> NativeRPCValue { .number((min(max(value, 0), 1) * 100_000).rounded() / 100_000) }
                        var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("x", unit(now.x)), .init("y", unit(now.y)),
                                                              .init("n", .number(Double(n)))]
                        if !now.onDisplay { fields.append(.init("off", .bool(true))) }
                        if now.displayWidth > 0 { fields.append(.init("pw", .number(now.displayWidth.rounded()))) }
                        if newShape, let picture = now.shape {
                            shape = picture.token
                            fields += [.init("img", .string(picture.png.base64EncodedString())), .init("hx", unit(picture.hotX)), .init("hy", unit(picture.hotY)),
                                       .init("cw", unit(picture.width)), .init("ch", unit(picture.height))]
                        }
                        if let message = try? BackendRemoteServerMessage(.simsPointer, fields: fields) { try? await send(connection, message) }
                        last = (now.x, now.y, n, now.onDisplay)
                    }
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// A simulator or emulator a phone opened: its elements are read once ahead (the first read builds the element
    /// reader and can take long), so Annotate's Pick has them at once (round 3, #26).
    private func warm(_ id: String) {
        guard warmed.insert(id).inserted else { return }
        let inspect = source.inspect
        Task.detached(priority: .utility) { _ = await inspect(id) }
    }

    // MARK: Record (round 3, #26)

    func record(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws {
        let rid = try message["rid"].requireString("request", nonempty: true), id = try deviceID(message["id"])
        let step = message["do"].string ?? ""
        guard !Self.isMac(id) else { throw NativeRPCError.invalidArguments("Recording is for a simulator or emulator.") }
        guard let record = source.record else { throw NativeRPCError(code: "unavailable", message: "This Mac cannot record a device for the phone.") }
        let key = WatchKey(connection: context.connectionID, device: id)
        guard watches[key] != nil else { throw NativeRPCError(code: "unavailable", message: "Open the device first.") }
        let rows = await source.list()["devices"].elements ?? []
        let row = rows.first { $0["id"].string == id }
        let to = message["to"].string ?? "hoot"
        if step == "stop", to != "hoot" {
            guard try await source.visibleSessions(context).contains(to) else {
                throw NativeRPCError(code: "unknown-session", message: "That chat is no longer open on this Mac. Choose another.")
            }
        }
        let request = BackendPhoneDeviceRecordStep(step: step, deviceID: id, deviceName: row?["name"].string ?? "", platform: row?["platform"].string ?? "ios",
                                                   kind: row?["kind"].string ?? "simulator", note: (message["note"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), to: to)
        let source = self.source, connection = context.connectionID
        switch step {
        case "start":
            _ = try await record(request)
            watches[key]?.recording = true
            try? await source.send(connection, try .init(.simsRecording, fields: [.init("rid", .string(rid)), .init("id", .string(id)), .init("state", .string("recording"))]))
        case "cancel":
            watches[key]?.recording = false
            _ = try? await record(request)
            try? await source.send(connection, try .init(.simsRecording, fields: [.init("rid", .string(rid)), .init("id", .string(id)), .init("state", .string("idle"))]))
        default:
            watches[key]?.recording = false
            // Stopping and sending takes a few seconds (the recorder finishes the file, a preview is made): answered later.
            Task {
                do {
                    let said = try await record(request)
                    try await source.send(connection, try .init(.simsSent, fields: [.init("rid", .string(rid)), .init("ok", .bool(true)), .init("message", .string(said))]))
                } catch {
                    let words = (error as? NativeRPCError)?.message ?? error.localizedDescription
                    try? await source.send(connection, try .init(.simsSent, fields: [.init("rid", .string(rid)), .init("ok", .bool(false)),
                        .init("message", .string(String(words.prefix(400))))]))
                }
            }
        }
    }

    /// The phone went away while recording: the recording is thrown away.
    private func discardRecording(_ key: WatchKey, _ watch: Watch) {
        guard let record = source.record else { return }
        let request = BackendPhoneDeviceRecordStep(step: "cancel", deviceID: key.device, deviceName: watch.deviceName, platform: "", kind: "", note: "", to: "hoot")
        Task { _ = try? await record(request) }
    }

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

    /// Keeps what Pick offers on a still and makes its `sims.elements` frame.
    func inspected(rid: String, id: String, token: String, _ inspection: BackendPhoneDeviceInspection) -> BackendRemoteServerMessage? {
        guard stills[token] != nil else { return nil }
        let kept = BackendPhoneDeviceInspection(elements: Array(inspection.elements.prefix(Self.mostElements)), app: inspection.app,
                                                screen: inspection.screen, note: inspection.note)
        stills[token]?.inspection = kept
        return try? .init(.simsElements, fields: [.init("rid", .string(rid)), .init("id", .string(id)), .init("shot", .string(token)),
            .init("elements", .array(kept.elements.map(\.wire))), .init("app", .string(String(kept.app.prefix(200)))),
            .init("screen", .string(String(kept.screen.prefix(200)))), .init("note", .string(String(kept.note.prefix(400))))])
    }

    /// What Pick offers from a device's element tree: the named or actionable elements a person points at, in
    /// reading order, inside the screen and smaller than it (the window and the app itself are not picks).
    public static func elements(from root: DeviceNode) -> [BackendPhoneDeviceElement] {
        var out: [BackendPhoneDeviceElement] = []
        var seen = Set<String>()
        for node in DeviceTreeQuery.flatten(root) {
            guard out.count < mostElements, node.hidden != true, let frame = node.usableFrame, !frame.isOffScreen else { continue }
            let x = max(0, frame.x), y = max(0, frame.y)
            let width = min(1, frame.x + frame.width) - x, height = min(1, frame.y + frame.height) - y
            guard width > 0.004, height > 0.002, width * height < 0.9 else { continue }
            let role = node.role ?? ""
            guard !["AXApplication", "AXWindow"].contains(role) else { continue }
            let name = DeviceTreeQuery.nodeName(node)
            let identifier = [node.identifier, node.testID].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            guard !name.isEmpty || !identifier.isEmpty || BackendDeckToolsMachinesDeviceRules.isActionable(node) else { continue }
            let key = "\(name)|\(identifier)|\(Int(x * 1000)),\(Int(y * 1000)),\(Int(width * 1000)),\(Int(height * 1000))"
            guard seen.insert(key).inserted else { continue }
            out.append(.init(role: DeviceTreeQuery.plainRole(role), name: name, identifier: identifier == name ? "" : identifier,
                             component: node.component ?? "", x: x, y: y, width: width, height: height))
        }
        return out
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
        // The picked elements, by their place in the still's list, in the order picked (#1 first).
        var picks: [BackendPhoneDeviceElement] = []
        for index in (message["picks"].elements ?? []).compactMap(\.number).map(Int.init) where picks.count < Self.mostPicks {
            guard still.inspection.elements.indices.contains(index) else {
                throw NativeRPCError(code: "unavailable", message: "Those elements are no longer on this Mac. Take the screenshot again.")
            }
            picks.append(still.inspection.elements[index])
        }
        let rows = Self.isMac(id) ? await source.macRows() : (await source.list()["devices"].elements ?? [])
        let row = rows.first { $0["id"].string == id }
        let source = self.source, connection = context.connectionID
        Task {
            do {
                guard let png = Self.drawn(still.png, marks: marks) else { throw NativeRPCError(code: "unavailable", message: "The marks could not be drawn.") }
                let said = try await source.deliver(.init(deviceID: id, deviceName: row?["name"].string ?? "", platform: row?["platform"].string ?? "ios",
                    kind: row?["kind"].string ?? "simulator", png: png, width: still.width, height: still.height, note: note, to: to,
                    picks: picks, app: still.inspection.app, screen: still.inspection.screen))
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
/// failed): a new picture for the video encoder when the screen changed, at most every `interval`.
public actor BackendPhoneDeviceStillStream: BackendPhoneDeviceStream {
    private let capture: @Sendable () async throws -> Data
    private let interval: UInt64
    private var last = Data()
    private var stopped = false
    private var why = ""

    public init(interval milliseconds: Int = 200, capture: @escaping @Sendable () async throws -> Data) {
        self.capture = capture; interval = UInt64(milliseconds) * 1_000_000
    }

    /// The screenshot as raw pixels for the video encoder, when the screen changed (a still device sends nothing new).
    public func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        let deadline = Date().addingTimeInterval(seconds)
        var failures = 0
        while !stopped, !Task.isCancelled {
            do {
                let data = try await capture()
                failures = 0
                if data != last, let image = BackendPhoneDevices.image(data), let buffer = BackendPhoneDeviceStillStream.buffer(image) {
                    last = data
                    return .pixels(BackendPhoneDevicePixels(buffer, capturedAt: Date().timeIntervalSince1970 * 1_000))
                }
            } catch {
                failures += 1
                if failures >= 3 { why = (error as? BackendAppSessionError)?.localizedDescription ?? error.localizedDescription; stopped = true; return .ended }
            }
            if Date() >= deadline { return .unchanged }
            try? await Task.sleep(nanoseconds: min(interval, UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000) + 1))
        }
        return .ended
    }

    /// A picture drawn into a new even-sized BGRA pixel buffer (VideoToolbox's input).
    static func buffer(_ image: CGImage) -> CVPixelBuffer? {
        let width = image.width / 2 * 2, height = image.height / 2 * 2
        guard width >= 2, height >= 2 else { return nil }
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
              let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(made), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(made), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return made
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
        /// The feature goes, and every watch with it (a watch left behind kept encoding for nobody).
        public func stop() async { await lease.cancelAndWait(); await devices.stopAll() }
    }

    /// Puts `sims` on the endpoint (before any phone connects); keep what this returns.
    public static func install(on endpoint: BackendRemoteHost, source: Source, ownerID: String = "native.phone-devices") async throws -> Installation {
        let devices = BackendPhoneDevices(source: source)
        let lease = try await endpoint.installFeatures(ownerID: ownerID, features: [await devices.feature()] + (source.record == nil ? [] : [await devices.recordFeature()])
                                                           + (source.touch == nil ? [] : [await devices.touchFeature()]),
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
            guard MacDisplaySelection.isValidID(id) || id.range(of: #"^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$"#, options: .regularExpression) != nil else { throw r.bad("\(r.type) with an unusable device") }
            return id
        }
        func rid() throws -> String { try r.id("rid", reason: "\(r.type) without a request id") }
        func unit(_ key: String) throws -> NativeRPCValue { .number(min(max(try r.finite(key, reason: "\(r.type) with an unusable \(key)"), 0), 1)) }
        var m = r.base
        switch r.type {
        case "sims.unlock":
            let id = try device()
            guard id.hasPrefix("mac:") else { throw r.bad("Sign-in needs a Mac display") }
            return m.setting("rid", .string(try rid())).setting("id", .string(id))
                .setting("password", .string(try r.text("password", reason: "Sign-in needs a password", units: 2_000, oversize: "The password is too long")))
        case "sims.list": return m.setting("rid", .string(try rid()))
        case "sims.power":
            return m.setting("rid", .string(try rid())).setting("id", .string(try device())).setting("on", .bool(try r.boolean("on", reason: "sims.power without on")))
        case "sims.watch":
            m = m.setting("id", .string(try device()))
                .setting("maxWidth", .number(min(2560, max(160, floor(try r.finite("maxWidth", reason: "sims.watch without a width") + 0.5)))))
                .setting("quality", .number(min(90, max(10, floor(try r.finite("quality", reason: "sims.watch without a quality") + 0.5)))))
            // At most 60 a second (the phone asks 30 for this Mac). 9 Nov: a simulator or emulator too (it was at most 24,
            // Reviewer 31 Oct, from the JPEG pictures' time; it is hardware H.264 paced by the link now, like this Mac).
            try r.optional("fps", into: &m) { .number(min(Double(BackendPhoneDevices.mostPace), max(1, floor(try r.finite("fps", reason: "sims.watch with an unusable fps"))))) }
            // Round 3: this phone draws the Mac's pointer itself.
            try r.optional("cursor", into: &m) { .bool(try r.boolean("cursor", reason: "sims.watch with an unusable cursor")) }
            // Item 61: the video codecs this phone plays ("h264").
            if r["video"] != .missing {
                guard let codecs = r["video"].elements, codecs.count <= 4, codecs.allSatisfy({ ($0.string?.count ?? 99) <= 16 }) else { throw r.bad("sims.watch with unusable video codecs") }
                m = m.setting("video", .array(codecs))
            }
            try r.optional("rid", into: &m) { .string(try rid()) }
            return m
        case "sims.unwatch": return m.setting("id", .string(try device()))
        case "sims.key": return m.setting("id", .string(try device()))   // stream step 2: a keyframe, please
        case "sims.ack":
            return m.setting("id", .string(try device())).setting("seq", .number(try r.whole("seq", 0, Double(Int32.max), reason: "sims.ack without a sequence number")))
        case "sims.touch":
            m = m.setting("id", .string(try device()))
                .setting("phase", .string(try r.named("phase", allowed: BackendPhoneDevices.touchPhases, reason: "sims.touch without a usable phase")))
                .setting("x", try unit("x")).setting("y", try unit("y"))
            try r.optional("n", into: &m) { .number(try r.whole("n", 0, Double(Int32.max), reason: "sims.touch with an unusable number")) }
            return m
        case "sims.input":
            m = m.setting("id", .string(try device())).setting("do", .string(try r.named("do", allowed: ["tap", "swipe", "type", "key", "button", "rotate", "scroll", "mouse", "keycode", "pointer", "click", "wheel"], reason: "sims.input without a usable kind")))
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
            case "pointer", "wheel":
                for key in ["dx", "dy"] { m = m.setting(key, .number(min(max(try r.finite(key, reason: "sims.input \(r["do"].string ?? "") without \(key)"), -1), 1))) }
                try r.optional("held", into: &m) { .bool(try r.boolean("held", reason: "sims.input pointer with an unusable held")) }
                // Round 3: the move's number (the Mac reports the last one applied in `sims.pointer`).
                try r.optional("n", into: &m) { .number(try r.whole("n", 0, Double(Int32.max), reason: "sims.input pointer with an unusable number")) }
                // Item 60: the place the phone draws the pointer, 0…1 (a pointer move only).
                if r["do"].string == "pointer" {
                    try r.optional("x", into: &m) { try unit("x") }
                    try r.optional("y", into: &m) { try unit("y") }
                }
            case "click":
                m = m.setting("button", .string(try r.named("button", allowed: BackendPhoneDevices.mouseButtons, reason: "sims.input click without a usable button")))
                try r.optional("phase", into: &m) { .string(try r.named("phase", allowed: ["down", "up"], reason: "sims.input click with an unusable phase")) }
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
        case "sims.record":
            let step = try r.named("do", allowed: ["start", "stop", "cancel"], reason: "sims.record without a usable step")
            m = m.setting("rid", .string(try rid())).setting("id", .string(try device())).setting("do", .string(step))
            if step == "stop" {
                let to = try r.text("to", reason: "sims.record without a destination", bytes: 128)
                guard to == "hoot" || to.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil else { throw r.bad("sims.record with an unusable destination") }
                let note = r["note"] == .missing ? "" : try r.text("note", reason: "sims.record with an unusable note", allowEmpty: true, units: 4_000, oversize: "sims.record note larger than 4000 characters")
                m = m.setting("to", .string(to)).setting("note", .string(note))
            }
            return m
        case "sims.shot":
            m = m.setting("rid", .string(try rid())).setting("id", .string(try device()))
            try r.optional("inspect", into: &m) { .bool(try r.boolean("inspect", reason: "sims.shot with an unusable inspect")) }
            return m
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
            m = m.setting("rid", .string(try rid())).setting("id", .string(try device())).setting("shot", .string(shot))
                .setting("to", .string(to)).setting("note", .string(note)).setting("marks", .array(marks))
            if r["picks"] != .missing {
                guard let picks = r["picks"].elements, picks.count <= BackendPhoneDevices.mostPicks,
                      picks.allSatisfy({ ($0.number).map { $0.rounded() == $0 && $0 >= 0 && $0 < Double(BackendPhoneDevices.mostElements) } == true }),
                      Set(picks.compactMap(\.number)).count == picks.count else { throw r.bad("sims.annotate with unusable picks") }
                m = m.setting("picks", .array(picks))
            }
            return m
        default:
            return nil
        }
    }
}


/// This Mac's pointer for a phone that draws it itself (round 3, `sims.pointer`): where it is on one display (0…1),
/// whether it is on that display at all, and its shape (PNG; hot spot as a share of the picture; size as a share of the
/// display). `token` changes when the shape does.
public struct BackendPhoneDevicePointer: Sendable, Equatable {
    public struct Shape: Sendable, Equatable {
        public let token: Int
        public let png: Data
        public let hotX: Double, hotY: Double, width: Double, height: Double
        public init(token: Int, png: Data, hotX: Double, hotY: Double, width: Double, height: Double) {
            self.token = token; self.png = png; self.hotX = hotX; self.hotY = hotY; self.width = width; self.height = height
        }
    }
    public let x: Double
    public let y: Double
    public let onDisplay: Bool
    public let shape: Shape?
    /// The display's width in points (item 60: the phone measures "a few points" of disagreement in the Mac's points).
    public var displayWidth: Double = 0
    public init(x: Double, y: Double, onDisplay: Bool, shape: Shape?, displayWidth: Double = 0) {
        self.x = x; self.y = y; self.onDisplay = onDisplay; self.shape = shape; self.displayWidth = displayWidth
    }
}

/// One step of a phone's recording of a simulator or emulator (round 3, #26).
public struct BackendPhoneDeviceRecordStep: Sendable, Equatable {
    public let step: String
    public let deviceID: String
    public let deviceName: String
    public let platform: String
    public let kind: String
    public let note: String
    public let to: String
}

/// One phone's input to this Mac (round 3, 1 Nov; Asad: "moving the finger moves the Mac cursor with a delay… the cursor
/// starts the instant the finger starts, stops the instant it lifts"): every input is applied on its own high-priority
/// serial queue the moment it arrives, in the order it came, with no answer awaited. Pointer moves that arrive while one
/// is being applied are added together and applied as one (never a backlog to catch up on). `applied` is the newest
/// numbered move applied, which `sims.pointer` reports so the phone can draw the pointer ahead of the picture.
final class BackendMacInputLane: @unchecked Sendable {
    /// A pointer move: by a share of the display (older phones; moves waiting add up) or to a place (the newest wins).
    enum Move: Equatable { case by(dx: Double, dy: Double), to(x: Double, y: Double) }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let post: @Sendable (BackendPhoneDeviceInput) -> String?
    private var pending: (move: Move, held: Bool)?
    private var pendingN = 0
    private var scheduled = false
    /// A flush queued before a click must not take the moves that came after that click.
    private var epoch = 0
    private var appliedN = 0
    private var queuedBlocks = 0
    var isIdle: Bool { lock.withLock { queuedBlocks == 0 } }

    init(label: String, post: @escaping @Sendable (BackendPhoneDeviceInput) -> String?) {
        queue = DispatchQueue(label: "dev.terminaldeck.mac-input." + label, qos: .userInteractive)
        self.post = post
    }

    var applied: Int { lock.withLock { appliedN } }

    func pointer(_ move: Move, held: Bool, n: Int, refused: @escaping @Sendable (String) -> Void) {
        let schedule = lock.withLock { () -> Int? in
            switch (pending?.move, move) {
            case let (.by(ax, ay)?, .by(bx, by)): pending = (.by(dx: ax + bx, dy: ay + by), held)
            default: pending = (move, held)   // a place replaces whatever waited (it already includes it)
            }
            pendingN = max(pendingN, n)
            guard !scheduled else { return nil }
            scheduled = true
            queuedBlocks += 1
            return epoch
        }
        if let schedule { queue.async {
            defer { self.lock.withLock { self.queuedBlocks -= 1 } }
            self.flushPointer(schedule, refused)
        } }
    }

    /// Older callers (tests): a move by a share of the display.
    func pointer(dx: Double, dy: Double, held: Bool, n: Int, refused: @escaping @Sendable (String) -> Void) {
        pointer(.by(dx: dx, dy: dy), held: held, n: n, refused: refused)
    }

    func send(_ input: BackendPhoneDeviceInput, refused: @escaping @Sendable (String) -> Void) {
        // A click or a key lands where the pointer is after every move sent BEFORE it — and before none sent after it
        // (Reviewer M1: the moves waiting are taken now, when the click is queued, not when its block runs).
        let (move, n) = lock.withLock { () -> ((move: Move, held: Bool)?, Int) in
            defer { pending = nil; scheduled = false; epoch += 1 }
            queuedBlocks += 1
            return (pending, pendingN)
        }
        queue.async {
            defer { self.lock.withLock { self.queuedBlocks -= 1 } }
            if let move { self.apply(move, n: n, refused) }
            if let words = self.post(input) { refused(words) }
        }
    }

    private func flushPointer(_ queued: Int, _ refused: @Sendable (String) -> Void) {
        let (move, n) = lock.withLock { () -> ((move: Move, held: Bool)?, Int) in
            guard queued == epoch else { return (nil, 0) }
            defer { pending = nil; scheduled = false }
            return (pending, pendingN)
        }
        guard let move else { return }
        apply(move, n: n, refused)
    }

    private func apply(_ move: (move: Move, held: Bool), n: Int, _ refused: @Sendable (String) -> Void) {
        let input: BackendPhoneDeviceInput
        switch move.move {
        case let .by(dx, dy): input = .pointer(dx: min(max(dx, -1), 1), dy: min(max(dy, -1), 1), held: move.held)
        case let .to(x, y): input = .pointerTo(x: x, y: y, held: move.held)
        }
        if let words = post(input) { refused(words) }
        lock.withLock { appliedN = max(appliedN, n) }
    }
}
