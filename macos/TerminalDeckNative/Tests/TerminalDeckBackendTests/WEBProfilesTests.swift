import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private typealias V = NativeRPCValue
private func webProfileJSON(_ raw: String) -> V { try! V.parseJSON(Data(raw.utf8)) }
private let webProfileRPC = NativeRPCContext(caller: .pairedDevice, ownerID: "web-profile-test")
private func webProfileRequest(_ id: String) -> BackendRemotePanelRequest { .init(path: "", scope: "agent:" + id, query: nil) }
private func webProfilePort(_ response: V, directory: V, level: BackendINT2PhoneAccessLevel = .full) -> BackendIOS2PanelPort {
    .init(call: { tool, _, _, _, _ in tool == "agents.profile" ? response : directory }, level: { _, _ in level }, device: { _, _, _ in "web-profile-test" })
}
private func webProfileFacts(_ row: V) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (row["facts"].elements ?? []).compactMap { fact in
        guard let label = fact["label"].string, let value = fact["value"].string else { return nil }
        return (label, value)
    })
}
private let webProfileDirectory = webProfileJSON(#"""
{"agents":[
 {"id":"reviewer","kind":"profile","name":"Cached reviewer","role":"Old role","provider":"claude","project":"/projects/review","projectName":"Review app","statusLabel":"Ready","activity":"Old work","reportsTo":"@hoot","machine":"This Mac"},
 {"id":"builder","kind":"profile","name":"Builder","reportsTo":"reviewer","project":"/projects/review"}]}
"""#)

@Suite("Web canonical agent profiles")
struct WEBProfilesTests {
    @Test func canonicalSectionsKeepTheRealProfileChoicesRuntimeTasksAndProjectLinks() async throws {
        let response = webProfileJSON(#"""
        {"profile":{"id":"reviewer","name":"Reviewer","role":"Checks changes","provider":"codex","model":"saved-model","icon":"sf:checkmark.seal","reportsTo":"@hoot"},
         "effective":{"provider":"codex","model":"running-model","effort":"high","permissionMode":"plan","allowedTools":["Read"]},
         "runtime":{"status":"waiting","sessionId":"chat-123","taskId":"task-1"},
         "tasks":[{"task_id":"task-1","title":"Review login","status":"in-progress","project":"/projects/other","updatedAt":1700000000000}],
         "ags":{"settings":{}},"notices":[]}
        """#)
        let provider = BackendIOS2PhonePanels.agents(port: webProfilePort(response, directory: webProfileDirectory))
        let page = try await provider.read(webProfileRequest("reviewer"), webProfileRPC)
        let rows = try #require(page["rows"].elements), header = try #require(rows.first)
        #expect(page["title"].string == "Reviewer")
        #expect(header["detail"].string == "Checks changes")
        #expect(header["meta"]["project"].string == "/projects/review")
        #expect(header["sessionId"].string == "chat-123")
        #expect(header["status"].string == "warn")
        #expect(webProfileFacts(header)["Coding AI"] == "Codex · running-model")
        #expect(webProfileFacts(header)["Effort"] == "High" || webProfileFacts(header)["Effort"] == "high")
        #expect(webProfileFacts(header)["Doing now"] == "Waiting for you · Review login")
        #expect(rows.first { $0["group"].string == "Now" }?["sessionId"].string == "chat-123")
        #expect(rows.first { $0["group"].string == "Direct reports" }?["open"].string == "agent:builder")
        let recent = try #require(rows.first { $0["id"].string == "task:task-1" })
        #expect(recent["meta"]["project"].string == "/projects/other")
        let edit = try #require(header["actions"].elements?.first)
        #expect(edit["fields"].elements?.first { $0["id"].string == "model" }?["value"].string == "saved-model")
    }

    @Test func restrictedCanonicalRuntimeDoesNotRestorePrivateActivityFromDirectoryOrExposeSettings() async throws {
        let directory = webProfileDirectory.setting("agents", .array([webProfileDirectory["agents"].elements![0]
            .setting("activity", .string("private current job")).setting("taskTitle", .string("Private title"))
            .setting("sessionId", .string("private-session")).setting("live", .string("working"))]))
        let response = webProfileJSON(#"""
        {"profile":{"id":"reviewer","name":"Reviewer","provider":"codex","instructions":"hidden instructions","environment":{"TOKEN":"hidden value"},"account":"hidden account"},
         "effective":{"effort":"high"},"runtime":{"state":"working","coverage":"scope-limited"},"tasks":[],"ags":{"settings":{}}}
        """#)
        let page = try await BackendIOS2PhonePanels.agents(port: webProfilePort(response, directory: directory, level: .look))
            .read(webProfileRequest("reviewer"), webProfileRPC)
        let header = try #require(page["rows"].elements?.first)
        #expect(header["actions"].elements?.isEmpty == true)
        #expect(header["sessionId"].isNullish)
        let encoded = String(decoding: try page.encodedJSON(), as: UTF8.self)
        for secret in ["private current job", "Private title", "private-session", "hidden instructions", "hidden value", "hidden account"] {
            #expect(!encoded.contains(secret))
        }
    }

    @Test func legacyFlatProfilesKeepTheirDetailsAndNowSessionLink() async throws {
        let flat = webProfileJSON(#"""
        {"id":"session:row-1","name":"Live builder","kind":"session","role":"Codex session","provider":"codex","project":"/projects/legacy","statusLabel":"Working","live":"working","activity":"Building","sessionId":"chat-old","settings":{},"reports":[],"recentTasks":[]}
        """#)
        let page = try await BackendIOS2PhonePanels.agents(port: webProfilePort(flat, directory: .object([])))
            .read(webProfileRequest("session:row-1"), webProfileRPC)
        let header = try #require(page["rows"].elements?.first)
        #expect(header["title"].string == "Live builder")
        #expect(header["badge"].string == "Live session")
        #expect(header["sessionId"].string == "chat-old")
        #expect(header["meta"]["project"].string == "/projects/legacy")
        #expect(header["actions"].elements?.isEmpty == true)
        #expect(page["rows"].elements?.first { $0["group"].string == "Now" }?["sessionId"].string == "chat-old")
    }
}
