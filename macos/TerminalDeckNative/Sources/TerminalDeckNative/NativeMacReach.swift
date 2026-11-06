import AppKit
import Foundation
import Observation
import ServiceManagement
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Devices owns helper setup; General owns the one power setting. Construction is read only.
@MainActor @Observable final class NativeMacReach {
    static let shared = NativeMacReach()
    private(set) var registration: MacReach.Registration = .notRegistered
    private(set) var keepAwake = false
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var agentConnected = false
    private(set) var keepAwakeActive = false
    @ObservationIgnored private(set) var client: BackendMacReachClient?
    @ObservationIgnored private var trustDirectory: URL?
    @ObservationIgnored private var powerSubscription: EngineSubscription?
    init() {}
    static func fixture(registration: MacReach.Registration) -> NativeMacReach {
        let model = NativeMacReach()
        model.registration = registration
        model.agentConnected = registration == .enabled
        return model
    }
    private var service: SMAppService { .daemon(plistName: MacReach.daemonPlist) }
    var available: Bool { client != nil && agentConnected }
    /// Scratch copies cannot claim the production service name, launch it, or register a helper.
    var releaseBundle: Bool { Bundle.main.bundleIdentifier == "dev.terminaldeck.app" && Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true }

    func prepare(trust: BackendRemoteTrustStore) async {
        trustDirectory = trust.directory
        if powerSubscription == nil {
            powerSubscription = EngineBridge.shared.on("power:lid-awake:state") { [weak self] args in
                guard let state = LidAwakeState.decode(args.first), state.known else { return }
                Task { @MainActor in await self?.powerChanged(on: state.on, active: state.idleBlocked) }
            }
        }
        await refreshPower()
        await refresh()
    }
    private func readRegistration() -> MacReach.Registration {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notFound: return .notBundled
        @unknown default: return .unknown
        }
    }
    func refresh() async {
        guard releaseBundle else { registration = .notBundled; return }
        registration = readRegistration()
        guard registration == .enabled, let trustDirectory else { return }
        do {
            if client == nil {
                let connection = try BackendMacReachClient()
                _ = try await connection.value("claim", .object([.init("trustDirectory", .string(trustDirectory.path)),
                    .init("name", .string(Host.current().localizedName ?? "Mac")), .init("allowed", .bool(NativeMacScreenSetting.allowed)),
                    .init("systemKeepAwake", .bool(keepAwake)),
                    .init("appVersion", .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"))]))
                client = connection
            }
            if let status = try await client?.value("status") {
                agentConnected = status["agentConnected"].bool == true
                keepAwakeActive = keepAwakeActive || status["keepAwakeActive"].bool == true
                let line = status["problem"].string ?? ""
                problem = line.isEmpty ? nil : line
            }
        } catch { client?.close(); client = nil; agentConnected = false; problem = deckMessage(error) }
    }
    /// Invoked only by an explicit person action (or an approved MCP action). No automatic registration at launch.
    func enable() async throws {
        guard releaseBundle else { throw NativeRPCError(code: "unavailable", message: "Access before sign-in needs the signed release app.") }
        busy = true; defer { busy = false }
        do {
            _ = try MacReach.enableHelper(isRelease: releaseBundle, status: { self.readRegistration() }, register: { try self.service.register() })
            await refresh()
        } catch { problem = "The access helper could not be registered. Try again from the installed release app."; throw error }
    }
    func disable() async throws {
        guard releaseBundle else { throw NativeRPCError(code: "unavailable", message: "Access before sign-in needs the signed release app.") }
        busy = true; defer { busy = false }
        if let client { _ = try await client.value("disable") }
        try await service.unregister()
        client?.close(); client = nil; agentConnected = false
        await refresh()
    }
    func setKeepAwake(_ enabled: Bool) async throws {
        let answer = LidAwakeResult.decode(try await EngineBridge.shared.invoke("power:lid-awake:set", [enabled]))
        if let state = answer.state, state.known { await powerChanged(on: state.on, active: state.idleBlocked) }
        guard !answer.isWarning else { throw NativeRPCError(code: "power", message: answer.message) }
    }
    private func powerChanged(on: Bool, active: Bool) async {
        keepAwake = on; keepAwakeActive = active
        await permissionsChanged()
    }
    func permissionsChanged() async {
        do { _ = try await client?.value("configure", .object([.init("allowed", .bool(NativeMacScreenSetting.allowed)), .init("systemKeepAwake", .bool(keepAwake))])) }
        catch { problem = "The helper could not confirm the new setting. Check again before leaving this Mac." }
    }
    func refreshPower() async {
        do {
            if let state = LidAwakeState.decode(try await EngineBridge.shared.invoke("power:lid-awake:get")), state.known {
                await powerChanged(on: state.on, active: state.idleBlocked)
            }
        } catch { problem = "The Mac's keep-awake setting could not be read." }
    }
    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    static func openRemoteLogin() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_RemoteLogin") { NSWorkspace.shared.open(url) }
    }
    func status() async -> NativeRPCValue {
        registration = releaseBundle ? readRegistration() : .notBundled
        if registration == .enabled, let client, let fresh = try? await client.value("status") {
            agentConnected = fresh["agentConnected"].bool == true
        } else { agentConnected = false }
        return .object([.init("helper", .string(registration.rawValue)), .init("agentConnected", .bool(agentConnected)),
            .init("keepAwake", .bool(keepAwake)), .init("keepAwakeOnPower", .bool(keepAwake)), .init("keepAwakeActive", .bool(keepAwakeActive)),
            .init("fileVault", .string(MacReach.diskDetail)), .init("problem", problem.map(NativeRPCValue.string) ?? .null)])
    }
    func screenRows() async -> [NativeRPCValue]? {
        guard let client else { return nil }
        do { return try await client.value("rows")["devices"].elements }
        catch { return nil }
    }
    func stream(_ id: String) async throws -> any BackendPhoneDeviceStream {
        // A daemon restart invalidates XPC but leaves the app and its relay alive. Reclaim it once on a new watch.
        await refresh()
        if client == nil { await refresh() }
        guard let client else { throw NativeRPCError(code: "unavailable", message: MacReach.State.setup.words) }
        return BackendMacReachStream(client: client, display: id)
    }
    func input(_ id: String, _ input: BackendPhoneDeviceInput) async throws {
        guard let client else { throw NativeRPCError(code: "unavailable", message: MacReach.State.setup.words) }
        _ = try await client.value("input", BackendMacReachInput.wire(input, display: id))
    }
}

/// A watch survives the GUI session changing: the capture source changes, while the phone's approved connection and
/// video encoder stay in place. State is checked only when the existing video pump asks for its next frame.
actor NativeMacReachSwitchingStream: BackendPhoneDeviceStream {
    let display: String
    private var current: (any BackendPhoneDeviceStream)?
    private var usingHelper = false
    private var stopped = false
    private var reason = ""
    private let mayWake: Bool
    private let progress: @Sendable (String) async -> Void
    private var phoneDrawsPointer = false
    private let local: @Sendable (String) async throws -> any BackendPhoneDeviceStream
    private let helper: @Sendable (String) async throws -> any BackendPhoneDeviceStream
    private let isLocked: @Sendable () -> Bool
    private let helperApproved: @Sendable () async -> Bool
    init(display: String,
         local: @escaping @Sendable (String) async throws -> any BackendPhoneDeviceStream = { try await NativeMacScreen.stream($0) },
         helper: @escaping @Sendable (String) async throws -> any BackendPhoneDeviceStream = { try await NativeMacReach.shared.stream($0) },
         isLocked: @escaping @Sendable () -> Bool = { NativeMacScreen.screenState == .locked },
         helperApproved: @escaping @Sendable () async -> Bool = { await NativeMacReach.shared.registration == .enabled }) {
        self.local = local; self.helper = helper; self.isLocked = isLocked; self.helperApproved = helperApproved
        self.display = display
        mayWake = MacScreenAvailability.mayWake
        progress = MacScreenAvailability.progress
    }
    func endReason() -> String { reason }
    func isStarting() async -> Bool { await current?.isStarting() ?? false }
    func stop() async { stopped = true; await current?.stop(); current = nil }
    func drawsPointer(_ phone: Bool) async { phoneDrawsPointer = phone; await current?.drawsPointer(phone) }
    func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        guard !stopped else { return .ended }
        do {
            // Keep a working stream when the Mac locks. Try local capture before requiring the optional helper.
            if current == nil {
                do {
                    current = try await MacScreenAvailability.$mayWake.withValue(mayWake) {
                        try await MacScreenAvailability.$progress.withValue(progress) { try await local(display) }
                    }
                } catch {
                    guard mayWake, isLocked(),
                          await helperApproved() else { throw error }
                    current = try await helper(display)
                    usingHelper = true
                }
                await current?.drawsPointer(phoneDrawsPointer)
            }
            guard let current else { return .ended }
            let next = await current.pixels(within: seconds)
            if case .ended = next {
                reason = await current.endReason()
                if !usingHelper, mayWake, isLocked(),
                   await helperApproved() {
                    await current.stop()
                    self.current = try await helper(display)
                    usingHelper = true
                    await self.current?.drawsPointer(phoneDrawsPointer)
                    return await self.current?.pixels(within: seconds) ?? .ended
                }
            }
            return next
        } catch {
            reason = (error as? NativeRPCError)?.message ?? "The Mac screen could not be opened. Try again."
            return .ended
        }
    }
}
