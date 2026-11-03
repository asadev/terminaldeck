import Foundation
import TerminalDeckNativeCore

/// Read-only engine adapter for guided setup. It shares the actual Stays Fixed
/// provisioner, pinned package and driver; it owns no checks or project state.
public actor BackendSFXSetupPlanner {
    private let userData: URL
    private let executable: String?
    private let inherited: [String: String]
    private let locate: @Sendable () throws -> BackendStaysFixedEngineHome
    private let loginPath: @Sendable () async throws -> String
    private let provisioning: (any BackendStaysFixedProvisioning)?
    private var ready: (any BackendStaysFixedEngineRunning)?

    public init(userData: URL, executable: String?, inheritedEnvironment: [String: String],
                locate: @escaping @Sendable () throws -> BackendStaysFixedEngineHome,
                loginPath: @escaping @Sendable () async throws -> String,
                provisioning: (any BackendStaysFixedProvisioning)? = nil) {
        self.userData = userData; self.executable = executable; inherited = inheritedEnvironment
        self.locate = locate; self.loginPath = loginPath; self.provisioning = provisioning
    }

    /// Tests supply the real ready engine against the copied sample project.
    public init(engine: any BackendStaysFixedEngineRunning) {
        ready = engine; userData = URL(fileURLWithPath: "/")
        executable = nil; inherited = [:]; provisioning = nil
        locate = { throw NativeRPCError(code: "unavailable", message: "The supplied setup engine is unavailable.") }
        loginPath = { "/usr/bin:/bin" }
    }

    private func engine(prepare: Bool) async throws -> any BackendStaysFixedEngineRunning {
        if let ready { return ready }
        let found: BackendStaysFixedEngineHome, node: String
        if let provisioning {
            let install: BackendNodelessStaysFixedInstall
            if prepare { install = try await provisioning.prepare() }
            else if let installed = await provisioning.installed() { install = installed }
            else { throw BackendStaysFixedNotDownloaded(note: provisioning.pendingNote) }
            found = try install.engineHome(); node = install.node.path
        } else {
            found = try locate()
            guard let executable else { throw NativeRPCError(code: "unavailable", message: "This build is missing the Stays Fixed runtime. Update Terminal Deck, then try again.") }
            node = executable
        }
        let path = try await loginPath()
        try Task.checkCancellation()
        let shim = BackendStaysFixedEngineFiles.ensureShim(userData.appendingPathComponent("staysfixed/bin"), executable: node)
        let driver = BackendStaysFixedEngine(home: found, executable: node, shim: shim, path: path, environment: inherited)
        ready = driver; return driver
    }

    public func plan(_ project: String, prepareRuntime: Bool = false) async throws -> NativeRPCValue {
        let root = try BackendStaysFixedWhere.folder(.string(project))
        let driver: any BackendStaysFixedEngineRunning
        do { driver = try await engine(prepare: prepareRuntime) }
        catch is CancellationError { throw CancellationError() }
        catch let pending as BackendStaysFixedNotDownloaded { throw pending }
        catch {
            let detail = error.localizedDescription
            let missingBuild = detail.localizedCaseInsensitiveContains("not part of this build") || detail.localizedCaseInsensitiveContains("incomplete") || detail.localizedCaseInsensitiveContains("packaging")
            throw NativeRPCError(code: "unavailable", message: detail + (missingBuild ? " Update and reopen Terminal Deck, then try Prepare Stays Fixed again." : " Check your internet connection and free disk space, then try Prepare Stays Fixed again."))
        }
        let result = await driver.cli(["init", "--dry-run", "--json", "--offline"], cwd: root, timeout: 120_000, keep: nil, onEvent: { _ in })
        try Task.checkCancellation()
        guard !result.cancelled, !result.timedOut, result.code == 0,
              let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout), raw["ok"].bool == true,
              raw["plan"]["config"]["text"].string != nil else {
            let raw = BackendStaysFixedEngineFiles.lastJSON(result.stdout)
            let detail = raw?["error"]["message"].string ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = result.cancelled ? "Setup preview was stopped." : result.timedOut ? "Setup preview took too long." : detail.isEmpty ? "The bundled engine could not read this project." : String(detail.prefix(1200))
            throw NativeRPCError(code: "failed", message: reason + " Try the preview again. If it still fails, check that the project folder is readable.")
        }
        return raw["plan"]
    }
}
