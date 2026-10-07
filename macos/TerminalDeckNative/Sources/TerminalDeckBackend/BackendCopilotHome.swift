import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendCopilotPaths: Sendable, Equatable {
    public let root: String
    public let ownFolder: Bool
    public let instructions: String
    public let layer: BackendCopilotLayerPaths
    public let memory: String
    public let memoryIndex: String
    public let log: String
    public let actions: String
    public init(userData: String, home: String? = nil) {
        let fallback = BackendCopilotHome.defaultHome(userData)
        root = home.flatMap { BackendSharedText.trim($0).isEmpty ? nil : $0 } ?? fallback
        ownFolder = root == fallback
        layer = BackendCopilotLayerPaths(userData: userData)
        instructions = layer.yours
        memory = BackendCopilotStorageIO.join(root, "memory")
        memoryIndex = BackendCopilotStorageIO.join(memory, "MEMORY.md")
        log = BackendCopilotStorageIO.join(userData, "copilot-log")
        actions = BackendCopilotStorageIO.join(log, "actions.jsonl")
    }
    public var wireValue: NativeRPCValue {
        .object([.init("root", .string(root)), .init("ownFolder", .bool(ownFolder)), .init("instructions", .string(instructions)),
            .init("layer", .object([.init("dir", .string(layer.dir)), .init("yours", .string(layer.yours)),
                .init("contract", .string(layer.contract)), .init("composed", .string(layer.composed))])),
            .init("memory", .string(memory)), .init("memoryIndex", .string(memoryIndex)), .init("log", .string(log)), .init("actions", .string(actions))])
    }
    public static func == (a: Self, b: Self) -> Bool { a.wireValue == b.wireValue }
}

public struct BackendCopilotAction: Sendable {
    public let action: String
    public let detail: String?
    public let sessionId: String?
    public init(action: String, detail: String? = nil, sessionId: String? = nil) {
        self.action = action; self.detail = detail; self.sessionId = sessionId
    }
}
public struct BackendCopilotScaffoldResult: Sendable {
    public let created: [String]
    public let removed: [String]
    public let error: String?
    public var wireValue: NativeRPCValue { .object([.init("created", .array(created.map(NativeRPCValue.string))),
        .init("removed", .array(removed.map(NativeRPCValue.string))), .init("error", BackendCopilotStorageIO.optional(error))]) }
}
public enum BackendCopilotInstructionsState: String, Codable, Sendable { case missing, current, superseded, edited }
public struct BackendCopilotStartupFile: Sendable {
    public let path: String
    public let purpose: String
    public let exists: Bool
    public let size: Int?
    public let modifiedAt: Double?
    public let owner: String
    public var wireValue: NativeRPCValue { .object([.init("path", .string(path)), .init("purpose", .string(purpose)),
        .init("exists", .bool(exists)), .init("size", BackendCopilotStorageIO.optional(size)),
        .init("modifiedAt", BackendCopilotStorageIO.optional(modifiedAt)), .init("owner", .string(owner))]) }
}
public struct BackendCopilotHomeReport: Sendable {
    public let paths: BackendCopilotPaths
    public let instructions: BackendCopilotInstructionsState
    public let startupFiles: [BackendCopilotStartupFile]
    public let layerFiles: [BackendCopilotStartupFile]
    public var instructionsAreDefault: Bool { instructions == .current }
    public var wireValue: NativeRPCValue { .object([.init("paths", paths.wireValue), .init("instructionsAreDefault", .bool(instructionsAreDefault)),
        .init("instructions", .string(instructions.rawValue)), .init("startupFiles", .array(startupFiles.map(\.wireValue))), .init("layerFiles", .array(layerFiles.map(\.wireValue)))]) }
}
public struct BackendCopilotInstructionsRead: Sendable {
    public let ok: Bool
    public let text: String?
    public let state: BackendCopilotInstructionsState?
    public let path: String
    public let error: String?
    public var wireValue: NativeRPCValue {
        var value: NativeRPCValue = .object([.init("ok", .bool(ok)), .init("path", .string(path))])
        if ok { value = value.setting("text", .string(text ?? "")).setting("state", .string(state?.rawValue ?? "missing")) }
        else { value = value.setting("error", BackendCopilotStorageIO.optional(error)) }
        return value
    }
}
public struct BackendCopilotInstructionsWrite: Sendable {
    public let saved: Bool
    public let backup: String?
    public let error: String?
    public var wireValue: NativeRPCValue { .object([.init("saved", .bool(saved)), .init("backup", BackendCopilotStorageIO.optional(backup)), .init("error", BackendCopilotStorageIO.optional(error))]) }
}
public struct BackendCopilotResetResult: Sendable {
    public let reset: Bool
    public let backup: String?
    public let error: String?
    public var wireValue: NativeRPCValue { .object([.init("reset", .bool(reset)), .init("backup", BackendCopilotStorageIO.optional(backup)), .init("error", BackendCopilotStorageIO.optional(error))]) }
}
public struct BackendCopilotFolderInstructionsRead: Sendable {
    public let path: String; public let text: String; public let exists: Bool; public let error: String?
    public var wireValue: NativeRPCValue { .object([.init("path", .string(path)), .init("text", .string(text)), .init("exists", .bool(exists)), .init("error", BackendCopilotStorageIO.optional(error))]) }
}
public struct BackendCopilotFolderInstructionsWrite: Sendable {
    public let saved: Bool; public let backup: String?; public let created: Bool; public let error: String?
    public var wireValue: NativeRPCValue { .object([.init("saved", .bool(saved)), .init("backup", BackendCopilotStorageIO.optional(backup)), .init("created", .bool(created)), .init("error", BackendCopilotStorageIO.optional(error))]) }
}

