import AppKit
import AVFoundation
import AVKit
import Quartz
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// SRVFILES #120: the side preview. Pictures, PDFs and documents in Quick Look (from a
// size-capped temporary copy, deleted on close), video and audio in AVKit while they
// download, text and code as their first 256 KB, anything else as facts + Download.

struct NativeServerFilePreview: View {
    let serverID: String
    let row: NativeServerFileRow
    let live: Bool
    let lookOnly: Bool
    var onOpen: (() -> Void)?
    var onDownload: () -> Void
    var onCopyPath: () -> Void
    var onShowInFolder: (() -> Void)?
    /// Renders only: what to show without a server.
    var fixture: Fixture? = nil

    enum Fixture { case image(NSImage), text(String, total: Int64) }
    private enum Shown { case loading, quickLook(URL), player(AVPlayer), text(String, shown: Int, total: Int64), info(String?), image(NSImage) }
    @State private var shown: Shown = .loading
    @State private var local: String?
    @State private var stream: NativeServerFileStream?
    @State private var measure: Double?

    static let textCap = 256 * 1024
    static let quickLookCap: Int64 = 300 * 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: row.symbol).foregroundStyle(.secondary)
                    Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle).help(row.path)
                }
                Text(facts).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(12)
            Divider()
            stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if row.isFolder, let onOpen { Button("Open", action: onOpen) }
                if !row.isFolder { Button("Download", action: onDownload).help("Save a copy in your Downloads folder") }
                if let onShowInFolder { Button("Show in folder", action: onShowInFolder) }
                Spacer()
                Button(action: onCopyPath) { Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(.rect) }
                    .buttonStyle(.borderless).help("Copy path").accessibilityLabel("Copy path")
            }.controlSize(.small).padding(10)
        }
        .task(id: row.id) { await load() }
        .onDisappear { close() }
    }

    private var facts: String {
        var parts = [row.kindWord]
        if !row.isFolder { parts.append(NativeServerFilesWords.size(row.size)) }
        if let m = measure ?? row.measure { parts.append(row.type == "document" ? "\(Int(m)) \(Int(m) == 1 ? "page" : "pages")" : NativeServerFilesWords.duration(m)) }
        if row.modified != nil { parts.append(NativeServerFilesWords.date(row.modified)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var stage: some View {
        switch shown {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .quickLook(let url):
            NativeQuickLookView(url: url)
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
        case .player(let player):
            NativeServerPlayerView(player: player, audioOnly: row.type == "audio")
        case .text(let text, let shownBytes, let total):
            VStack(alignment: .leading, spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize().padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if Int64(shownBytes) < total {
                    Text("Showing the first \(NativeServerFilesWords.size(Int64(shownBytes))) / \(NativeServerFilesWords.size(total))").font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        case .info(let why):
            VStack(spacing: 10) {
                Image(systemName: row.symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
                Text(why ?? (row.isFolder ? "A folder. Double-click to open it." : "No preview for this kind of file. Download it to open it on this Mac."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 240)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        close()
        if let fixture {
            switch fixture { case .image(let image): shown = .image(image); case .text(let text, let total): shown = .text(text, shown: text.utf8.count, total: total) }
            return
        }
        guard live else { shown = .info(nil); return }
        if row.isFolder || row.kind == "link" { shown = .info(nil); return }
        if ["audio", "video", "document"].contains(row.type), row.measure == nil {
            Task { measure = await NativeServerThumbs.shared.measure(server: serverID, path: row.path) }
        }
        switch row.type {
        case "video", "audio":
            let stream = NativeServerFileStream(serverID: serverID, path: row.path, name: row.name, size: row.size ?? 0)
            self.stream = stream
            let player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset))
            shown = .player(player)
            // Not every format streams; fall back to a temporary copy when the stream fails.
            Task {
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard self.stream === stream else { return }
                    if player.currentItem?.status == .readyToPlay { return }
                    if player.currentItem?.status == .failed { await quickLookCopy(play: true) { self.stream === stream }; return }
                }
            }
        case "text", "code":
            do {
                let answer = try await NativeServerFilesAPI.raw("servers:files:read", serverID, ["path": row.path, "from": 0, "length": Self.textCap])
                let bytes = (answer as? [String: Any])?["bytes"] as? Data ?? Data()
                let total = Int64(CodingAIJSON(answer)["size"].number ?? Double(bytes.count))
                shown = .text(String(decoding: bytes, as: UTF8.self), shown: bytes.count, total: total)
            } catch { shown = .info(NativeServerFilesAPI.message(error)) }
        case "photo", "document":
            await quickLookCopy(play: false)
        default:
            shown = .info(nil)
        }
    }
    /// `wanted` says whether this file is still the one on show once the copy is made.
    private func quickLookCopy(play: Bool, wanted: () -> Bool = { !Task.isCancelled }) async {
        guard (row.size ?? 0) <= Self.quickLookCap || play else { shown = .info("This file is too big to preview here. Download it to open it."); return }
        do {
            let path = try await NativeServerFilesAPI.call("servers:files:preview", serverID, ["path": row.path])["local"].string ?? ""
            // He moved on while the copy was made: nothing will show it or close it later, so it goes now.
            guard wanted() else { discard(path); return }
            local = path
            let url = URL(fileURLWithPath: path)
            shown = play ? .player(AVPlayer(url: url)) : .quickLook(url)
        } catch { shown = .info(NativeServerFilesAPI.message(error)) }
    }
    private func close() {
        if case .player(let player) = shown { player.pause() }
        stream?.cancel(); stream = nil
        if let local { self.local = nil; discard(local) }
    }
    private func discard(_ local: String) {
        guard live, !local.isEmpty else { return }
        Task { _ = try? await EngineBridge.shared.invoke("servers:files:preview:close", [serverID, ["local": local]]) }
    }
}

struct NativeQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct NativeServerPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let audioOnly: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = audioOnly ? .inline : .floating
        view.showsFullScreenToggleButton = !audioOnly
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

/// Plays a server file while it downloads: AVFoundation asks for byte ranges and each
/// one is read over the server's SFTP sign-in (servers:files:read, 1 MB at a time).
final class NativeServerFileStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let serverID: String, path: String, size: Int64
    let asset: AVURLAsset
    private let queue = DispatchQueue(label: "dev.terminaldeck.server-file-stream")
    private let lock = NSLock()
    private var cancelled = false
    private let contentType: String

    init(serverID: String, path: String, name: String, size: Int64) {
        self.serverID = serverID; self.path = path; self.size = size
        let ext = (name as NSString).pathExtension.lowercased()
        contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
        var parts = URLComponents(); parts.scheme = "tdserverfile"; parts.host = "stream"; parts.path = "/" + (ext.isEmpty ? "file" : "file." + ext)
        asset = AVURLAsset(url: parts.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType; info.contentLength = size; info.isByteRangeAccessSupported = true
        }
        guard let data = loadingRequest.dataRequest else { loadingRequest.finishLoading(); return true }
        let request = UncheckedRequest(loadingRequest)
        let start = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
        let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
        let server = serverID, file = path
        Task { @MainActor [weak self] in
            var at = start
            while at < end {
                guard let self, !self.isCancelled, !request.value.isCancelled else { return }
                do {
                    let length = Int(min(1024 * 1024, end - at))
                    let answer = try await NativeServerFilesAPI.raw("servers:files:read", server, ["path": file, "from": at, "length": length])
                    guard let bytes = (answer as? [String: Any])?["bytes"] as? Data, !bytes.isEmpty else { break }
                    request.value.dataRequest?.respond(with: bytes)
                    at += Int64(bytes.count)
                } catch {
                    request.value.finishLoading(with: error); return
                }
            }
            request.value.finishLoading()
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {}

    private final class UncheckedRequest: @unchecked Sendable {
        let value: AVAssetResourceLoadingRequest
        init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
    }
}
