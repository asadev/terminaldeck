import Foundation
import ImageIO
import TerminalDeckBackend
import TerminalDeckNativeCore

/// U11 (#22, #622): a file an AI names (a chat attachment, a project logo) is read only from inside that caller's
/// own file grants. The answer is each file's real path, so a link swapped afterwards cannot widen it.
enum NativeGrantedFiles {
    static func paths(_ paths: [String], authority: BackendFilesystemAuthority?, context: NativeRPCContext) async throws -> [String] {
        guard let authority else { throw NativeRPCError(code: "not-granted", message: "Reading files needs the app's file access, which is not ready.") }
        var granted: [String] = []
        for path in paths { granted.append(try await authority.authorize(path, context: context).path) }
        return granted
    }
}

extension ChatAttachmentLimits {
    func validateFiles(_ urls: [URL]) throws {
        guard urls.count <= Self.count else { throw NativeRPCError.invalidArguments(note) }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard url.isFileURL, extensions.contains(ext) else { throw NativeRPCError.invalidArguments(note) }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size > 0,
                  size <= (ext == "pdf" ? Self.payloadBytes : Self.inputBytes) else { throw NativeRPCError.invalidArguments("\(url.lastPathComponent): \(note)") }
            if ext == "pdf" {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                guard try file.read(upToCount: 5) == Data("%PDF-".utf8) else { throw NativeRPCError.invalidArguments("\(url.lastPathComponent) is not a readable PDF.") }
            } else {
                guard CGImageSourceCreateWithURL(url as CFURL, nil) != nil else { throw NativeRPCError.invalidArguments("\(url.lastPathComponent) is not a readable image.") }
            }
        }
    }
}

extension NativeHootChatModel {
    var attachmentLimits: ChatAttachmentLimits {
        let provider = composerDraft.modelID.split(separator: ":").first.map(String.init) ?? (source.agentName.contains("Codex") ? "codex" : source.agentName.contains("Gemini") ? "gemini" : "claude")
        let caps = attachmentCapabilities["provider"].string == provider ? attachmentCapabilities : .null
        return .init(provider: provider, images: caps["images"].bool, documents: caps["documents"].bool)
    }
    func attachmentTool(_ action: String, paths: [String]) throws -> NativeRPCValue {
        guard !readOnly else { throw NativeRPCError.invalidArguments("This is saved history.") }
        switch action {
        case "add":
            var draft = composerDraft
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Choose an absolute local file path.") }
                if !draft.attachments.contains(where: { $0.url == url }) { draft.attachments.append(.init(url: url)) }
            }
            try attachmentLimits.validateFiles(draft.attachments.map(\.url)); composerDraft = draft
            retainAttachmentDraft()
        case "remove": composerDraft.attachments.removeAll { paths.contains($0.url.path) }
        case "validate": try attachmentLimits.validateFiles(composerDraft.attachments.map(\.url))
        case "send": try attachmentLimits.validateFiles(composerDraft.attachments.map(\.url)); send()
        case "read": break
        default: throw NativeRPCError.invalidArguments("Choose read, add, remove, validate or send.")
        }
        return attachmentLimits.wire.setting("files", .array(composerDraft.attachments.map { .object([.init("path", .string($0.url.path)), .init("name", .string($0.name))]) }))
    }
}