public enum BackendCopilotHome {
    public static let maxInstructionsBytes = 256 * 1024
    public static let logLimitBytes = 4 * 1024 * 1024
    public static func defaultHome(_ userData: String) -> String { BackendCopilotStorageIO.join(userData, "copilot") }
    public static func folderInstructions(_ paths: BackendCopilotPaths) -> String { BackendCopilotStorageIO.join(paths.root, "CLAUDE.md") }
    public static func folderInstructionsBackup(_ paths: BackendCopilotPaths) -> String { BackendCopilotStorageIO.join(paths.layer.dir, "folder-instructions.bak") }
    public static func legacyRoutinesDir(_ paths: BackendCopilotPaths) -> String { BackendCopilotStorageIO.join(paths.root, "routines") }
    public static func legacyLogDir(_ paths: BackendCopilotPaths) -> String { BackendCopilotStorageIO.join(paths.root, "log") }
    public static func legacyInstructionsFile(_ paths: BackendCopilotPaths) -> String { folderInstructions(paths) }

    public static func appendAction(_ paths: BackendCopilotPaths, _ entry: BackendCopilotAction, now: Date = Date()) {
        do {
            // Request 8: the one shared raw writer for copilot-log/actions.jsonl,
            // the same sink deck-core's action log appends through. Same bytes,
            // same >=4 MiB rotation of the existing file.
            try BackendHootJoinRawSink.shared(directory: URL(fileURLWithPath: paths.log, isDirectory: true)).home(entry, now: now)
        } catch { /* Source log failures are deliberately nonfatal. */ }
    }

