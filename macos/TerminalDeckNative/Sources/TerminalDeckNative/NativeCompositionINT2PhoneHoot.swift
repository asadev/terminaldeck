import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

final class NativeCompositionINT2PhoneConsent: BackendDeckCoreConsentRelay, @unchecked Sendable {
    private weak var production: NativeCompositionProduction?
    @MainActor init(_ production: NativeCompositionProduction) { self.production = production }
    func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        guard let bridge = await MainActor.run(body: { self.production?.phoneHoot }) else { return false }
        return try await bridge.ask(request)
    }
    func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        try await (await MainActor.run { self.production?.phoneHoot })?.settled(id: id, outcome: outcome)
    }
}

extension NativeCompositionProduction {
    func installINT2PhoneHoot() async throws {
        guard phoneHoot == nil, let trust = remoteTrust, let endpoint = remoteEndpoint, let core else {
            throw NativeRPCError(code: "composition-incomplete", message: "Phone Hoot needs its actual trust, endpoint and consent owners.")
        }
        let bridge = BackendINT2HootPhone(trust: trust, endpoint: endpoint, consent: core.consent,
            runtime: { [weak self] in await MainActor.run { self?.hoot?.runtime } },
            log: { [core] count in await core.log.tail(Double(count)) },
            setInteractive: { [root] enabled in _ = try await root.settings.patch(.object([.init(RNMHootSettingsMigration.interactiveKey, .bool(enabled))])) })
        let owner = "native.phone-hoot"
        let lease = try await endpoint.installFeatures(ownerID: owner, features: [await bridge.feature()],
            connectionClosed: { await bridge.disconnected($0) })
        do {
            try await root.retain(.init(name: "phone-hoot", domains: ["phone-hoot"], ownerID: owner,
                invokes: [], stop: { await lease.cancelAndWait(); await bridge.stop() }))
            phoneHoot = bridge
        } catch { await lease.cancelAndWait(); await bridge.stop(); throw error }
    }
}
