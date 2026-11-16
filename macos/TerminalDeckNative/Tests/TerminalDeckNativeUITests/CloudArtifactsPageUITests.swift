import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Lane L3 slice 2, under the delete rule (lane L5): "Artifacts" as a kind in the Your Cloud window, built from the
/// window's own rows exactly as the Cloud folder's section is: each artifact a row with the two bin buttons, its old
/// own-kind Bin rows folded into the ONE Bin, its plain lines, a quiet "Make it again" when its store is missing, and
/// "Artifacts" (the file manager: Space used is in Settings › Profile › Cloud now). No question is drawn. No store, window or network: actions recorded.
@Suite("Artifacts in your Cloud — the page")
@MainActor
struct CloudArtifactsPageUITests {
    typealias F = BackendCloudContentsFixture
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    final class Done: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        func add(_ call: String) { lock.withLock { calls.append(call) } }
        var all: [String] { lock.withLock { calls } }
    }
    func page(_ done: Done, answer: CloudFolderAnswer? = nil, lines: [String] = []) throws -> NativeCloudContentsModel {
        let account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        let ops = NativeCloudFileOps(text: { _ in nil }, keptText: { _, _ in nil }, useVersion: { _, _ in }, remove: { _, _ in }, putBack: { _ in },
                                     emptyBin: { 0 }, cleanUp: { 0 }, counts: { (bin: 0, kept: 0) })
        let deletes = NativeCloudDeleteOps(read: { _ in .init(gateOpen: true) }, delete: { items, scope, actor in
            done.add("delete \(scope.rawValue) " + items.map(\.id).joined(separator: ","))
            return [.init(id: actor.group, by: actor.by, macName: actor.macName, at: actor.at, items: items)]
        }, makeRoot: { kind in done.add("makeRoot " + kind.rawValue) })
        var fixture = F.fileManager(now: now)
        // Made-up artifacts (and one description sidecar), never his real ones.
        fixture.contents = CloudSyncContents(thisDevice: fixture.contents.thisDevice, items: fixture.contents.items + [
            .init(key: .init(domain: CloudArtifactsFormat.domain, sourceId: "files/I23", recordId: "file/artifacts/terminal-deck/reports/weekly.html", projectId: F.project),
                  changes: [.init(deviceId: F.pro, at: now - 120_000)], standing: .inCloud),
            .init(key: .init(domain: CloudArtifactsFormat.domain, sourceId: "files/I23", recordId: "file/artifacts/terminal-deck/reports/weekly.html.tdabout", projectId: F.project),
                  changes: [.init(deviceId: F.pro, at: now - 120_000)], standing: .inCloud)
        ], packs: fixture.contents.packs, held: fixture.contents.held, refused: fixture.contents.refused)
        let records = fixture.contents
        let model = NativeCloudContentsModel(account: account, read: { records }, files: ops, deletions: deletes)
        var names = fixture.names
        names.artifactsAnswer = answer
        names.artifactsLines = lines
        names.artifactsBin = [CloudFolderKept(path: "terminal-deck/reports/old.html", name: "old.html", place: "Terminal Deck",
                                              at: now - 60_000, device: F.pro, bytes: 4_200, keptUntil: now + 30 * 86_400_000,
                                              sha256: String(repeating: "b", count: 64))]
        let built = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names, now: now))
        model.deleteGateOpen = true
        model.show(BackendCloudDeletePage.applying([], groups: [], to: built.model), handles: built.handles)
        return model
    }

    @Test func eachArtifactIsARowAndEverywhereIsOnePressWithUndo() async throws {
        let done = Done()
        let model = try page(done)
        #expect(model.model?.kinds.contains(.artifacts) == true)
        let rows = try #require(model.model?.items(.artifacts))
        #expect(rows.map(\.name) == ["weekly.html"]) // the .tdabout description is never a row
        #expect(model.model?.items.contains { $0.name == "old.html" } == false) // the old own Bin folds into the ONE Bin
        let gate = CloudFilesUITests.UndoGate()
        model.undoWait = { _ in await gate.wait() }
        model.startDelete([rows[0]], scope: .everywhere)
        #expect(model.pending[.remove(itemId: rows[0].id)] != nil) // the 10-second Undo line, no sheet
        let waiting = Array(model.pendingTasks.values)
        await gate.open()
        for task in waiting { await task.value }
        #expect(done.all == ["delete everywhere terminal-deck/reports/weekly.html"])
    }

    @Test func aMissingStoreIsQuietAndNothingAsksHim() async throws {
        let done = Done()
        let model = try page(done, answer: CloudFolderAnswer(folderMissing: true))
        #expect(model.model?.answerLine == nil)
        var input = BackendCloudStatusLineInput(snapshot: F.snapshot(now: now))
        input.artifactsAnswer = CloudFolderAnswer(folderMissing: true)
        #expect(BackendCloudStatusLineBuilder.needs(input).isEmpty)
        model.makeRootAgain(.artifacts)
        for task in Array(model.pageTasks.values) { await task.value }
        #expect(done.all.contains("makeRoot artifacts"))
    }

    /// An arrived artifact is a row like a local one with one quiet "From <Mac>" line; one of a project not on this Mac
    /// yet waits (no row) and appears once the project is here; one this Mac's own list holds is never listed twice.
    @Test func arrivedArtifactsAreRowsOnceTheirProjectIsHere() {
        let store = URL(fileURLWithPath: "/tmp/never-read/artifacts-files", isDirectory: true)
        func item(_ project: String, _ rel: String, device: String?) -> CloudArtifactItem {
            CloudArtifactItem(path: project + "/" + rel, projectId: project, relPath: rel, name: (rel as NSString).lastPathComponent, project: "P",
                              madeBy: "Reviewer", createdAt: now - 5_000, changedAt: now, type: "Web page", bytes: 10, device: device,
                              url: store.appendingPathComponent(project + "/" + rel))
        }
        let items = [item("site", "out/report.html", device: "mac-b"), item("later", "notes.md", device: "mac-b"), item("site", "mine.html", device: nil)]
        let local = [NativeArtifactsCatalogModel.Row(root: "/Users/x/site", artifact: Artifact(relPath: "mine.html", projectID: "site"), source: [:])]
        let names: (String?) -> String? = { $0 == "mac-b" ? "MacBook Pro" : nil }
        var rows = NativeArtifactsCatalogModel.cloudRows(items, store: store, projects: ["site"], local: local, macName: names)
        #expect(rows.map(\.artifact.relPath) == ["out/report.html"])
        #expect(rows.first?.fromMac == "MacBook Pro")
        #expect(rows.first?.url?.path == store.appendingPathComponent("site/out/report.html").path)
        #expect(rows.first?.source["title"] == "Reviewer")
        rows = NativeArtifactsCatalogModel.cloudRows(items, store: store, projects: ["site", "later"], local: local, macName: names)
        #expect(Set(rows.map(\.artifact.relPath)) == ["out/report.html", "notes.md"])
    }

    /// Pictures (written to `macos/night/codex/artifacts-travel-evidence/`, light and dark): the Your Cloud window with
    /// Artifacts chosen (an artifact row with its two bin buttons and one plain line), and the side panel's Cloud page with "Artifacts"
    /// (the file manager: Space used is in Settings › Profile › Cloud now).
    @Test func picturesOfTheArtifactsSection() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/artifacts-travel-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try page(Done(), lines: [CloudArtifactsFormat.tooLargeLine(1), CloudArtifactsFormat.secretNameLine(["deploy-notes.md"])])
        model.chooseShelf(kind: .artifacts)
        let size = NSSize(width: 1240, height: 860)
        for dark in [false, true] {
            let shots: [(String, AnyView)] = [("window", AnyView(NativeCloudContentsView(model: model))),
                                              ("page", AnyView(NativeCloudContentsPage(model: model, live: false)))]
            for (name, view) in shots {
                let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: size.width, height: size.height).background(DeckTokens.page))
                host.sizingOptions = []
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("artifacts-\(name)-\(dark ? "dark" : "light").png"))
                #expect(image.pixelsWide >= Int(size.width))
            }
        }
    }
}
