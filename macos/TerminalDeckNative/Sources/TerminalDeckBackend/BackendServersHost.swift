import Foundation

public enum BackendServersHostLinkOutcome: Sendable {
    case linked(machineId: String, machineName: String, deviceFingerprint: String)
    case refused(String)
}
public struct BackendServersHostDependencies: Sendable {
    public var runScript: @Sendable (String, String) async throws -> BackendServersRunResult
    public var linkThisComputer: (@Sendable (String) async -> BackendServersHostLinkOutcome)?
    public var whenReaching: (@Sendable (String, Int) async -> Bool)?
    public var relayWaitMilliseconds: Int
    public var putFile: (@Sendable (String, String, String) async throws -> String)?
    public var hostPackage: @Sendable () -> BackendServersHostPackage?
    public var broadcast: @Sendable (BackendServersHostState) -> Void
    public init(runScript: @escaping @Sendable (String, String) async throws -> BackendServersRunResult,
                linkThisComputer: (@Sendable (String) async -> BackendServersHostLinkOutcome)? = nil,
                whenReaching: (@Sendable (String, Int) async -> Bool)? = nil, relayWaitMilliseconds: Int = 20_000,
                putFile: (@Sendable (String, String, String) async throws -> String)? = nil,
                hostPackage: @escaping @Sendable () -> BackendServersHostPackage?, broadcast: @escaping @Sendable (BackendServersHostState) -> Void = { _ in }) {
        self.runScript = runScript; self.linkThisComputer = linkThisComputer; self.whenReaching = whenReaching
        self.relayWaitMilliseconds = relayWaitMilliseconds; self.putFile = putFile; self.hostPackage = hostPackage; self.broadcast = broadcast
    }
}

