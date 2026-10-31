import Foundation

public struct ChatAttachmentLimits: Sendable {
    public static let count = 4
    public static let inputBytes = 16_000_000
    public static let payloadBytes = 500_000
    public static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp"]
    public let images: Bool
    public let documents: Bool
    public init(provider: String, images: Bool? = nil, documents: Bool? = nil) {
        self.images = images ?? ["claude", "codex"].contains(provider)
        self.documents = documents ?? (provider == "claude")
    }
    public var extensions: [String] { (images ? Self.imageExtensions : []) + (documents ? ["pdf"] : []) }
    public var note: String {
        if extensions.isEmpty { return "This AI connection has not reported attachment support." }
        let types = [images ? "PNG, JPEG, GIF, WebP" : nil, documents ? "PDF" : nil].compactMap { $0 }.joined(separator: "; ")
        return "Up to 4 files: \(types). Images up to 16 MB, resized to 500 KB for sending.\(documents ? " PDFs up to 500 KB." : "")"
    }
    public var wire: NativeRPCValue {
        .object([.init("maxCount", .number(Double(Self.count))), .init("imageInputBytes", .number(Double(Self.inputBytes))),
                 .init("payloadBytes", .number(Double(Self.payloadBytes))), .init("extensions", .array(extensions.map(NativeRPCValue.string))),
                 .init("images", .bool(images)), .init("documents", .bool(documents)), .init("note", .string(note))])
    }
    public func validate(_ blocks: [NativeRPCValue]) throws {
        guard blocks.count <= Self.count else { throw NativeRPCError.invalidArguments(note) }
        for block in blocks {
            let source = block["source"], type = block["type"].string ?? "", media = source["media_type"].string ?? ""
            guard source["type"].string == "base64", let encoded = source["data"].string,
                  encoded.utf8.count <= (Self.payloadBytes + 2) / 3 * 4,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= Self.payloadBytes,
                  (images && type == "image" && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(media)) ||
                    (documents && type == "document" && media == "application/pdf" && bytes.starts(with: Data("%PDF-".utf8))) else {
                throw NativeRPCError.invalidArguments(note)
            }
        }
    }
}
