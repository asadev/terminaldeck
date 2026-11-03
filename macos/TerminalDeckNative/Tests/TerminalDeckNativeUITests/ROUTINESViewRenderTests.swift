import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Explicit test-only preflight. Normal/shipping suites skip this until READY.
/// Run by the parent only through one-build.sh ROUTINES with ROUTINES_RENDER_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ROUTINES_RENDER_TESTS"] == "1"))
@MainActor
struct ROUTINESViewRenderTests {
    @Test("Twelve actual view captures and in-memory control checks; provisional shell adapters")
    func renderAndCheckFixtures() async throws {
        // Framework initialization only: no app bundle is launched or activated.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        try #require(!application.isActive)
        try #require(application.windows.allSatisfy { !$0.isVisible })
        let folder = try #require(ProcessInfo.processInfo.environment["ROUTINES_RENDER_OUTPUT"])
        let output = URL(fileURLWithPath: folder).standardizedFileURL
        try #require(output.lastPathComponent == "built.noindex")
        ROUTINESRenderFixtures.seedProjectsAndAgents()
        let routines = ROUTINESRenderFixtures.routines()
        let skills = ROUTINESRenderFixtures.skills()
        let hoot = ROUTINESRenderFixtures.hoot()
        var rendered = 0
        for dark in [false, true] {
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1000, height: 700)] {
                let suffix = "\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
                func save<V: View>(_ view: V, name: String) throws {
                    try ROUTINESHiddenRender.render(view, dark: dark, size: size,
                        to: output.appendingPathComponent("ROUTINES-\(name)-\(suffix).png"))
                    rendered += 1
                }
                try save(ROUTINESRenderShell(active: "Agents") {
                    ROUTINESRenderAgentsPage(mode: "Routines", subtitle: "7 routines · next: What happened overnight, 08:30", width: 1120) {
                        AGTRoutinesView(projectID: nil, model: routines, live: false)
                    }
                }, name: "routines")
                try save(ROUTINESRenderShell(active: "Agents") {
                    ROUTINESRenderAgentsPage(mode: "Skills", subtitle: skills.subtitle, width: 1360) {
                        AGTSkillsView(projectID: nil, model: skills)
                    }
                }, name: "skills")
                // The old Settings › Hoot page is gone (SETTINGS-TRUTH row 105): Hoot's profile, with its Reset Hoot…, instead.
                try save(ROUTINESRenderShell(active: "Hoot") {
                    HootProfileView(onBack: {}, model: hoot.state, brain: hoot.brain, preferences: hoot.preferences, routines: routines, live: false)
                }, name: "hoot-profile")
            }
        }
        #expect(rendered == 12)
        try await checkFixtureControls(routines: routines, skills: skills)
        try #require(application.windows.allSatisfy { !$0.isVisible })
        try #require(!application.isActive)
        print("ROUTINES: 12 view frames; in-memory controls checked; no app launch; no windows shown; provisional GLITCH/AGKIT/SETTINGS frame adapters")
    }

    private func checkFixtureControls(routines: ROUTINESPageModel, skills: ROUTINESSkillsStore) async throws {
        let skill = try #require(skills.installed.first { $0.name == "stripe-billing" })
        let before = try #require(skills.profiles.first { $0["id"].string == "matchmaker" })
        await skills.assign(skill, to: "matchmaker", enabled: true)
        let assigned = try #require(skills.profiles.first { $0["id"].string == "matchmaker" })
        #expect(assigned["skills"].elements?.contains(.string("stripe-billing")) == true)
        #expect(assigned["name"] == before["name"])
        #expect(assigned["projectId"] == before["projectId"])
        await skills.assign(skill, to: "matchmaker", enabled: false)
        #expect(skills.profiles.first { $0["id"].string == "matchmaker" } == before)
        await skills.open(skill)
        #expect(skills.preview?["markdown"].string?.contains("stripe-billing") == true)
        #expect(skills.preview?["files"].elements == [.string("SKILL.md")])
        skills.preview = nil

        routines.newRoutine(projectID: "imatch")
        var draft = try #require(routines.draft)
        #expect(draft.projectID == "imatch")
        #expect(draft.folder == "/fixture/iMatch")
        draft.name = "Fixture routine"; draft.prompt = "Read the fixture and report."
        let routineID = draft.id
        let receipt = ROUTINESRenderControlReceipt()
        routines.call = { channel, args in
            receipt.calls.append(channel)
            try #require(channel == "routines:save-text")
            try #require(args.first as? String == routineID)
            try #require((args[1] as? String)?.contains("project-id: imatch") == true)
            return CodingAIJSON(["ok": true, "id": routineID])
        }
        let saved = await routines.save(draft)
        #expect(saved)
        #expect(receipt.calls == ["routines:save-text"])
        #expect(routines.draft == nil)

        let choices = CodingAIJSON(["provider": "claude", "choices": ["provider": "claude", "profileId": "fixture-account", "model": "", "effort": "high"],
            "accounts": [["id": "fixture-account", "name": "Fixture account", "provider": "claude"]]])
        let brain = ROUTINESHootBrainModel(snapshot: choices, invoke: { channel, args in
            try #require(channel == "hoot:ready:save")
            let patch = try #require(args.first as? [String: Any])
            #expect(patch["profileId"] as? String == "fixture-account")
            #expect(patch["effort"] as? String == "high")
            return CodingAIJSON(["provider": "claude", "choices": patch, "accounts": []])
        })
        brain.selectModel("fixture-model")
        for _ in 0..<100 where brain.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!brain.busy && brain.model == "fixture-model")
        #expect(brain.profile == "fixture-account" && brain.effort == "high")

        let settings = ROUTINESHootSettingsModel(snapshot: CodingAIJSON(["runSessions": true, "capabilities": ["runSessions": true]]), live: false,
            invoke: { channel, args in
                try #require(channel == "hoot:settings:set")
                let patch = try #require(args.first as? [String: Any])
                #expect(patch["field"] as? String == "runSessions")
                return CodingAIJSON(["runSessions": patch["value"] as? Bool ?? true, "capabilities": ["runSessions": true]])
            })
        settings.boolBinding("runSessions").wrappedValue = false
        for _ in 0..<100 where settings.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!settings.busy && settings.values["runSessions"].bool == false)
    }
}

