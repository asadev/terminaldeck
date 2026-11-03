import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore

@Suite(.serialized)
@MainActor
struct Routines21UITests {
    @Test func reportFieldsAndDeliveryFailures() {
        let report = Routines21Report(CodingAIJSON(["id": "report-1", "kind": "report", "at": 1_791_870_000_000.0,
            "status": "ok", "text": "Read three runs. Two need you.",
            "deliveries": [["destinationId": "telegram", "label": "Telegram", "status": "failed", "message": "The bot token was refused.", "attempts": 2]]]))
        #expect(report.id == "report-1" && report.status == "ok")
        #expect(report.deliveries[0]["status"].text == "failed")
        #expect(report.deliveries[0]["attempts"].number == 2)
    }

    @Test func followUpUsesDedicatedChannelAndReportContext() async {
        let receipt = Routines21UIReceipt()
        let model = Routines21ReportsModel(routineID: "nightly", call: { channel, args in
            receipt.calls.append(channel)
            if channel == "routines:follow-up" {
                #expect(args[0] as? String == "nightly")
                #expect(args[1] as? String == "Why did it fail?")
                #expect(args[2] as? String == "run-report")
                return CodingAIJSON(["ok": true, "jobId": "fresh-question-job"])
            }
            return CodingAIJSON([] as [Any])
        })
        model.fixture = true; model.draft = " Why did it fail? "; model.reportID = "run-report"
        await model.send()
        #expect(receipt.calls == ["routines:follow-up"])
        #expect(model.draft.isEmpty && model.reportID == nil && !model.sending)
    }

    // #325: slow recent runs never undo routines that already loaded. #208: a deleted routine's report chat goes.
    // #209: a report change reloads only its own routine's chat.
    @Test func slowRunsKeepLoadedRoutinesAndDeletedRoutinesLoseTheirChat() async {
        let gate = Routines21UIGate(), model = ROUTINESPageModel()
        model.call = { channel, _ in
            if channel == "routines:list" {
                return CodingAIJSON([["id": "nightly", "name": "Nightly", "prompt": "Read the night.", "file": "/fixture/nightly.md", "folder": "/fixture",
                                      "agentId": "@hoot", "projectId": "every-project", "enabled": true, "state": "armed", "triggers": ["schedule 08:30"]]])
            }
            await gate.wait(); return CodingAIJSON([] as [Any])
        }
        func settled() async { for _ in 0..<200 where model.loading { try? await Task.sleep(for: .milliseconds(5)) } }
        model.load(); await settled()
        #expect(!model.loading && model.loadProblem == nil && model.routines.map(\.id) == ["nightly"])
        let kept = model.reportChat("nightly"), gone = model.reportChat("gone")
        model.load(); await settled(); await Task.yield()
        #expect(model.reportChat("nightly") === kept && model.reportChat("gone") !== gone)
        gate.open()
        #expect(Routines21ReportsModel.concerns(["nightly"], routineID: "nightly") && !Routines21ReportsModel.concerns(["other"], routineID: "nightly"))
        #expect(Routines21ReportsModel.concerns([], routineID: "nightly"))
    }

    @Test func destinationsDoNotReadBackSecrets() {
        var destination = Routines21Destination(CodingAIJSON(["id": "hook", "kind": "webhook", "label": "Night report", "url": "http://127.0.0.1/report", "hasSecret": true, "secret": "must-not-read", "secretHeader": "X-Report-Key"]))
        #expect(destination.hasSecret)
        #expect(destination.replacementSecret.isEmpty)
        #expect(destination.wire["secret"] == nil)
        destination.replacementSecret = "new-fake-value"
        #expect(destination.wire["secret"] as? String == "new-fake-value")
        #expect(destination.problem == nil)
    }

