import Foundation

/// Source task-agent launch constraints and owned system-prompt files.
/// An absent model leaves the agent's own default/account configuration alone.
/// Runtime MCP/browser/project tool additions are backend-owned composition
/// supplied in context.extraArguments/environmentOverrides, never renderer argv.
public struct BackendNativeInstructions: BackendInstructionLaunchResolver, Sendable {
    public let readiness: BackendLaunchReadiness = .ready
    private let storageRoot: URL

    public init(storageRoot: URL) throws {
        guard storageRoot.isFileURL, storageRoot.path.hasPrefix("/") else {
            throw BackendSessionFailure.invalidInput("Agent instructions need the app's own absolute remote storage folder.")
        }
        self.storageRoot = storageRoot.standardizedFileURL
    }

    public func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                          context: BackendLaunchContext) async throws -> [String] {
        var arguments: [String] = []
        if let file = input.agentDefinitionsFile {
            guard provider.id == "claude", let name = input.claudeAgent else { throw BackendSessionFailure.invalidInput("An owned Claude agent definition needs its named Claude identity.") }
            arguments += try BackendTAGAgentDefinitionLaunch.arguments(file: file, storageRoot: storageRoot, name: name)
        }
        arguments += try BackendTAGLaunchArguments.arguments(input, provider: provider.id)
        let denied = input.deniedTools ?? []
        if !denied.isEmpty || input.noSkills == true {
            guard provider.id == "claude" else {
                throw BackendSessionFailure.unsupported("Only Claude Code can block named tools or turn every skill off; this agent was not started.")
            }
            guard denied.allSatisfy({ $0.range(of: #"^(?:[A-Z][A-Za-z0-9]{0,63}|mcp__[A-Za-z0-9_-]{1,64}(?:__[A-Za-z0-9_-]{1,64})?)$"#, options: .regularExpression) != nil }) else {
                throw BackendSessionFailure.invalidInput("A blocked tool name is invalid.")
            }
            if !denied.isEmpty { arguments += ["--disallowedTools", denied.joined(separator: ",")] }
            if input.noSkills == true { arguments.append("--disable-slash-commands") }
        }
        if let agentID = input.agentInstructions, input.claudeAgent == nil {
            // TS agents/agent-launch.ts instructionLaunchArgs, in its order and words.
            guard agentID.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else {
                throw BackendSessionFailure.invalidInput("\(agentID) is not a task agent id.")
            }
            guard ["claude", "codex"].contains(provider.id) else {
                throw BackendSessionFailure.unsupported("This coding agent cannot be given standing instructions at the start, so the task agent was not started on it.")
            }
            let root = storageRoot
            let instruction = try await Task.detached(priority: .utility) { try Self.readInstruction(agentID, storageRoot: root) }.value
            if provider.id == "claude" { arguments += ["--append-system-prompt-file", instruction.file.path] }
            else { arguments += ["-c", "developer_instructions=" + Self.tomlString(instruction.text)] }
        }
        if let model = input.model, !model.isEmpty {
            guard provider.id == "claude" else {
                throw BackendSessionFailure.unsupported("This app has not connected model selection for this coding agent; it was not started with an ignored model.")
            }
            guard !model.contains("\0"), model.utf8.count <= 512 else { throw BackendSessionFailure.invalidInput("The session model is invalid.") }
            arguments += ["--model", model]
        }
        guard (arguments + context.extraArguments).allSatisfy({ !$0.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("The session launch contains an invalid argument.")
        }
        return arguments
    }

    private struct Instruction: Sendable { let file: URL; let text: String }

    /// TS instructionLaunchArgs + agent-instructions.ts readInstructions: a file
    /// that cannot be read, or is blank, is "missing or empty"; past 32000
    /// characters it is refused as too long. The folder never escapes storage.
    private static func readInstruction(_ id: String, storageRoot: URL) throws -> Instruction {
        let root = storageRoot.resolvingSymlinksInPath().appendingPathComponent("agent-instructions", isDirectory: true)
        let file = root.appendingPathComponent(id + ".md")
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw BackendSessionFailure.invalidInput("The task agent's instructions must remain in the app's own instructions folder.")
        }
        let missing = BackendSessionFailure.invalidInput("The instructions file for \(id) is missing or empty (\(file.path)). Save the agent’s instructions again, or clear them.")
        let tooLong = BackendSessionFailure.invalidInput("The instructions file for \(id) is longer than 32000 characters. Shorten it.")
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { throw missing }
        // Four bytes per character at most: a larger file cannot be within the limit.
        guard (values.fileSize ?? Int.max) <= 128_000 else { throw tooLong }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw missing }
        guard text.utf16.count <= 32_000 else { throw tooLong }
        return Instruction(file: file, text: text)
    }

    public static func tomlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00...0x1f, 0x7f: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
