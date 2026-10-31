import Network
import AppKit
import CoreImage
import Foundation
import IOSurface
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Mac's simulators and emulators on a paired phone (Asad, 31 Oct): the remote `sims` capability
/// (`BackendPhoneDevices`) over this Mac's own device engine. The live picture comes from the same direct screen the
/// phone panel shows (the device's own screen buffer, no video encode): each new picture is made small and sent as a
/// JPEG. A device with no direct screen (a cable phone, or when the direct path failed) is shown from screenshots.
/// Input goes the panel's way (the direct helper first, then the device tools' own route); an annotated still is sent
/// to Hoot or a chat the way the Mac's Annotate sends it (`NativeHOOTSIMFeedback`, `NativeCapturedFeedback`).
/// Not fatal: without it the phone simply has no Devices page.
extension NativeCompositionProduction {
    func installPhoneDevices() async {
        guard let endpoint = remoteEndpoint else { report("Phone devices are unavailable: the remote endpoint is not wired."); return }
        guard let installed = devices else { report("Phone devices are unavailable: the device engine is not installed."); return }
        let manager = installed.manager, tools = installed.tools
        let pictures = BackendCompositionDevices.picturesDirectory(home: configuration.homeDirectory.path)
        let source = BackendPhoneDevices.Source(
            list: { await manager.list() },
            power: { id, on in on ? try await manager.boot(id) : try await manager.shutDown(id) },
            stream: { id, row in
                if id.hasPrefix("mac:") { return try await NativeMacScreen.stream(id) }
                if let direct = await NativePhoneDeviceScreens.shared.stream(row) { return direct }
                return BackendPhoneDeviceStillStream { try await manager.capture(id).png }
            },
            input: { id, input in
                if id.hasPrefix("mac:") { try await NativeMacScreen.input(id, input); return }
                if await NativePhoneDeviceScreens.shared.send(id, input) { return }
                switch input {
                case let .tap(x, y, hold): try await tools.tap(id, x: x, y: y, holdMS: hold.map { Int($0) })
                case let .swipe(fromX, fromY, toX, toY, ms):
                    try await tools.swipe(id, from: .object([.init("x", .number(fromX)), .init("y", .number(fromY))]),
                                          to: .object([.init("x", .number(toX)), .init("y", .number(toY))]), durationMS: Int(ms))
                case .type(let text): try await tools.type(id, text: text)
                case .key(let key): try await tools.key(id, key: key, modifiers: [])
                case .button(let button): try await tools.button(id, button: button)
                case .rotate: _ = try await manager.rotate(id)
                case let .secondaryTap(x, y): try await tools.tap(id, x: x, y: y, holdMS: 600)
                case let .shortcut(key, modifiers): try await tools.key(id, key: key, modifiers: modifiers)
                case .scroll: throw NativeRPCError.invalidArguments("Scroll with a swipe on a simulator or emulator.")
                case .mouse, .keyCode: throw NativeRPCError.invalidArguments("That input is for a Mac's screen.")
                }
            },
            shot: { id in id.hasPrefix("mac:") ? try await NativeMacScreen.shot(id) : try await manager.capture(id) },
            deliver: { annotation in try await NativePhoneDeviceAnnotate.deliver(annotation, folder: pictures) },
            visibleSessions: { context in try await endpoint.panelSessionIDs(context) },
            send: { id, message in try await endpoint.sendToConnection(id, message: message) },
            macRows: { await MainActor.run { NativeMacScreen.rows() } },
            phoneName: { [trust = remoteTrust] context in
                let name = await trust?.device(context.deviceID)?.name ?? ""
                return name.isEmpty ? "A phone" : name
            },
            macViewers: { viewers in await MainActor.run { NativeMacScreenIndicator.shared.update(viewers) } })
        let owner = "native.phone-devices"
        do {
            let installation = try await BackendPhoneDevices.install(on: endpoint, source: source, ownerID: owner)
            do {
                try await root.retain(.init(name: "phone-devices", domains: ["phone-devices"], ownerID: owner, invokes: [],
                                            stop: { await installation.stop() }))
                phoneDevices = installation
                // Stop on the Mac's card lets every phone go at once.
                NativeMacScreenIndicator.shared.stop = { Task { await installation.devices.stopMac() } }
            } catch { await installation.stop(); throw error }
            await installPhoneDevicesTool(installation.devices)
        } catch {
            report("Phone devices are unavailable: " + error.localizedDescription)
        }
    }

