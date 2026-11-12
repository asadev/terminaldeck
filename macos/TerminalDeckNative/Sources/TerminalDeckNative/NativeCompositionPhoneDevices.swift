import Network
import AppKit
import CoreImage
import Foundation
import IOSurface
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The Mac's simulators and emulators on a paired phone (Asad, 31 Oct): the remote `sims` capability
/// (`BackendPhoneDevices`) over this Mac's own device engine. The live screen comes from the same direct screen the
/// phone panel shows (the device's own screen buffer), encoded as H.264 for the phone's direct link (3 Nov: no JPEG
/// pictures any more). A device with no direct screen (a cable phone, or when the direct path failed) is encoded from
/// screenshots.
/// Input goes the panel's way (the direct helper first, then the device tools' own route); an annotated still is sent
/// to Hoot or a chat the way the Mac's Annotate sends it (`NativeHOOTSIMFeedback`, `NativeCapturedFeedback`).
/// Not fatal: without it the phone simply has no Devices page.
extension NativeCompositionProduction {
    func installPhoneDevices() async {
        guard let endpoint = remoteEndpoint else { report("Phone devices are unavailable: the remote endpoint is not wired."); return }
        guard let installed = devices else { report("Phone devices are unavailable: the device engine is not installed."); return }
        let manager = installed.manager, tools = installed.tools
        var source = BackendPhoneDevices.Source(
            list: { await manager.list() },
            power: { id, on in on ? try await manager.boot(id) : try await manager.shutDown(id) },
            stream: { id, row in
                if id.hasPrefix("mac:") { return NativeMacReachSwitchingStream(display: id) }
                // 9 Nov: the direct screen, with screenshots standing in only until it shows (never for the whole watch).
                return await NativePhoneDeviceScreens.shared.phoneStream(row) { try await manager.capture(id).png }
            },
            input: { id, input in
                if id.hasPrefix("mac:") {
                    if NativeMacScreen.screenState == .locked, await NativeMacReach.shared.available { try await NativeMacReach.shared.input(id, input) }
                    else { try await NativeMacScreen.input(id, input) }
                    return
                }
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
                case .mouse, .keyCode, .pointer, .pointerTo, .click, .wheel: throw NativeRPCError.invalidArguments("That input is for a Mac's screen.")
                }
            },
            shot: { id in id.hasPrefix("mac:") ? try await NativeMacScreen.shot(id) : try await manager.capture(id) },
            deliver: { annotation in try await NativePhoneDeviceAnnotate.deliver(annotation, manager: manager) },
            visibleSessions: { context in try await endpoint.panelSessionIDs(context) },
            send: { id, message in try await endpoint.sendToConnection(id, message: message) },
            macRows: {
                let helperRows = NativeMacScreen.screenState == .locked ? await NativeMacReach.shared.screenRows() : nil
                let rows = if let helperRows { helperRows } else { await MainActor.run { NativeMacScreen.rows() } }
                // Settings → Devices switch off (round 3, #24): This Mac is still listed, with the reason.
                guard !NativeMacScreenSetting.allowed else { return rows }
                return rows.map { $0.setting("canWatch", .bool(false)).setting("canControl", .bool(false)).setting("note", .string(NativeMacScreenSetting.refusal)) }
            },
            phoneName: { [trust = remoteTrust] context in
                let name = await trust?.device(context.deviceID)?.name ?? ""
                return name.isEmpty ? "A phone" : name
            },
            macViewers: { viewers in await MainActor.run { NativeMacScreenIndicator.shared.update(viewers) } },
            inspect: { id in
                if id.hasPrefix("mac:") { return await NativeMacScreenElements.read(id) }
                return await NativePhoneDeviceAnnotate.inspect(id, manager: manager)
            },
            // Which sessions each device is attached to, for the phones' session header (item 45).
            attachedSessions: { [weak self] in
                guard let attachments = await MainActor.run(body: { self?.sessionSimulator?.attachments }) else { return [:] }
                return await attachments.sessionsByDevice()
            })
        // Round 3: this Mac's input goes straight to the events (no main thread, no answer awaited), the phone draws the
        // pointer from `sims.pointer`, the Settings switch gates it all, and a phone can record a simulator or emulator.
        source.macPost = { id, input in NativeMacScreen.postNow(id, input) }
        source.macInputAsyncWhen = { NativeMacScreen.screenState == .locked }
        source.macSignIn = { id, password in
            guard let client = await NativeMacReach.shared.client else {
                throw NativeRPCError(code: "unavailable", message: MacReach.State.setup.words)
            }
            _ = try await client.value("password", .object([.init("id", .string(id)), .init("password", .string(password))]))
        }
        source.macControlNow = { id in await endpoint.canControlMacScreen(id) }
        source.macState = {
            switch NativeMacScreen.screenState {
            case .locked: return MacReach.State.locked.rawValue
            case .asleep: return MacReach.State.asleep.rawValue
            case .awake: return MacReach.State.desktop.rawValue
            case .unknown: return MacReach.State.unreachable.rawValue
            }
        }
        source.pointer = { id in NativeMacScreenPointer.read(id) }
        source.macAllowed = { NativeMacScreenSetting.allowed }
        source.macRefusal = NativeMacScreenSetting.refusal
        source.record = { step in try await NativePhoneDeviceRecording.run(step) }
        // 9 Nov: a phone's finger on a simulator or emulator as it moves, straight onto its direct input.
        source.touch = { id, phase, x, y in await NativePhoneDeviceScreens.shared.touch(id, phase: phase, x: x, y: y) }
        // stream step 2 (2 Nov): the screen's video goes on the connection's link once it has moved there (same network,
        // internet peer-to-peer, Cloudflare TURN), the relay otherwise. Nothing to set.
        source.direct = { [endpoint] id, data, lane in await endpoint.sendDirect(id, data: data, lane: lane) }
        source.linkVideo = { [endpoint] id in await endpoint.linkVideo(id) }
        let owner = "native.phone-devices"
        do {
            let installation = try await BackendPhoneDevices.install(on: endpoint, source: source, ownerID: owner)
            do {
                try await root.retain(.init(name: "phone-devices", domains: ["phone-devices"], ownerID: owner, invokes: [],
                                            stop: { await installation.stop() }))
                phoneDevices = installation
                // Settings → Devices switched off: every phone watching this Mac is let go, with the reason.
                NativeMacScreenSetting.changed = { on in
                    Task { @MainActor in await NativeMacReach.shared.permissionsChanged() }
                    if !on { Task { await installation.devices.stopMac(why: NativeMacScreenSetting.refusal) } }
                }
                // A text field on this Mac took the focus: the watching phones bring their keyboard up (1 Nov).
                NativeMacScreenFocus.shared.changed = { text in Task { await installation.devices.macFocus(text: text) } }
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

/// A phone's recording of a simulator or emulator (round 3, #26): the floating window's recorder (`simctl io
/// recordVideo` / `adb screenrecord`), one per device; Stop sends the video the way the Mac panel's recorder does (to
/// Hoot: a preview picture and the video's path; to a chat: the same words with the path). Videos stay in
/// ~/Movies/Terminal Deck.
@MainActor enum NativePhoneDeviceRecording {
    private static var recorders: [String: NativeDeviceDirectRecorder] = [:]

    static func run(_ step: BackendPhoneDeviceRecordStep) async throws -> String {
        let id = step.deviceID
        switch step.step {
        case "start":
            let recorder = recorders[id] ?? NativeDeviceDirectRecorder()
            recorders[id] = recorder
            do { _ = try await recorder.run("start", deviceID: id) } catch { recorders[id] = nil; throw NativeRPCError(code: "unavailable", message: error.localizedDescription) }
            return ""
        case "cancel":
            guard let recorder = recorders.removeValue(forKey: id) else { return "" }
            if let answer = try? await recorder.run("stop", deviceID: id) as? [String: String], let path = answer["path"] {
                try? FileManager.default.removeItem(atPath: path)
            }
            return ""
        default:
            guard let recorder = recorders.removeValue(forKey: id) else { throw NativeRPCError(code: "unavailable", message: "Nothing is recording. Start again.") }
            let answer: [String: String]
            do {
                guard let stopped = try await recorder.run("stop", deviceID: id) as? [String: String] else { throw NativeRPCError(code: "unavailable", message: "The recorder did not save a finished video.") }
                answer = stopped
            } catch let error as NativeRPCError { throw error } catch { throw NativeRPCError(code: "unavailable", message: error.localizedDescription) }
            guard let path = answer["path"] else { throw NativeRPCError(code: "unavailable", message: "The recorder did not save a finished video.") }
            return try await deliver(URL(fileURLWithPath: path), step)
        }
    }

    private static func deliver(_ video: URL, _ step: BackendPhoneDeviceRecordStep) async throws -> String {
        let info = try await NativeSimRecordingMedia.info(video)
        let kind = DeviceEntry.kindWords(platform: step.platform, kind: step.kind)
        let line = NarrationPayload.plain(videoPath: video.path, width: info.width, height: info.height, seconds: info.seconds,
                                          kind: kind, deviceName: step.deviceName, note: step.note)
        if step.to == "hoot" {
            guard let poster = await NativeSimRecordingMedia.poster(video),
                  let png = NSBitmapImageRep(cgImage: poster).representation(using: .png, properties: [:]) else {
                throw NativeRPCError(code: "unavailable", message: "The recording preview could not be made. Nothing was sent.")
            }
            try await NativeHOOTSIMFeedback.send(line + "\nThe attached picture is a video preview. The full video stays at the named path.", images: [png],
                                                 source: .object([.init("path", .string(video.path)), .init("noteCount", .number(step.note.isEmpty ? 0 : 1))]))
            return "Sent to Hoot."
        }
        try await NativeCapturedFeedback.send(sessionID: step.to, text: line, chatText: line, paths: [video.path],
                                              source: .object([.init("kind", .string("device")), .init("path", .string(video.path))]))
        return "Sent to the chat."
    }
}

/// Sends a phone's annotated still the way the Mac's Annotate does (devices-fix, 31 Oct: with inspection). The picked
/// elements get the Mac's own numbered markers on top of the phone's drawing; the round is kept by the device engine
/// (`devices_annotations` reads it: elements, note, picture, where it went) and described in the Mac's own words.
@MainActor enum NativePhoneDeviceAnnotate {
    static func deliver(_ annotation: BackendPhoneDeviceAnnotation, manager: BackendAppDeviceManager) async throws -> String {
        let markers = annotation.picks.enumerated().map { index, pick in
            Annotation(id: "phone-\(index + 1)", n: index + 1, rect: NormRect(x: pick.x, y: pick.y, width: pick.width, height: pick.height),
                       element: AnnotatedElement(role: pick.role.isEmpty ? nil : pick.role, name: pick.name.isEmpty ? nil : pick.name,
                                                 identifier: pick.identifier.isEmpty ? nil : pick.identifier,
                                                 component: pick.component.isEmpty ? nil : pick.component))
        }
        var png = annotation.png, width = annotation.width, height = annotation.height
        if !markers.isEmpty {
            guard let image = BackendPhoneDevices.image(png), let marked = MarkedPicture.draw(image, markers: markers) else {
                throw NativeRPCError(code: "unavailable", message: "The markers could not be drawn.")
            }
            png = marked.png; width = marked.width; height = marked.height
        }
        let mac = annotation.platform == "mac"
        let place = mac ? "Mac screen" : BackendAppDeviceManager.place(platform: annotation.platform, kind: annotation.kind)
        let name = annotation.deviceName.isEmpty ? (mac ? "This Mac" : "device") : annotation.deviceName
        let round = AnnotationRound(id: "phone-round-\(UUID().uuidString)", createdAt: (Date().timeIntervalSince1970 * 1000).rounded(),
            where_: AnnotateWhere(place: place, name: name, deviceId: annotation.deviceID,
                                  app: annotation.app.isEmpty ? nil : annotation.app, screen: annotation.screen.isEmpty ? nil : annotation.screen),
            frameWidth: width, frameHeight: height, annotations: markers, note: annotation.note)
        let saved = try await manager.saveRound(png: .string("data:image/png;base64," + png.base64EncodedString()),
                                                round: try NativeRPCValue.fromFoundation(round.json))
        guard let path = saved["path"].string, !path.isEmpty else { throw NativeRPCError(code: "unavailable", message: "The picture could not be saved, so nothing was sent.") }
        let kind = mac ? "Mac screen" : DeviceEntry.kindWords(platform: annotation.platform, kind: annotation.kind)
        let line = markers.isEmpty
            ? Handoff.composeScreenshot(path: path, width: width, height: height, kind: kind, deviceName: name, instruction: annotation.note)
            : Handoff.composeRound(round, picturePath: path)
        let source = NativeRPCValue.object([.init("kind", .string("device")), .init("path", .string(path)),
            .init("deviceId", .string(annotation.deviceID)), .init("title", .string(name)),
            .init("noteCount", .number(annotation.note.isEmpty ? 0 : 1))])
        if annotation.to == "hoot" {
            try await NativeHOOTSIMFeedback.send(line, images: [png], source: source)
            await manager.markSent(round.id, sessionID: "hoot", label: "Hoot")
            return markers.isEmpty ? "Sent to Hoot." : "Sent to Hoot with \(markers.count) marked element\(markers.count == 1 ? "" : "s")."
        }
        try await NativeCapturedFeedback.send(sessionID: annotation.to, text: line, chatText: markers.isEmpty ? annotation.note : line,
                                              paths: [path], source: .object([.init("kind", .string("device")), .init("path", .string(path))]))
        await manager.markSent(round.id, sessionID: annotation.to, label: await sessionLabel(annotation.to))
        return markers.isEmpty ? "Sent to the chat." : "Sent to the chat with \(markers.count) marked element\(markers.count == 1 ? "" : "s")."
    }

    private static func sessionLabel(_ id: String) async -> String {
        let rows = (try? await EngineBridge.shared.invoke("session:list")) as? [[String: Any]] ?? []
        let row = rows.first { $0["id"] as? String == id }
        return [row?["title"], row?["name"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "A chat"
    }

    /// Pick on a simulator or emulator: its element tree now, as the Mac's Annotate reads it.
    static func inspect(_ id: String, manager: BackendAppDeviceManager) async -> BackendPhoneDeviceInspection {
        do {
            let answer = try await BackendAppDeviceDeadline.run(within: 12, "Reading the screen's elements") { try await manager.tree(id) }
            guard let tree = DeviceTree(json: answer["tree"].foundation) else {
                return .init(note: "This screen's elements could not be read. You can still draw on it.")
            }
            let elements = BackendPhoneDevices.elements(from: tree.root)
            return .init(elements: elements, app: answer["foreground"]["app"].string ?? "", screen: answer["foreground"]["screen"].string ?? "",
                         note: elements.isEmpty ? "Nothing on this screen can be picked. You can still draw on it." : "")
        } catch {
            return .init(note: "This screen's elements could not be read (\((error as? NativeRPCError)?.message ?? error.localizedDescription)). You can still draw on it.")
        }
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

    /// 9 Nov (Asad: "streaming simulator from ios app is too slow … blurry … moves slow", while this Mac's screen is
    /// fast): a phone's view of a simulator or emulator. Before, a direct screen that showed nothing within
    /// `firstPictureWithin` (seen on 9 Nov while the Mac was busy: the device list took 7-13 s) was replaced by
    /// `simctl`/`adb` screenshots for the WHOLE watch (a few pictures a second, each sent as a new moving picture, so
    /// blurry), silently, and taps then went the slow tool way. Now screenshots only stand in until the direct screen
    /// shows; it keeps being tried and takes over the moment it does (input with it).
    func phoneStream(_ row: NativeRPCValue, capture: @escaping @Sendable () async throws -> Data) async -> any BackendPhoneDeviceStream {
        let still = BackendPhoneDeviceStillStream(capture: capture)
        guard let id = row["id"].string,
              DeviceDirect.hasPath(for: DeviceDetails(id: id, name: row["name"].string ?? id, platform: row["platform"].string ?? "ios",
                                                      kind: row["kind"].string ?? "simulator")) else { return still }
        return NativePhoneSwitchingStream(id: id, row: row, screens: self, still: still)
    }

    /// A stream from the device's direct screen, or nil when it has none (the caller uses screenshots).
    /// `ignoringCooldown`: a phone's view tries again even within the panel's two minutes after a failure.
    func stream(_ row: NativeRPCValue, ignoringCooldown: Bool = false) async -> NativePhoneDirectStream? {
        guard let id = row["id"].string else { return nil }
        if let screen = screens[id], screen.ended == nil {
            screen.users += 1
            return NativePhoneDirectStream(screen: screen, owner: self)
        }
        let details = DeviceDetails(id: id, name: row["name"].string ?? id, platform: row["platform"].string ?? "ios", kind: row["kind"].string ?? "simulator")
        guard let source = DeviceDirect.source(for: details, ignoringCooldown: ignoringCooldown) else { return nil }
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
            // Said in the log (9 Nov: this was silent, so a phone's slow screenshot view left no trace).
            let why = screen.ended ?? "nothing within \(Int(Self.firstPictureWithin)) s"
            NativeCompositionRoot.note("phone devices: \(id) direct screen did not show (\(why))")
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

    /// 9 Nov: one finger step (down, move, up) from a phone straight onto a watched device's direct input; false when
    /// it cannot take a finger there now (the caller replays the gesture as a tap or a swipe). A finger that went down
    /// this way keeps going this way until it lifts (the direct sources keep a gesture on one touchscreen).
    nonisolated func touch(_ id: String, phase: String, x: Double, y: Double) async -> Bool {
        await MainActor.run {
            guard let screen = screens[id], screen.ended == nil, screen.source.inputReady else { return false }
            if phase == "down", !screen.source.canTouch { return false }
            return screen.source.send(.touch(phase: phase, x: x, y: y))
        }
    }

    /// Input through a watched device's own direct path; false when it cannot take it there.
    nonisolated func send(_ id: String, _ input: BackendPhoneDeviceInput) async -> Bool {
        await MainActor.run {
            guard let screen = screens[id], screen.ended == nil, screen.source.inputReady else { return false }
            switch input {
            case let .tap(x, y, hold): return screen.source.send(.tap(x: x, y: y, holdMs: hold))
            case let .swipe(fromX, fromY, toX, toY, ms): return screen.source.send(.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms))
            case .type(let text): return screen.source.canType && screen.source.send(.type(text))
            case .key, .button, .rotate, .secondaryTap, .scroll, .shortcut, .mouse, .keyCode, .pointer, .pointerTo, .click, .wheel: return false
            }
        }
    }

    /// The screen surface copied into a new BGRA pixel buffer (item 61, for the video encoder), even-sized.
    nonisolated static func pixels(_ box: DirectSurfaceBox) -> BackendPhoneDevicePixels? {
        let image = CIImage(ioSurface: box.surface)
        let width = Int(image.extent.width) / 2 * 2, height = Int(image.extent.height) / 2 * 2
        guard width >= 2, height >= 2, let made = pooledBuffer(width: width, height: height) else { return nil }
        context.render(image, to: made, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return BackendPhoneDevicePixels(made, capturedAt: 0)
    }

    /// 9 Nov: the copies come from a pool per size (a simulator's 1206 × 2622 is 12.6 MB: a new IOSurface for every
    /// picture at 30 a second was a fresh allocation each time, where this Mac's screen arrives in ScreenCaptureKit's
    /// own recycled buffers). A buffer goes back to the pool once the encoder and the last-picture keeper let it go.
    nonisolated private static let poolLock = NSLock()
    nonisolated(unsafe) private static var pools: [String: CVPixelBufferPool] = [:]

    nonisolated static func pooledBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = "\(width)x\(height)"
        let pool = poolLock.withLock { () -> CVPixelBufferPool? in
            if let pool = pools[key] { return pool }
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width,
                                               kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made) == kCVReturnSuccess, let made else { return nil }
            // A few sizes at most (two devices a phone, a turn of each); an old size's pool goes.
            if pools.count >= 4 { pools.removeAll() }
            pools[key] = made
            return made
        }
        var buffer: CVPixelBuffer?
        if let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer { return buffer }
        // No pool: a buffer of its own, as before.
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

}

/// One phone viewer's video source from a shared direct screen.
@MainActor final class NativePhoneDirectStream: BackendPhoneDeviceStream {
    private let screen: NativePhoneDeviceScreens.Screen
    private weak var owner: NativePhoneDeviceScreens?
    private var seen = -1
    private var stopped = false

    init(screen: NativePhoneDeviceScreens.Screen, owner: NativePhoneDeviceScreens) { self.screen = screen; self.owner = owner }

    /// Item 61: the device's newest screen, copied into its own pixel buffer (the device keeps drawing into its surface)
    /// for the hardware video encoder.
    func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        let deadline = Date().addingTimeInterval(seconds)
        while !stopped, !Task.isCancelled, screen.ended == nil {
            if screen.generation != seen, let surface = screen.surface {
                seen = screen.generation
                let box = DirectSurfaceBox(surface: surface)
                let copied = await Task.detached(priority: .userInitiated) { NativePhoneDeviceScreens.pixels(box) }.value
                if let copied { return .pixels(BackendPhoneDevicePixels(copied.buffer, capturedAt: Date().timeIntervalSince1970 * 1_000)) }
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let owner else { return stopped || screen.ended != nil ? .ended : .unchanged }
            await owner.wait(screen, after: seen, within: left)
        }
        return .ended
    }

    func endReason() -> String { screen.ended ?? "The device stopped." }

    func stop() {
        guard !stopped else { return }
        stopped = true
        owner?.release(screen)
    }
}

/// 9 Nov: one phone viewer's video of a simulator or emulator that has a direct path — the direct screen (the same
/// zero-copy surface the Mac's panel shows), and screenshots only until it shows. The first `standInAfter` seconds wait
/// for the direct screen alone (it normally shows within a second; a screenshot would only be a slow, blurry first
/// picture). After that screenshots stand in while the direct screen is tried again (`retries`), and it takes over the
/// moment it shows; input follows it (`NativePhoneDeviceScreens.send`). A direct screen that ends under the view (its
/// helper died) hands back to screenshots and is tried again.
@MainActor final class NativePhoneSwitchingStream: BackendPhoneDeviceStream {
    /// Seconds before each next try of the direct screen while screenshots stand in: soon, then less often.
    static let retries: [Double] = [3, 10, 30, 60]
    /// The first seconds wait for the direct screen only.
    static let standInAfter: Double = 2
    /// The pause after an unchanged screenshot before the next (one screenshot takes about as long as a slice, so the
    /// still stream's own pause never came and the Mac took screenshots back to back on a still screen).
    static let stillPause: Double = 0.2

    private let id: String
    private let row: NativeRPCValue
    private weak var screens: NativePhoneDeviceScreens?
    private let still: BackendPhoneDeviceStillStream
    private var direct: NativePhoneDirectStream?
    private var attempt: Task<Void, Never>?
    private var trying = false
    private var tries = 0
    private var stoodIn = false
    private var quietUntil = Date.distantPast
    private var stopped = false
    private let opened = Date()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(id: String, row: NativeRPCValue, screens: NativePhoneDeviceScreens, still: BackendPhoneDeviceStillStream) {
        self.id = id; self.row = row; self.screens = screens; self.still = still
        tryDirect(after: 0)
    }

    func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        let deadline = Date().addingTimeInterval(seconds)
        while !stopped, !Task.isCancelled {
            if let direct {
                let answer = await direct.pixels(within: max(0, deadline.timeIntervalSinceNow))
                guard case .ended = answer, !stopped else { return answer }
                // The direct screen ended under this view: screenshots stand in, and it is tried again.
                if self.direct === direct { self.direct = nil }
                NativeCompositionRoot.note("phone devices: \(id) direct screen ended (\(direct.endReason())); screenshots stand in")
                direct.stop()
                tryDirect(after: Self.retries[0])
                continue
            }
            let left = deadline.timeIntervalSinceNow
            let grace = opened.addingTimeInterval(Self.standInAfter).timeIntervalSinceNow
            if trying, grace > 0 {
                if left <= 0 { return .unchanged }
                await waitForDirect(within: min(grace, left))
                continue
            }
            if !stoodIn {
                stoodIn = true
                NativeCompositionRoot.note("phone devices: \(id) screenshots stand in until the direct screen shows")
            }
            // After an unchanged screenshot, a pause (a direct screen that shows meanwhile still takes over at once).
            let pause = quietUntil.timeIntervalSinceNow
            if pause > 0 {
                if left <= 0 { return .unchanged }
                await waitForDirect(within: min(pause, left))
                continue
            }
            // A screenshot, in short steps, so a direct screen that shows meanwhile takes over at once.
            let answer = await still.pixels(within: min(max(0, left), 0.25))
            if case .unchanged = answer { quietUntil = Date().addingTimeInterval(Self.stillPause) }
            if case .unchanged = answer, deadline.timeIntervalSinceNow > 0 { continue }
            if case .ended = answer, direct != nil { continue }
            return answer
        }
        return .ended
    }

    func endReason() async -> String {
        if let direct { return direct.endReason() }
        return await still.endReason()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        attempt?.cancel(); attempt = nil
        direct?.stop(); direct = nil
        wakeAll()
        await still.stop()
    }

    // MARK: Inside

    private func tryDirect(after delay: Double) {
        attempt?.cancel()
        attempt = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard !Task.isCancelled, let self, let next = await self.directOnce() else { return }
                wait = next
            }
        }
    }

    /// One try of the direct screen: nil when there is nothing more to try (it took over, or this view ended), else
    /// the seconds until the next try.
    private func directOnce() async -> Double? {
        guard !stopped, direct == nil, let screens else { return nil }
        trying = true
        let found = await screens.stream(row, ignoringCooldown: true)
        trying = false
        defer { wakeAll() }
        guard let found else {
            if stopped { return nil }
            let wait = Self.retries[min(tries, Self.retries.count - 1)]
            tries += 1
            return wait
        }
        guard !stopped, direct == nil else { found.stop(); return nil }
        direct = found
        if stoodIn { NativeCompositionRoot.note("phone devices: \(id) direct screen took over from screenshots") }
        return nil
    }

    /// Until the direct screen shows or its try fails (or `seconds`); a cancelled caller stops waiting at once.
    private func waitForDirect(within seconds: Double) async {
        let key = UUID()
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            self?.waiters.removeValue(forKey: key)?.resume()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || stopped { resume.resume(); return }
                waiters[key] = resume
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: key)?.resume() }
        }
    }

