import Foundation
import Darwin
import TerminalDeckNativeCore

/// Read-only inventory and preflight for the existing profile importer. The
/// caller owns folder grants and approval; this helper never broadens its scan.
public enum BackendPROJAgentBatches {
    /// Folders in ONE import request (a request size). There is no limit on how many agents are imported.
    public static let maximumBatches = 32
    public struct Batch: Sendable {
        public let folder: String
        public let projectID: String
        public let options: NativeRPCValue
        public let selectedFiles: [String]?
    }

    /// Only direct, canonical, regular Markdown files from this directory may
    /// be selected. Source bodies remain in their files; no instructions copy.
    public static func selectedFiles(_ raw: NativeRPCValue, directory: URL) throws -> Set<String> {
        let values = try raw.requireArray("selected agent files")
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var selected = Set<String>()
        for value in values {
            let path = try value.requireString("selected agent file", nonempty: true)
            let file = try regularFile(path, directory: directory)
            guard selected.insert(file.path).inserted else { throw NativeRPCError.invalidArguments("An agent file was selected more than once.") }
            guard try BackendTAGAgentImport.read(file) != nil else { throw NativeRPCError.invalidArguments("The selected file has no agent definition.") }
        }
        return selected
    }

    /// Validates every batch and selection before callers enter a write path.
    /// Older folder/options requests keep their settings and override meanings.
    public static func batches(_ request: NativeRPCValue, projects: [PROJProject]) throws -> [Batch] {
        _ = try request.requireObject("agent import")
        let grouped = request.has("batches")
        let inputs: [NativeRPCValue]
        if grouped {
            guard !request.has("folder") else { throw NativeRPCError.invalidArguments("Choose batches or one folder, not both.") }
            inputs = try request["batches"].requireArray("agent batches")
            guard !inputs.isEmpty, inputs.count <= maximumBatches else { throw NativeRPCError.invalidArguments("Choose from 1 to 32 agent folders.") }
        } else { inputs = [request] }
        var result: [Batch] = [], directories = Set<String>(), paths = Set<String>()
        for input in inputs {
            _ = try input.requireObject("agent batch")
            if grouped {
                let allowed: Set<String> = ["folder", "projectId", "project", "selectedFiles"]
                guard input.fields?.allSatisfy({ allowed.contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("An agent batch accepts folder, projectId or project, and selectedFiles.") }
            }
            let folder = try input["folder"].requireString("agent folder", nonempty: true)
            let directory = try BackendTAGAgentImport.directory(folder)
            guard directories.insert(directory.path).inserted else { throw NativeRPCError.invalidArguments("Choose a project once for each agent folder.") }
            let rawOptions = grouped ? NativeRPCValue.object([]) : input["options"]
            let rawSelected: NativeRPCValue
            if input.has("selectedFiles") { rawSelected = input["selectedFiles"] }
            else { rawSelected = rawOptions["selectedFiles"] }
            var options = try BackendTAGAgentImport.options(rawOptions.removing("selectedFiles"))
            // removing() on null/missing produces an empty object, as old options do.
            if !rawOptions.isNullish { _ = try rawOptions.requireObject("import options") }
            let chosen: NativeRPCValue
            if input.has("projectId") && input.has("project") && input["projectId"] != input["project"] {
                throw NativeRPCError.invalidArguments("Choose one project for the batch.")
            }
            if input.has("projectId") { chosen = input["projectId"] }
            else if input.has("project") { chosen = input["project"] }
            else { chosen = options["projectId"] }
            let id: String
            if chosen == .null { id = PROJProjects.independentID }
            else if chosen == .missing { id = PROJProjects.resolve(projectID: nil, folder: folder, projects: projects) }
            else {
                guard let value = chosen.string, PROJProjects.isValidID(value) else { throw NativeRPCError.invalidArguments("Choose a valid project, or Independent.") }
                id = value
            }
            if chosen != .missing || id != PROJProjects.independentID {
                options = options.setting("projectId", .string(id)).setting("projectIdInferred", .bool(false))
            }
            let projectRoot = directory.deletingLastPathComponent().deletingLastPathComponent().path
            if grouped || !options.has("defaultProject") { options = options.setting("defaultProject", .string(projectRoot)) }
            let selected: [String]?
            if rawSelected == .missing {
                selected = nil
                _ = try markdownFiles(directory)
            } else {
                let values = try selectedFiles(rawSelected, directory: directory).sorted()
                for path in values where !paths.insert(path).inserted { throw NativeRPCError.invalidArguments("An agent file was selected more than once across the batches.") }
                selected = values
                options = options.setting("selectedFiles", .array(values.map(NativeRPCValue.string)))
            }
            result.append(.init(folder: directory.path, projectID: id, options: options, selectedFiles: selected))
        }
        return result
    }

    /// Scans ONLY caller-approved folders. Projects are inference metadata.
    /// A registered root with no agents is normal; invalid extra folders report
    /// an error. Explicit missing registered roots are rejected by the caller.
    public static func scan(folders: [String], projects: [PROJProject], agents: [NativeRPCValue]) throws -> NativeRPCValue {
        guard folders.count <= 256 else { throw NativeRPCError.invalidArguments("Too many agent folders to scan at once.") }
        let registered = Set(projects.flatMap(\.folders).map(PROJProjects.normalize))
        var seen = Set<String>(), groups: [NativeRPCValue] = [], errors: [NativeRPCValue] = []
        let imported = Set(agents.compactMap { $0["sourceFile"].string }.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
        for folder in folders {
            do {
                if registered.contains(PROJProjects.normalize(folder)), !agentDirectoryExists(folder) { continue }
                let directory = try BackendTAGAgentImport.directory(folder)
                guard seen.insert(directory.path).inserted else { continue }
                var rows: [NativeRPCValue] = [], problems: [NativeRPCValue] = []
                for file in try markdownFiles(directory) {
                    do {
                        let canonical = try regularFile(file.path, directory: directory)
                        guard let definition = try BackendTAGAgentImport.read(canonical) else { continue }
                        rows.append(.object([.init("file", .string(canonical.path)), .init("name", .string(definition.name)),
                            .init("alreadyImported", .bool(imported.contains(canonical.path)))]))
                    } catch { problems.append(problem(file: file.path, error: error)) }
                }
                let id = PROJProjects.resolve(projectID: nil, folder: folder, projects: projects)
                groups.append(.object([.init("folder", .string(directory.path)), .init("projectId", .string(id)),
                    .init("agents", .array(rows)), .init("errors", .array(problems))]))
            } catch { errors.append(problem(file: folder, error: error)) }
        }
        return .object([.init("batches", .array(groups)), .init("errors", .array(errors))])
    }

    public static func preview(configuration: BackendTaskConfiguration, request: NativeRPCValue, projects: [PROJProject]) async throws -> [String] {
        let values = try batches(request, projects: projects)
        var names: [String] = []
        for batch in values { names.append(contentsOf: try await configuration.importPreview(folder: batch.folder, options: batch.options)) }
        return names
    }

    /// The existing configuration owns import policy, saves, and source watches.
    /// All previews must succeed before the first import can write anything.
    public static func importBatches(configuration: BackendTaskConfiguration, request: NativeRPCValue, projects: [PROJProject],
        narrowOnly: Bool = false, inheritedPermissionMode: String = "default", callerKeyID: String? = nil,
        authorizeProject: (@Sendable (String) async throws -> Void)? = nil) async throws -> NativeRPCValue {
        let values = try batches(request, projects: projects)
        for batch in values {
            if let selected = batch.selectedFiles { _ = try selectedFiles(.array(selected.map(NativeRPCValue.string)), directory: URL(fileURLWithPath: batch.folder)) }
            _ = try await configuration.importPreview(folder: batch.folder, options: batch.options)
        }
        var results: [NativeRPCValue] = [], imported = 0, updated = 0, errors: [NativeRPCValue] = []
        for batch in values {
            if batch.selectedFiles?.isEmpty == true { continue }
            let answer = try await configuration.importAgents(folder: batch.folder, narrowOnly: narrowOnly,
                inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID, options: batch.options, authorizeProject: authorizeProject)
            if !request.has("batches") { return answer }
            imported += Int(answer["imported"].number ?? 0); updated += Int(answer["updated"].number ?? 0)
            errors.append(contentsOf: answer["errors"].elements ?? [])
            results.append(answer.setting("projectId", .string(batch.projectID)))
        }
        return .object([.init("batches", .array(results)), .init("agents", .array(try await configuration.allAgents())),
            .init("imported", .number(Double(imported))), .init("updated", .number(Double(updated))), .init("errors", .array(errors))])
    }

    private static func regularFile(_ path: String, directory: URL) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw NativeRPCError.invalidArguments("Choose a full agent file path.") }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.path, file.pathExtension.lowercased() == "md",
              file.resolvingSymlinksInPath().path == file.path else { throw NativeRPCError.invalidArguments("Choose a Markdown file directly inside this agents folder, without a link.") }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeRPCError.invalidArguments("The selected agent file is missing or is not a regular file.") }
        return file
    }
    private static func markdownFiles(_ directory: URL) throws -> [URL] {
        // Children are built from the canonical directory: a listing of /var/... reports /private/var/....
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.lowercased().hasSuffix(".md") }.sorted().map { directory.appendingPathComponent($0) }
    }
    private static func agentDirectoryExists(_ folder: String) -> Bool {
        let selected = URL(fileURLWithPath: folder).standardizedFileURL
        let directory: URL
        if selected.lastPathComponent == "agents", selected.deletingLastPathComponent().lastPathComponent == ".claude" { directory = selected }
        else if selected.lastPathComponent == ".claude" { directory = selected.appendingPathComponent("agents") }
        else { directory = selected.appendingPathComponent(".claude/agents") }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private static func problem(file: String, error: Error) -> NativeRPCValue {
        .object([.init("file", .string(file)), .init("message", .string(error.localizedDescription))])
    }
}
