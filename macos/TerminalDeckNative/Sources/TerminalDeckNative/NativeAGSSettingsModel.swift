import Foundation
import Observation
import TerminalDeckNativeCore

/// An owner-only editor session. Drafts stay separate from successful backend writes.
@MainActor
@Observable
final class NativeAGSSettingsModel {
    var settings = AGSAgentSettings()
    var defaults = AGSDefaults()
    private(set) var savedSettings = AGSAgentSettings()
    private(set) var savedDefaults = AGSDefaults()
    private(set) var revision: UInt64?
    private(set) var loading = false
    private(set) var saving = false
    private(set) var testing = false
    private(set) var loaded = false
    private(set) var profileID: String?
    var problem: String?
    private(set) var status = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var changed: EngineSubscription?
    @ObservationIgnored private var provider = "claude"

    var busy: Bool { loading || saving || testing }
    var hasChanges: Bool { profileID == nil ? defaults != savedDefaults : settings != savedSettings }
    var canSave: Bool { loaded && revision != nil && hasChanges && !busy }

    /// Call once on appearance, and stop on disappearance. Updates use the engine's event.
    func start(profile: String? = nil, provider: String = "claude") async {
        if changed == nil {
            changed = EngineBridge.shared.on("ags:changed") { [weak self] _ in
                guard let self, !self.busy else { return }
                if self.hasChanges {
                    self.problem = "Agent settings changed elsewhere. Keep your draft, or reload before saving."
                } else {
                    Task { @MainActor in await self.load(profile: self.profileID, provider: self.provider) }
                }
            }
        }
        await load(profile: profile, provider: provider)
    }

    func stop() {
        changed?.cancel()
        changed = nil
        generation += 1
        loading = false
    }

    /// A reload cannot silently replace unsaved edits. The host explicitly offers discard/reload.
    func load(profile: String? = nil, provider: String = "claude", discardDraft: Bool = false) async {
        guard !saving, !testing else { return }
        if loaded, hasChanges, !discardDraft {
            problem = "Save your changes, or discard them before reloading."
            return
        }
        generation += 1
        let mine = generation
        profileID = profile
        self.provider = provider
        loading = true
        loaded = false
        revision = nil
        problem = nil
        status = "Reading agent settings…"
        defer { if generation == mine { loading = false } }
        do {
            let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:get", [profile.map { $0 as Any } ?? NSNull()]))
            guard generation == mine, !Task.isCancelled else { return }
            let nextRevision = try readRevision(raw)
            if profile == nil {
                let next = try JSONDecoder().decode(AGSDefaults.self, from: raw["defaults"].encodedJSON())
                defaults = next
                savedDefaults = next
                if let actual = raw["defaultProvider"].string { settings = AGSAgentSettings(provider: actual); savedSettings = settings }
            } else {
                let next: AGSAgentSettings
                if raw["settings"].isNullish { next = AGSAgentSettings(provider: provider) }
                else { next = try JSONDecoder().decode(AGSAgentSettings.self, from: raw["settings"].encodedJSON()) }
                settings = next
                savedSettings = next
            }
            revision = nextRevision
            loaded = true
            status = ""
        } catch {
            guard generation == mine, !Task.isCancelled else { return }
            problem = CodingAIErrorText.from(error, fallback: "Could not read agent settings.")
            status = "Settings were not read."
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave, let revision else { return false }
        let submittedSettings = settings
        let submittedDefaults = defaults
        let submittedProfile = profileID
        saving = true
        problem = nil
        status = "Saving agent settings…"
        defer { saving = false }
        do {
            var input: [String: Any] = ["revision": NSNumber(value: revision)]
            if let submittedProfile {
                input["profile"] = submittedProfile
                input["settings"] = try object(submittedSettings)
            } else { input["defaults"] = try object(submittedDefaults) }
            let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:save", [input]))
            guard raw["ok"].bool == true else {
                throw NativeRPCError(code: "save-refused", message: raw["message"].string ?? "Agent settings were not saved.")
            }
            let nextRevision = try readRevision(raw)
            guard nextRevision > revision else {
                throw NativeRPCError.malformed("The save reply did not confirm a new settings revision. Reload before trying again.")
            }
            self.revision = nextRevision
            if submittedProfile == nil { savedDefaults = submittedDefaults }
            else { savedSettings = submittedSettings }
            status = "Saved."
            return true
        } catch {
            problem = CodingAIErrorText.from(error, fallback: "Could not save agent settings. Your draft is still here.")
            status = "Not saved. Your changes are still here."
            return false
        }
    }

    func discardChanges() {
        guard !busy else { return }
        settings = savedSettings
        defaults = savedDefaults
        problem = nil
        status = "Changes discarded."
    }

    /// A real command or web request: the backend owns approval, limits and redaction.
    func testHook(_ id: String) async throws -> String {
        guard loaded, profileID == nil, !busy, let revision,
              let hook = defaults.hooks.first(where: { $0.id == id }), savedDefaults.hooks.contains(hook) else {
            throw NativeRPCError(code: "save-first", message: "Save this hook before testing it.")
        }
        testing = true
        defer { testing = false }
        let input: [String: Any] = ["revision": NSNumber(value: revision), "hook": id]
        let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:hook-test", [input], timeout: 180))
        guard raw["ok"].bool == true else {
            throw NativeRPCError(code: "hook-test-failed", message: raw["message"].string ?? "The hook test did not finish.")
        }
        return raw["message"].string ?? "Test finished."
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func readRevision(_ value: NativeRPCValue) throws -> UInt64 {
        guard let number = value["revision"].number, number >= 0, number <= Double(Int32.max), number.rounded() == number else {
            throw NativeRPCError.malformed("The agent settings reply has no valid revision.")
        }
        return UInt64(number)
    }
}
