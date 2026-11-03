import Foundation

public struct SkillVersionFile: Codable, Equatable, Sendable {
    public let path: String, hash: String
    public let bytes: Int
    public let directory: Bool, executable: Bool
    public init(path: String, hash: String, bytes: Int, directory: Bool, executable: Bool) {
        self.path = path; self.hash = hash; self.bytes = bytes; self.directory = directory; self.executable = executable
    }
}
public struct SkillVersionRevision: Codable, Equatable, Sendable {
    public let id: String, label: String, digest: String, commandName: String
    public let createdAt: Double
    public let files: [SkillVersionFile]
    public init(id: String, label: String, digest: String, commandName: String, createdAt: Double, files: [SkillVersionFile]) {
        self.id = id; self.label = label; self.digest = digest; self.commandName = commandName; self.createdAt = createdAt; self.files = files
    }
    public var wire: NativeRPCValue { (try? NativeRPCValue.parseJSON(JSONEncoder().encode(self))) ?? .null }
}
public struct SkillVersionCheck: Codable, Equatable, Sendable {
    public let id: String, version: String, digest: String, validator: String
    public let at: Double
    public let passed: Bool
    public let findings: [String]
    public init(id: String, version: String, digest: String, validator: String, at: Double, passed: Bool, findings: [String]) {
        self.id = id; self.version = version; self.digest = digest; self.validator = validator; self.at = at; self.passed = passed; self.findings = findings
    }
    public var wire: NativeRPCValue { (try? NativeRPCValue.parseJSON(JSONEncoder().encode(self))) ?? .null }
}
