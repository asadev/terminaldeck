import Foundation
import TerminalDeckNativeCore

public struct BackendWebKitProfileArmingWatchGrant: Sendable {
    public let ownDevice: Bool
    public let canInput: Bool
    public let baton: BackendWebKitProfileArmingBaton
    /// The live authenticated caller holder, not a name received in arguments.
    public let humanHolder: String?
    public init(ownDevice: Bool, canInput: Bool, baton: BackendWebKitProfileArmingBaton, humanHolder: String?) {
        self.ownDevice = ownDevice; self.canInput = canInput; self.baton = baton; self.humanHolder = humanHolder
    }
}

/// Pixel privacy is established by the runtime BEFORE JPEG bytes are returned.
/// Unreadable child frames count as private. Guest frames may only be secretFree
/// or fully withheld; owner pixels are accepted only for a current own-device.
public struct BackendWebKitProfileArmingWatchFrame: Sendable {
    public enum Privacy: String, Sendable { case secretFree, masked, owner }
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let pageScale: Double
    public let scrollX: Double
    public let scrollY: Double
    public let privacy: Privacy
    public let prompt: String
    public init(jpeg: Data, width: Int, height: Int, viewportWidth: Double, viewportHeight: Double,
                pageScale: Double, scrollX: Double, scrollY: Double, privacy: Privacy, prompt: String = "") throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              [viewportWidth, viewportHeight, pageScale, scrollX, scrollY].allSatisfy(\.isFinite),
              viewportWidth > 0, viewportHeight > 0, pageScale > 0,
              jpeg.count <= 67 * 1024,
              (privacy == .masked ? jpeg.isEmpty : jpeg.starts(with: [0xff, 0xd8])) else {
            throw NativeRPCError.invalidArguments("A watch frame needs measured finite geometry and a bounded real JPEG, or no pixels when masked.")
        }
        self.jpeg = jpeg; self.width = width; self.height = height; self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.pageScale = pageScale; self.scrollX = scrollX; self.scrollY = scrollY; self.privacy = privacy; self.prompt = String(prompt.prefix(512))
    }
    func wire(window: String, sequence: Int) -> NativeRPCValue {
        var value = NativeRPCValue.object([
            .init("t", .string("browser.frame")), .init("window", .string(window)), .init("seq", .number(Double(sequence))),
            .init("w", .number(Double(width))), .init("h", .number(Double(height))),
            .init("dw", .number(viewportWidth)), .init("dh", .number(viewportHeight)), .init("scale", .number(Double(width) / viewportWidth)),
            .init("offsetTop", .number(0)), .init("pageScale", .number(pageScale)), .init("scrollX", .number(scrollX)), .init("scrollY", .number(scrollY)),
            .init("data", .string(jpeg.base64EncodedString()))
        ])
        if privacy == .masked { value = value.setting("masked", .bool(true)).setting("prompt", .string(prompt)) }
        return value
    }
}

public struct BackendWebKitProfileArmingWatchHooks: Sendable {
    /// Throw unless this connection still has exact window/profile/origin grants.
    public let grant: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> BackendWebKitProfileArmingWatchGrant
    public let snapshot: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, Bool, Int, Int) async throws -> BackendWebKitProfileArmingWatchFrame
    /// The input is already mapped using host-held frame geometry. Preserve the
    /// actual browser driver's tier/consent/log/baton checks in this dispatcher.
    public let input: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, NativeRPCValue, Bool) async throws -> NativeRPCValue
    public let take: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> Void
    public let untake: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> Void
    public init(grant: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> BackendWebKitProfileArmingWatchGrant,
                snapshot: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, Bool, Int, Int) async throws -> BackendWebKitProfileArmingWatchFrame,
                input: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, NativeRPCValue, Bool) async throws -> NativeRPCValue,
                take: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> Void,
                untake: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> Void) {
        self.grant = grant; self.snapshot = snapshot; self.input = input; self.take = take; self.untake = untake
    }
}

