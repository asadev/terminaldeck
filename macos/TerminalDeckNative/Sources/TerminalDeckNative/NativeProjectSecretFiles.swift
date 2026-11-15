import Foundation
import SystemConfiguration
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Project secret files (14 Nov): the app's side of `BackendProjectSecretFilesStore`. The store joins saved passwords
/// with the other stores (`NativeCloudSecretsOwners.live`), so it is sealed with that key, opened only by his computers
/// that hold it, and only while saved passwords are on.
@MainActor
enum NativeProjectSecretFiles {
    /// Where the ledger, the sealed waiting arrivals and the stricter setting live (folder 0700, files 0600).
    nonisolated static func stateRoot(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("project-secret-files", isDirectory: true) }

    /// One store for one identity. `requireWriter`: the app's own check (a read-only copy never writes his folders).
    static func store(production: NativeCompositionProduction, dataRoot: URL,
                      requireWriter: @escaping @Sendable () throws -> Void) -> BackendProjectSecretFilesStore {
        let registry = production.root.registry
        let source = Source(production)
        let made = BackendProjectSecretFilesStore(stateRoot: stateRoot(dataRoot),
            projects: {
                guard let authority = await source.authority(), let context = try? authority.localContext(),
                      let list = try? await NativeCompositionProduction.registeredProjects(registry: registry, context: context) else { return [] }
                return list.map { .init(id: $0.id, name: $0.name, folders: $0.folders) }
            },
            deviceName: { deviceName() },
            gate: { await gate() },
            requireWriter: requireWriter,
            deleteGate: { await deleteRuleGate() },
            deleteStamp: { await deleteIdentity()?.at },
            deleteDevice: { await deleteIdentity()?.mac ?? "" },
            deleteMacName: { await macName($0) })
        BackendProjectSecretFilesHolder.shared.stateRoot = stateRoot(dataRoot)
        return made
    }

    nonisolated static func deleteRuleGate() async -> Bool {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return false }
        return await store.cloudDeleteRuleIsOpen()
    }
    nonisolated static func deleteIdentity() async -> (mac: String, at: Int64)? {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return nil }
        return await store.projectSecretDeleteIdentity()
    }

    nonisolated static func macName(_ id: String) async -> String? {
        await MainActor.run {
            NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
                .flatMap { BackendCloudContentsWords.plain($0.shownName) }
        }
    }

    /// The "every Mac understands" gate, the Cloud folder's mechanism: this Mac announces it takes project secret files,
    /// and nothing is sent until every Mac of the account has announced it (an older Mac is never sent a pack it cannot
    /// take). Shut whenever anything is unknown. The marks travel with Cloud memory: when it is off on this Mac, that is
    /// the reason given (review 14 Nov, F11), not "waits for your devices".
    nonisolated static func gate() async -> BackendProjectSecretFilesGate {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return .waitingForMacs }
        guard await store.cloudMemoryIsOn() else { return .cloudMemoryOff }
        _ = try? await store.cloudFeatureAnnounce(BackendProjectSecretFilesRules.feature, format: BackendProjectSecretFilesRules.format)
        return await store.cloudFeatureEveryMacUnderstands(BackendProjectSecretFilesRules.feature, format: BackendProjectSecretFilesRules.format) ? .open : .waitingForMacs
    }
    /// Announced also while this Mac's saved passwords are still locked (a Mac waiting for the key must not hold the gate
    /// shut for his other Macs). Renewed by the store's regular look.
    nonisolated static func announce() async {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return }
        _ = try? await store.cloudFeatureAnnounce(BackendProjectSecretFilesRules.feature, format: BackendProjectSecretFilesRules.format)
    }

    /// This Mac's name as he set it in System Settings ("Asad's Mac mini").
    nonisolated static func deviceName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// A look every 10 minutes (file edits have no signal of their own), plus the gate's announcement. The result stops it.
    nonisolated static func looks(_ changed: @escaping @Sendable (String) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await announce()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                changed(BackendProjectSecretFilesRules.sourceId)
            }
        }
    }

    /// The composition, held weakly; its authority is read when the projects are asked for (it may be set later).
    @MainActor final class Source {
        weak var production: NativeCompositionProduction?
        init(_ production: NativeCompositionProduction) { self.production = production }
        func authority() -> BackendCompositionAuthority? { production?.authority }
    }

    nonisolated static func toolActions() -> BackendProjectSecretFilesTools.Actions {
        .init(status: { await BackendProjectSecretFilesHolder.shared.store?.status() })
    }
}