@MainActor
private final class ROUTINESRenderControlReceipt { var calls: [String] = [] }

@MainActor
enum ROUTINESRenderTestFailure {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "ROUTINESViewRenderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
@MainActor
enum ROUTINESRenderFixtures {
    static let projects = [
        PROJProject(id: "imatch", name: "iMatch", folders: ["/fixture/iMatch"], colour: "blue"),
        PROJProject(id: "crm", name: "CRM", folders: ["/fixture/CRM"], colour: "purple"),
        PROJProject(id: "daftar", name: "Daftar", folders: ["/fixture/Daftar"], colour: "green"),
        PROJProject(id: "independent", name: "Independent", colour: "graphite")
    ]
    static let people: [(id: String, project: String, icon: String, skills: [String])] = [
        ("accounts-keeper", "imatch", "sf:key", ["stripe-billing", "sign-in-flows"]),
        ("panel-engineer", "imatch", "sf:square.grid.2x2", ["stripe-billing"]),
        ("matchmaker", "imatch", "sf:star", []),
        ("analyst", "imatch", "sf:chart.bar", ["psql-readonly"]),
        ("critic", "imatch", "sf:ladybug", ["psql-readonly"]),
        ("db-surgeon", "imatch", "sf:cylinder.split.1x2", ["psql-readonly"]),
        ("ios-engineer", "imatch", "sf:iphone", ["sign-in-flows", "release-to-testflight"]),
        ("android-engineer", "imatch", "sf:iphone", ["sign-in-flows"]),
        ("whatsapp-officer", "imatch", "sf:message", ["whatsapp-channel"]),
        ("portal-mechanic", "crm", "sf:wrench", []),
        ("crm-db", "crm", "sf:cylinder.split.1x2", []),
        ("release-captain", "independent", "sf:shippingbox", [])
    ]
    static func seedProjectsAndAgents() {
        NativePROJLabels.shared.projects = projects
        NativePROJLabels.shared.activeProjectID = nil
        let profiles = people.map { person in
            AgentProfile(id: person.id, name: person.id, role: "Keeps the project working", provider: "claude", model: "AI default",
                skills: person.skills, defaultProject: "/fixture/" + (person.project == "crm" ? "CRM" : "iMatch"),
                icon: person.icon, projectID: person.project)
        }
        AGTAgentsStore.shared.fixture = TasksState(agents: profiles)
        AGTAgentsStore.shared.liveLoaded = true
    }
    static func routines() -> ROUTINESPageModel {
        let model = ROUTINESPageModel(); model.fixture = true; model.loading = false
        model.call = { channel, _ in throw ROUTINESRenderTestFailure.failure("Fixture called engine channel " + channel) }
        let rows: [(String, String, String, String, String, Bool, Bool)] = [
            ("What happened overnight", "Sums up what every session did and what needs you", "schedule 08:30", "@hoot", "every-project", true, false),
            ("Weekly look at what you remember", "Tidies Hoot's notes and drops stale ones", "schedule 03:00 sun", "@hoot", "every-project", true, true),
            ("A session died", "Finds out why and offers to resume it", "session-failed", "@hoot", "every-project", true, false),
            ("Check the work before it counts as done", "Runs the agent's check before a task closes", "task-finished", "@hoot", "every-project", false, false),
            ("Fleet self-audit", "Looks for broken alerts and noisy checks", "schedule every 6h", "critic", "imatch", true, false),
            ("Nightly database check", "Slow queries, missing indexes, disk use", "schedule 02:00", "db-surgeon", "imatch", true, false),
            ("Lead export sanity check", "Counts rows and compares with last week", "schedule 09:00 mon", "crm-db", "crm", true, false)
        ]
        model.routines = ROUTINESRoutine.list(CodingAIJSON(rows.enumerated().map { index, row -> [String: Any] in
            var value: [String: Any] = ["id": "fixture-routine-\(index)", "name": row.0, "prompt": row.1,
                "file": "/fixture/routines/\(index).md", "folder": "/fixture/iMatch", "triggers": [row.2],
                "agentId": row.3, "projectId": row.4, "enabled": row.5, "state": row.5 ? "armed" : "disabled"]
            if row.5 {
                value["lastOutcome"] = row.6 ? "failed" : "ok"
                value["lastFinishedAt"] = 1_791_600_000_000.0 - Double(index) * 3_600_000
                if row.6 { value["lastError"] = "The notes folder could not be read." }
            }
            return value
        }))
        return model
    }
    static func skills() -> ROUTINESSkillsStore {
        let model = ROUTINESSkillsStore(); model.fixture = true; model.loading = false; model.catalogueLoading = false
        let rows: [(String, String, String, String?)] = [
            ("stripe-billing", "Plans, trials, invoices and webhooks the way iMatch uses Stripe.", "Code", "imatch"),
            ("sign-in-flows", "Google, Apple and email sign-in, sessions and resets — with the traps we hit.", "Code", "imatch"),
            ("psql-readonly", "Read-only database questions: explain, counts, slow queries. Never writes.", "Data", "imatch"),
            ("whatsapp-channel", "Sending and reading WhatsApp messages through the company gateway.", "Messaging", "imatch"),
            ("release-to-testflight", "Bumps the build, uploads to TestFlight and waits for processing.", "Release", nil),
            ("crm-portal", "How the CRM portal is built: pages, forms, sign-in and the data it reads.", "Design", "crm")
        ]
        model.installed = rows.map { name, summary, category, projectID in
            ROUTINESSkill(id: "/fixture/skills/" + name, name: name, summary: summary, category: category, projectID: projectID,
                source: projectID == "imatch" ? "iMatch · .claude/skills" : projectID == "crm" ? "CRM · .claude/skills" : "Terminal Deck · built in",
                folder: "/fixture/skills/" + name, builtIn: projectID == nil)
        }
        // Counts match the mockup from real fixture rows, not fabricated labels.
        for index in 1...19 {
            model.installed.append(ROUTINESSkill(id: "/fixture/skills/example-\(index)", name: "project-helper-\(index)",
                summary: "How the project handles its everyday work.", category: "Code", projectID: "imatch",
                source: "iMatch · .claude/skills", folder: "/fixture/skills/example-\(index)"))
        }
        model.profiles = people.map { person in
            .object([.init("id", .string(person.id)), .init("name", .string(person.id)), .init("projectId", .string(person.project)),
                .init("defaultProject", .string("/fixture/" + person.project)), .init("icon", .string(person.icon)),
                .init("skills", .array(person.skills.map(NativeRPCValue.string)))])
        }
        model.catalogue = CommunityRules.view(["items": (1...36).map { index -> [String: Any] in
            ["id": "fixture/store-skill-\(index)", "kind": "skill", "name": "store-skill-\(index)", "summary": "Reusable project instructions.",
             "publisher": "Fixture", "state": "available", "agents": ["claude"], "tags": ["Code"], "version": "1.0"]
        }])
        return model
    }
    static func hoot() -> (state: CopilotSettingsPageModel, preferences: ROUTINESHootSettingsModel, brain: ROUTINESHootBrainModel) {
        let never: @MainActor (String, [Any?]) async throws -> CodingAIJSON = { channel, _ in
            throw ROUTINESRenderTestFailure.failure("Fixture called engine channel " + channel)
        }
        let model = CopilotSettingsPageModel(live: false, invoke: never); model.loading = false
        model.state = CopilotState.from(CodingAIJSON(["status": "running", "sessionId": "fixture-hoot", "paths": ["root": "/fixture/Hoot"],
            "folder": ["home": "/fixture/Hoot", "isDefault": true], "records": ["enforced": true]]))
        model.memory = CopilotMemoryReport.from(CodingAIJSON(["dir": "/fixture/Hoot/memory", "exists": true,
            "facts": (1...12).map { ["name": "note-\($0).md", "description": "Project note \($0)", "index": false] as [String: Any] }]))
        model.actions = CopilotActionLog.from(CodingAIJSON(["dir": "/fixture/Hoot/log", "file": "/fixture/Hoot/log/actions.jsonl", "exists": true,
            "rows": (1...200).map { _ in ["at": "2026-10-10T02:00:00Z", "action": "session.read", "detail": "Read a fixture session", "tool": "sessions_read"] as [String: Any] }]))
        let fields: [String: Any] = ["permissionMode": "ask", "runSessions": true, "routingMode": "ask", "useDevices": true,
            "folders": ["/fixture/iMatch", "/fixture/CRM", "/fixture/Daftar"],
            "capabilities": ["permissionMode": true, "runSessions": true, "routingMode": true, "useDevices": true, "folders": true, "reset": true]]
        let preferences = ROUTINESHootSettingsModel(snapshot: CodingAIJSON(fields), live: false, invoke: never)
        let brain = ROUTINESHootBrainModel(snapshot: CodingAIJSON(["provider": "claude", "choices": ["provider": "claude", "profileId": "fixture-account", "model": "Opus 5.5", "effort": ""],
            "accounts": [["id": "fixture-account", "name": "Asad · Max plan", "provider": "claude"]]]), invoke: never)
        return (model, preferences, brain)
    }
}

/// Provisional inert frame only. Replace with GLITCH/AGFRAME when READY arrives.
/// The page bodies below are actual product views, never screenshot replicas.
struct ROUTINESRenderAgentsPage<Content: View>: View {
    let mode: String
    let subtitle: String
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                ZStack {
                    HStack { title.frame(width: 260, alignment: .leading); Spacer(); actions }
                    viewSwitch
                }.frame(minWidth: 1020, minHeight: 42)
                VStack(alignment: .leading, spacing: 10) {
                    HStack { title; Spacer(); actions }
                    viewSwitch.frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            ScrollView {
                content().frame(maxWidth: width, alignment: .topLeading)
                    .padding(24).frame(maxWidth: .infinity, alignment: .top)
            }.frame(minHeight: 0, maxHeight: .infinity)
        }.background(ROUTINESKit.page)
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Agents").font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button("All projects") { }.buttonStyle(.bordered).controlSize(.small)
            Button(mode == "Routines" ? "New routine" : "New skill") { }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
    private var viewSwitch: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                ForEach(["All agents", "Org chart", "At work", "Routines", "Skills"], id: \.self) { item in
                    Text(item).font(.system(size: 12, weight: item == mode ? .semibold : .regular))
                        .foregroundStyle(item == mode ? Color.primary : Color.secondary)
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(item == mode ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                }
            }.padding(3).glassEffect(.regular, in: .capsule)
        }
    }
}