    /// `devices.phone_watch`: which simulators and emulators a paired phone is watching now, so an AI does not shut
    /// one down under the person's eyes (and knows a person is looking).
    private func installPhoneDevicesTool(_ devices: BackendPhoneDevices) async {
        guard let authority else { return }
        let mcp = root.mcp, id = "devices.phone_watch"
        await installMacScreenTools(devices, authority: authority)
        guard !(await mcp.registrations().contains { $0.0.id == id }) else { return }
        do {
            let spec = try BackendMCPTool(id: id, wireName: "devices_phone_watch",
                description: "Which simulators and emulators a paired phone is watching live from the phone app's Devices page right now (device, phone, pictures a second). Leave those running: a person is looking at them.",
                inputSchema: .object([.init("type", .string("object")), .init("properties", .object([])), .init("additionalProperties", .bool(false))]),
                tier: .read)
            try await mcp.registerTool(spec, ownerID: "native.phone-devices") { caller, _ in
                _ = try await authority.resolve(caller)
                return .value(.object([.init("watching", await devices.watching())]))
            }
        } catch {
            report("The devices.phone_watch tool was not installed: " + error.localizedDescription)
        }
    }
}

/// Sends a phone's annotated still the way the Mac's Annotate does.
@MainActor enum NativePhoneDeviceAnnotate {
    static func deliver(_ annotation: BackendPhoneDeviceAnnotation, folder: URL) async throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = annotation.deviceName.isEmpty ? "device" : annotation.deviceName
        let file = folder.appendingPathComponent(BackendAppDeviceManager.pictureName(name, now: Date()) + "-phone-annotate.png")
        try annotation.png.write(to: file)
        let kind = annotation.platform == "mac" ? "Mac screen" : DeviceEntry.kindWords(platform: annotation.platform, kind: annotation.kind)
        let line = Handoff.composeScreenshot(path: file.path, width: annotation.width, height: annotation.height,
                                             kind: kind, deviceName: annotation.deviceName, instruction: annotation.note)
        let source = NativeRPCValue.object([.init("kind", .string("device")), .init("path", .string(file.path)),
            .init("deviceId", .string(annotation.deviceID)), .init("title", .string(annotation.deviceName)),
            .init("noteCount", .number(annotation.note.isEmpty ? 0 : 1))])
        if annotation.to == "hoot" {
            try await NativeHOOTSIMFeedback.send(line, images: [annotation.png], source: source)
            return "Sent to Hoot."
        }
        try await NativeCapturedFeedback.send(sessionID: annotation.to, text: line, chatText: annotation.note, paths: [file.path],
                                              source: .object([.init("kind", .string("device")), .init("path", .string(file.path))]))
        return "Sent to the chat."
    }
}

/// The direct screens the phone watches: one per device, shared by every phone watching it.
@MainActor final class NativePhoneDeviceScreens {
    static let shared = NativePhoneDeviceScreens()
    /// How long a direct screen may take to show its first picture before screenshots stand in.
    static let firstPictureWithin: Double = 8

    @MainActor final class Screen {
        let id: String
        let source: any DeviceDirectSource
        var surface: IOSurfaceRef?
        var generation = 0
        var ended: String?
        var users = 0
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        init(id: String, source: any DeviceDirectSource) { self.id = id; self.source = source }
        func wakeAll() {
            let waiting = waiters; waiters.removeAll()
            for waiter in waiting.values { waiter.resume() }
        }
    }
    private var screens: [String: Screen] = [:]
    /// Shared and safe across threads (CIContext is).
    nonisolated(unsafe) static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    /// A stream from the device's direct screen, or nil when it has none (the caller uses screenshots).
    func stream(_ row: NativeRPCValue) async -> NativePhoneDirectStream? {
        guard let id = row["id"].string else { return nil }
        if let screen = screens[id], screen.ended == nil {
            screen.users += 1
            return NativePhoneDirectStream(screen: screen, owner: self)
        }
        let details = DeviceDetails(id: id, name: row["name"].string ?? id, platform: row["platform"].string ?? "ios", kind: row["kind"].string ?? "simulator")
        guard let source = DeviceDirect.source(for: details) else { return nil }
        let screen = Screen(id: id, source: source)
        source.onSurface = { [weak screen] surface in
            guard let screen else { return }
            screen.surface = surface; screen.generation += 1; screen.wakeAll()
        }
        source.onFrame = { [weak screen] in
            guard let screen else { return }
            screen.generation += 1; screen.wakeAll()
        }
        source.onEnded = { [weak screen] reason in
            guard let screen else { return }
            NativeCompositionRoot.note("phone devices: \(id) direct screen ended: \(reason)")
            screen.ended = reason.isEmpty ? "The device stopped." : reason; screen.wakeAll()
        }
        screens[id] = screen
        source.start()
        // The first picture, or screenshots stand in.
        let deadline = Date().addingTimeInterval(Self.firstPictureWithin)
        while screen.surface == nil, screen.ended == nil, Date() < deadline {
            await wait(screen, after: screen.generation, within: max(0.05, deadline.timeIntervalSinceNow))
        }
        guard screen.surface != nil, screen.ended == nil else {
            if screens[id] === screen { screens[id] = nil }
            source.stop()
            DeviceDirect.failed(id)
            return nil
        }
        screen.users += 1
        return NativePhoneDirectStream(screen: screen, owner: self)
    }

