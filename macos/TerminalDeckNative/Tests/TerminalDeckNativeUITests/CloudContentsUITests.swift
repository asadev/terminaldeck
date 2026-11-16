import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// "See what is in your Cloud", the window side. No window is shown, no Keychain item or network is used.
@Suite("Cloud contents — the window")
@MainActor
struct CloudContentsUITests {
    typealias F = BackendCloudContentsFixture
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    @Test func signedOutNothingIsReadOrBuilt() async {
        let account = NativeCloudAccount()
        var asked = 0
        let model = NativeCloudContentsModel(account: account, read: { asked += 1; return F.contents(now: 0) })
        await model.refresh()
        #expect(asked == 0)
        #expect(model.reads == 0)
        #expect(model.model == nil)
        // Signed in: the store's read is asked once per refresh.
        account.fixtureSnapshot(F.snapshot(now: now))
        await model.refresh()
        #expect(asked == 1)
        #expect(model.model?.devices.first?.name == "Studio Mac")
        // Signing out clears what was shown.
        account.fixtureSnapshot(CloudAccountSnapshot(phase: .signedOut, gate: .closed))
        await model.refresh()
        #expect(asked == 1)
        #expect(model.model == nil)
    }

    /// Owner, 14 Nov: no mystery button in Settings; Cloud is a page of the side panel, inside the main window.
    @Test @MainActor func theSidePanelOpensThePage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudSettings.swift"), encoding: .utf8)
        #expect(!page.contains("BackendCloudContentsWords.openButton"))
        #expect(SHELLRoutes.owns(Sidebar21Pages.cloudID))
        #expect(Sidebar21Pages.standard.contains { $0.id == Sidebar21Pages.cloudID })
    }

    /// Owner, 14 Nov (items 3, 4, 5): the real device name, no sentence above the list, places by name, no code-like
    /// titles, replaced notes told apart, one number beside every kind.
    @Test func pageRuleItems() throws {
        // 3. "Asad’s Mac mini": the device's own name, never the trust list's filtered "Asad s Mac mini".
        let base = F.snapshot(now: now)
        let named = base.devices.map { device -> CloudDevice in
            var made = device
            if device.deviceId == F.mac { made.displayName = "Asad’s Mac mini" }
            return made
        }
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: base.gate, displayName: base.displayName, devices: named,
                                            trust: base.trust, cloudHead: base.cloudHead, fetched: base.fetched)
        #expect(BackendCloudTrustRows.plainName("Asad’s Mac mini") != "Asad’s Mac mini", "the trust list's filter is what lost the apostrophe")
        let built = try #require(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: snapshot, names: F.names, now: now)).model
        #expect(built.devices.first?.name == "Asad’s Mac mini")
        #expect(!built.allText.contains { $0.contains("Asad s ") })
        // 4. No sentence above the list (the page source draws no kind line).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudContents.swift"), encoding: .utf8)
        #expect(!page.contains("contents.kindLines["))
        #expect(!page.contains("Text(\"History\")"))
        // 5a. Places by name, never a folder's role word.
        let names = BackendCloudContentsNames(projects: ["terminal-deck": "Terminal Deck", "crm": "CRM"], agents: ["reviewer": "Rita"])
        #expect(BackendCloudContentsWords.memoryPlace("projects/terminal-deck/lead/notes/a.md", names: names) == "Terminal Deck")
        #expect(BackendCloudContentsWords.memoryPlace("archive/projects/crm/lead/notes/a.md", names: names) == "CRM")
        #expect(BackendCloudContentsWords.memoryPlace("projects/terminal-deck/roles/reviewer/notes/a.md", names: names) == "Terminal Deck · Rita")
        #expect(BackendCloudContentsWords.memoryPlace("hoot/notes/a.md", names: names) == "Hoot")
        #expect(BackendCloudContentsWords.memoryPlace("templates/orchestrator/a.md", names: names) == nil)
        #expect(BackendCloudContentsWords.memoryPlace("projects/unknown/lead/notes/a.md", names: names) == nil)
        // 5b. A real title with a web address is shown; a second copy's file name loses its random ending.
        let mail = "archive/projects/crm/lead/notes/2026-11-13-ocs-agents-e-mail-onecollective-ae-50-70-mailbox-17djo2.md"
        let title = "OCS agents' e-mail (onecollective.ae, 50-70+ mailboxes): research done 11-13"
        #expect(BackendCloudContentsWords.noteName(mail, titles: [mail: title])?.hasPrefix("OCS agents' e-mail (onecollective.ae") == true)
        let copy = "notes/2026-11-13-asad-11-13-wants-near-free-e-mail-for-50-70-agen-vn6nqf-2.md"
        let said = try #require(BackendCloudContentsWords.noteName(copy, titles: [:]))
        #expect(!said.contains("vn6nqf"))
        // 5c, lane L4 (owner: "a proper file manager"): a replaced note is one of the earlier versions of the note that
        // replaced it (its own record says which), never a row of its own.
        let live = "projects/terminal-deck/lead/notes/2026-11-14-a-defect-cjq3ho.md", old = "archive/projects/terminal-deck/lead/notes/2026-11-14-a-defect-cy24yo.md"
        let items = [live, old].map {
            CloudSyncContents.Item(key: .init(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/" + $0, projectId: nil),
                                   changes: [.init(deviceId: F.mac, at: now - 1_000)], standing: .inCloud)
        }
        var linked = names
        linked.noteFacts = [live: .init(path: live, id: "n-new", changedAt: now - 1_000),
                            old: .init(path: old, id: "n-old", archivedAt: now - 1_000, reason: "superseded", supersededBy: "n-new", changedAt: now - 2_000)]
        let notes = try #require(BackendCloudContentsBuilder.build(contents: CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: []),
                                                                   snapshot: F.snapshot(now: now), names: linked, now: now)).model.items(.memory)
        #expect(notes.count == 1)
        // Memory one rule phase 2 (1967148d1, with 1699f1977/761c1c0b0): with changes to memory notes offered (the app's
        // default), a note's earlier versions are the keeper's kept texts only; the replaced copy in the memory folder
        // stays history there and is neither a row nor a version. None is kept here, so none is shown.
        #expect(notes.first?.versions.isEmpty == true)
        // With memory changes off, the L4 rule still holds: the replaced copy is the one earlier version of its note.
        let offNotes = try #require(BackendCloudContentsBuilder.build(contents: CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: []),
                                                                      snapshot: F.snapshot(now: now), names: linked, memoryChanges: false, now: now)).model.items(.memory)
        #expect(offNotes.count == 1)
        #expect(offNotes.first?.versions.count == 1)
        #expect(NativeCloudContentsRow.presence(try #require(notes.first)) == "On this Mac")
        // 5d. One number beside memory and settings.
        let counts = BackendCloudPageCounts(here: [.notes: 3_539, .diary: 41_668, .topics: 61, .settings: 5, .appSettings: 12, .tasks: 10])
        #expect(counts.count(.memory) == 3_539)
        #expect(counts.count(.settings) == 17)
        #expect(counts.count(.tasks) == 10)
    }

    @Test func picturesOfThePageLightAndDark() throws {
        let account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        let model = NativeCloudContentsModel(account: account, read: { nil })
        let built = try #require(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: F.snapshot(now: now), names: F.names, now: now))
        model.show(built.model, handles: built.handles)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/cloud-view").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = NSSize(width: 1120, height: 760)
        let shots: [(String, BackendCloudContents.Kind, String?)] = [
            ("instruction-files", .instructionFiles, built.model.items(.instructionFiles).first?.id),
            ("memory", .memory, built.model.items(.memory).first { $0.name == "Todo" }?.id),
        ]
        for (name, kind, selected) in shots {
            model.kind = kind
            model.selected = selected
            for dark in [false, true] {
                let view = NativeCloudContentsView(model: model).environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("cloud-view-\(name)-\(dark ? "dark" : "light").png"))
                #expect(image.pixelsWide >= Int(size.width))
            }
        }
        // The signed-out page.
        let signedOut = NativeCloudContentsView(model: NativeCloudContentsModel(account: NativeCloudAccount(), read: { nil })).frame(width: 600, height: 300)
        let host = NSHostingView(rootView: signedOut)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("cloud-view-signed-out.png"))
    }
}