    @Test func destinationsSaveAfterRoutineAndBeforeDismiss() async {
        let receipt = Routines21UIReceipt()
        let model = ROUTINESPageModel(); model.fixture = true
        model.call = { channel, args in
            receipt.calls.append(channel)
            if channel == "routines:set-destinations" {
                let rows = args[1] as? [[String: Any]]
                #expect(rows?.first?["kind"] as? String == "hoot")
            }
            return CodingAIJSON(["ok": true])
        }
        var draft = ROUTINESDraft(id: "fixture-routine"); draft.name = "Night report"; draft.folder = "/fixture"; draft.prompt = "Read fixture reports."
        model.draft = draft
        let saved = await model.save(draft, destinations: [Routines21Destination(kind: "hoot")])
        #expect(saved && model.draft == nil)
        #expect(receipt.calls == ["routines:save-text", "routines:set-destinations"])
    }

    @Test func telegramConnectionInputIsClearedAndSelectionKept() async {
        let model = Routines21DestinationsModel(routineID: "fixture", call: { channel, args in
            #expect(channel == "routines:add-connection")
            let input = args[0] as? [String: String]
            #expect(input?["kind"] == "telegram")
            #expect(input?["botToken"] == "fake-token")
            return CodingAIJSON(["id": "telegram-1", "kind": "telegram", "label": "Daily results", "hasSecret": true])
        })
        model.add("telegram"); model.newToken = "fake-token"; model.newChatID = "-123"; model.newLabel = "Daily results"
        await model.addTelegram()
        #expect(model.newToken.isEmpty)
        #expect(model.destinations[0].connectionID == "telegram-1")
        #expect(model.destinations[0].chatID == "-123")
        #expect(model.destinations[0].problem == nil)
    }

    @Test func partialSaveKeepsSheetOpenAndExplainsWhatSaved() async {
        let model = ROUTINESPageModel(); model.fixture = true
        model.call = { channel, _ in
            if channel == "routines:set-destinations" { throw NSError(domain: "fixture", code: 1) }
            return CodingAIJSON(["ok": true])
        }
        var draft = ROUTINESDraft(id: "fixture-routine"); draft.name = "Night report"; draft.folder = "/fixture"; draft.prompt = "Read fixture reports."
        model.draft = draft
        let saved = await model.save(draft, destinations: [])
        #expect(!saved && model.draft?.id == draft.id)
        #expect(model.actionProblem == "The routine saved, but its result destinations did not. Try saving again.")
    }

    @Test func failedDestinationSaveStopsTestAndShowsReason() async {
        let receipt = Routines21UIReceipt()
        let model = Routines21DestinationsModel(routineID: "fixture", call: { channel, _ in
            receipt.calls.append(channel)
            return CodingAIJSON(["ok": false])
        })
        var webhook = Routines21Destination(); webhook.url = "http://127.0.0.1/report"
        model.destinations = [webhook]
        await model.test(webhook)
        #expect(receipt.calls == ["routines:set-destinations"])
        #expect(model.testStatus[webhook.id] == "Result destinations did not save. The test was not sent.")
        #expect(model.testing == nil)
    }