/// Test-only frame follows the source mockup's solid app chrome.
struct ROUTINESRenderShell<Content: View>: View {
    let active: String
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    private var frame: Color { scheme == .dark ? Color(red: 0.086, green: 0.086, blue: 0.094) : Color(red: 0.914, green: 0.914, blue: 0.933) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 8) { ForEach([Color.red, .orange, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) } }.frame(width: 224, alignment: .leading)
                HootMark(size: 15, animated: false); Text("Hoot")
                Divider().frame(height: 16); Text("Commander")
                Divider().frame(height: 16); Text("CRM session")
                Spacer()
            }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 44)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Hoot", "bird"); row("Agents", "person.2"); row("Tasks", "checklist"); row("Artifacts", "doc.richtext")
                    section("Projects"); projectRow("iMatch", dot: .blue); projectRow("CRM", dot: .purple); projectRow("Daftar", dot: .green)
                    section("Machines"); row("Servers", "server.rack"); row("Devices", "iphone"); row("Simulators", "iphone.gen3.radiowaves.left.and.right")
                    section("Integrations"); row("Receiver", "antenna.radiowaves.left.and.right"); row("MCP servers", "puzzlepiece.extension"); row("Store", "bag")
                    Spacer(); Divider(); row("Settings", "gearshape")
                }.padding(12).frame(width: 264)
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 0, maxHeight: .infinity)
        }.background(frame).tint(.accentColor)
    }
    private func section(_ name: String) -> some View {
        Text(name).font(.caption).foregroundStyle(.secondary).padding(.top, 12).padding(.horizontal, 12)
    }
    private func row(_ name: String, _ symbol: String) -> some View {
        Label(name, systemImage: symbol).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 28)
            .background(name == active ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private func projectRow(_ name: String, dot: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).frame(width: 18)
            Text(name).font(.system(size: 13)).foregroundStyle(.primary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 28)
    }
}

/// Settings frame is provisional; SETTINGS/GLITCH owns the real window frame.
struct ROUTINESRenderSettingsFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ForEach([Color.red, .orange, .green], id: \.self) { Circle().fill($0).frame(width: 11, height: 11) } }.padding(.bottom, 12)
                ForEach(["Hoot", "General", "Appearance", "Notifications", "Dynamic Island", "Coding AIs", "Agents", "Browser", "Outside AI apps", "Power", "Advanced", "Simulators"], id: \.self) { title in
                    Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(title == "Hoot" ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }.padding(12).frame(width: 190).background(Color.primary.opacity(0.03))
            VStack(spacing: 0) {
                Text("Hoot").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Divider()
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(ROUTINESKit.page, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}
