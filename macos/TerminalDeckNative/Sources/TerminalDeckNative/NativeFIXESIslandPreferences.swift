import AppKit
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// An observable view of the existing settings owner. Construction is inert;
/// the live app supplies settings snapshots and its existing guarded writer.
@MainActor @Observable final class NativeFIXESIslandPreferences {
    static let shared = NativeFIXESIslandPreferences()
    static let screenKey = "IslandShowOn", lookKey = "copilot.islandLook"
    static let widthKey = "copilot.islandWidthPreset", quietKey = "copilot.islandQuiet"
    private(set) var choice = FIXESIslandScreenChoice.main
    private(set) var options = FIXESIslandOptions()
    private(set) var enabled = true
    @ObservationIgnored private var hasStoredChoice = false
    @ObservationIgnored private var writer: ((NativeRPCValue) async throws -> NativeRPCValue)?
    @ObservationIgnored var changed: (() -> Void)?
    init(values: NativeRPCValue = .object([]), write: ((NativeRPCValue) async throws -> NativeRPCValue)? = nil) {
        writer = write; accept(values)
    }
    func bind(write: @escaping (NativeRPCValue) async throws -> NativeRPCValue) { writer = write }
    func accept(_ raw: NativeRPCValue) {
        let values = raw["values"].fields != nil ? raw["values"] : raw
        let before = choice, previous = options, wasEnabled = enabled
        enabled = values[BackendHootMenuBar.menuBarKey].bool != false
        hasStoredChoice = values[Self.screenKey].string != nil
        choice = values[Self.screenKey].string.flatMap { try? JSONDecoder().decode(FIXESIslandScreenChoice.self, from: Data($0.utf8)) } ?? .main
        options = .init(look: values[Self.lookKey].string.flatMap(FIXESIslandOptions.Look.init(rawValue:)) ?? .matchApp,
            width: values[Self.widthKey].string.flatMap(FIXESIslandOptions.Width.init(rawValue:)) ?? .standard,
            whenQuiet: values[Self.quietKey].string.flatMap(FIXESIslandOptions.WhenQuiet.init(rawValue:)) ?? .show)
        if before != choice || previous != options || wasEnabled != enabled { changed?() }
    }
    func stop() { writer = nil; changed = nil }
    var persistedChoice: FIXESIslandScreenChoice? { hasStoredChoice ? choice : nil }
    /// SETTINGS uses this for Screen because the existing settings store accepts
    /// primitive values. The named-screen object is encoded as one JSON string.
    func update(showOn: FIXESIslandScreenChoice? = nil, look: FIXESIslandOptions.Look? = nil,
        width: FIXESIslandOptions.Width? = nil, whenQuiet: FIXESIslandOptions.WhenQuiet? = nil, enabled: Bool? = nil) async throws {
        guard let writer else { throw NativeRPCError(code: "unavailable", message: "Dynamic Island settings are not connected.") }
        var fields: [NativeRPCValue.Field] = []
        if let showOn {
            guard showOn.mode != .named || showOn.screenID?.isEmpty == false else { throw NativeRPCError.invalidArguments("Choose a screen for Hoot.") }
            let encoded = try JSONEncoder().encode(showOn)
            fields.append(.init(Self.screenKey, .string(String(decoding: encoded, as: UTF8.self))))
        }
        if let look { fields.append(.init(Self.lookKey, .string(look.rawValue))) }
        if let width {
            fields.append(.init(Self.widthKey, .string(width.rawValue)))
            fields.append(.init(BackendHootMenuBar.widthKey, .null))
        }
        if let whenQuiet { fields.append(.init(Self.quietKey, .string(whenQuiet.rawValue))) }
        if let enabled { fields.append(.init(BackendHootMenuBar.menuBarKey, .bool(enabled))) }
        guard !fields.isEmpty else { return }
        accept(try await writer(.object(fields)))
    }
    func read() -> NativeRPCValue {
        .object([.init("enabled", .bool(enabled)), .init("showOn", wire(choice)), .init("look", .string(options.look.rawValue)),
            .init("width", .string(options.width.rawValue)), .init("whenQuiet", .string(options.whenQuiet.rawValue)),
            .init("screens", .array(NativeHootScreens.displays().map {
                .object([.init("id", .string($0.id)), .init("screenUUID", .string($0.id)), .init("name", .string($0.name)), .init("builtIn", .bool($0.builtIn))])
            }))])
    }
    func configure(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        let selection = raw["showOn"].fields == nil ? raw : raw["showOn"]
        var next: FIXESIslandScreenChoice?
        if !selection["mode"].isNullish {
            guard let mode = selection["mode"].string.flatMap(FIXESIslandScreenChoice.Mode.init(rawValue:)) else {
                throw NativeRPCError.invalidArguments("Choose main, builtIn, pointer, or named for Screen.")
            }
            let id = selection["screenUUID"].string ?? selection["screenID"].string
            let screen = NativeHootScreens.displays().first { $0.id == id }
            if mode == .named, screen == nil { throw NativeRPCError.invalidArguments("That screen is not connected.") }
            next = .init(mode: mode, screenID: mode == .named ? id : nil, screenName: screen?.name)
        }
        let look = raw["look"].string.flatMap(FIXESIslandOptions.Look.init(rawValue:))
        let width = raw["width"].string.flatMap(FIXESIslandOptions.Width.init(rawValue:))
        let whenQuiet = raw["whenQuiet"].string.flatMap(FIXESIslandOptions.WhenQuiet.init(rawValue:))
        guard raw["look"].isNullish || look != nil, raw["width"].isNullish || width != nil,
              raw["whenQuiet"].isNullish || whenQuiet != nil else { throw NativeRPCError.invalidArguments("Choose a valid Look, Width, or quiet setting.") }
        guard raw["enabled"].isNullish || raw["enabled"].bool != nil else { throw NativeRPCError.invalidArguments("Show Hoot must be on or off.") }
        try await update(showOn: next, look: look, width: width, whenQuiet: whenQuiet, enabled: raw["enabled"].bool)
        return read()
    }
    private func wire(_ value: FIXESIslandScreenChoice) -> NativeRPCValue {
        .object([.init("mode", .string(value.mode.rawValue)), .init("screenUUID", value.screenID.map(NativeRPCValue.string) ?? .null),
            .init("screenName", value.screenName.map(NativeRPCValue.string) ?? .null)])
    }
}
