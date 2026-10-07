import Foundation
import TerminalDeckNativeCore

public struct BackendCopilotFolderVerdict: Sendable {
    public let ok: Bool; public let path: String?; public let problem: String?
    public var wireValue: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("path", BackendCopilotStorageIO.optional(path)), .init("problem", BackendCopilotStorageIO.optional(problem))]) }
}
public struct BackendCopilotFolderReport: Sendable {
    public let home: String; public let chosen: String?; public let isDefault: Bool; public let problem: String?
    public let runningIn: String?; public let restartNeeded: Bool
    public var wireValue: NativeRPCValue { .object([.init("home", .string(home)), .init("chosen", BackendCopilotStorageIO.optional(chosen)),
        .init("isDefault", .bool(isDefault)), .init("problem", BackendCopilotStorageIO.optional(problem)), .init("runningIn", BackendCopilotStorageIO.optional(runningIn)), .init("restartNeeded", .bool(restartNeeded))]) }
}
public struct BackendCopilotFolderChangeResult: Sendable {
    public let report: BackendCopilotFolderReport; public let problem: String?; public let cancelled: Bool
    public var wireValue: NativeRPCValue { .object([.init("report", report.wireValue), .init("problem", BackendCopilotStorageIO.optional(problem)), .init("cancelled", .bool(cancelled))]) }
}
public enum BackendCopilotFolder {
    public static let homeSetting = "copilot.home"
    public static let choosing = CopilotFolderWords.choosing
    public static let needsRestart = CopilotFolderWords.needsRestart
    public static func chosenHome(_ stored: NativeRPCValue) -> String? {
        guard let text = stored.string, !BackendSharedText.trim(text).isEmpty else { return nil }
        return BackendCopilotStorageIO.normalize(BackendSharedText.trim(text))
    }
    public static func validate(_ raw: NativeRPCValue, userData: String,
                                checks: ((String) -> Bool)? = nil) -> BackendCopilotFolderVerdict {
        guard let raw = raw.string, !BackendSharedText.trim(raw).isEmpty else { return .init(ok: false, path: nil, problem: "No folder was chosen.") }
        let path = BackendCopilotStorageIO.normalize(BackendSharedText.trim(raw))
        if !path.hasPrefix("/") { return .init(ok: false, path: path, problem: "That has to be a full path — a relative one would be resolved against wherever this app happens to be running from.") }
        if path == "/" { return .init(ok: false, path: path, problem: "The root of the disk is not a working directory. Choose a folder inside it.") }
        let home = BackendCopilotHome.defaultHome(userData), data = BackendCopilotStorageIO.normalize(userData)
        if !within(path, home) && within(path, data) {
            return .init(ok: false, path: path, problem: "That is inside this app’s own storage, where the action log, the routines and the paired-device records are kept — the files \(BackendSharedBrand.assistant) is deliberately held away from. Choose a folder of your own.")
        }
        if !(checks?(path) ?? BackendCopilotStorageIO.directory(path)) { return .init(ok: false, path: path, problem: "There is no folder there, or it cannot be read. \(BackendSharedBrand.assistant) starts in it, so it has to exist first.") }
        return .init(ok: true, path: path, problem: nil)
    }
    public static func report(stored: NativeRPCValue, userData: String, runningIn: String? = nil,
                              checks: ((String) -> Bool)? = nil) -> BackendCopilotFolderReport {
        let fallback = BackendCopilotHome.defaultHome(userData), chosen = chosenHome(stored)
        let verdict = chosen.map { validate(.string($0), userData: userData, checks: checks) }
        let home = verdict?.ok == true ? (verdict?.path ?? fallback) : fallback
        return .init(home: home, chosen: chosen, isDefault: home == fallback, problem: verdict?.problem,
            runningIn: runningIn, restartNeeded: runningIn != nil && runningIn != home)
    }
    public static func pickerStart(_ report: BackendCopilotFolderReport, home: String) -> String {
        !report.isDefault ? (report.chosen ?? home) : home
    }
    private static func within(_ path: String, _ parent: String) -> Bool {
        let a = BackendCopilotStorageIO.normalize(path), b = BackendCopilotStorageIO.normalize(parent)
        // Node relative treats trailing separators as the same directory.
        let p = a.hasSuffix("/") && a != "/" ? String(a.dropLast()) : a
        let q = b.hasSuffix("/") && b != "/" ? String(b.dropLast()) : b
        return p == q || p.hasPrefix(q == "/" ? "/" : q + "/")
    }
}

/// Settings and AppKit provide these operations; no page-supplied folder path.
public protocol BackendCopilotFolderDependencies: Sendable {
    func userData() async throws -> String
    func read() async throws -> NativeRPCValue
    func write(_ value: String?) async throws
    func runningIn() async -> String?
    func pick(defaultPath: String) async throws -> String?
    func homeDir() async -> String
    func log(_ entry: BackendCopilotAction) async
}
public struct BackendCopilotFolderUnavailable: BackendCopilotFolderDependencies {
    public init() {}
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "Hoot's folder settings and native folder picker are unavailable.") }
    public func userData() async throws -> String { throw unavailable() }
    public func read() async throws -> NativeRPCValue { throw unavailable() }
    public func write(_ value: String?) async throws { throw unavailable() }
    public func runningIn() async -> String? { nil }
    public func pick(defaultPath: String) async throws -> String? { throw unavailable() }
    public func homeDir() async -> String { FileManager.default.homeDirectoryForCurrentUser.path }
    public func log(_ entry: BackendCopilotAction) async {}
}
public struct BackendCopilotFolderService: Sendable {
    private let deps: any BackendCopilotFolderDependencies
    public init(dependencies: any BackendCopilotFolderDependencies) { deps = dependencies }
    public func report() async throws -> BackendCopilotFolderReport {
        let stored = try await deps.read(), userData = try await deps.userData(), running = await deps.runningIn()
        return BackendCopilotFolder.report(stored: stored, userData: userData, runningIn: running)
    }
    public func pick() async throws -> BackendCopilotFolderChangeResult {
        let before = try await report(), home = await deps.homeDir()
        guard let picked = try await deps.pick(defaultPath: BackendCopilotFolder.pickerStart(before, home: home)) else {
            return .init(report: before, problem: nil, cancelled: true)
        }
        let verdict = BackendCopilotFolder.validate(.string(picked), userData: try await deps.userData())
        guard verdict.ok, let path = verdict.path else { return .init(report: before, problem: verdict.problem, cancelled: false) }
        try await deps.write(path)
        let after = try await report()
        await deps.log(.init(action: "folder.chosen", detail: "you pointed \(BackendSharedBrand.assistant) at \(path). Nothing of this app’s is written there; it takes effect the next time \(BackendSharedBrand.assistant) starts."))
        return .init(report: after, problem: nil, cancelled: false)
    }
    public func clear() async throws -> BackendCopilotFolderChangeResult {
        try await deps.write(nil)
        let after = try await report()
        await deps.log(.init(action: "folder.cleared", detail: "\(BackendSharedBrand.assistant) goes back to \(after.home) the next time it starts. Nothing was moved out of the folder you had chosen."))
        return .init(report: after, problem: nil, cancelled: false)
    }
    public func register(registry: NativeChannelRegistry, ownerID: String) async throws -> [String] {
        let channels = ["copilot:folder", "copilot:folder:pick", "copilot:folder:clear"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may change Hoot's working folder.") }
                try context.requireCount(args, 0...0)
                if channel == "copilot:folder" { return try await report().wireValue }
                if channel == "copilot:folder:pick" { return try await pick().wireValue }
                return try await clear().wireValue
            }
        }
        return channels
    }
}
