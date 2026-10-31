import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Narrow Format+Binding checks. No engine, process, live file or AI calls.
struct ROUTINESBindingChecks {
    private func text(headers: String) -> String {
        "# Audit\nwhen: manual\nin: /work/fleet/services/api\n" + headers + "\n---\nRead the logs.\n"
    }
    private func draft(_ routine: BackendRoutinesRoutine) -> NativeRPCValue {
        .object([.init("name", .string(routine.name)), .init("when", .array(routine.triggers.map { .string(BackendRoutinesFormat.serializeTrigger($0)) })),
            .init("in", .string(routine.folder)), .init("prompt", .string(routine.prompt)), .init("enabled", .bool(routine.enabled)),
            .init("projectId", .string(routine.projectID)), .init("projectIdInferred", .bool(routine.projectIdInferred)),
            .init("unknown", BackendROUTINESBinding.unknownWire(routine))])
    }
    @Test func legacyHootAndProjectInferenceRoundTripWithoutNewProjectHeader() throws {
        let parsed = try #require(BackendRoutinesFormat.parseRoutine("audit", text: text(headers: "custom: keep")).routine)
        #expect(parsed.agentID == "@hoot")
        #expect(parsed.projectIdInferred)
        let serialized = BackendRoutinesFormat.serializeRoutine(parsed)
        #expect(!serialized.contains("project-id:"))
        #expect(!serialized.contains("agent-id:"))
        let next = try #require(BackendRoutinesFormat.routineFromDraft("audit", draft: draft(parsed)).routine)
        #expect(next.unknown == parsed.unknown)
        #expect(next.projectIdInferred)
    }
    @Test func explicitBindingPreservesUnknownListsAndExplicitProjectProvenance() throws {
        let parsed = try #require(BackendRoutinesFormat.parseRoutine("audit", text: text(headers: "custom: one\nagent-id: critic\nproject-id: fleet\ncustom: two\nsecond: a:b\nwith-tab: a\tb")).routine)
        #expect(parsed.agentID == "critic")
        #expect(parsed.wire["agentId"].string == "critic")
        #expect(!parsed.projectIdInferred)
        let next = try #require(BackendRoutinesFormat.routineFromDraft("audit", draft: draft(parsed)).routine)
        #expect(next.unknown == parsed.unknown)
        #expect(next.unknownKeyOrder == parsed.unknownKeyOrder)
        #expect(next.projectID == "fleet")
        #expect(!next.projectIdInferred)
    }
    @Test func owningAgentValidatorMatchesCanonicalTaskProfiles() {
        for id in ["@hoot", "critic", "db-surgeon", String(repeating: "a", count: 40)] { #expect(BackendROUTINESBinding.isValidAgentID(id)) }
        for id in ["", "Critic", "critic_name", "critic\nenabled: no", String(repeating: "a", count: 41), "session:worker"] { #expect(!BackendROUTINESBinding.isValidAgentID(id)) }
        #expect(BackendRoutinesFormat.parseRoutine("audit", text: text(headers: "agent-id: critic\nagent-id: critic")).routine == nil)
        #expect(BackendROUTINESBinding.agentID(unknown: ["agent-id": ["critic", "critic"]]) == nil)
    }
    @Test func explicitAgentChangeKeepsUnrelatedMetadataAndMissingUpdateCarriesIt() throws {
        let old = try #require(BackendRoutinesFormat.parseRoutine("audit", text: text(headers: "agent-id: critic\nproject-id: fleet\ncustom: one\ncustom: two")).routine)
        let changed = draft(old).setting("agentId", .string("db-surgeon"))
        let next = try #require(BackendRoutinesFormat.routineFromDraft("audit", draft: changed).routine)
        #expect(next.agentID == "db-surgeon")
        #expect(next.unknown["custom"] == ["one", "two"])
        let omitted = draft(old).removing("unknown").removing("projectId").removing("projectIdInferred")
        let carried = BackendROUTINESBinding.carrying(existing: old, draft: omitted)
        let reread = try #require(BackendRoutinesFormat.routineFromDraft("audit", draft: carried).routine)
        #expect(reread.agentID == "critic")
        #expect(reread.unknown == old.unknown)
        #expect(reread.projectID == "fleet")
        #expect(!reread.projectIdInferred)
    }
    @Test func unknownDraftHeadersCannotOverrideKnownFieldsOrInjectMoreLines() throws {
        let old = try #require(BackendRoutinesFormat.parseRoutine("audit", text: text(headers: "agent-id: critic")).routine)
        let known = draft(old).setting("unknown", .object([.init("enabled", .array([.string("no")]))]))
        #expect(BackendRoutinesFormat.routineFromDraft("audit", draft: known).routine == nil)
        let injected = draft(old).setting("unknown", .object([.init("custom", .array([.string("one\nenabled: no")]))]))
        #expect(BackendRoutinesFormat.routineFromDraft("audit", draft: injected).routine == nil)
        let nullAgent = draft(old).setting("agentId", .null)
        #expect(BackendRoutinesFormat.routineFromDraft("audit", draft: nullAgent).routine == nil)
    }
}
