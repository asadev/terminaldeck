import Foundation
import TerminalDeckNativeCore

/// One call for "open app X on a phone, in this session" (ANDROID lane, 10 Oct). Asad: sessions opened
/// Simulator.app or an emulator window instead of Terminal Deck's own phone panel. This tool picks the
/// session's phone (or a running one, or one it can start), attaches it to the calling session (asking
/// the person first when it is a new device), starts it headless, shows it in the session's phone panel,
/// then installs / launches / opens what was asked. iOS Simulator (simctl) and Android emulator (adb).
public struct BackendANDROIDPhoneOpenApp: Sendable {
    public static let id = "devices.open_app"
    /// How long the session's panel has to show the phone before the app is installed and opened anyway.
    static let showWithin: Double = 45
    let service: any BackendDeckToolsMachinesDeviceService
    let attachments: BackendUIGSessionSimulatorAttachments

    public init(service: any BackendDeckToolsMachinesDeviceService, attachments: BackendUIGSessionSimulatorAttachments) {
        self.service = service; self.attachments = attachments
    }

    public func definitions(environment: any BackendDeckToolsMachinesEnvironment) throws -> [BackendDeckToolsDefinition] {
        func text(_ description: String) -> NativeRPCValue { .object([.init("type", .string("string")), .init("description", .string(description))]) }
        let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object([
            .init("platform", .object([.init("type", .string("string")), .init("enum", .array([.string("ios"), .string("android")]))])),
            .init("app", text("Bundle id (iOS) or package (Android) to launch, or \"settings\" for the phone's Settings. Optional.")),
            .init("installPath", text("A built .app (iOS Simulator) or .apk (Android) on this Mac to install first. Optional.")),
            .init("url", text("A link or deep link to open on the phone. Optional.")),
            .init("deviceId", text("A specific device id from devices_list. Optional: by default this session's phone, else a running one, else one that can start.")),
            .init("sessionId", text("Owner callers only: which session's panel. Sessions omit this.")),
        ])), .init("required", .array([.string("platform")])), .init("additionalProperties", .bool(false))])
        let title = "Open an app on a phone in this session’s phone panel"
        let spec = try BackendMCPTool(id: Self.id, wireName: "devices_open_app",
            description: title + ". Use this instead of `open -a Simulator`, `xcrun simctl boot/install/launch` or `emulator -avd`: it starts the iOS Simulator or Android emulator headless, shows it in the calling session’s phone panel inside Terminal Deck, and installs/launches the app or opens the link. Attaching a new device to the session counts as a change; it runs when the calling AI’s permission mode allows it.",
            inputSchema: schema, tier: .alter, advertised: true)
        let service = self.service, attachments = self.attachments
        return [BackendDeckToolsDefinition(spec: spec, title: title, index: spec.description) { call, args in
            var prepared: BackendDeckToolsMachinesPolicy?
            do {
                let context = try await environment.context(for: call)
                try await environment.validate(arguments: args, schema: schema)
                if let reason = await service.unavailable() { throw NativeRPCError(code: "unavailable", message: reason) }
                let sessionID: String
                if context.kind == .session {
                    guard context.machineID.isEmpty, let id = context.sessionID, !id.isEmpty, args["sessionId"].isNullish else {
                        throw NativeRPCError(code: "device-refused", message: "A session opens apps only on its own phone panel on this Mac.")
                    }
                    sessionID = id
                } else {
                    guard context.actsAsOwner else { throw NativeRPCError(code: "device-refused", message: "Only the person at this Mac may choose another session's phone.") }
                    sessionID = try args["sessionId"].requireString("sessionId", nonempty: true)
                }
                let platform = try args["platform"].requireString("platform")
                let rows = try await service.list()
                try await attachments.refresh(service: service, devices: rows)
                let held = try await attachments.attached(sessionID: sessionID)
                let mine = held.first { ticket in rows.contains { $0["id"].string == ticket.deviceID && $0["platform"].string == platform } }
                let wanted = args["deviceId"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                let options = rows.filter { $0["platform"].string == platform && ["simulator", "emulator"].contains($0["kind"].string ?? "") }
                let pick: NativeRPCValue? = {
                    // Any spelling of the id ("emulator-5554", a bare UDID), its name or its AVD; a running one first,
                    // so an emulator that is already up is adopted as it is and never started a second time.
                    if let wanted {
                        let id = BackendAppDeviceIDs.normalize(wanted)
                        return options.first { $0["id"].string == id }
                            ?? options.first { $0["state"].string == "ready" && BackendAppDeviceIDs.matches($0, wanted) }
                            ?? options.first { BackendAppDeviceIDs.matches($0, wanted) }
                    }
                    if let mine { return options.first { $0["id"].string == mine.deviceID } }
                    return options.first { $0["state"].string == "ready" } ?? options.first { $0["canBoot"].bool == true }
                }()
                guard let row = pick, let deviceID = row["id"].string else {
                    let kind = platform == "ios" ? "iOS Simulator" : "Android emulator"
                    if let wanted {
                        if let other = rows.first(where: { BackendAppDeviceIDs.matches($0, wanted) }), let otherPlatform = other["platform"].string, otherPlatform != platform {
                            throw NativeRPCError(code: "device-refused", message: "\(wanted) is \(otherPlatform == "ios" ? "an iOS Simulator" : "an Android device"), so call this again with platform \(otherPlatform).")
                        }
                        throw NativeRPCError(code: "device-refused", message: "There is no \(kind) \(wanted) on this Mac right now. Call devices_list for the current ids (they look like android:emulator-5554 or ios:…) and pass one of them.")
                    }
                    if options.isEmpty, let why = await service.emptyReason() { throw NativeRPCError(code: "device-refused", message: "No \(kind) can be opened: \(why)") }
                    throw NativeRPCError(code: "device-refused", message: platform == "ios"
                        ? "No iOS Simulator on this Mac. Create one in Xcode (or with simctl create), then call this again."
                        : "No Android emulator on this Mac. Create one in Android Studio's Device Manager, then call this again.")
                }
                let attaching = !held.contains { $0.deviceID == deviceID }
                let policy = BackendDeckToolsMachinesPolicy(tool: spec, arguments: args, loggedArguments: args, tier: attaching ? .alter : .act,
                    ownerMustAnswer: attaching, spends: "device-input",
                    sentence: attaching ? "Show \(row["name"].string ?? deviceID) in this session’s phone panel and open \(args["app"].string ?? args["url"].string ?? "it")" : title)
                prepared = policy
                return try await environment.execute(context: context, policy: policy) {
                    if call.cancellation.isCancelled { throw CancellationError() }
                    try await attachments.refresh(service: service)
                    let held = try await attachments.attached(sessionID: sessionID)
                    var ticket: BackendUIGSessionSimulatorTicket
                    if let current = held.first(where: { $0.deviceID == deviceID }) { ticket = current }
                    else {
                        let taken = Set(held.map(\.slot))
                        guard let slot = BackendUIGSessionSimulatorAttachments.slots.first(where: { !taken.contains($0) }) else {
                            throw NativeRPCError(code: "device-refused", message: "This session already shows two devices. Detach one first.")
                        }
                        ticket = try await attachments.attach(sessionID: sessionID, deviceID: deviceID, slot: slot, service: service)
                    }
                    var liveID = deviceID
                    if row["state"].string != "ready" {
                        let booted = try await service.boot(deviceID) // headless: simctl boot / emulator -no-window
                        if booted["ok"].bool == false { throw NativeRPCError(code: "device-fault", message: booted["message"].string ?? "The phone did not start.") }
                        if let next = booted["id"].string, next != deviceID { ticket = try await attachments.booted(ticket, as: next); liveID = next }
                    }
                    // The session's phone panel (opens it when closed); a window-less engine just skips this.
                    // Devices freeze (26 Oct): showing it in the panel is a courtesy with its own deadline; a panel that does
                    // not answer never holds the install, the launch or the next device call.
                    if let shown = (try? await service.list())?.first(where: { $0["id"].string == liveID }) {
                        _ = try? await BackendAppDeviceDeadline.run(within: Self.showWithin, "Showing the phone in the session's panel") {
                            try await BackendFIXESDevicePresenter.shared.show(shown, destination: "beside", sessionID: sessionID)
                        }
                    }
                    var done: [String] = ["shown in the session’s phone panel"]
                    if let path = args["installPath"].string, !path.isEmpty {
                        try await Self.install(path, on: liveID); done.append("installed \((path as NSString).lastPathComponent)")
                    }
                    if let app = args["app"].string, !app.isEmpty { done.append(try await Self.launch(app, on: liveID)) }
                    if let url = args["url"].string, !url.isEmpty { try await Self.open(url, on: liveID); done.append("opened \(url)") }
                    let value = ticket.value.setting("deviceId", .string(liveID)).setting("done", .array(done.map(NativeRPCValue.string)))
                    return .init(value, .object([.init("deviceId", .string(liveID)), .init("done", .string(done.joined(separator: "; ")))]))
                }
            } catch {
                try? await attachments.refresh(service: service)
                return await environment.failed(call: call, tool: spec, policy: prepared, loggedArguments: args, error: error)
            }
        }]
    }

    // MARK: On the phone (headless commands only; never Simulator.app or an emulator window)

    static func install(_ path: String, on id: String) async throws {
        if let udid = udid(id) { try await run("/usr/bin/xcrun", ["simctl", "install", udid, path], "The app could not be installed on the simulator.") }
        else if let serial = BackendAndroidScreenRecord.serial(id) { try await run(try adb(), ["-s", serial, "install", "-r", path], "The app could not be installed on the emulator.") }
    }
    static func launch(_ app: String, on id: String) async throws -> String {
        let settings = app.lowercased() == "settings"
        if let udid = udid(id) {
            try await run("/usr/bin/xcrun", ["simctl", "launch", udid, settings ? "com.apple.Preferences" : app], "The app could not be opened on the simulator.")
            return "opened \(app)"
        } else if let serial = BackendAndroidScreenRecord.serial(id) {
            return try await launchAndroid(app, serial: serial, executable: adb())
        }
        throw NativeRPCError(code: "device-fault", message: "That phone cannot open apps here.")
    }
    /// monkey also performs input/graphics checks after sending the launch. Its exit status does
    /// not tell us whether the activity opened. Resolve the launcher and ask Activity Manager instead.
    static func launchAndroid(_ app: String, serial: String, executable: String,
                              executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor()) async throws -> String {
        let settings = app.lowercased() == "settings"
        func command(_ args: [String], timeout: Int = 30_000) async -> BackendAppSessionCommandResult {
            await BackendAppDeviceDeadline.command(executor, executable, arguments: ["-s", serial, "shell"] + args,
                environment: ProcessInfo.processInfo.environment, cwd: NSHomeDirectory(), timeoutMilliseconds: timeout, maximumBytes: 256 * 1024)
        }
        var args = ["am", "start", "-W"]
        if settings { args += ["-a", "android.settings.SETTINGS"] }
        else {
            let resolved = await command(["cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", app])
            guard resolved.ok, let component = resolved.stdout.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix(app + "/") && !$0.contains(" ") }) else {
                if resolved.killed || resolved.exitCode == nil { return "The emulator is slow to answer. Opening \(app) could not be confirmed; try again when it responds." }
                throw NativeRPCError(code: "device-fault", message: "Android could not find an opening screen for \(app). Check that it is installed on this emulator.")
            }
            args += ["-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", component]
        }
        let started = await command(args, timeout: 60_000)
        let package = settings ? "com.android.settings" : app
        let output = started.stdout + "\n" + started.stderr
        if Self.androidLaunchConfirmed(output) { return "opened \(app)" }
        // A slow guest can time out after launching. Read the actual resumed activity, accepting
        // any activity in this package (a splash or redirect can replace the launcher immediately).
        let foreground = await command(["dumpsys", "activity", "activities"], timeout: 10_000)
        if Self.androidForeground(foreground.stdout, package: package) { return "opened \(app)" }
        if started.killed || started.exitCode == nil || output.contains("Status: timeout") {
            return "Opening \(app) was requested, but the emulator is slow to answer. The app may be open; its screen could not be confirmed."
        }
        throw NativeRPCError(code: "device-fault", message: "Android did not confirm opening \(app). Check that the app has a launcher and that the emulator responds.")
    }
    static func androidLaunchConfirmed(_ output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains("Status: ok") && !lines.contains(where: { $0.hasPrefix("Error:") || $0.hasPrefix("Exception") })
    }
    static func androidForeground(_ output: String, package: String) -> Bool {
        output.components(separatedBy: .newlines).contains {
            ($0.contains("mResumedActivity") || $0.contains("topResumedActivity")) && $0.contains(" " + package + "/")
        }
    }
    static func open(_ url: String, on id: String) async throws {
        if let udid = udid(id) { try await run("/usr/bin/xcrun", ["simctl", "openurl", udid, url], "The link could not be opened on the simulator.") }
        else if let serial = BackendAndroidScreenRecord.serial(id) {
            try await run(try adb(), ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url], "The link could not be opened on the emulator.")
        }
    }
    private static func udid(_ id: String) -> String? {
        guard id.hasPrefix("ios:"), UUID(uuidString: String(id.dropFirst(4))) != nil else { return nil }
        return String(id.dropFirst(4))
    }
    private static func adb() throws -> String {
        guard let adb = BackendAndroidScreenRecord.adbPath() else { throw NativeRPCError(code: "unavailable", message: "adb is not installed on this Mac (Android Studio's platform tools).") }
        return adb
    }
    private static func run(_ tool: String, _ arguments: [String], _ failure: String) async throws {
        let status = await BackendAndroidScreenRecordProcess.runToEnd(tool, arguments)
        guard status == 0 else { throw NativeRPCError(code: "device-fault", message: failure) }
    }
}
