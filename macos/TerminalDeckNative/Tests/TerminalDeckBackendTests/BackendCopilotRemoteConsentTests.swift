import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote Hoot consent projection")
struct BackendCopilotRemoteConsentTests: Sendable {
    private func question(origin: String = "device:phone", label: String? = nil, askedBy: String? = nil) -> BackendDeckCoreSecurityConsentRequest {
        .init(id: "ask-1", tool: "settings.write", tier: .alter, summary: "Change the default agent to Codex",
            arguments: .object([.init("scope", .string("preferences")), .init("patch", .object([.init("defaultProvider", .string("codex"))]))]),
            requestedAt: 1000, expiresAt: 121000, origin: origin, label: label, askedBy: askedBy)
    }
    @Test func watchingCarriesNoArgumentsOrOriginButPreservesCountdownAndMine() throws {
        let row = BackendCopilotRemoteWiring.pendingRow(question(), mine: false)
        #expect(Set(row.fields!.map(\.key)) == ["id", "tool", "summary", "requestedAt", "expiresAt", "mine"])
        #expect(row["args"] == .missing); #expect(row["origin"] == .missing)
        #expect(row["expiresAt"].number! - row["requestedAt"].number! == 120000)
        #expect(row["mine"].bool == false)
        #expect(BackendCopilotRemoteWiring.pendingRow(question(), mine: true)["mine"].bool == true)
        #expect(!String(decoding: try row.encodedJSON(), as: UTF8.self).contains("phone"))
    }
    @Test func actualApproverGetsExactArgsSummaryOriginTierAndDeadline() {
        let request = question(), wire = BackendCopilotRemoteWiring.consentQuestion(request)
        #expect(wire["args"] == request.arguments); #expect(wire["summary"].string == request.summary)
        #expect(wire["origin"].string == request.origin); #expect(wire["tier"].string == "alter")
        #expect(wire["expiresAt"].number! - wire["requestedAt"].number! == 120000)
    }
    @Test func outsideAppNameReplacesOpaqueKeyIDAndPrefixesBothSentences() {
        let request = question(origin: "key:k1", label: "“ChatGPT” — an AI app you gave an access key to", askedBy: "ChatGPT")
        let wire = BackendCopilotRemoteWiring.consentQuestion(request)
        #expect(wire["origin"].string == request.label)
        #expect(wire["summary"].string == "From “ChatGPT”: " + request.summary)
        #expect(BackendCopilotRemoteWiring.pendingRow(request, mine: true)["summary"] == wire["summary"])
    }
}
