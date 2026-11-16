import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Hand-over item 3, the window side: the Cloud page's ONE place that says where this Mac stands. No window is
/// shown, the app-wide page gate is not opened, and no Keychain item or network is used.
@Suite("Cloud page — the one summary place in the window")
@MainActor
struct CloudOverviewUITests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let idA = "10000000-0000-4000-8000-00000000000a"

    private func coverage(_ row: String, items: Int, complete: Bool = true) -> CloudCoverage {
        CloudCoverage(sourceId: "fixture-" + row, inventoryRow: row, complete: complete, items: items, bytes: 10, blockedReasons: [])
    }
    private func level(_ coverage: [CloudCoverage]) -> CloudAccountSnapshot {
        CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture person", coverage: coverage,
                             cloudHead: CloudSequence(4), fetched: CloudSequence(4))
    }

    @Test func theSummaryIsBuiltOnlyFromWhatIsSwitchedOn() throws {
        let model = NativeCloudAccount(), secrets = NativeCloudSecrets(), parts = NativeCloudFeatureParts()
        // Nobody signed in: there is no summary at all.
        let signedOut = NativeCloudOverview.current(model: model, secrets: secrets, parts: parts)
        #expect(signedOut == nil)
        model.fixtureSnapshot(level([coverage("I01", items: 3)]))
        // 0.22.0: memory rows are switched on, so a signed-in, allowed account sees the Memory row (choice not yet asked).
        #expect(!NativeCloudBrainRegistration.memoryRows.isEmpty)
        let on = NativeCloudOverview.input(model: model, secrets: secrets, parts: parts)
        #expect(on.memory == BackendCloudOverviewInput.Memory(included: nil))
        let shown = try #require(NativeCloudOverview.current(model: model, secrets: secrets, parts: parts))
        #expect(shown.rows.map { $0.kind } == [.memory])
        // With no memory row switched on, no lane reported and saved passwords not wired: no row, nothing waiting, so
        // the place is absent (never an empty or greyed box).
        let off = NativeCloudOverview.input(model: model, secrets: secrets, parts: parts, memoryOn: false)
        #expect(off.memory == nil)
        #expect(off.projects == nil)
        #expect(off.bootFiles == nil)
        #expect(off.passwords == nil)
        let absent = NativeCloudOverview.current(model: model, secrets: secrets, parts: parts, memoryOn: false)
        #expect(absent == nil)
        // With memory switched on (as proof P3's plan does) the Memory row is there and carries the person's choice.
        let asked = NativeCloudOverview.input(model: model, secrets: secrets, parts: parts, memoryOn: true)
        #expect(asked.memory == BackendCloudOverviewInput.Memory(included: nil))
        model.fixtureSnapshot(level([coverage("I01", items: 3)]), memoryIncluded: true)
        let included = NativeCloudOverview.input(model: model, secrets: secrets, parts: parts, memoryOn: true)
        #expect(included.memory == BackendCloudOverviewInput.Memory(included: true))
        let withMemory = try #require(BackendCloudOverviewBuilder.build(included))
        #expect(withMemory.standing == .upToDate)
        // A lane that reports gets its row and its waiting line; when it is cleared (sign-out) both are gone.
        let file = BackendCloudOverview.Waiting(id: "file:f1", text: "A file from your Cloud can run a command and waits for you.", action: .acceptFile(id: "f1"))
        parts.bootFiles = BackendCloudOverviewInput.Feature(waiting: [file])
        let reported = try #require(NativeCloudOverview.current(model: model, secrets: secrets, parts: parts, memoryOn: false))
        let kinds = reported.rows.map { $0.kind }
        #expect(kinds == [.bootFiles])
        #expect(reported.standing == .needsYou)
        parts.clear()
        let cleared = NativeCloudOverview.current(model: model, secrets: secrets, parts: parts, memoryOn: false)
        #expect(cleared == nil)
    }

    @Test func aListNotReadYetOrUnreadableIsNeverNothingWaits_B3() throws {
        // Review B-M3: lanes used to start with an EMPTY part and turn a failed read into "nothing waits".
        #expect(BackendCloudOverviewInput.Feature.notReadYet.checking)
        #expect(BackendCloudOverviewInput.Feature.unreadable.couldNotCheck)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let records = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudRecords.swift"), encoding: .utf8)
        let boot = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudBoot.swift"), encoding: .utf8)
        for source in [records, boot] {
            #expect(!source.contains("= BackendCloudOverviewInput.Feature()"))
            #expect(source.contains(".notReadYet"))
            #expect(source.contains(".unreadable"))
        }
        #expect(!records.contains("(try? await projects.needingFolder()) ?? []"))
        #expect(!records.contains("try? await records.tools.counts()"))
        #expect(!boot.contains("(try? await boot.items()) ?? []"))
        // A lane that has just started: its row says "Checking…"; a failed read is said with Check again.
        let model = NativeCloudAccount(), secrets = NativeCloudSecrets(), parts = NativeCloudFeatureParts()
        model.fixtureSnapshot(level([coverage("I11", items: 3)]))
        parts.projects = .notReadYet
        let starting = try #require(NativeCloudOverview.current(model: model, secrets: secrets, parts: parts, memoryOn: false))
        #expect(starting.standing == .checking)
        #expect(starting.title == "Checking…")
        parts.projects = .unreadable
        let failed = try #require(NativeCloudOverview.current(model: model, secrets: secrets, parts: parts, memoryOn: false))
        // Page-names 2: a failed read is not a task: a calm line with Check again, and never "Up to date".
        #expect(failed.standing == .notReady)
        let actions = failed.notices.map { $0.action }
        #expect(actions == [.checkAgain])
    }

    @Test func thePageHasOnePlaceForItAndNoSecondStatusLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudSettings.swift"), encoding: .utf8)
        #expect(page.components(separatedBy: "NativeCloudOverviewSection(").count == 2)
        // What used to be said in several places is said in that one place only.
        for old in ["LabeledContent(\"Status\"", "Waiting to send", "Needs attention", "Source coverage", "This Mac's first save", "Button(\"Retry\")"] {
            #expect(!page.contains(old), "\(old)")
        }
        #expect(page.contains("Button(\"Sync now\")"))
    }

    @Test func theSummaryRendersInBothThemesWithEveryRowAndWhatWaits() throws {
        let model = NativeCloudAccount(), secrets = NativeCloudSecrets(), parts = NativeCloudFeatureParts()
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "fixture", y: "fixture")
        let device = CloudDeviceTrustRow(deviceId: Self.idA, name: "Fixture MacBook Air", standing: .new, code: "4F2A 91C3 B07E 55D1 8A2C", keyId: nil,
                                         signKey: key, waiting: 14)
        let going = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 2, waitingUntil: nil, reason: nil)
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture person",
                                            coverage: [coverage("I01", items: 1_200, complete: false), coverage("I11", items: 12), coverage("I09", items: 30)],
                                            waitingRecords: 3_800, trust: [device], heldChanges: 14, baseline: going,
                                            cloudHead: CloudSequence(40), fetched: CloudSequence(28))
        model.fixtureSnapshot(snapshot, memoryIncluded: true)
        var locked = BackendCloudSecretsPage()
        locked.standing = .locked
        let folder = BackendCloudOverview.Waiting(id: "project:p1", text: "Project “Fixture site” needs a folder on this Mac.", action: .chooseFolder(projectId: "p1"))
        let file = BackendCloudOverview.Waiting(id: "file:f1", text: "A file from your Cloud can run a command and waits for you: .claude/commands/deploy.md",
                                                action: .acceptFile(id: "f1"))
        let input = BackendCloudOverviewInput(snapshot: snapshot, memory: BackendCloudOverviewInput.Memory(included: true),
                                              projects: BackendCloudOverviewInput.Feature(waiting: [folder]),
                                              bootFiles: BackendCloudOverviewInput.Feature(waiting: [file]), passwords: locked)
        let overview = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(overview.rows.count == 4)
        #expect(overview.waiting.count == 4)
        #expect(overview.standing == .needsYou)
        // Every standing has its own symbol; "Up to date" alone carries the tick.
        let standings: [BackendCloudOverview.Standing] = [.upToDate, .needsYou, .paused, .unreachable, .savingAndCatchingUp, .saving, .catchingUp, .notReady, .checking, .notUsed]
        for standing in standings {
            let symbol = NativeCloudOverviewSection.symbol(standing)
            #expect(!symbol.isEmpty)
            let ticked = symbol == "checkmark.circle.fill"
            let isUpToDate = standing == .upToDate
            #expect(ticked == isUpToDate)
        }
        // Rendered proof goes under the agreed scratch root whatever launched the tests.
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112").resolvingSymlinksInPath()
        let folderURL = approved.appendingPathComponent("a-overview-render-" + UUID().uuidString + "/proof")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let size = NSSize(width: 760, height: 620)
        for dark in [false, true] {
            let view = Form { NativeCloudOverviewSection(overview: overview, model: model, secrets: secrets, parts: parts) }
                .formStyle(.grouped).environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: folderURL.appendingPathComponent("cloud-overview-\(dark ? "dark" : "light").png"))
            #expect(image.pixelsWide >= Int(size.width))
        }
    }
}
