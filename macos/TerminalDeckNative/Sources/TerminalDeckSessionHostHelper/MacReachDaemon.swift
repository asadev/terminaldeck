import AppKit
import Darwin
import Foundation
import Security
import SystemConfiguration
import TerminalDeckBackend
import TerminalDeckNativeCore
import TerminalDeckPeer

/// The system half owns networking, never the WindowServer or a user's sessions. The GUI half connects back from
/// LoginWindow/Aqua. Both modes use the keeper's existing stable signing identity, without another privacy entry.
@MainActor final class MacReachDaemon: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: MacReach.daemonLabel)
    private let directory = URL(fileURLWithPath: "/Library/Application Support/TerminalDeckReach", isDirectory: true)
    private var configuration: NativeRPCValue = .null
    private var app: UUID?
    private var agent: BackendMacReachClient?
    private var agentID: UUID?
    private var connections: [UUID: NSXPCConnection] = [:]
    private var boot: MacReachBootHost?
    private var bootStart: Task<Void, Error>?
    private var generation = 0
    private var problem = ""
    private let awake = BackendMacReachAwake()
    private var appExit: DispatchSourceProcess?
    private var trustWatch: DispatchSourceFileSystemObject?
    private var trustFD: Int32 = -1
    private var reread: Task<Void, Never>?

    func run() {
        guard geteuid() == 0, (try? BackendMacReachSigning.requirements()) != nil else { exit(78) }
        // The system location is fixed, root-owned and private; it contains connection settings, never passwords.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { exit(78) }
            defer { Darwin.close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o077 == 0 else { exit(78) }
            let file = directory.appendingPathComponent("configuration.json")
            let configFD = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if configFD >= 0 {
                let handle = FileHandle(fileDescriptor: configFD, closeOnDealloc: true)
                guard fstat(configFD, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o077 == 0,
                      let bytes = try handle.read(upToCount: 65_537), bytes.count <= 65_536 else { exit(78) }
                configuration = try NativeRPCValue.parseJSON(bytes, maximumBytes: 65_536)
            }
        } catch { exit(78) }
        updateAwake() // Hold before networking, sign-in, or access to the user’s home directory.
        listener.delegate = self
        listener.resume()
        if configuration.fields != nil { watchTrust(); watchAppExit(); Task { await takeOver() } }
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirements = try? BackendMacReachSigning.requirements() else { return false }
        // A PID is used only to choose an exact requirement; XPC then enforces that requirement on every message.
        var guest: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else { return false }
        let helper = identifier.hasSuffix(".session-host")
        connection.setCodeSigningRequirement(helper ? requirements.helper : requirements.app)
        let id = UUID(), uid = connection.effectiveUserIdentifier
        let peer = MacReachConnection(connection)
        let object = BackendMacReachRequest { [weak self] command, payload in
            guard let self else { throw Self.unavailable }
            return try await self.handle(command, payload: payload, peer: peer, id: id, uid: uid, helper: helper)
        }
        connection.exportedInterface = NSXPCInterface(with: BackendMacReachRPC.self)
        connection.exportedObject = object
        connection.remoteObjectInterface = NSXPCInterface(with: BackendMacReachRPC.self)
        connection.invalidationHandler = { [weak self] in
            object.cancelAll()
            Task { @MainActor in await self?.lost(id) }
        }
        connection.interruptionHandler = { peer.value?.invalidate() }
        connection.resume()
        Task { @MainActor [weak self] in self?.connections[id] = peer.value }
        return true
    }

    private func handle(_ command: String, payload: Data, peer: MacReachConnection, id: UUID, uid: uid_t, helper: Bool) async throws -> Data {
        guard let connection = peer.value else { throw Self.unavailable }
        guard payload.count <= 1_048_576 else { throw Self.unavailable }
        if helper {
            guard command == "agent", uid == 0 || uid == owner else { throw Self.unavailable }
            // A user's inactive Aqua agent must not replace the active login-window agent.
            let value = try NativeRPCValue.parseJSON(payload)
            let login = value["loginWindow"].bool == true
            guard uid == 0 ? login : Self.consoleUID == uid else { throw Self.unavailable }
            agent?.close(); agentID = id; agent = BackendMacReachClient(connection: connection)
            return try NativeRPCValue.object([.init("ok", .bool(true))]).encodedJSON()
        }
        // First setup must come from the console owner. The already-approved owner remains authorised while locked.
        guard uid > 0, owner.map({ $0 == uid }) ?? (Self.consoleUID == uid) else { throw Self.unavailable }
        switch command {
        case "claim":
            let value = try NativeRPCValue.parseJSON(payload)
            guard let path = value["trustDirectory"].string, let home = getpwuid(uid).map({ String(cString: $0.pointee.pw_dir) }),
                  path.hasPrefix(home + "/"), !path.contains("/../"), URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw Self.unavailable }
            generation += 1
            app = id
            await stopBoot()
            configuration = value.setting("uid", .number(Double(uid))).setting("appPID", .number(Double(connection.processIdentifier)))
            try saveConfiguration()
            try installScreenAgent(uid: uid)
            watchTrust(); watchAppExit()
            updateAwake()
            return try status().encodedJSON()
        case "configure":
            guard app == id else { throw Self.unavailable }
            let value = try NativeRPCValue.parseJSON(payload)
            guard let allowed = value["allowed"].bool, let keep = value["systemKeepAwake"].bool else { throw Self.unavailable }
            configuration = configuration.setting("allowed", .bool(allowed)).setting("systemKeepAwake", .bool(keep))
            try saveConfiguration()
            if !allowed { _ = try? await agent?.request("stop-all", payload: Data()) }
            updateAwake()
            return try status().encodedJSON()
        case "status": return try status().encodedJSON()
        case "disable":
            guard app == nil || app == id else { throw Self.unavailable }
            generation += 1; app = nil
            await stopBoot(); awake.stop()
            trustWatch?.cancel(); trustWatch = nil
            appExit?.cancel(); appExit = nil
            configuration = .null
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("configuration.json"))
            try? FileManager.default.removeItem(atPath: "/Library/LaunchAgents/" + MacReach.agentPlist)
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["bootout", "gui/\(uid)/" + MacReach.agentLabel]
            unload.standardOutput = FileHandle.nullDevice; unload.standardError = FileHandle.nullDevice
            try Self.unload(unload)
            agent?.close(); agent = nil
            return try status().encodedJSON()
        case "close":
            guard app == id, let agent else { throw Self.unavailable }
            return try await agent.request(command, payload: payload)
        case "input":
            guard app == id, let agent else { throw Self.unavailable }
            if configuration["allowed"].bool != true {
                let value = try NativeRPCValue.parseJSON(payload)
                guard macReachIsRelease(try BackendMacReachInput.decode(value)) else { throw Self.unavailable }
            }
            return try await agent.request(command, payload: payload)
        case "rows", "open", "frame", "cursor", "password", "wake":
            guard app == id, configuration["allowed"].bool == true, let agent else { throw Self.unavailable }
            return try await agent.request(command, payload: payload)
        default: throw Self.unavailable
        }
    }
    private static func unload(_ process: Process) throws {
        try process.run()
        process.waitUntilExit()
    }
    private var owner: uid_t? { configuration["uid"].number.map { uid_t($0) } }
    private static var consoleUID: uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil), name as String != "loginwindow", uid > 0 else { return nil }
        return uid
    }
    private func status() -> NativeRPCValue {
        .object([.init("agentConnected", .bool(agent != nil)), .init("bootServing", .bool(boot != nil)),
            .init("keepAwakeActive", .bool(awake.active)), .init("problem", .string(awake.problem ?? problem)), .init("passwordsStored", .bool(false))])
    }
    private func saveConfiguration() throws {
        let bytes = try configuration.encodedJSON()
        try bytes.write(to: directory.appendingPathComponent("configuration.json"), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("configuration.json").path)
    }
    private func stageScreenHelper() throws -> URL {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { throw Self.unavailable }
        let origin = URL(fileURLWithPath: String(cString: path))
        let parent = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.unavailable }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else { throw Self.unavailable }
        let destination = parent.appendingPathComponent("TerminalDeckReach", isDirectory: true)
        let staging = parent.appendingPathComponent(".TerminalDeckReach-" + UUID().uuidString, isDirectory: true)
        let binary = staging.appendingPathComponent("Contents/MacOS/TerminalDeckSessionHostHelper")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.copyItem(at: origin, to: binary)
        let frameworks = origin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.path) {
            try FileManager.default.copyItem(at: frameworks, to: staging.appendingPathComponent("Contents/Frameworks"))
        }
        // Validate the private copy after copying: a changed source cannot race verification of the installed bytes.
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecRequirementCreateWithString(try BackendMacReachSigning.requirements().helper as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw Self.unavailable }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walk = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: keys) else { throw Self.unavailable }
        let entries = walk.compactMap { $0 as? URL }
        guard entries.count < 10_000, entries.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(staging.path + "/") }) else { throw Self.unavailable }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let mode = (try FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try FileManager.default.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0,
                .posixPermissions: values.isDirectory == true || mode & 0o111 != 0 ? 0o755 : 0o644], ofItemAtPath: entry.path)
        }
        let installed = destination.appendingPathComponent("Contents/MacOS/TerminalDeckSessionHostHelper")
        if FileManager.default.fileExists(atPath: destination.path) {
            // An update replaces this owned helper only, never the person's keeper or sessions.
            let old = parent.appendingPathComponent(".TerminalDeckReach-old-" + UUID().uuidString)
            try FileManager.default.moveItem(at: destination, to: old)
            do { try FileManager.default.moveItem(at: staging, to: destination) }
            catch { try? FileManager.default.moveItem(at: old, to: destination); throw error }
            try? FileManager.default.removeItem(at: old)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return installed
    }
    private func installScreenAgent(uid: uid_t) throws {
        // The daemon is approved through SMAppService. LoginWindow agents must be global, not per-user login items.
        // Only this fixed plist and this same signed executable may be installed. No caller supplies an executable.
        let executable = try stageScreenHelper().path
        let plist: [String: Any] = ["Label": MacReach.agentLabel, "ProgramArguments": [executable, MacReach.agentArgument],
            "LimitLoadToSessionType": MacReach.agentSessionTypes, "RunAtLoad": true, "KeepAlive": true,
            "ProcessType": "Interactive", "ThrottleInterval": 5]
        let file = URL(fileURLWithPath: "/Library/LaunchAgents/" + MacReach.agentPlist)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: file.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(uid)", file.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        // An already loaded agent is expected; the XPC connection, not this exit status, proves availability.
    }
    private func lost(_ id: UUID) async {
        connections[id] = nil
        if agentID == id { agent = nil; agentID = nil }
        if app == id { app = nil; await takeOver() }
    }
    private var appPID: pid_t? {
        guard let number = configuration["appPID"].number, number > 1, number <= Double(Int32.max), number.rounded() == number else { return nil }
        return pid_t(number)
    }
    private func ownerAppIsAlive() -> Bool {
        guard let pid = appPID, kill(pid, 0) == 0,
              let text = try? BackendMacReachSigning.requirements().app else { return false }
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }
    private func watchAppExit() {
        appExit?.cancel(); appExit = nil
        guard let pid = appPID, ownerAppIsAlive() else { return }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in Task { @MainActor in await self?.takeOver() } }
        appExit = watch; watch.resume()
    }
    private func stopBoot() async {
        // Keep the old owner local before awaiting: an older start must never stop a newer owner after re-entry.
        let flight = bootStart, current = boot
        bootStart = nil; boot = nil
        flight?.cancel()
        _ = await flight?.result
        await current?.stop()
    }
    private func takeOver() async {
        updateAwake()
        // A broken/restarted XPC connection is not proof the app stopped. Never race its relay socket.
        guard app == nil, !ownerAppIsAlive(), configuration["allowed"].bool == true, let uid = owner,
              let source = configuration["trustDirectory"].string else { return }
        let allowed = BackendMacReachTrust.screenAllowed(trustDirectory: URL(fileURLWithPath: source), owner: uid)
        guard allowed else { await stopBoot(); return }
        generation += 1; let current = generation
        await stopBoot()
        guard generation == current, app == nil, !ownerAppIsAlive() else { return }
        let host = MacReachBootHost()
        do {
            let target = directory.appendingPathComponent("remote", isDirectory: true)
            let roster = try BackendMacReachTrust.stage(from: URL(fileURLWithPath: source), owner: uid, to: target)
            guard roster.controllers > 0 else { updateAwake(); return }
            boot = host
            let name = configuration["name"].string ?? "Mac", version = configuration["appVersion"].string ?? "unknown"
            let flight = Task { try await host.start(directory: target, name: name, version: version, agent: { [weak self] in await self?.agent }) }
            bootStart = flight
            try await flight.value
            guard current == generation, app == nil else { await host.stop(); if boot === host { boot = nil }; return }
            bootStart = nil; problem = ""
            updateAwake()
        } catch {
            await host.stop()
            if boot === host { boot = nil }
            if current == generation {
                bootStart = nil
                problem = "Access before sign-in could not start. Open Devices → Device access → General after signing in."
            }
        }
    }
    private func updateAwake() {
        // Root-owned configuration mirrors the verified General setting. Phone revocation only stops phone access.
        awake.update(enabled: MacReach.bootKeepsAwake(configuration))
    }
    private func watchTrust() {
        trustWatch?.cancel(); trustWatch = nil
        guard let path = configuration["trustDirectory"].string else { return }
        let fd = Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        watch.setCancelHandler { Darwin.close(fd) }
        watch.setEventHandler { [weak self] in Task { @MainActor in
            guard let self else { return }
            self.reread?.cancel()
            self.reread = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                if self.app == nil { await self.takeOver() } else { self.updateAwake() }
            }
        } }
        trustWatch = watch; watch.resume()
    }
    nonisolated private static var unavailable: NativeRPCError {
        .init(code: "mac-access", message: "The Mac sign-in screen is unavailable. Check Devices → Device access → General on your Mac.")
    }
}

