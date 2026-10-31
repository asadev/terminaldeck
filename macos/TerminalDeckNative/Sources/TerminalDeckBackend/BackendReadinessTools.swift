import Foundation
import TerminalDeckNativeCore

/// Concrete macOS package-manager execution, invoked only by an explicitly
/// authorised fix. Construction does not resolve PATH or start a child.
public struct BackendReadinessTools: Sendable {
    public struct Outcome: Sendable { public let ok: Bool, output: String }
    private let providers: BackendNativeProviders
    private let executor: BackendDevProcessExecutor
    private let authority: BackendFilesystemAuthority
    private let inherited: [String: String]
    private let home: String
    private let guestPlan: (@Sendable (NativeRPCContext, BackendGitExecutionPlan) async throws -> BackendGitExecutionPlan)?
    public init(providers: BackendNativeProviders, executor: BackendDevProcessExecutor, authority: BackendFilesystemAuthority,
                inheritedEnvironment: [String: String], home: String,
                guestPlan: (@Sendable (NativeRPCContext, BackendGitExecutionPlan) async throws -> BackendGitExecutionPlan)? = nil) {
        self.providers = providers; self.executor = executor; self.authority = authority; inherited = inheritedEnvironment; self.home = home; self.guestPlan = guestPlan
    }
    public func run(_ command: String, arguments: [String], cwd: String, timeout: Int, context: NativeRPCContext) async throws -> Outcome {
        guard ["npm", "brew", "gemini"].contains(command), (1...600_000).contains(timeout) else { throw NativeRPCError.invalidArguments("This readiness executor only accepts the supported package-manager and agent operations.") }
        _ = try await authority.authorize(cwd, context: context, intent: .write)
        let path = try await providers.loginPath()
        guard let executable = BackendNativeProviders.lookup(command, path: path) else { return Outcome(ok: false, output: "\(command) is not on the login shell's PATH.") }
        var environment = BackendSessionEnvironment.stripInherited(inherited); environment["PATH"] = path; environment["CI"] = "1"; environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        var plan = BackendGitExecutionPlan(command: executable, arguments: arguments, environment: environment, cwd: cwd)
        if context.caller == .pairedDevice || context.caller == .page {
            guard let guestPlan else { throw NativeRPCError(code: "missing-capability", message: "This caller has no enforced guest environment for readiness tool execution.") }
            plan = try await guestPlan(context, plan)
        }
        let result = try await executor.run(command: plan.command, arguments: plan.arguments, environment: plan.environment, cwd: plan.cwd, timeoutMilliseconds: timeout, maximumBytes: 1_048_576)
        return Outcome(ok: result.ok, output: String((result.stdout + "\n" + result.stderr).suffix(4000)))
    }
    public func upgradeGemini(context: NativeRPCContext) async throws -> ReadinessFixResult {
        guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "A guest or Page cannot upgrade a machine-wide agent CLI.") }
        let beforePath = try await providers.loginPath(), before = await providers.resolveBinary("gemini", path: beforePath, refresh: true)
        guard let beforeVersion = before.version, before.runnable != nil else { return .init(ok: false, message: "Gemini CLI is not installed or its current version could not be read.") }
        let brew = try await run("brew", arguments: ["list", "--formula", "--versions", "gemini-cli"], cwd: home, timeout: 20_000, context: context)
        let route: String
        if brew.ok { route = "brew" }
        else { let npm = try await run("npm", arguments: ["ls", "-g", "--depth=0", "@google/gemini-cli"], cwd: home, timeout: 20_000, context: context); guard npm.ok else { return .init(ok: false, message: "Neither Homebrew nor npm reports owning this Gemini CLI installation. Upgrade it through the route that installed it.") }; route = "npm" }
        let result = try await run(route, arguments: route == "brew" ? ["upgrade", "gemini-cli"] : ["install", "-g", "@google/gemini-cli@latest"], cwd: home, timeout: 600_000, context: context)
        await providers.resetCaches(); let afterPath = try await providers.loginPath(), after = await providers.resolveBinary("gemini", path: afterPath, refresh: true)
        guard let version = after.version, after.runnable != nil else { return .init(ok: false, message: "The package manager completed, but the runnable Gemini CLI version could not be confirmed.") }
        guard version != beforeVersion else { return .init(ok: false, message: "Gemini CLI still reports \(beforeVersion); its version did not change. " + String(result.output.suffix(400))) }
        return .init(ok: true, message: "Upgraded Gemini CLI from \(beforeVersion) to \(version). Sign in again if needed.", changed: [])
    }
}