    @Test func renderRoutinePageAndPickerLightAndDark() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        #expect(!app.isActive)
        let previousAgents = AGTAgentsStore.shared.fixture
        AGTAgentsStore.shared.fixture = TasksState(agents: [])
        defer { AGTAgentsStore.shared.fixture = previousAgents }
        let output = URL(fileURLWithPath: "/Users/imatch/Deck Dev/notes/routines21-20261013.noindex")
        let page = ROUTINESPageModel(); page.fixture = true; page.loading = false
        page.routines = ROUTINESRoutine.list(CodingAIJSON([["id": "nightly", "name": "What happened overnight", "prompt": "Read last night’s runs and tell me what needs me.", "file": "/fixture/nightly.md", "folder": "/fixture", "agentId": "@hoot", "projectId": "every-project", "enabled": true, "state": "armed", "triggers": ["schedule 08:30"], "lastOutcome": "ok", "lastFinishedAt": 1_791_870_000_000.0]]))
        let reportChat = page.reportChat("nightly")
        reportChat.entries = [
            Routines21Report(CodingAIJSON(["id": "report-1", "kind": "report", "at": 1_791_780_000_000.0, "status": "ok", "text": "All five checks passed. There’s nothing you need to do."])),
            Routines21Report(CodingAIJSON(["id": "report-2", "kind": "report", "at": 1_791_870_000_000.0, "status": "ok", "text": "Read last night’s three runs. Two finished; the database check needs a new password.", "deliveries": [["label": "Telegram", "status": "failed", "message": "The bot token was refused.", "attempts": 2]]]))
        ]
        let destinations = Routines21DestinationsModel(routineID: "nightly", call: { _, _ in CodingAIJSON.null })
        destinations.fixture = true; destinations.loading = false
        destinations.connections = [Routines21Connection(CodingAIJSON(["id": "whapi-1", "kind": "whatsapp", "label": "Work WhatsApp", "chats": [["id": "work-group", "name": "Work updates group"]]])), Routines21Connection(CodingAIJSON(["id": "telegram-1", "kind": "telegram", "label": "Daily Telegram", "chatId": "-12345"]))]
        var webhook = Routines21Destination(kind: "webhook"); webhook.url = "http://127.0.0.1:8080/reports"; webhook.label = "Daily summary"; webhook.hasSecret = true
        var whatsapp = Routines21Destination(kind: "whatsapp"); whatsapp.connectionID = "whapi-1"; whatsapp.chatID = "work-group"
        var telegram = Routines21Destination(kind: "telegram"); telegram.connectionID = "telegram-1"; telegram.chatID = "-12345"
        destinations.destinations = [webhook, whatsapp, telegram, Routines21Destination(kind: "hoot")]
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            try Routines21HiddenRender.render(VStack(alignment: .leading, spacing: 16) {
                Text("Agents · Routines").font(.title2.weight(.semibold))
                Text("1 routine · next: What happened overnight, 08:30").foregroundStyle(.secondary)
                AGTRoutinesView(model: page, live: false)
                Spacer()
            }.padding(24).background(ROUTINESKit.page), dark: dark, size: CGSize(width: 1200, height: 750), to: output.appendingPathComponent("routines-page-\(mode).png"))
            try Routines21HiddenRender.render(VStack(alignment: .leading, spacing: 12) {
                Text("Edit routine · What happened overnight").font(.title3.weight(.semibold))
                Routines21DestinationsView(model: destinations, canTest: true)
                Spacer()
                HStack { Spacer(); Button("Cancel") {}; Button("Save routine") {}.buttonStyle(.borderedProminent) }
            }.padding(24).background(ROUTINESKit.page), dark: dark, size: CGSize(width: 640, height: 840), to: output.appendingPathComponent("routines-destinations-\(mode).png"))
            // U106 #154: Telegram with no connection yet shows the form that adds one, not a pointer to nothing.
            let firstTelegram = Routines21DestinationsModel(routineID: "nightly", call: { _, _ in CodingAIJSON.null })
            firstTelegram.fixture = true; firstTelegram.loading = false; firstTelegram.add("telegram")
            #expect(firstTelegram.destinations.first?.problem == "Choose a Telegram connection.")
            try Routines21HiddenRender.render(VStack(alignment: .leading, spacing: 12) {
                Routines21DestinationsView(model: firstTelegram, canTest: false)
                Spacer()
            }.padding(24).background(ROUTINESKit.page), dark: dark, size: CGSize(width: 640, height: 520), to: output.appendingPathComponent("routines-destinations-first-telegram-\(mode).png"))
        }
        #expect(app.windows.allSatisfy { !$0.isVisible } && !app.isActive)
    }
}

@MainActor private final class Routines21UIReceipt { var calls: [String] = [] }
@MainActor private final class Routines21UIGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func open() { waiting.forEach { $0.resume() }; waiting = [] }
}

@MainActor private enum Routines21HiddenRender {
    static func render<V: View>(_ view: V, dark: Bool, size: CGSize, to output: URL) throws {
        let app = NSApplication.shared
        guard !app.isActive, app.windows.allSatisfy({ !$0.isVisible }), output.deletingLastPathComponent().lastPathComponent == "routines21-20261013.noindex" else {
            throw NSError(domain: "Routines21Render", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offscreen render guard failed."])
        }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Routines21Render", code: 2) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Routines21Render", code: 3) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        print("Routines21 offscreen frame: \(output.lastPathComponent), \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