@MainActor final class MacReachBootHost {
    private var endpoint: BackendRemoteHost?
    private var relay: BackendRemoteRelayClient?
    private var trust: BackendRemoteTrustStore?
    private var devices: BackendPhoneDevices.Installation?
    func start(directory: URL, name: String, version: String, agent: @escaping @Sendable () async -> BackendMacReachClient?) async throws {
        let trust = BackendRemoteTrustStore(directory: directory)
        self.trust = trust
        try await trust.open()
        try Task.checkCancellation()
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let endpoint = BackendRemoteHost(trust: trust, manager: manager, state: NativeStateStore(), home: "/var/empty",
            hostName: name, appVersion: version, privateRoots: ["/"], screenOnly: true)
        self.endpoint = endpoint
        await endpoint.setLinkEngine(TerminalDeckPeerEngine())
        try Task.checkCancellation()
        let pointers = MacReachPointerCache()
        var source = BackendPhoneDevices.Source(list: { .object([.init("devices", .array([]))]) },
            power: { _, _ in throw NativeRPCError(code: "unavailable", message: "Sign in to your Mac first.") },
            stream: { id, _ in
                return BackendMacReachStream(display: id, agent: {
                    await agent().map { BackendMacReachScreenAgent(client: $0) }
                })
            }, input: { id, input in
                guard let agent = await agent() else { throw Self.noScreen }
                _ = try await agent.value("input", BackendMacReachInput.wire(input, display: id))
            }, shot: { _ in throw Self.noScreen }, deliver: { _ in throw Self.noScreen }, visibleSessions: { _ in [] },
            send: { id, message in try await endpoint.sendToConnection(id, message: message) },
            macRows: {
                guard let agent = await agent(), let value = try? await agent.value("rows") else { return [] }
                let rows = value["devices"].elements ?? []
                pointers.update(rows)
                return rows
            })
        source.direct = { id, data, lane in await endpoint.sendDirect(id, data: data, lane: lane) }
        source.linkVideo = { id in await endpoint.linkVideo(id) }
        source.pointer = { id in pointers.read(id) }
        source.macControlNow = { id in await endpoint.canControlMacScreen(id) }
        source.macState = {
            guard let agent = await agent(), let rows = try? await agent.value("rows") else { return nil }
            pointers.update(rows["devices"].elements ?? [])
            return rows["devices"].elements?.first?["screenState"].string
        }
        source.macSignIn = { id, password in
            guard let agent = await agent() else { throw Self.noScreen }
            _ = try await agent.value("password", .object([.init("id", .string(id)), .init("password", .string(password))]))
        }
        devices = try await BackendPhoneDevices.install(on: endpoint, source: source, ownerID: "mac-reach.screen")
        try Task.checkCancellation()
        try await endpoint.start()
        try Task.checkCancellation()
        guard let relayURL = BackendRelayAddress.resolve() else { throw Self.noScreen }
        let relay = try BackendRemoteRelayClient(url: relayURL, identity: await trust.hostIdentity(), trust: trust, host: endpoint)
        self.relay = relay
        await relay.start()
        try Task.checkCancellation()
    }
    func stop() async {
        await relay?.stop(); relay = nil
        await devices?.stop(); devices = nil
        await endpoint?.stop(); endpoint = nil
        await trust?.close(); trust = nil
    }
    nonisolated private static var noScreen: NativeRPCError {
        .init(code: "unavailable", message: "The Mac sign-in screen is starting. Try again in a moment.")
    }
}

/// NSXPCConnection is thread-safe but not annotated Sendable. A weak box also avoids an exported-object retain cycle.
final class MacReachConnection: @unchecked Sendable {
    weak var value: NSXPCConnection?
    init(_ value: NSXPCConnection) { self.value = value }
}

/// Pointer facts are read in the GUI agent, never by the system daemon. The phone keeps its ordinary local predictor.
final class MacReachPointerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: BackendPhoneDevicePointer] = [:]
    private var main: BackendPhoneDevicePointer?
    func update(_ rows: [NativeRPCValue]) {
        lock.withLock {
            values = [:]; main = nil
            for row in rows.prefix(64) {
                guard let id = row["id"].string, let x = row["pointer"]["x"].number, let y = row["pointer"]["y"].number,
                      x.isFinite, y.isFinite else { continue }
                let pointer = BackendPhoneDevicePointer(x: x, y: y, onDisplay: row["pointer"]["onDisplay"].bool == true,
                    shape: nil, displayWidth: row["pointer"]["width"].number ?? 0)
                values[id] = pointer
                if row["main"].bool == true { main = pointer }
            }
        }
    }
    func read(_ id: String) -> BackendPhoneDevicePointer? { lock.withLock { values[id] ?? main } }
}
