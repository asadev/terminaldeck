import AppKit
import ImageIO
import SwiftUI

private struct NativeChatFolderKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var nativeChatFolder: String {
        get { self[NativeChatFolderKey.self] }
        set { self[NativeChatFolderKey.self] = newValue }
    }
}

/// Only an explicit image URL or a file inside this session's folder is read.
enum NativeChatImageSource {
    static func resolve(_ source: String, folder: String) -> URL? {
        if let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return url }
        if source.lowercased().hasPrefix("data:image/"), source.utf8.count <= 24 * 1024 * 1024 { return URL(string: source) }
        guard folder.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate: URL
        if let url = URL(string: source), url.isFileURL { candidate = url }
        else if source.hasPrefix("/") { candidate = URL(fileURLWithPath: source) }
        else if URL(string: source)?.scheme == nil { candidate = root.appendingPathComponent(source.removingPercentEncoding ?? source) }
        else { return nil }
        let real = candidate.resolvingSymlinksInPath().standardizedFileURL
        return real.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") ? real : nil
    }
}

struct NativeChatMarkdownImage: View {
    @Environment(\.nativeChatFolder) private var folder
    let source: String
    let alt: String
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420).accessibilityLabel(alt)
            } else if failed {
                Label(alt.isEmpty ? "Image could not be loaded" : alt, systemImage: "photo").foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius).fill(.quaternary).frame(height: 120)
                    .overlay { ProgressView().controlSize(.small) }.accessibilityLabel("Loading image")
            }
        }
        .task(id: folder + "\n" + source) {
            image = nil; failed = false
            guard let url = NativeChatImageSource.resolve(source, folder: folder) else { failed = true; return }
            do {
                let bytes: Data
                let limit = 16 * 1024 * 1024
                if url.isFileURL || url.scheme == "data" {
                    if url.isFileURL {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
                        guard size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
                    }
                    bytes = try Data(contentsOf: url)
                } else {
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    var request = URLRequest(url: url); request.timeoutInterval = 20
                    let (stream, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
                    var data = Data()
                    for try await byte in stream {
                        guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
                        data.append(byte)
                    }
                    bytes = data
                }
                guard bytes.count <= limit, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                image = NSImage(cgImage: bitmap, size: .zero)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