    public static func scaffold(_ paths: BackendCopilotPaths) -> BackendCopilotScaffoldResult {
        var created: [String] = [], removed: [String] = []
        do {
            for dir in [paths.layer.dir, paths.log] where try BackendCopilotStorageIO.mkdir(dir) { created.append(dir) }
            if paths.ownFolder && !BackendCopilotStorageIO.exists(paths.instructions)
                && BackendCopilotStorageIO.regularFile(legacyInstructionsFile(paths)) {
                if (try? BackendCopilotStorageIO.rename(legacyInstructionsFile(paths), paths.instructions)) != nil {
                    removed.append(legacyInstructionsFile(paths))
                }
            }
            if try BackendCopilotStorageIO.write(paths.instructions, instructions(), exclusive: true) { created.append(paths.instructions) }
            if paths.ownFolder {
                for dir in [paths.root, paths.memory] where try BackendCopilotStorageIO.mkdir(dir) { created.append(dir) }
                if Darwin.rmdir(legacyRoutinesDir(paths)) == 0 { removed.append(legacyRoutinesDir(paths)) }
                let oldLog = legacyLogDir(paths)
                if BackendCopilotStorageIO.directory(oldLog) {
                    for name in ["actions.jsonl", "actions.jsonl.1"] {
                        let destination = BackendCopilotStorageIO.join(paths.log, name)
                        if !BackendCopilotStorageIO.exists(destination) { try? BackendCopilotStorageIO.rename(BackendCopilotStorageIO.join(oldLog, name), destination) }
                    }
                    if Darwin.rmdir(oldLog) == 0 { removed.append(oldLog) }
                }
                if try BackendCopilotStorageIO.write(paths.memoryIndex, "# Memory index\n\nOne file per fact, in this directory. This file lists them, newest first.\n\nNothing has been remembered yet.\n", exclusive: true) {
                    created.append(paths.memoryIndex)
                }
            }
            return .init(created: created, removed: removed, error: nil)
        } catch { return .init(created: created, removed: removed, error: error.localizedDescription) }
    }