/// Mac controller for the existing Linux/macOS headless package. Construction
/// has no side effects. Only an explicitly invoked operation sends a command.
public actor BackendServersHosts {
    private let deps: BackendServersHostDependencies
    private var attempts: [String: BackendServersSetupAttempt] = [:]
    private var states: [String: BackendServersHostState] = [:]
    public init(_ dependencies: BackendServersHostDependencies) { deps = dependencies }
    public var canLink: Bool { deps.linkThisComputer != nil }
    public func carriedPackage() -> BackendServersHostPackage? { deps.hostPackage() }
    public func stateOf(_ serverId: String) -> BackendServersHostState { states[serverId] ?? .init(serverId: serverId) }
    public func look(_ serverId: String) async throws -> BackendServersHostLook {
        BackendServersHostRules.readHostProbe(try await deps.runScript(serverId, BackendServersHostScripts.probe).stdout)
    }
    @discardableResult private func say(_ next: BackendServersHostState) -> BackendServersHostState { states[next.serverId] = next; deps.broadcast(next); return next }
    private func fail(_ serverId: String, attempt: BackendServersSetupAttempt, line: String, detail: String = "", done: [String] = [], installed: Bool = true) -> BackendServersHostState {
        if let current = attempts[serverId], current.id != attempt.id { return stateOf(serverId) }
        attempts[serverId] = nil
        return say(.init(serverId: serverId, step: .failed, line: line, detail: detail, done: done, weInstalled: installed))
    }
    public func install(_ serverId: String, shell: any BackendServersShell, look: BackendServersHostLook, serverName: String) async -> BackendServersHostState {
        await cancel(serverId)
        let attempt = BackendServersSetupAttempt(serverId: serverId); attempts[serverId] = attempt
        var done: [String] = []
        say(.init(serverId: serverId, step: .checking, line: "Checking what \(serverName) has.", weInstalled: true))
        if let refusal = BackendServersHostRules.whyNotHost(look.room) { return fail(serverId, attempt: attempt, line: refusal, installed: false) }
        guard let pack = deps.hostPackage() else { return fail(serverId, attempt: attempt, line: "This copy of the app does not carry the host package any more.", installed: false) }
        guard let put = deps.putFile else { return fail(serverId, attempt: attempt, line: "This build cannot put a file on a server, so it cannot install one from here.", installed: false) }
        done.append(BackendServersHostRules.usableNode(look.room) ? "\(serverName) has Node \(look.room.node) and npm, so no runtime is needed." : "\(serverName) has no Node 22 or newer, so the installer will fetch one and check it.")
        say(.init(serverId: serverId, step: .uploading, line: "Copying the host package to \(serverName).", done: done, weInstalled: true))
        let installer: String; let tarball: String
        do {
            installer = try await put(serverId, pack.installer, "install.sh")
            guard !attempt.cancelled else { return fail(serverId, attempt: attempt, line: "Stopped before \(serverName) had finished installing it.", done: done, installed: false) }
            tarball = try await put(serverId, pack.tarball, "\(BackendSharedBrand.id)-\(pack.version).tgz")
        } catch { return fail(serverId, attempt: attempt, line: "The host package could not be copied to this server.", detail: error.localizedDescription, done: done, installed: false) }
        done.append("Copied the package to \(tarball).")
        if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped before \(serverName) had finished installing it.", done: done, installed: false) }
        say(.init(serverId: serverId, step: .installing, line: "Installing on \(serverName). This takes a minute or two.", done: done, weInstalled: true))
        let line = "TERMINALDECK_PACKAGE=\(BackendServersHostRules.shellQuote(tarball)) sh \(BackendServersHostRules.shellQuote(installer)); echo \(BackendServersHostRules.done) $?"
        let tape = BackendServersSetupTape(shell); defer { tape.close() }
        attempt.setStop { shell.write("\u{03}") }; attempt.setWake { tape.close() }
        shell.write(line + "\n")
        let code = (await tape.next(BackendServersHostRules.done + #" (\d+)"#, milliseconds: 12 * 60 * 1000)).flatMap(Int.init) ?? -1
        attempt.setStop(nil); attempt.setWake(nil)
        if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped before \(serverName) had finished installing it.", done: done, installed: false) }
        if code != 0 {
            return fail(serverId, attempt: attempt, line: "The host could not be installed on \(serverName).", detail: code == -1 ? "It was still running after twelve minutes, so this stopped waiting for it." : "The installer ended with \(code). Its own output is in the terminal above.", done: done, installed: false)
        }
        do {
            let after = try await self.look(serverId)
            if after.host.command.isEmpty { return fail(serverId, attempt: attempt, line: "The install finished and there is no \(BackendSharedBrand.id) command on this server.", done: done, installed: false) }
            done.append("Installed \(after.host.version.isEmpty ? "the host" : after.host.version) at \(after.host.command).")
            say(.init(serverId: serverId, step: .service, line: "Setting it to start on its own.", done: done, weInstalled: true))
            done.append(try await startIt(serverId, command: after.host.command, room: look.room))
            if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped before it had asked for a pairing code.", done: done) }
            return await link(serverId, shell: shell, command: after.host.command, done: done)
        } catch { return fail(serverId, attempt: attempt, line: "The host setup stopped before it finished.", detail: error.localizedDescription, done: done) }
    }
    private func startIt(_ serverId: String, command: String, room: BackendServersHostRoom) async throws -> String {
        if room.systemdUser {
            let result = try await deps.runScript(serverId, BackendServersHostScripts.service(command))
            if result.code == 0 { return result.stdout.contains("linger yes") ? "It runs as a systemd user service and keeps running when you log out." : "It runs as a systemd user service. It will stop when your last login on this server ends — running `sudo loginctl enable-linger $(id -un)` once on that server is what stops that." }
        }
        let started = try await deps.runScript(serverId, BackendServersHostScripts.startDirectly(command))
        return started.code == 0 ? "This server has no systemd user manager, so it was started directly. It is running now and will not come back on its own after a reboot." : "It is installed and not running. Start it on that server with `\(BackendSharedBrand.id) pair`."
    }
    public func pairDevice(_ serverId: String, shell: any BackendServersShell, command: String, done: [String] = []) async -> BackendServersHostState {
        let attempt = attempts[serverId] ?? BackendServersSetupAttempt(serverId: serverId); attempts[serverId] = attempt
        say(.init(serverId: serverId, step: .pairing, line: "Asking it for a pairing code.", done: done, weInstalled: true))
        let tape = BackendServersSetupTape(shell); defer { tape.close() }
        attempt.setStop { shell.write("\u{03}") }; attempt.setWake { tape.close() }
        shell.write(BackendServersHostRules.shellQuote(command) + " pair --kind mine\n")
        let code = await tape.next(BackendServersHostRules.codePattern, milliseconds: 30_000)
        attempt.setWake(nil)
        guard let code else { return fail(serverId, attempt: attempt, line: attempt.cancelled ? "Stopped before it had printed a pairing code." : "It did not print a pairing code.", detail: "Whatever it did print is in the terminal above.", done: done) }
        // This code is for a phone. Its unknown fingerprint must be approved by
        // the person at the PTY; no auto-approval or redemption occurs here.
        return say(.init(serverId: serverId, step: .done, line: "It is running and showing a code for a phone.", done: done + ["It printed a pairing code."], code: code, weInstalled: true))
    }
    public func link(_ serverId: String, shell: any BackendServersShell, command: String, done: [String] = []) async -> BackendServersHostState {
        guard let redeem = deps.linkThisComputer else { return await pairDevice(serverId, shell: shell, command: command, done: done) }
        let attempt = attempts[serverId] ?? BackendServersSetupAttempt(serverId: serverId); attempts[serverId] = attempt
        say(.init(serverId: serverId, step: .pairing, line: "Linking it to this computer.", done: done, weInstalled: true))
        let tape = BackendServersSetupTape(shell); defer { tape.close(); attempt.setWake(nil) }
        attempt.setStop { shell.write("\u{03}") }; attempt.setWake { tape.close() }
        var linked: (id: String, name: String, fingerprint: String)?
        for go in 1...3 {
            _ = await waitForRelay(serverId, attempt: attempt)
            if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped before it had asked for a pairing code.", done: done) }
            tape.forget()
            shell.write(BackendServersHostRules.shellQuote(command) + " pair --kind mine\n")
            guard let code = await tape.next(BackendServersHostRules.codePattern, milliseconds: 30_000) else {
                return fail(serverId, attempt: attempt, line: attempt.cancelled ? "Stopped before it had printed a pairing code." : "It did not print a pairing code.", detail: attempt.cancelled ? "" : "Whatever it did print is in the terminal above.", done: done)
            }
            // The spent code stays on the authenticated connection and is never
            // placed on any state pushed to a window.
            let outcome = await redeem(code)
            if attempt.cancelled {
                let detail: String
                if case .linked(_, let name, _) = outcome { detail = "This computer paired with that host as \(name), and nothing approved it, so it can reach nothing yet. Link this computer again to finish it with a fresh code." } else { detail = "" }
                return fail(serverId, attempt: attempt, line: "Stopped while linking.", detail: detail, done: done)
            }
            switch outcome {
            case .linked(let id, let name, let fingerprint): linked = (id, name, fingerprint)
            case .refused(let message):
                shell.write("\u{03}")
                if go < 3 { continue }
                let why = await whyNothingAnswered(serverId)
                return fail(serverId, attempt: attempt, line: "The host is installed and running, and could not be linked to this computer.",
                            detail: [message, why, "A fresh code was minted and offered 3 times. Press Link this computer to try again."].filter { !$0.isEmpty }.joined(separator: " "), done: done)
            }
            if linked != nil { break }
        }
        guard let linked else { return fail(serverId, attempt: attempt, line: "The host could not be linked to this computer.", done: done) }
        guard let shown = await tape.next(BackendServersHostRules.fingerprintPattern, milliseconds: 45_000) else {
            if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped before that host had shown the new device.", done: done) }
            shell.write("\u{03}")
            return fail(serverId, attempt: attempt, line: "This computer paired with that host, and the host never said so.", detail: "The terminal printed no new device, so there was no fingerprint to check and nothing to approve. This computer is left paired and unapproved over there, which can reach nothing. Link this computer again to try with a fresh code.", done: done)
        }
        guard shown == linked.fingerprint else {
            shell.write("n\n")
            return fail(serverId, attempt: attempt, line: "Something other than this computer answered that pairing code.", detail: "That host is showing \(shown), and this computer paired as \(linked.fingerprint). It was refused rather than approved, so nothing was let in: whatever did answer is left over there paired and unapproved, which can reach nothing, and so is this computer. Link this computer again to try with a fresh code.", done: done)
        }
        shell.write("y\n")
        let verdict = await tape.next(BackendServersHostRules.verdictPattern, milliseconds: 30_000)
        guard verdict == "Approved as your own device" else {
            return fail(serverId, attempt: attempt, line: attempt.cancelled ? "Stopped before that host had answered the approval." : "That host did not approve this computer.", detail: attempt.cancelled ? "" : verdict == nil ? "It never answered the approval. Its own output is in the terminal above." : "It said so itself; its words are in the terminal above.", done: done)
        }
        say(.init(serverId: serverId, step: .pairing, line: "Approved. Waiting for this computer to reach it.", done: done, weInstalled: true))
        let reaching = await deps.whenReaching?(linked.id, 20_000) ?? true
        if attempt.cancelled { return fail(serverId, attempt: attempt, line: "Stopped while linking.", done: done) }
        attempts[serverId] = nil; attempt.setStop(nil)
        return say(.init(serverId: serverId, step: .done,
                         line: reaching ? "It is running, and linked to this computer." : "It is running and linked to this computer, and this computer has not reached it yet.",
                         detail: reaching ? "" : "That host approved this computer, and no connection to it has come up since. It usually takes a second or two. If the section above still says nothing is reaching it, press Link this computer to pair again with a fresh code.",
                         done: done + ["It is linked to this computer as \(linked.name), approved as your own device."], weInstalled: true))
    }
    private func waitForRelay(_ serverId: String, attempt: BackendServersSetupAttempt) async -> BackendServersHostRelay {
        let ceiling = max(0, deps.relayWaitMilliseconds), end = Date().addingTimeInterval(Double(ceiling) / 1000)
        while true {
            guard let reading = try? await look(serverId) else { return .unknown }
            let seen = BackendServersHostRules.relayState(reading.host.status)
            if seen != .notConnected || attempt.cancelled || Date() >= end { return seen }
            try? await Task.sleep(for: .milliseconds(min(2_000, ceiling)))
        }
    }
    private func whyNothingAnswered(_ serverId: String) async -> String {
        guard let reading = try? await look(serverId) else { return "" }
        switch BackendServersHostRules.relayState(reading.host.status) {
        case .connected: return "That host says it is connected to the relay, so the code was published and simply was not answered in time. Linking again mints a fresh one."
        case .notConnected, .off:
            let word = BackendServersHostRules.relayState(reading.host.status) == .off ? "off" : "not connected"
            return "That host says its relay is \(word), so there was nothing at the relay to answer for the code. It has just started; give it a moment and link again."
        case .unknown: return ""
        }
    }
    public func uninstall(_ serverId: String, look: BackendServersHostOnServer, alsoData: Bool) async -> BackendServersHostState {
        await cancel(serverId)
        if look.command.isEmpty { return say(.init(serverId: serverId, step: .failed, line: "There is nothing here for this app to remove.")) }
        say(.init(serverId: serverId, step: .removing, line: "Stopping it and taking it off this server."))
        do {
            let result = try await deps.runScript(serverId, BackendServersHostScripts.remove(look.command, dataDir: look.dataDir, alsoData: alsoData))
            if result.code != 0 { return say(.init(serverId: serverId, step: .failed, line: "That could not be removed from this server.", detail: BackendServersSetupWire.trim(result.stderr))) }
            return say(.init(serverId: serverId, line: "It was removed from this server.", done: ["The host program is gone, and its service with it.", alsoData ? "\(look.dataDir) is gone too, so any device paired to it will need pairing again." : "\(look.dataDir) was left alone — the devices paired to it and the folders each of them may use are still there for a later install."]))
        } catch { return say(.init(serverId: serverId, step: .failed, line: "That could not be removed from this server.", detail: error.localizedDescription)) }
    }
    public func cancel(_ serverId: String) async { if let attempt = attempts.removeValue(forKey: serverId) { await attempt.clean() } }
    public func cancelAll() async { for id in Array(attempts.keys) { await cancel(id) } }
    public func forget(_ serverId: String) { states[serverId] = nil }
}