    /// Waits until the screen draws again (or ends), for at most `seconds`; a cancelled caller stops waiting at once.
    func wait(_ screen: Screen, after generation: Int, within seconds: Double = 2) async {
        guard screen.generation == generation, screen.ended == nil else { return }
        let key = UUID()
        let timer = Task { @MainActor [weak screen] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            screen?.waiters.removeValue(forKey: key)?.resume()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { resume.resume(); return }
                screen.waiters[key] = resume
            }
        } onCancel: {
            Task { @MainActor [weak screen] in screen?.waiters.removeValue(forKey: key)?.resume() }
        }
    }

    func release(_ screen: Screen) {
        screen.users -= 1
        guard screen.users <= 0 else { return }
        screen.wakeAll()
        if screens[screen.id] === screen { screens[screen.id] = nil }
        screen.source.stop()
    }

    /// Input through a watched device's own direct path; false when it cannot take it there.
    nonisolated func send(_ id: String, _ input: BackendPhoneDeviceInput) async -> Bool {
        await MainActor.run {
            guard let screen = screens[id], screen.ended == nil, screen.source.inputReady else { return false }
            switch input {
            case let .tap(x, y, hold): return screen.source.send(.tap(x: x, y: y, holdMs: hold))
            case let .swipe(fromX, fromY, toX, toY, ms): return screen.source.send(.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms))
            case .type(let text): return screen.source.canType && screen.source.send(.type(text))
            case .key, .button, .rotate, .secondaryTap, .scroll, .shortcut, .mouse, .keyCode: return false
            }
        }
    }

    /// The screen surface as a JPEG at most `maxWidth` wide.
    nonisolated static func encode(_ box: DirectSurfaceBox, maxWidth: Int, quality: Int, maxBytes: Int) -> BackendPhoneDeviceFrame? {
        let image = CIImage(ioSurface: box.surface)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, CGFloat(maxWidth) / extent.width)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        guard let picture = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return BackendPhoneDevices.encode(picture, maxWidth: picture.width, quality: quality, maxBytes: maxBytes)
    }
}

/// One phone viewer's pictures from a shared direct screen.
@MainActor final class NativePhoneDirectStream: BackendPhoneDeviceStream {
    private let screen: NativePhoneDeviceScreens.Screen
    private weak var owner: NativePhoneDeviceScreens?
    private var seen = -1
    private var stopped = false

    init(screen: NativePhoneDeviceScreens.Screen, owner: NativePhoneDeviceScreens) { self.screen = screen; self.owner = owner }

    func next(maxWidth: Int, quality: Int, maxBytes: Int) async -> BackendPhoneDeviceFrame? {
        while !stopped, !Task.isCancelled, screen.ended == nil {
            if screen.generation != seen, let surface = screen.surface {
                seen = screen.generation
                let box = DirectSurfaceBox(surface: surface)
                let frame = await Task.detached(priority: .userInitiated) {
                    NativePhoneDeviceScreens.encode(box, maxWidth: maxWidth, quality: quality, maxBytes: maxBytes)
                }.value
                if let frame { return frame }
            }
            guard let owner else { return nil }
            await owner.wait(screen, after: seen)
        }
        return nil
    }

    func endReason() -> String { screen.ended ?? "The device stopped." }

    func stop() {
        guard !stopped else { return }
        stopped = true
        owner?.release(screen)
    }
}

