import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Cloud file manager (owner, 15 Nov, items 26, 27, 30): every kind as real folders and files, one row per thing (each
/// task, each setting with its value, each saved password by name), counts from the same listing as the rows, and the
/// `cloud.items` tool listing a folder the way the page shows it. Made-up records only.
@Suite("Cloud file manager — folders, rows and the folder read")
struct CloudManagerTreeTests {
    typealias F = BackendCloudContentsFixture
    typealias T = BackendCloudManagerTree
    static let now: Int64 = 1_794_000_000_000
    static let lead = "projects/" + F.project + "/"

    static func record(_ domain: String, _ source: String, _ record: String, project: String? = nil, minutesAgo: Int64 = 1) -> CloudSyncContents.Item {
        .init(key: .init(domain: domain, sourceId: source, recordId: record, projectId: project),
              changes: [.init(deviceId: F.mac, at: now - minutesAgo * 60_000)], standing: .inCloud)
    }
    static func names() -> BackendCloudContentsNames {
        var names = F.names
        names.agents["decker"] = "Decker"
        names.notes = [lead + "roles/decker/notes/2026-11-14-plan-for-the-launch-k3m9pq.md": "Plan for the launch",
                       lead + "roles/decker/notes/2026-11-13-design-review-a1b2c3.md": "Design review",
                       lead + "lead/notes/2026-11-12-weekly-plan-z9z9z9.md": "Weekly plan"]
        names.tasks = ["local:launch": "Ship the Mac app", "local:phones": "Ship the phones", "local:loose": "Water the plants"]
        names.passwords = ["github": "GitHub", "mini": "Mac mini"]
        for (record, value) in [("setting:appearance.theme", NativeRPCValue.string("dark")), ("setting:appearance.terminalFontSize", .number(13)),
                                ("preference:notifyOnComplete", .bool(true)), ("project-setting:" + F.project + "/setup.hootLeads", .string("claude")),
                                ("choice:landing.draft.v1", .string("a private sentence he was typing"))] {
            names.settingValues[record] = BackendCloudManagerSettings.value(recordId: record, value)
        }
        return names
    }
    static func built() throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        let items = [
            record("brain/memory/i01", "memory", "file/" + lead + "roles/decker/notes/2026-11-14-plan-for-the-launch-k3m9pq.md", project: F.project),
            record("brain/memory/i01", "memory", "file/" + lead + "roles/decker/notes/2026-11-13-design-review-a1b2c3.md", project: F.project, minutesAgo: 5),
            record("brain/memory/i01", "memory", "file/" + lead + "roles/decker/card.md", project: F.project, minutesAgo: 9),
            record("brain/memory/i01", "memory", "file/" + lead + "lead/notes/2026-11-12-weekly-plan-z9z9z9.md", project: F.project, minutesAgo: 20),
            record("brain/memory/i02", "memory", "row/diary/1", minutesAgo: 2),
            record("brain/memory/i02", "memory", "row/diary/2", minutesAgo: 3),
            record(BackendCloudKindsTasks.domain, "task-list", "task:local:launch", project: F.project),
            record(BackendCloudKindsTasks.domain, "task-list", "task:local:phones", project: F.project, minutesAgo: 4),
            record(BackendCloudKindsTasks.domain, "task-list", "task:local:loose"),
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, "setting:appearance.theme"),
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, "setting:appearance.terminalFontSize"),
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, "preference:notifyOnComplete"),
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, "project-setting:" + F.project + "/setup.hootLeads"),
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, "choice:landing.draft.v1"),
            record(CloudSecretsDomain.apiKey.rawValue, "api-keys", "github"),
            record(CloudSecretsDomain.server.rawValue, "servers", "mini"),
            record(CloudBootFilesFormat.domain, "files/I09/project/abc", "file/project/abc/.claude/skills/ship/SKILL.md", project: F.project),
            record(CloudFolderFormat.domain, "files/I24", "file/folder/Plans/2026/proposal.md"),
            record(CloudArtifactsFormat.domain, "files/I23", "file/artifacts/" + F.project + "/reports/weekly.html", project: F.project),
        ]
        let contents = CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
        return try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: F.snapshot(now: now), names: names(), now: now))
    }

    @Test func memoryIsProjectSeatAndNotesWithTheDiaryAtTheTop() throws {
        let model = try Self.built().model
        let top = T.listing(model, kind: .memory, path: [])
        #expect(top.folders.map(\.name) == ["Terminal Deck"])
        #expect(top.files.map(\.name) == ["Diary"], "the diary is one row that says what it is")
        #expect(top.folders[0].count == 4)
        let project = T.listing(model, kind: .memory, path: ["Terminal Deck"])
        #expect(project.folders.map(\.name) == ["Decker", "Lead"])
        let seat = T.listing(model, kind: .memory, path: ["Terminal Deck", "Decker"])
        #expect(seat.folders.map(\.name) == ["Notes"])
        #expect(seat.files.map(\.name) == ["Card · Decker"])
        let notes = T.listing(model, kind: .memory, path: ["Terminal Deck", "Decker", "Notes"])
        #expect(notes.folders.isEmpty)
        #expect(notes.files.map(\.name) == ["Plan for the launch", "Design review"], "newest first")
        // Search finds files at any depth inside the open folder, and no folders.
        let found = T.listing(model, kind: .memory, path: ["Terminal Deck"], search: "plan")
        #expect(Set(found.files.map(\.name)) == ["Plan for the launch", "Weekly plan"] && found.folders.isEmpty)
    }

    @Test func everyPlaceCountIsExactlyWhatItLists() throws {
        let model = try Self.built().model
        for kind in BackendCloudContents.Kind.allCases {
            let top = T.listing(model, kind: kind, path: [])
            #expect(T.count(model, kind: kind) == top.files.count + top.folders.reduce(0) { $0 + $1.count }, "\(kind)")
            #expect(T.count(model, kind: kind) == model.items(kind).count, "\(kind)")
        }
    }

    @Test func tasksAreOneRowEachByProject() throws {
        let model = try Self.built().model
        let top = T.listing(model, kind: .tasks, path: [])
        #expect(top.folders.map(\.name) == ["Terminal Deck"] && top.folders[0].count == 2)
        #expect(top.files.map(\.name) == ["Water the plants"])
        #expect(T.listing(model, kind: .tasks, path: ["Terminal Deck"]).files.map(\.name) == ["Ship the Mac app", "Ship the phones"])
    }

    @Test func settingsAreOneRowEachWithTheirValueUnderTheirPage() throws {
        let model = try Self.built().model
        let top = T.listing(model, kind: .settings, path: [])
        #expect(top.folders.map(\.name) == ["Appearance", "New session", "Notifications", "Projects"])
        #expect(top.files.isEmpty)
        let appearance = T.listing(model, kind: .settings, path: ["Appearance"]).files
        #expect(Set(appearance.map(\.name)) == ["Theme", "Terminal text size"])
        #expect(appearance.first { $0.name == "Theme" }?.value == "Dark")
        #expect(appearance.first { $0.name == "Terminal text size" }?.value == "13")
        #expect(T.listing(model, kind: .settings, path: ["Notifications"]).files.first?.value == "On")
        #expect(T.listing(model, kind: .settings, path: ["Projects"]).folders.map(\.name) == ["Terminal Deck"])
        // What he was typing is never shown: only that a text is saved.
        #expect(T.listing(model, kind: .settings, path: ["New session"]).files.first?.value == "Saved text")
        #expect(!model.items(.settings).contains { $0.canRemove }, "settings have no bin actions")
        #expect(!model.items(.settings).contains { $0.name == "Your settings" }, "no single grouped row any more")
    }

    @Test func savedPasswordsAreRowsByNameUnderWhatTheyAreFor() throws {
        let model = try Self.built().model
        let top = T.listing(model, kind: .passwords, path: [])
        #expect(top.folders.map(\.name) == ["API keys", "Server logins"])
        #expect(T.listing(model, kind: .passwords, path: ["API keys"]).files.map(\.name) == ["GitHub"])
        #expect(model.items(.passwords).allSatisfy { $0.value == nil && !$0.isText }, "a value is never on a row")
    }

    @Test func filesSitInTheirRealFolders() throws {
        let model = try Self.built().model
        let skill = try #require(model.items(.instructionFiles).first)
        #expect(skill.folder == ["Terminal Deck", "Claude", "skills", "ship"])
        #expect(try #require(model.items(.cloudFolder).first).folder == ["Plans", "2026"])
        #expect(try #require(model.items(.artifacts).first).folder == ["Terminal Deck", "reports"])
        for item in model.items {
            for name in item.folder { #expect(!BackendCloudContentsWords.looksLikeCode(name) && !name.contains("/"), "\(name)") }
        }
    }

    @Test func settingWordsAndValues() {
        typealias S = BackendCloudManagerSettings
        #expect(S.words("appearance.terminalFontFamily") == "Terminal font family")
        #expect(S.words("sidebar.pinnedTabs.v2") == "Pinned tabs")
        #expect(S.words(value: .bool(false)) == "Off")
        #expect(S.words(value: .string("system")) == "Same as the Mac")
        #expect(S.words(value: .string(String(repeating: "a", count: 60))) == "Set")
        #expect(S.words(value: .array([.string("a"), .string("b")])) == "2 chosen")
        #expect(S.name(recordId: "setting:hoot.permission.deploy") == "Hoot may · Deploy")
        #expect(S.name(recordId: "nonsense") == "A setting")
    }

    /// One read lists one folder as the page shows it: folders first, then items, paged.
    @Test func theReadToolListsAFolderAsThePageDoes() async throws {
        let made = try Self.built()
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder }, session: { _, _ in .null },
            runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
            authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let actions = BackendCloudManagerTools.Actions(contents: { .init(contents: made.model, handles: made.handles) },
                                                       read: { _, _ in throw BackendCloudManagerTools.signedOut }, change: { _ in "done" })
        let tools = try BackendCloudManagerTools.definitions(access: access, actions: actions)
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: "/scratch", attended: false,
                                            allowedTools: BackendCloudManagerTools.pageIDs, allowedTiers: [.read], cancellation: .init())
        let items = try #require(tools.first { $0.spec.id == BackendCloudManagerTools.itemsID })
        func call(_ fields: [NativeRPCValue.Field]) async throws -> NativeRPCValue {
            let reply = try await items.handler(context, .object(fields))
            #expect(!reply.isError)
            return try #require(reply.structuredContent)
        }
        let seat = try await call([.init("kind", .string("Memory")), .init("folder", .string("Terminal Deck › Decker"))])
        let rows = try #require(seat["rows"].elements)
        #expect(rows.first?["isFolder"].bool == true && rows.first?["name"].string == "Notes" && rows.first?["items"].number == 2)
        #expect(rows.last?["name"].string == "Card · Decker")
        #expect(seat["total"].number == 2 && seat["next"] == .null)
        // Paged: one row at a time, `next` says where the next page starts.
        let first = try await call([.init("kind", .string("Settings")), .init("folder", .array([])), .init("limit", .number(1))])
        #expect(first["rows"].elements?.count == 1 && first["next"].number == 1 && first["total"].number == 4)
        let second = try await call([.init("kind", .string("Settings")), .init("folder", .array([])), .init("limit", .number(1)), .init("offset", .number(1))])
        #expect(second["rows"].elements?.first?["name"].string == "New session")
        // Items carry their folders, and a setting its value; a saved password never one.
        let plain = try await call([.init("kind", .string("Settings")), .init("search", .string("Theme"))])
        let theme = try #require(plain["items"].elements?.first)
        #expect(theme["folder"].elements?.compactMap(\.string) == ["Appearance"] && theme["value"].string == "Dark")
        let passwords = try await call([.init("kind", .string("Saved passwords"))])
        #expect(passwords["items"].elements?.allSatisfy { $0["value"] == .null } == true)
    }
}
