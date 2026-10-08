import Foundation
import Darwin
import TerminalDeckNativeCore

/// Imported definitions remain one named Claude identity even when a task uses
/// an isolated workspace or another project. Only the app's owned JSON is written.
public enum BackendTAGAgentDefinitionLaunch {
    public static func prepare(agent: NativeRPCValue, specs: BackendTaskPersistence) throws -> String? {
        guard let name = agent["claudeAgent"].string, let source = agent["sourceFile"].string else { return nil }
        guard let definition = try BackendTAGAgentImport.read(URL(fileURLWithPath: source)), definition.name == name else {
            throw NativeRPCError.invalidArguments("The imported source no longer defines \(name). Sync the profile before starting it.")
        }
        guard !definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("The imported agent definition has no prompt body.") }
        let project = URL(fileURLWithPath: source).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let prompt = "This named Claude Code agent is imported from \(source). Relative .claude/ references in this definition belong to \(project). The task's working folder is supplied separately.\n\n" + definition.prompt
        var value = BackendTaskValues.object([("description", .string(definition.description)), ("prompt", .string(prompt))])
        if let model = agent["model"].string ?? definition.model { value = value.setting("model", .string(model)) }
        if let tools = agent["allowedTools"].elements { value = value.setting("tools", .array(tools)) }
        else if let tools = definition.tools { value = value.setting("tools", .array(tools.map(NativeRPCValue.string))) }
        let nameOnDisk = "\(Int(BackendTaskValues.time()))-\(UUID().uuidString.lowercased())-agent-definition.json"
        try specs.write(nameOnDisk, value: BackendTaskValues.object([(name, value)]))
        return try specs.file(nameOnDisk).path
    }
    /// The installed interactive CLI accepts JSON, while its file form requires
    /// --print. Read the owned snapshot and use JSON, with no appended identity.
    public static func arguments(file: String, storageRoot: URL, name: String) throws -> [String] {
        let root = storageRoot.appendingPathComponent("task-briefs", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let path = URL(fileURLWithPath: file).standardizedFileURL
        guard path.path.hasPrefix(root.path + "/"), path.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"), path.pathExtension == "json" else {
            throw BackendSessionFailure.invalidInput("The named agent definitions must remain in the app's own task brief folder.")
        }
        let persistence = try BackendTaskPersistence(directory: root)
        guard let parsed = try persistence.read(path.lastPathComponent, maximumBytes: 1_048_576),
              parsed.fields?.count == 1, parsed[name]["prompt"].string != nil else { throw BackendSessionFailure.invalidInput("The owned agent definition does not contain \(name).") }
        let bytes = try parsed.encodedJSON()
        guard bytes.count <= 128_000 else { throw BackendSessionFailure.invalidInput("The imported agent definition is too large for an interactive Claude launch. Shorten its prompt body.") }
        guard let json = String(data: bytes, encoding: .utf8) else { throw BackendSessionFailure.invalidInput("The owned agent definition is not text.") }
        return ["--agents", json]
    }
}