/// Event-driven snapshot watch, not a fabricated CDP screencast. One JPEG in
/// flight per watcher; invalidation replaces a dirty bit, never queues images.
/// ACK is the only way another image is sent while a watcher holds one.
public actor BackendWebKitProfileArmingWatch {
    public struct Token: Sendable { fileprivate let id: UUID }
    private struct Viewer: Sendable {
        let caller: BackendBrowserScrapingCaller
        let window: String
        let width: Int
        var quality: Int
        let emit: @Sendable (NativeRPCValue) async throws -> Void
        var sequence = 0
        var inFlight: Int?
        var rendering = false
        var dirty = true
        var history: [(sequence: Int, frame: BackendWebKitProfileArmingWatchFrame)] = []
    }
    private var target: BackendBrowserCaptureTarget
    private let hooks: BackendWebKitProfileArmingWatchHooks
    private var viewers: [UUID: Viewer] = [:]
    private var epoch = 0
    private var curtained = false
    private var prompt = "The person has this page right now."
    private var disposed = false
    public init(target: BackendBrowserCaptureTarget, hooks: BackendWebKitProfileArmingWatchHooks) { self.target = target; self.hooks = hooks }

    public func watch(caller: BackendBrowserScrapingCaller, window: String, maxWidth: Int, quality: Int,
                      emit: @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> Token {
        guard !disposed, viewers.count < 64 else { throw NativeRPCError(code: "watch-limit", message: "This WebKit page is closed or already has 64 watchers.") }
        _ = try await hooks.grant(caller, target)
        let token = Token(id: UUID())
        viewers[token.id] = Viewer(caller: caller, window: window, width: min(1920, max(64, maxWidth)), quality: min(100, max(1, quality)), emit: emit)
        try await render(token.id)
        return token
    }
    public func unwatch(_ token: Token, caller: BackendBrowserScrapingCaller) async throws {
        let viewer = try owned(token, caller)
        // Untake is an idempotent holder-scoped cleanup operation; revocation
        // cannot leave a disconnected human holder on the page.
        try await hooks.untake(viewer.caller, target)
        viewers[token.id] = nil
    }
    /// The runtime calls this for authorized navigation/scroll/resize/input/DOM
    /// events. It starts no timer or display link, and idle pages cost nothing.
    public func invalidate(target next: BackendBrowserCaptureTarget? = nil) async {
        guard !disposed else { return }
        if let next {
            guard next.tabID == target.tabID, next.profileID == target.profileID else { return }
            target = next
        }
        epoch += 1
        let ids = Array(viewers.keys)
        for id in ids { viewers[id]?.dirty = true }
        for id in ids where viewers[id]?.inFlight == nil && viewers[id]?.rendering == false { try? await render(id) }
    }
    public func acknowledge(_ token: Token, caller: BackendBrowserScrapingCaller, sequence: Int) async throws {
        let viewer = try owned(token, caller)
        guard viewer.inFlight == sequence else { return }
        _ = try await hooks.grant(viewer.caller, target)
        viewers[token.id]?.inFlight = nil
        if viewers[token.id]?.dirty == true { try await render(token.id) }
    }
    /// Call before the actual baton flips. The tiny lock frame supersedes the
    /// outstanding ordinary frame; no further sensitive JPEG can be emitted.
    public func curtain(_ text: String) async {
        curtained = true; prompt = String(text.prefix(512)); epoch += 1
        for id in Array(viewers.keys) {
            guard let viewer = viewers[id] else { continue }
            do {
                let grant = try await hooks.grant(viewer.caller, target)
                if grant.baton == .human, grant.humanHolder == viewer.caller.holder { continue }
                viewers[id]?.rendering = false; viewers[id]?.dirty = false
                try await emitMasked(id, message: prompt)
            } catch { viewers[id] = nil }
        }
    }
    public func uncurtain() async { curtained = false; await invalidate() }
    public func take(_ token: Token, caller: BackendBrowserScrapingCaller) async throws {
        let viewer = try owned(token, caller)
        let grant = try await hooks.grant(viewer.caller, target)
        guard grant.baton == .human, grant.canInput else { throw BackendBrowserScrapingError.denied("There is no permitted human handover to take.") }
        try await hooks.take(viewer.caller, target)
        let after = try await hooks.grant(viewer.caller, target)
        guard after.baton == .human, after.humanHolder == viewer.caller.holder else {
            throw BackendBrowserScrapingError.denied("The live browser handover was not assigned to this watcher.")
        }
        viewers[token.id]?.inFlight = nil; viewers[token.id]?.dirty = true
        try await render(token.id)
    }
    public func untake(_ token: Token, caller: BackendBrowserScrapingCaller) async throws {
        let viewer = try owned(token, caller)
        try await hooks.untake(viewer.caller, target)
        try await emitMasked(token.id, message: prompt)
    }
    public func input(_ token: Token, caller: BackendBrowserScrapingCaller, sequence: Int, value: NativeRPCValue) async throws -> NativeRPCValue {
        let viewer = try owned(token, caller)
        let grant = try await hooks.grant(viewer.caller, target)
        let person = grant.baton == .human && grant.humanHolder == viewer.caller.holder
        guard grant.canInput, (!curtained && grant.baton != .human) || person else { throw BackendBrowserScrapingError.denied("The person has this page right now.") }
        guard let frame = viewer.history.first(where: { $0.sequence == sequence })?.frame, frame.privacy != .masked else {
            throw BackendBrowserScrapingError.denied("This input names an unavailable or hidden frame. Wait for the current visible frame.")
        }
        guard frame.privacy != .owner || grant.ownDevice else { throw BackendBrowserScrapingError.denied("This connection no longer owns the private frame it named.") }
        let mapped = try mapInput(value, frame: frame)
        let result = try await hooks.input(viewer.caller, target, mapped, person)
        await invalidate(); return result
    }
    public func dispose() async {
        disposed = true; epoch += 1
        let old = Array(viewers.values); viewers.removeAll()
        for viewer in old { try? await hooks.untake(viewer.caller, target) }
    }
    private func owned(_ token: Token, _ caller: BackendBrowserScrapingCaller) throws -> Viewer {
        guard !disposed, let viewer = viewers[token.id], viewer.caller.holder == caller.holder, viewer.caller.ownerID == caller.ownerID else {
            throw BackendBrowserScrapingError.denied("This connection does not own that watch token.")
        }; return viewer
    }
    private func render(_ id: UUID) async throws {
        guard let viewer = viewers[id], !viewer.rendering, viewer.inFlight == nil, !disposed else { return }
        viewers[id]?.rendering = true; viewers[id]?.dirty = false
        let generation = epoch, page = target
        defer {
            if viewers[id] != nil {
                viewers[id]?.rendering = false
                if viewers[id]?.dirty == true, viewers[id]?.inFlight == nil {
                    Task { try? await self.render(id) }
                }
            }
        }
        do {
            let grant = try await hooks.grant(viewer.caller, page)
            let person = grant.baton == .human && grant.humanHolder == viewer.caller.holder
            if (curtained || grant.baton == .human) && !person { try await emitMasked(id, message: prompt); return }
            let frame = try await hooks.snapshot(viewer.caller, page, grant.ownDevice, viewer.width, viewer.quality)
            let current = try await hooks.grant(viewer.caller, page)
            guard generation == epoch, viewers[id] != nil, !disposed else { viewers[id]?.dirty = true; return }
            guard current.ownDevice == grant.ownDevice, current.baton == grant.baton, current.humanHolder == grant.humanHolder else {
                viewers[id]?.dirty = true; throw BackendBrowserScrapingError.denied("This watcher's device or browser baton grant changed during capture.")
            }
            guard frame.privacy != .owner || current.ownDevice else { throw BackendBrowserScrapingError.denied("Owner-only pixels cannot be sent to a guest watcher.") }
            try await emit(id, frame: frame)
        } catch { viewers[id] = nil; throw error }
    }
    private func emitMasked(_ id: UUID, message: String) async throws {
        let frame = try BackendWebKitProfileArmingWatchFrame(jpeg: Data(), width: 1, height: 1, viewportWidth: 1, viewportHeight: 1,
            pageScale: 1, scrollX: 0, scrollY: 0, privacy: .masked, prompt: message)
        try await emit(id, frame: frame)
    }
    private func emit(_ id: UUID, frame: BackendWebKitProfileArmingWatchFrame) async throws {
        guard var viewer = viewers[id] else { return }
        viewer.sequence += 1; viewer.inFlight = viewer.sequence
        viewer.history.append((viewer.sequence, frame)); viewer.history = Array(viewer.history.suffix(8)); viewers[id] = viewer
        try await viewer.emit(frame.wire(window: viewer.window, sequence: viewer.sequence))
    }
    private func mapInput(_ value: NativeRPCValue, frame: BackendWebKitProfileArmingWatchFrame) throws -> NativeRPCValue {
        _ = try value.requireObject("watch input")
        let choices = ["mouse", "key", "touch", "paste"].filter { value.has($0) }
        guard choices.count == 1, value.fields?.allSatisfy({ choices.contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("An input needs exactly one mouse, key, touch or paste event.") }
        let scale = Double(frame.width) / frame.viewportWidth * frame.pageScale
        func point(_ raw: NativeRPCValue) throws -> NativeRPCValue {
            guard let x = raw["x"].number, let y = raw["y"].number, x >= 0, y >= 0, x <= Double(frame.width), y <= Double(frame.height) else { throw NativeRPCError.invalidArguments("Input coordinates must be finite points inside the host's recorded image.") }
            return raw.setting("x", .number(x / scale)).setting("y", .number(y / scale))
        }
        if value.has("paste") {
            let paste = try value["paste"].requireString("paste")
            guard paste.utf8.count <= 65_536 else { throw NativeRPCError.invalidArguments("Watch paste exceeds 64 KiB.") }; return value
        }
        if value.has("mouse") {
            let mouse = try value["mouse"].requireObject("mouse")
            guard ["down", "up", "move", "wheel"].contains(mouse["type"].string ?? ""),
                  mouse.fields?.allSatisfy({ ["type", "x", "y", "button", "clicks", "dx", "dy"].contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("Unknown mouse input.") }
            for key in ["dx", "dy", "clicks"] where mouse.has(key) {
                guard let number = mouse[key].number, abs(number) <= 100_000 else { throw NativeRPCError.invalidArguments("Mouse deltas/clicks must be bounded finite numbers.") }
            }
            if mouse.has("button"), !["left", "right", "middle", "none"].contains(mouse["button"].string ?? "") { throw NativeRPCError.invalidArguments("Unknown mouse button.") }
            if let clicks = mouse["clicks"].number, clicks < 1 || clicks > 3 || clicks.rounded() != clicks { throw NativeRPCError.invalidArguments("Mouse clicks must be an integer from 1 through 3.") }
            return value.setting("mouse", try point(mouse))
        }
        if value.has("touch") {
            let touch = try value["touch"].requireObject("touch")
            guard ["start", "move", "end", "cancel"].contains(touch["type"].string ?? ""), touch.fields?.allSatisfy({ ["type", "points"].contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("Unknown touch input.") }
            let points = try touch["points"].requireArray("touch points")
            guard points.count <= 10 else { throw NativeRPCError.invalidArguments("At most 10 touch points are supported.") }
            return value.setting("touch", touch.setting("points", .array(try points.map(point))))
        }
        let key = try value["key"].requireObject("key")
        guard ["down", "up", "char"].contains(key["type"].string ?? ""), key.fields?.allSatisfy({ ["type", "key", "code", "text", "mods"].contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("Unknown keyboard input.") }
        for name in ["key", "code", "text"] where key.has(name) { guard let text = key[name].string, text.utf8.count <= 4_096 else { throw NativeRPCError.invalidArguments("A key field must be bounded text.") } }
        if key.has("mods") { guard let mods = key["mods"].number, mods >= 0, mods <= 15, mods.rounded() == mods else { throw NativeRPCError.invalidArguments("Key modifiers must be an integer bitmask from 0 through 15.") } }
        return value
    }
}
