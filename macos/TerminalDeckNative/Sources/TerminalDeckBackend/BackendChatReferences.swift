import Foundation
import TerminalDeckNativeCore

public enum BackendChatReferences {
    public static func relative(_ path: String) throws -> String {
        let path = try BackendDeckToolsFiles.relative(path)
        guard !BackendFilesystemIgnore.credentialPath(path) else { throw NativeRPCError(code: "access-denied", message: "Credential-shaped files cannot be attached as context.") }
        return path
    }
    public static func candidates(_ paths: [String], query: String) -> [NativeRPCValue] {
        let files = paths.filter { (try? relative($0)) != nil }
        var folders = Set<String>()
        for path in files {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                folders.insert(parent); parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let ranked = BackendDeckToolsFiles.rankMatches(files + folders.sorted().map { $0 + "/" }, words: words)
        return ranked.prefix(80).map { path in
            let folder = path.hasSuffix("/")
            let clean = folder ? String(path.dropLast()) : path
            return .object([.init("path", .string(clean)), .init("kind", .string(folder ? "folder" : "file")),
                .init("name", .string((clean as NSString).lastPathComponent + (folder ? "/" : "")))])
        }
    }
    public static func content(path: String, kind: String, value: NativeRPCValue) throws -> NativeRPCValue {
        let path = try relative(path)
        let text: String
        var truncated = false
        if kind == "folder" {
            let rows = value["entries"].elements ?? []
            text = rows.prefix(200).compactMap { row -> String? in
                guard row["blocked"].bool != true, let name = row["name"].string,
                      !BackendFilesystemIgnore.credentialPath(path + "/" + name) else { return nil }
                return name + (row["kind"].string == "dir" ? "/" : "")
            }.joined(separator: "\n")
            truncated = rows.count > 200 || value["truncated"].bool == true
        } else {
            guard kind == "file", value["kind"].string == "text", let full = value["text"].string else {
                throw NativeRPCError.invalidArguments("Only readable text files can be mentioned; use attachments for images or PDFs.")
            }
            text = String(full.prefix(8_000)); truncated = text != full
        }
        return .object([.init("path", .string(path)), .init("kind", .string(kind)), .init("text", .string(text)), .init("truncated", .bool(truncated))])
    }
    public static func read(_ references: [NativeRPCValue], root: String, service: BackendFilesystemService,
                            context: NativeRPCContext) async throws -> [NativeRPCValue] {
        guard references.count <= 8 else { throw NativeRPCError.invalidArguments("Attach up to eight file or folder references.") }
        var result: [NativeRPCValue] = []
        for reference in references {
            let path = try relative(reference["path"].requireString("path", nonempty: true))
            let kind = reference["kind"].string ?? "file"
            let value = kind == "folder" ? try await service.list(root: root, relative: path, context: context) :
                try await service.read(root: root, relative: path, context: context, refuseCredentials: true)
            result.append(try content(path: path, kind: kind, value: value))
        }
        return result
    }
}