extension NativeCompositionProduction {
    /// This Mac's screen on a phone, for agents: what it is doing and a way to end it. There is deliberately no tool
    /// that starts showing the screen: only the person, from the phone, starts it.
    fileprivate func installMacScreenTools(_ devices: BackendPhoneDevices, authority: BackendCompositionAuthority) async {
        let mcp = root.mcp, joins = self.joins
        let empty = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([])), .init("additionalProperties", .bool(false))])
        let tools: [(String, BackendMCPTier, String)] = [
            ("mac_screen.status", .read, "This Mac's screen on paired phones and other Macs: whether Terminal Deck has the Screen Recording and Accessibility permissions, the displays, which phones or Macs are watching or controlling this Mac now, and which other Macs this Mac is showing (remote). Read only."),
            ("mac_screen.stop", .act, "Stop every phone or Mac watching or controlling this Mac's screen (as the Stop on the Mac's card does) and close every window here showing another Mac's screen. Nothing can start a screen session except the person, from a phone or from Devices › Other Macs."),
        ]
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description) in tools where !taken.contains(id) {
            do {
                let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: empty, tier: tier)
                try await mcp.registerTool(spec, ownerID: "native.phone-devices") { caller, _ in
                    guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                    _ = try await authority.resolve(caller)
                    if id == "mac_screen.stop" {
                        try await joins.prepareNative(caller, tier: tier, sentence: "Stop the phones and Macs watching this Mac's screen, and close the windows here showing other Macs' screens", ownerMustAnswer: false)
                        let before = await devices.macViewers().count
                        await devices.stopMac(why: "An agent stopped sharing this Mac's screen.")
                        let remote = await BackendRemoteMacScreens.shared.closeAll()
                        await MainActor.run { NativeRemoteMacs.shared.closeAll() }
                        return .value(.object([.init("stopped", .number(Double(before))), .init("remoteClosed", .number(Double(remote)))]))
                    }
                    let viewers = await devices.macViewers()
                    let (rows, record, control) = await MainActor.run { (NativeMacScreen.rows(), NativeMacScreen.canRecord, NativeMacScreen.canControl) }
                    return .value(.object([
                        .init("screenRecording", .bool(record)), .init("accessibility", .bool(control)),
                        .init("permissionNote", .string(NativeMacScreen.missingLine(record: record, control: control))),
                        .init("displays", .array(rows.map { row in .object([.init("id", row["id"]), .init("name", row["name"]), .init("pixels", row["runtime"])]) })),
                        .init("remote", .array(await BackendRemoteMacScreens.shared.watching())),
                        .init("phones", .array(viewers.map { viewer in .object([.init("phone", .string(viewer.phone)), .init("display", .string(viewer.display)),
                                                                              .init("controlling", .bool(viewer.controlling))]) }))]))
                }
            } catch {
                report("The \(id) tool was not installed: " + error.localizedDescription)
            }
        }
    }
}

/// The relay link checks itself the moment the Mac wakes, its screens wake or the person unlocks it (Macky study,
/// learnings 9–10: Macky had no wake handling and could stay offline until "Go Online" was pressed). Events the system
/// already sends; nothing polls.
@MainActor enum NativeRelayWake {
    private static var observers: [NSObjectProtocol] = []
    private static let path = NWPathMonitor()
    private static var pathUp = true

    static func nudgeMachines() {
        guard let coordinator = NativeRemoteMacs.shared.coordinator else { return }
        Task { await coordinator.nudgeAll() }
    }

    static func install() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, why) in [(NSWorkspace.didWakeNotification, "The Mac woke."), (NSWorkspace.screensDidWakeNotification, "The screen woke."),
                            (NSWorkspace.sessionDidBecomeActiveNotification, "The person came back.")] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in BackendRemoteRelayClient.nudgeAll(why) })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            BackendRemoteRelayClient.nudgeAll("The Mac was unlocked.")
            nudgeMachines()
        })
        // Links to other Macs (Mac to Mac) dial again too: on wake, and when the network comes back.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in nudgeMachines() })
        }
        path.pathUpdateHandler = { update in
            let up = update.status == .satisfied
            Task { @MainActor in
                if up, !pathUp { nudgeMachines() }
                pathUp = up
            }
        }
        path.start(queue: DispatchQueue(label: "dev.terminaldeck.machines.path"))
    }
}
