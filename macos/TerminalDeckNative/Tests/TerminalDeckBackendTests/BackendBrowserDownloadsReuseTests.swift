import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// U52: a stopped download frees its name (#382), and a fast download's progress
/// reaches subscribers a few times a second, not once per tick (#191).
@Suite("Browser downloads: names freed, progress coalesced")
struct BackendBrowserDownloadsReuseTests {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "downloads-reuse-owner")
    private let binding = BackendBrowserDownloadBinding(tabID: "tab-1", profileID: "default")

    private func service() throws -> (BackendBrowserDownloads, URL) {
        // The storage refuses symbolic links in a path, and /var is one
        // (resolvingSymlinksInPath would strip /private again).
        let temporary = FileManager.default.temporaryDirectory.path
        let real = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temporary
        let root = URL(fileURLWithPath: real, isDirectory: true)
            .appendingPathComponent("downloads-reuse-" + UUID().uuidString + ".noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloads = try BackendBrowserDownloads(dataRoot: root, defaultFolder: root.appendingPathComponent("Downloads", isDirectory: true),
            applicationName: "Terminal Deck", dependencies: BackendBrowserDownloadsDependencies(
                authorize: { _, _ in },
                open: { _ in .init(ok: true) }, reveal: { _ in .init(ok: true) }, chooseFolder: { _ in "" }))
        return (downloads, root)
    }

    private func begin(_ downloads: BackendBrowserDownloads, _ name: String = "report.pdf") async throws -> BackendBrowserDownloads.TransportTicket {
        try await downloads.begin(context: context, binding: binding, suggested: name, source: nil, expected: 10, cancel: {})
    }

    @Test func aStoppedOrFailedDownloadFreesItsName() async throws {
        let (downloads, root) = try service()
        defer { try? FileManager.default.removeItem(at: root) }
        try await downloads.restore(context: context)

        let first = try await begin(downloads)
        #expect(first.plannedURL.lastPathComponent == "report.pdf")
        await downloads.fail(first, message: "", cancelled: true)
        let second = try await begin(downloads)
        #expect(second.plannedURL.lastPathComponent == "report.pdf", "nothing is called report.pdf any more")

        _ = try await downloads.cancel(second.id, context: context)
        let third = try await begin(downloads)
        #expect(third.plannedURL.lastPathComponent == "report.pdf")

        let running = try await begin(downloads)
        #expect(running.plannedURL.lastPathComponent == "report (2).pdf", "a download still moving keeps its name")

        try Data("done".utf8).write(to: third.stagingURL)
        try await downloads.finish(third)
        await downloads.fail(running, message: "", cancelled: true)
        let after = try await begin(downloads)
        #expect(after.plannedURL.lastPathComponent == "report (2).pdf", "a landed file is still found on disk")
    }

    @Test func fastProgressIsCoalesced() async throws {
        let (downloads, root) = try service()
        defer { try? FileManager.default.removeItem(at: root) }
        try await downloads.restore(context: context)
        let stream = try await downloads.updates(context: context)
        let seen = Views()
        let reader = Task { for try await view in stream { await seen.add(view) } }
        defer { reader.cancel() }

        let ticket = try await begin(downloads, "big.iso")
        for tick in 1...50 { try await downloads.progress(ticket, received: Int64(tick), expected: 50) }
        var last: Int64 = 0
        for _ in 0..<40 where last != 50 {
            try await Task.sleep(for: .milliseconds(50))
            last = await seen.all().last?.items.first(where: { $0.id == ticket.id })?.received ?? 0
        }
        #expect(last == 50, "the newest numbers always arrive")
        let progressViews = await seen.all().filter { ($0.items.first(where: { $0.id == ticket.id })?.received ?? 0) > 0 }
        #expect(progressViews.count <= 3, "50 ticks became \(progressViews.count) views")
    }
}

private actor Views {
    private var views: [BackendBrowserDownloadsView] = []
    func add(_ view: BackendBrowserDownloadsView) { views.append(view) }
    func all() -> [BackendBrowserDownloadsView] { views }
}
