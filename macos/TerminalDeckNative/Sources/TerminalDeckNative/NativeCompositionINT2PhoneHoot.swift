import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

final class NativeCompositionINT2PhoneConsent: BackendDeckCoreConsentRelay, @unchecked Sendable {
    private weak var production: NativeCompositionProduction?
    @MainActor init(_ production: NativeCompositionProduction) { self.production = production }
    func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        // HOOTFIX: an AI app's question must reach the owner even when he is in another app.
        // Every question goes on screen: the island's request card (NativePermissionDesk), answered
        // through this same consent broker. The old banner stays only while the island is off.
        let onIsland = await MainActor.run { () -> Bool in
            let desk = NativePermissionDesk.shared
            guard desk.islandOn else { return false }
            desk.addConsent(id: request.id, asker: request.askedBy ?? request.label ?? Self.asker(request.origin), what: request.summary)
            return true
        }
        if !onIsland, request.origin.hasPrefix("key:") {
            await MainActor.run { NativeOwnerAttention.ask(id: request.id, asker: request.askedBy ?? "An AI app", what: request.summary, why: nil) }
        }
        guard let bridge = await MainActor.run(body: { self.production?.phoneHoot }) else { return onIsland }
        let phone = (try? await bridge.ask(request)) == true
        return phone || onIsland
    }
    nonisolated static func asker(_ origin: String) -> String {
        if origin.hasPrefix("key:") { return "An AI app" }
        if origin.contains("hoot") || origin.contains("copilot") { return "Hoot" }
        if origin.hasPrefix("agent") { return "An agent" }
        return "Terminal Deck"
    }
    func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        await MainActor.run { NativeOwnerAttention.settled(id: id); NativePermissionDesk.shared.settled(consent: id) }
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
            setInteractive: { [root] enabled in _ = try await root.settings.patch(.object([.init(RNMHootSettingsMigration.interactiveKey, .bool(enabled))])) },
            // Switch from the phone (iOS batch 1): Hoot's ready state, and the same orchestrator-seat write as
            // Hoot's own account dropdown on this Mac. Both through this Mac's own owner context.
            readAccounts: { [root, authority] in
                guard let authority else { throw NativeRPCError(code: "unavailable", message: "Hoot's accounts are not ready.") }
                let context = try authority.localContext()
                let ready = try await root.registry.invoke("hoot:ready:read", context: context, arguments: [.bool(false)])
                // The live sign-in facts the Mac's own Hoot setup reads (profiles:signin, its 30-second cache), so the
                // phone folds and names Hoot's accounts exactly as this Mac does (Reviewer 28 Oct, SHOULD 1).
                let provider = ready["provider"].string ?? "claude"
                let ids = (ready["accounts"].elements ?? []).filter { $0["provider"].string == provider }.compactMap { $0["id"].string }.prefix(64)
                let facts = await withTaskGroup(of: (String, NativeRPCValue?).self) { group in
                    for id in ids {
                        group.addTask {
                            (id, try? await root.registry.invoke("profiles:signin", context: context, arguments: [.string(id),
                                .object([.init("provider", .string(provider)), .init("refresh", .bool(false))])]))
                        }
                    }
                    var out: [NativeRPCValue.Field] = []
                    for await (id, fact) in group { if let fact, fact.fields != nil { out.append(.init(id, fact)) } }
                    return out
                }
                return ready.setting("signIns", .object(facts))
            },
            switchAccount: { [root, authority] provider, account in
                guard let authority else { throw NativeRPCError(code: "unavailable", message: "Hoot's accounts are not ready.") }
                _ = try await root.registry.invoke("profiles:set-level", context: authority.localContext(), arguments: [
                    .object([.init("kind", .string("seat")), .init("key", .string(BackendHootAccountSeat.key))]),
                    .string(provider), .string(account)])
            },
            // Hoot's box from the phone (iOS batch 1): the one live copy of Hoot's choices, so the Mac's own box,
            // the island and Settings → Hoot show a phone's change at once.
            options: { patch in
                try await Task { @MainActor in
                    let choices = HootChatChoices.shared
                    if let fields = patch?.fields, !fields.isEmpty {
                        var change: [String: Any] = [:]
                        for field in fields { if let value = field.value.string { change[field.key] = value } }
                        return try await choices.change(change)
                    }
                    await choices.reload()
                    guard let value = choices.value else { throw NativeRPCError(code: "unavailable", message: "Hoot's choices are not ready yet.") }
                    return value
                }.value
            })
        // 31 Oct (`chats.files`): files from the phone for Hoot's AI, as for an agent chat.
        let uploads = BackendUploadDestination.uploadsFolder(home: configuration.homeDirectory, appName: configuration.appName)
        await bridge.setAttach { files, text, provider, device in
            let resolved = try await NativePhoneAttachments.resolve(files, text: text, provider: provider, deviceID: device, uploads: uploads, trust: trust)
            return (resolved.attachments, resolved.text)
        }
        let owner = "native.phone-hoot"
        let lease = try await endpoint.installFeatures(ownerID: owner, features: [await bridge.feature()],
            connectionClosed: { await bridge.disconnected($0) })
        do {
            try await root.retain(.init(name: "phone-hoot", domains: ["phone-hoot"], ownerID: owner,
                invokes: [], stop: { await lease.cancelAndWait(); await bridge.stop() }))
            phoneHoot = bridge
        } catch { await lease.cancelAndWait(); await bridge.stop(); throw error }
        // On-screen answers go through the same owners as every other surface (by: "island").
        await MainActor.run { [consent = core.consent] in
            NativePermissionDesk.shared.answerConsent = { id, ok in await consent.respond(id: id, approved: ok, by: "island") }
        }
    }
}
