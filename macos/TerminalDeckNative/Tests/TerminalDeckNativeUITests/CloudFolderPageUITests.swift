import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Delete rule (lane L5): the Cloud folder's files are rows of their own with the two bin buttons; its old own-kind Bin
/// rows fold into the ONE Bin; a missing folder is one quiet line with "Make it again"; no question is ever drawn. No
/// store, window or network: the page's actions are recorded.
@Suite("Cloud folder — the page")
@MainActor
struct CloudFolderPageUITests {
    typealias F = BackendCloudContentsFixture
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    final class Done: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        func add(_ call: String) { lock.withLock { calls.append(call) } }
        var all: [String] { lock.withLock { calls } }
    }
    func page(_ done: Done, folderAnswer: CloudFolderAnswer? = nil, replaced: [CloudVersionReplacedLine] = [], lines: [String] = []) throws -> NativeCloudContentsModel {
        let account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        var ops = NativeCloudFileOps(text: { _ in nil }, keptText: { _, _ in nil }, useVersion: { _, _ in }, remove: { _, _ in }, putBack: { _ in },
                                     emptyBin: { 0 }, cleanUp: { 0 }, counts: { (bin: 0, kept: 0) })
        ops.folderKept = { path in done.add("folderKept " + path); return nil }
        let deletes = NativeCloudDeleteOps(read: { _ in .init(gateOpen: true) },
                                           makeRoot: { kind in done.add("makeRoot " + kind.rawValue) })
        var fixture = F.fileManager(now: now)
        // Made-up files in the Cloud folder, never his real ones.
        fixture.contents = CloudSyncContents(thisDevice: fixture.contents.thisDevice, items: fixture.contents.items + [
            .init(key: .init(domain: CloudFolderFormat.domain, sourceId: "files/I24", recordId: "file/folder/Plans/proposal.md", projectId: nil),
                  changes: [.init(deviceId: F.mac, at: now - 120_000)], standing: .inCloud),
            .init(key: .init(domain: CloudFolderFormat.domain, sourceId: "files/I24", recordId: "about/8b156633-04ec-4960-bf8d-dc74802e01ab", projectId: nil),
                  changes: [.init(deviceId: F.mac, at: now - 60_000)], standing: .inCloud)
        ], packs: fixture.contents.packs, held: fixture.contents.held, refused: fixture.contents.refused)
        let records = fixture.contents
        let model = NativeCloudContentsModel(account: account, read: { records }, files: ops, deletions: deletes)
        var names = fixture.names
        names.folderAnswer = folderAnswer
        names.folderReplaced = replaced
        names.folderLines = lines
        names.folderBin = [CloudFolderKept(path: "Plans/old.md", name: "old.md", place: "Plans", at: now - 60_000, device: F.pro, bytes: 12,
                                           keptUntil: now + 86_400_000, sha256: String(repeating: "a", count: 64))]
        let built = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names, now: now))
        model.deleteGateOpen = true
        model.show(BackendCloudDeletePage.applying([], groups: [], to: built.model), handles: built.handles)
        return model
    }

    @Test func folderFilesAreRowsWithBothButtonsAndTheOldBinIsNotASecondList() throws {
        let model = try page(Done())
        let rows = try #require(model.model?.items(.cloudFolder))
        #expect(rows.map(\.name) == ["proposal.md"]) // the about/ sidecar is provenance, never a row
        #expect(rows[0].canRemove && rows[0].deleteItems.first?.kind == "cloudFolder")
        // The old own-kind Bin row is gone from the kind; the ONE Bin (owners' groups) lists it instead.
        #expect(model.model?.items.contains { $0.name == "old.md" } == false)
        #expect(model.model?.answerLine == nil)
    }

    @Test func aMissingFolderIsOneQuietLineWithMakeItAgain() async throws {
        let done = Done()
        let model = try page(done, folderAnswer: CloudFolderAnswer(folderMissing: true), lines: ["Your Cloud folder is not on this Mac"])
        #expect(model.model?.folderLines == ["Your Cloud folder is not on this Mac"])
        #expect(model.model?.answerLine == nil)
        // No delete question reaches the status line either.
        var input = BackendCloudStatusLineInput(snapshot: F.snapshot(now: now))
        input.folderAnswer = CloudFolderAnswer(folderMissing: true)
        #expect(BackendCloudStatusLineBuilder.needs(input).isEmpty)
        model.makeRootAgain(.cloudFolder)
        for task in Array(model.pageTasks.values) { await task.value }
        #expect(done.all.contains("makeRoot cloudFolder"))
    }

    /// Pictures (written to `macos/night/codex/cloud-folder-evidence/`, light and dark): the Your Cloud window with the
    /// Cloud folder chosen (a file row with its two bin buttons, a "kept · Show" line, one plain line), and the side
    /// panel's Cloud page with "Cloud folder" (the file manager: Space used is in Settings › Profile › Cloud now).
    @Test func picturesOfTheCloudFolderSection() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/cloud-folder-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let replaced = CloudVersionReplacedLine(device: "MacBook Pro", name: "notes.txt", project: nil, keptUntil: now + 30 * 86_400_000,
                                                itemId: BackendCloudFolder.kind + ":Plans/notes.txt")
        let model = try page(Done(), replaced: [replaced], lines: [CloudFolderFormat.secretLine(["config.toml", "design-tokens.json"])])
        model.chooseShelf(kind: .cloudFolder)
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
                try png.write(to: output.appendingPathComponent("cloud-folder-\(name)-\(dark ? "dark" : "light").png"))
                #expect(image.pixelsWide >= Int(size.width))
            }
        }
    }
}
