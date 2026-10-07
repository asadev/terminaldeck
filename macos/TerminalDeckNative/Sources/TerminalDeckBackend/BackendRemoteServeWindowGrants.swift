import Foundation
import TerminalDeckNativeCore

/// Correct window-grants.ts adapter. Existing BackendRemoteTrustStore has the
/// same schema, but lacks the source's 64 KiB ceiling/no-op writes and its forget
/// mutates window permissions before a failed disk write. Use one window owner.
public actor BackendRemoteServeWindowGrants {
    public static let fileName = "remote-windows.json"
    public nonisolated let file: URL
    public typealias Writer = @Sendable (NativeRPCValue, URL) throws -> Void
    private let kind: @Sendable (String) async -> BackendRemoteDeviceKind
    private let writer: Writer
    private let changed: @Sendable () async -> Void
    private let report: @Sendable (String) -> Void
    private var allowed: [String] = [], denied: [String] = []
    private var opened = false
    public init(directory: URL, kindOf: @escaping @Sendable (String) async -> BackendRemoteDeviceKind = { _ in .guest },
                write: Writer? = nil,
                onChange: @escaping @Sendable () async -> Void = {}, report: (@Sendable (String) -> Void)? = nil) {
        file = directory.appendingPathComponent(Self.fileName); kind = kindOf
        writer = write ?? { try BackendRemoteServeWindowFile.write($0, $1) }; changed = onChange
        self.report = report ?? { BackendRemoteServeWindowFile.report($0) }
    }
    public func open() {
        guard !opened else { return }
        let raw = BackendRemoteServeWindowFile.read(file,
            oversized: "[remote] the remote window grant list is implausibly large; ignoring it",
            parseFailure: "[remote] could not read the remote window grant list:", report: report)
        denied = BackendRemoteServeWindowFile.ids(raw["denied"])
        allowed = BackendRemoteServeWindowFile.ids(raw["devices"]).filter { !denied.contains($0) }
        opened = true
    }
    public func drives(_ id: String) async throws -> Bool {
        try requireOpen()
        guard !id.isEmpty else { return false }
        if denied.contains(id) { return false }; if allowed.contains(id) { return true }
        let own = await kind(id) == .mine
        // A grant may change while the async kind provider answers.
        try requireOpen(); if denied.contains(id) { return false }; if allowed.contains(id) { return true }; return own
    }
    public func list() throws -> [String] { try requireOpen(); return allowed }
    @discardableResult public func set(_ rawID: NativeRPCValue, drives: NativeRPCValue) async throws -> Bool {
        try requireOpen()
        guard let supplied = rawID.string, let id = BackendRemoteServeWindowFile.validID(supplied) else { return false }
        let wanted = drives.bool == true
        let into = wanted ? allowed : denied, outOf = wanted ? denied : allowed
        if into.contains(id) && !outOf.contains(id) { return try await self.drives(id) }
        if !into.contains(id), into.count >= 64 { return try await self.drives(id) }
        var nextAllowed = allowed, nextDenied = denied
        if wanted { if !nextAllowed.contains(id) { nextAllowed.append(id) }; nextDenied.removeAll { $0 == id } }
        else { if !nextDenied.contains(id) { nextDenied.append(id) }; nextAllowed.removeAll { $0 == id } }
        try commit(allowed: nextAllowed, denied: nextDenied)
        await changed(); return try await self.drives(id)
    }
    @discardableResult public func forget(_ id: String) async throws -> Bool {
        try requireOpen(); guard allowed.contains(id) || denied.contains(id) else { return false }
        try commit(allowed: allowed.filter { $0 != id }, denied: denied.filter { $0 != id }); await changed(); return true
    }
    public func close() { opened = false; allowed = []; denied = [] }
    private func commit(allowed: [String], denied: [String]) throws {
        try writer(.object([.init("version", .number(1)), .init("devices", .array(allowed.map(NativeRPCValue.string))), .init("denied", .array(denied.map(NativeRPCValue.string)))]), file)
        self.allowed = allowed; self.denied = denied
    }
    private func requireOpen() throws { guard opened else { throw NativeRPCError(code: "unavailable", message: "Open the remote window grant store before reading or changing permissions") } }
}

/// Common source limits/format; preserves JS Set insertion order and trims ids.
enum BackendRemoteServeWindowFile {
    private static let trim = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    static func validID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: trim)
        return !id.isEmpty && id.utf16.count <= 200 ? id : nil
    }
    static func ids(_ value: NativeRPCValue) -> [String] {
        var result: [String] = []
        for value in value.elements ?? [] {
            if result.count >= 64 { break }
            guard let raw = value.string, let id = validID(raw), !result.contains(id) else { continue }; result.append(id)
        }
        return result
    }
    static func read(_ file: URL, oversized: String, parseFailure: String, report: @Sendable (String) -> Void) -> NativeRPCValue {
        // TS checks decoded String.length, in UTF-16 units, before parsing.
        guard let data = try? Data(contentsOf: file) else { return .object([]) }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf16.count <= 65_536 else { report(oversized); return .object([]) }
        do { let raw = try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 262_144); return raw.fields == nil ? .object([]) : raw }
        catch { report(parseFailure + " " + error.localizedDescription); return .object([]) }
    }
    static func report(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    static func write(_ value: NativeRPCValue, _ file: URL) throws {
        var contents = try value.encodedJSON(pretty: true); contents.append(0x0a)
        try BackendRemoteServeSecretFile.write(directory: file.deletingLastPathComponent(), file: file, contents: contents)
    }
}

public enum BackendRemoteServeWindowGrantChannels {
    public static func register(registry: NativeChannelRegistry, grants: BackendRemoteServeWindowGrants, trust: BackendRemoteTrustStore, ownerID: String = "remote-serve-windows") async throws {
        let effective: @Sendable () async throws -> NativeRPCValue = {
            var ids: [NativeRPCValue] = []
            for device in await trust.listDevices().sorted(by: { $0.addedAt > $1.addedAt }) { if try await grants.drives(device.id) { ids.append(.string(device.id)) } }
            return .array(ids)
        }
        let owner: NativeChannelRegistry.Policy = { context in
            guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only this app's owner may change remote browser permissions") }
        }
        try await registry.register("remote:windows", ownerID: ownerID, policy: owner) { _, _ in try await effective() }
        try await registry.register("remote:windows:set", ownerID: ownerID, policy: owner) { context, args in
            _ = try await grants.set(context.argument(0, in: args), drives: context.argument(1, in: args)); return try await effective()
        }
    }
}
