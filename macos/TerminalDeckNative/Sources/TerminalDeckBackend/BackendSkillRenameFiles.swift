import Foundation
import TerminalDeckNativeCore

/// Renames the folder and only its front-matter name; helper files and instructions stay intact.
enum BackendSkillRenameFiles {
    static func renamed(_ text: String, name: String) throws -> String {
        let quoted = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return "---\nname: \(quoted)\n---\n\n" + text
        }
        let names = (1..<end).filter { SkillCommandNames.isNameHeaderLine(lines[$0]) }
        if let index = names.first {
            for duplicate in names.dropFirst().reversed() { lines.remove(at: duplicate) }
            lines[index] = "name: " + quoted
        } else { lines.insert("name: " + quoted, at: 1) }
        return lines.joined(separator: "\n")
    }
    static func move(folder: URL, name: String) throws -> URL {
        try SkillCommandNames.require(name)
        guard ROUTINESSkillsRules.safeName(name) else { throw NativeRPCError.invalidArguments("Use a short name with letters, numbers, dots, dashes or underscores.") }
        let target = folder.deletingLastPathComponent().appendingPathComponent(name)
        let file = folder.appendingPathComponent("SKILL.md")
        let props = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              props.isRegularFile == true, props.isSymbolicLink != true, (props.fileSize ?? 0) <= 262_144,
              (try folder.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              !FileManager.default.fileExists(atPath: target.path) else {
            throw NativeRPCError(code: "rename-refused", message: "The skill is linked, too large, or that name already exists. Nothing was renamed.")
        }
        let original = try Data(contentsOf: file)
        let body = try renamed(String(decoding: original, as: UTF8.self), name: name)
        try FileManager.default.moveItem(at: folder, to: target)
        do { try Data(body.utf8).write(to: target.appendingPathComponent("SKILL.md"), options: .atomic) }
        catch { try? FileManager.default.moveItem(at: target, to: folder); throw error }
        return target
    }
}
