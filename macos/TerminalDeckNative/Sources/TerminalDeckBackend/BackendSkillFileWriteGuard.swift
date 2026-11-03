import Foundation
import TerminalDeckNativeCore

/// Generic downloads can become skills or commands when saved in an AI's folders.
/// Check their final destination, including an alias pointing into those folders.
enum BackendSkillFileWriteGuard {
    private static func paths(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return Array(Set([url.path, BackendROUTINESSkillsScope.canonical(url.path)]))
    }
    static func require(path: String, bytes: Data) throws {
        for destination in paths(path) where SkillCommandNames.protects(path: destination) {
            let skill = URL(fileURLWithPath: destination).lastPathComponent.lowercased() == "skill.md"
            if skill && bytes.count > 262_144 { throw NativeRPCError.invalidArguments("A skill file must be under 256 KB.") }
            try SkillCommandNames.requireFile(path: destination, text: skill ? String(decoding: bytes, as: UTF8.self) : "", targets: SkillCommandNames.targets(path: destination))
        }
    }
    static func require(path: String, stagedFile: URL) throws {
        guard paths(path).contains(where: { SkillCommandNames.protects(path: $0) }) else { return }
        if URL(fileURLWithPath: path).lastPathComponent.lowercased() != "skill.md" {
            try require(path: path, bytes: Data()); return
        }
        let file = try FileHandle(forReadingFrom: stagedFile); defer { try? file.close() }
        let bytes = try file.read(upToCount: 262_145) ?? Data()
        try require(path: path, bytes: bytes)
    }
}
