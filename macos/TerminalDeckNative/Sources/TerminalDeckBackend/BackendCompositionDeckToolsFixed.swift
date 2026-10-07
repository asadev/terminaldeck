import Foundation
import TerminalDeckNativeCore

/// fixed.* over the page's one Stays Fixed actor (`BackendCompositionClients.staysFixed`),
/// staysfixed/ipc.ts:118-131 `fixedToolDeps`: the service's methods as closures,
/// so a check Hoot starts is the check the page shows, and a second check joins
/// it. Folder grants (known + runnable project) and consent are the factory's.
///
/// D2 (NIGHT-PLAN.md): Stays Fixed fetches its own Node only when someone sets
/// up or checks a project. `status` already reads without downloading
/// (`engine(download: false)`); `readiness` (fixed.status `machine`) and
/// `markGood` would otherwise fetch it, so while nothing is downloaded they
/// answer with the add-on's own pending sentence instead. `provisioning` is
/// the same `BackendCompositionClientsDependencies.staysFixedProvisioning`
/// the service was built with; nil means the transitional bundled runtime,
/// which never downloads.
public struct BackendCompositionDeckToolsFixed: BackendDeckToolsAppFixedService, Sendable {
    private let service: BackendStaysFixedService
    private let provisioning: (any BackendStaysFixedProvisioning)?
    public init(service: BackendStaysFixedService, provisioning: (any BackendStaysFixedProvisioning)?) {
        self.service = service; self.provisioning = provisioning
    }

    private func requireDownloaded() async throws {
        guard let provisioning, await provisioning.installed() == nil else { return }
        throw BackendStaysFixedNotDownloaded(note: provisioning.pendingNote)
    }
    private static func present(_ value: NativeRPCValue) -> NativeRPCValue? { value.isNullish ? nil : value }

    public func status(_ project: String) async throws -> NativeRPCValue { await service.status(project) }
    public func readiness(_ project: String, refresh: Bool) async throws -> NativeRPCValue {
        try await requireDownloaded()
        return try await service.readiness(project, refresh: refresh)
    }
    public func setup(_ project: String) async throws -> NativeRPCValue { try await service.setup(project) }
    /// Joins a running check; the factory's bounded wait never cancels it.
    public func check(_ project: String, by: String) async throws -> NativeRPCValue { try await service.check(project, by: by) }
    public func progress(_ project: String) async throws -> NativeRPCValue? { Self.present(await service.progress(project)) }
    public func stop(_ project: String) async throws -> Bool { await service.stop(project) }
    public func waitFor(_ project: String, milliseconds: Int) async throws -> NativeRPCValue? {
        Self.present(await service.waitFor(project, milliseconds: milliseconds))
    }
    public func results(_ project: String, full: Bool) async throws -> NativeRPCValue? {
        Self.present(await service.results(project, full: full))
    }
    public func markGood(_ project: String, anyway: Bool) async throws -> NativeRPCValue {
        try await requireDownloaded()
        return try await service.markGood(project, anyway: anyway)
    }
    public func setAgents(_ project: String, on: Bool) async throws -> NativeRPCValue { try await service.setAgents(project, on: on) }
}