    public static func startupFiles(_ paths: BackendCopilotPaths, list: ((String) -> [String])? = nil) -> [BackendCopilotStartupFile] {
        var files = [describe(paths.layer.composed, "\(BackendSharedBrand.assistant)’s layer — handed to it on the command line, never written into the folder", "app"),
            describe(folderInstructions(paths), paths.ownFolder
                ? "The folder’s own instructions. This app never writes one here — an empty row means nothing in this folder claims to be \(BackendSharedBrand.assistant)"
                : "The folder’s own instructions — yours, read the ordinary way, never written by this app", "folder"),
            describe(paths.memoryIndex, "Memory index", "folder")]
        let memories = list?(paths.memory) ?? ((try? FileManager.default.contentsOfDirectory(atPath: paths.memory)) ?? []).filter { $0.hasSuffix(".md") }.sorted().map { BackendCopilotStorageIO.join(paths.memory, $0) }
        for file in memories where file != paths.memoryIndex { files.append(describe(file, "Memory", "folder")) }
        return files
    }
    public static func layerFiles(_ paths: BackendCopilotPaths) -> [BackendCopilotStartupFile] {
        [describe(paths.layer.yours, "Yours — the persona and the standing instructions. Editable, and never written over.", "yours"),
         describe(paths.layer.contract, "The app’s — the tool contract and the permission rules. Generated from the live tool catalogue every time \(BackendSharedBrand.assistant) starts.", "app"),
         describe(paths.layer.composed, "The two of them composed — byte for byte what \(BackendSharedBrand.assistant) was handed when it last started.", "app")]
    }
    private static func describe(_ path: String, _ purpose: String, _ owner: String) -> BackendCopilotStartupFile {
        var s = stat()
        guard stat(path, &s) == 0 else { return .init(path: path, purpose: purpose, exists: false, size: nil, modifiedAt: nil, owner: owner) }
        return .init(path: path, purpose: purpose, exists: true, size: Int(s.st_size), modifiedAt: Double(s.st_mtimespec.tv_sec) * 1000 + Double(s.st_mtimespec.tv_nsec) / 1_000_000, owner: owner)
    }
    public static func instructionsState(_ paths: BackendCopilotPaths) -> BackendCopilotInstructionsState {
        guard let current = try? BackendCopilotStorageIO.read(paths.instructions) else { return .missing }
        if current == instructions() { return .current }
        return BackendCopilotHistory.rendered(paths).contains(current) ? .superseded : .edited
    }
    public static func report(_ paths: BackendCopilotPaths) -> BackendCopilotHomeReport {
        .init(paths: paths, instructions: instructionsState(paths), startupFiles: startupFiles(paths), layerFiles: layerFiles(paths))
    }
    public static func readInstructions(_ paths: BackendCopilotPaths) -> BackendCopilotInstructionsRead {
        do { return .init(ok: true, text: try BackendCopilotStorageIO.read(paths.instructions), state: instructionsState(paths), path: paths.instructions, error: nil) }
        catch { return .init(ok: false, text: nil, state: nil, path: paths.instructions,
            error: BackendCopilotStorageIO.isMissing(error) ? "There are no instructions yet. Create its files first." : error.localizedDescription) }
    }
    public static func resetInstructions(_ paths: BackendCopilotPaths) -> BackendCopilotResetResult {
        let previous = try? BackendCopilotStorageIO.read(paths.instructions), backup = paths.instructions + ".bak"
        do {
            try BackendCopilotStorageIO.mkdir(paths.layer.dir)
            if let previous { try BackendCopilotStorageIO.write(backup, previous) }
            try BackendCopilotStorageIO.write(paths.instructions, instructions())
            return .init(reset: true, backup: previous == nil ? nil : backup, error: nil)
        } catch { return .init(reset: false, backup: nil, error: error.localizedDescription) }
    }
    public static func writeInstructions(_ paths: BackendCopilotPaths, text raw: NativeRPCValue) -> BackendCopilotInstructionsWrite {
        if let error = validation(raw, folder: false) { return .init(saved: false, backup: nil, error: error) }
        let text = raw.string!, previous = try? BackendCopilotStorageIO.read(paths.instructions), backup = paths.instructions + ".bak"
        if previous == text { return .init(saved: true, backup: nil, error: nil) }
        do {
            try BackendCopilotStorageIO.mkdir(paths.layer.dir)
            if let previous { try BackendCopilotStorageIO.write(backup, previous) }
            try BackendCopilotStorageIO.write(paths.instructions, text)
            return .init(saved: true, backup: previous == nil ? nil : backup, error: nil)
        } catch { return .init(saved: false, backup: nil, error: error.localizedDescription) }
    }
    public static func readFolderInstructions(_ paths: BackendCopilotPaths) -> BackendCopilotFolderInstructionsRead {
        let path = folderInstructions(paths)
        do { return .init(path: path, text: try BackendCopilotStorageIO.read(path), exists: true, error: nil) }
        catch { return .init(path: path, text: "", exists: false, error: BackendCopilotStorageIO.isMissing(error) ? nil : error.localizedDescription) }
    }
    public static func writeFolderInstructions(_ paths: BackendCopilotPaths, text raw: NativeRPCValue) -> BackendCopilotFolderInstructionsWrite {
        if let error = validation(raw, folder: true) { return .init(saved: false, backup: nil, created: false, error: error) }
        let path = folderInstructions(paths), text = raw.string!, previous = try? BackendCopilotStorageIO.read(path)
        if previous == text { return .init(saved: true, backup: nil, created: false, error: nil) }
        do {
            var backup: String?
            if let previous {
                backup = folderInstructionsBackup(paths)
                try BackendCopilotStorageIO.mkdir(paths.layer.dir)
                try BackendCopilotStorageIO.write(backup!, previous)
            }
            // No mkdir of the chosen folder, and no permission changes to their existing file.
            try BackendCopilotStorageIO.write(path, text, mode: 0o666)
            return .init(saved: true, backup: backup, created: previous == nil, error: nil)
        } catch { return .init(saved: false, backup: nil, created: false, error: error.localizedDescription) }
    }
    private static func validation(_ raw: NativeRPCValue, folder: Bool) -> String? {
        guard let text = raw.string else { return "Nothing was supplied to save." }
        if BackendSharedText.trim(text).isEmpty {
            return folder ? "This is a file in your own folder, so this app will not blank it for you. Delete it yourself if that is what you want."
                : "Instructions cannot be empty — \(BackendSharedBrand.assistant) with no instructions still has its tools and its boundary, and nothing telling it what it is for."
        }
        return text.utf8.count > maxInstructionsBytes ? "Instructions cannot be larger than 256 KB. This file is read at the start of every conversation." : nil
    }
}