    private func wakeAll() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting.values { waiter.resume() }
    }
}

extension NativeCompositionProduction {
    /// This Mac's screen on a phone, for agents: what it is doing and a way to end it. There is deliberately no tool
    /// that starts showing the screen: only the person, from the phone, starts it.
    fileprivate func installMacScreenTools(_ devices: BackendPhoneDevices, authority: BackendCompositionAuthority) async {
        await installMacReachTools(devices, authority: authority)
        let mcp = root.mcp, joins = self.joins
        let empty = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([])), .init("additionalProperties", .bool(false))])
        let tools: [(String, BackendMCPTier, String)] = [
            ("mac_screen.status", .read, "This Mac's screen on paired phones and other Macs: whether Terminal Deck has the Screen Recording and Accessibility permissions, the displays, which phones or Macs are watching or controlling this Mac now, and which other Macs this Mac is showing (remote). Read only."),
            ("mac_screen.wake", .act, "Ask the person to wake this Mac's sleeping displays once. Never unlocks it or starts screen sharing."),
            ("mac_screen.stop", .act, "Stop every phone or Mac watching or controlling this Mac's screen and close every window here showing another Mac's screen. Nothing can start a screen session except the person, from a phone or from Devices › Other Macs."),

        ]
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description) in tools where !taken.contains(id) {
            do {
                let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: empty, tier: tier)
                try await mcp.registerTool(spec, ownerID: "native.phone-devices") { caller, _ in
                    guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                    _ = try await authority.resolve(caller)
                    if id == "mac_screen.wake" {
                        try await joins.prepareNative(caller, tier: tier, sentence: "Wake this Mac's screen once", ownerMustAnswer: true)
                        let message = try await NativeMacScreen.wakeForTool()
                        return .value(.object([.init("message", .string(message)), .init("screenState", .string(NativeMacScreen.screenState.rawValue))]))
                    }
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
                        .init("accessAfterRestart", await NativeMacReach.shared.status()),
                        .init("screenState", .string(NativeMacScreen.screenState.rawValue)),
                        .init("screenNote", .string(NativeMacScreen.screenState == .locked ? MacScreenAvailability.locked
                            : NativeMacScreen.screenState == .asleep ? MacScreenAvailability.asleep : "")),
                        .init("screenRecording", .bool(record)), .init("accessibility", .bool(control)),
                        .init("phonesAllowed", .bool(NativeMacScreenSetting.allowed)),
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
