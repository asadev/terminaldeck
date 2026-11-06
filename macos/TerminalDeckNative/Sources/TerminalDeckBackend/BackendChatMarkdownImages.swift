import Darwin
import Foundation
import ImageIO
import TerminalDeckNativeCore
import UniformTypeIdentifiers

/// The paired phone receives raster bytes, never a Mac file URL or a mixed-content HTTP request.
public enum BackendChatMarkdownImages {
    public static let maximumInput = 8 * 1024 * 1024
    public static let maximumEncoded = 2 * 1024 * 1024
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static func resolve(_ text: String, folder: String?, fetch: Fetch = http,
                               access: (@Sendable () async throws -> Void)? = nil) async throws -> String {
        let ordered = ChatMarkdownImages.references(text).sorted { $0.start < $1.start }
        let references = Array(ordered.prefix(8)), omitted = Array(ordered.dropFirst(8))
        let repetitions = references.reduce(into: [String: Int]()) { $0[$1.source, default: 0] += 1 }
        var sources: [String: String] = [:], remaining = maximumEncoded, count = 0
        for reference in references where sources[reference.source] == nil {
            try await access?()
            guard count < 8, remaining > 0 else { sources[reference.source] = ""; continue }
            count += 1
            let data: Data?
            if let url = URL(string: reference.source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                data = try? await fetch(url)
            } else if reference.source.lowercased().hasPrefix("data:image/"),
                      reference.source.utf8.count <= maximumInput * 2,
                      let comma = reference.source.firstIndex(of: ","),
                      reference.source[..<comma].lowercased().hasSuffix(";base64") {
                data = Data(base64Encoded: String(reference.source[reference.source.index(after: comma)...]))
            } else { data = try? file(reference.source, folder: folder) }
            if let data, data.count <= maximumInput, let image = raster(data),
               image.utf8.count <= remaining / max(1, repetitions[reference.source, default: 1]) {
                sources[reference.source] = image
                remaining -= image.utf8.count * repetitions[reference.source, default: 1]
            } else { sources[reference.source] = "" }
            try await access?()
        }
        // Drop later references first, so the first eight keep their original byte positions.
        // Repeated sources spend the budget for every occurrence, even when their bytes are fetched once.
        let empty = Dictionary(omitted.map { ($0.source, "") }, uniquingKeysWith: { _, last in last })
        let bounded = ChatMarkdownImages.replacing(text, references: omitted, sources: empty)
        return ChatMarkdownImages.replacing(bounded, references: references, sources: sources)
    }

    static func file(_ source: String, folder: String?) throws -> Data {
        guard let folder, folder.hasPrefix("/"), !source.contains("\0") else { throw URLError(.noPermissionsToReadFile) }
        let root = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate: URL
        if let url = URL(string: source), url.isFileURL { candidate = url }
        else if source.hasPrefix("/") { candidate = URL(fileURLWithPath: source) }
        else if URL(string: source)?.scheme == nil { candidate = root.appendingPathComponent(source.removingPercentEncoding ?? source) }
        else { throw URLError(.unsupportedURL) }
        let real = candidate.standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard real.path.hasPrefix(prefix) else { throw URLError(.noPermissionsToReadFile) }
        let relative = try BackendChatReferences.relative(String(real.path.dropFirst(prefix.count)))
        // Walk descriptors to prevent a symlink replacement between confinement and reading.
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw URLError(.noPermissionsToReadFile) }
        defer { close(parent) }
        let components = relative.split(separator: "/").map(String.init)
        for part in components.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw URLError(.noPermissionsToReadFile) }
            close(parent); parent = next
        }
        guard let name = components.last else { throw URLError(.badURL) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw URLError(.noPermissionsToReadFile) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumInput else { throw URLError(.dataLengthExceedsMaximum) }
        let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: maximumInput + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maximumInput else { throw URLError(.dataLengthExceedsMaximum) }
        return bytes
    }

    public static func http(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              ["http", "https"].contains(response.url?.scheme?.lowercased() ?? ""),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= maximumInput else { throw URLError(.badServerResponse) }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < maximumInput else { throw URLError(.dataLengthExceedsMaximum) }
            bytes.append(byte)
        }
        return bytes
    }

    static func raster(_ bytes: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumEncoded else { return nil }
        return "data:image/png;base64," + (output as Data).base64EncodedString()
    }
}
