import Foundation
import TerminalDeckNativeCore

/// The identity is assembled from the trusted link and a session on that peer.
/// The native browser dispatcher must resolve the <machineID, sessionID>
/// binding and apply its ordinary read/act/alter policy, including consent.
public struct BackendMachineWindowCaller: Sendable {
    public let machineID: String
    public let sessionID: String
    public let attended: Bool
    public let tiers: Set<BackendMCPTier> = [.read, .act, .alter]
}
public struct BackendMachineWindowServices: Sendable {
    public let allowedTools: Set<String>
    public let call: @Sendable (String, NativeRPCValue, BackendMachineWindowCaller) async throws -> NativeRPCValue
    public let attended: @Sendable () async -> Bool
    public let held: (@Sendable (String) async -> [NativeRPCValue])?
    public let ownSessions: (@Sendable () async -> [NativeRPCValue])?
    public let receivedHolds: (@Sendable (String, [String], [NativeRPCValue]) async -> Void)?
    public let receivedResult: (@Sendable (String, Bool, String) async -> Void)?
    public init(allowedTools: Set<String>, call: @escaping @Sendable (String, NativeRPCValue, BackendMachineWindowCaller) async throws -> NativeRPCValue,
                attended: @escaping @Sendable () async -> Bool, held: (@Sendable (String) async -> [NativeRPCValue])? = nil,
                ownSessions: (@Sendable () async -> [NativeRPCValue])? = nil,
                receivedHolds: (@Sendable (String, [String], [NativeRPCValue]) async -> Void)? = nil,
                receivedResult: (@Sendable (String, Bool, String) async -> Void)? = nil) {
        self.allowedTools = allowedTools; self.call = call; self.attended = attended; self.held = held
        self.ownSessions = ownSessions; self.receivedHolds = receivedHolds; self.receivedResult = receivedResult
    }
    public func serve(machineID: String, sessionID: String, tool: String, arguments: String) async -> (ok: Bool, body: String) {
        guard tool != "browser.screenshot", tool != "browser_screenshot" else { return Self.refuse("browser.screenshot writes the picture on the computer the browser window is on, so the path it answers with is not a file you can open. Use browser.read: the outline is what tells you what to click, and a picture is not.") }  // window-serve.ts:176
        guard allowedTools.contains(tool) else { return Self.refuse("there is no such tool here.") }  // window-serve.ts:249
        do {
            let args: NativeRPCValue
            do { args = try NativeRPCValue.parseJSON(Data(arguments.utf8), maximumBytes: 16384) } catch { return Self.refuse("those arguments were not readable.") }  // window-serve.ts:256
            let caller = BackendMachineWindowCaller(machineID: machineID, sessionID: sessionID, attended: await attended())
            return Self.fit(try await call(tool, args, caller))
        } catch { let said = error.localizedDescription; return Self.refuse(said.isEmpty ? "that could not be done." : said) }
    }
    private static func refuse(_ message: String) -> (ok: Bool, body: String) { (false, NativeRPCValue.object([.init("message", .string(message))]).compact) }
    public static func fit(_ input: NativeRPCValue) -> (ok: Bool, body: String) {
        func fits(_ text: String) -> Bool { text.utf8.count <= 49152 && ((try? NativeRPCValue.string(text).encodedJSON().count) ?? Int.max) + 512 <= 65536 }
        let whole = input == .missing ? "null" : input.compact
        if fits(whole) { return (true, whole) }
        guard input.fields != nil else { return refuse("that answer was too large to send between the two computers. Ask again for less of it — a `selector` for the one part you need, or a smaller `textChars`.") }
        var value = input, droppedChars = 0, droppedItems = 0
        for _ in 0..<64 {
            value = value.setting("truncatedOnTheWay", .object([.init("message", .string("This answer was too large to send between the two computers, so part of it was left out on the way. The page itself is unchanged. Ask again with a `selector` for the part you need, or a smaller `textChars`, and do not treat what is here as the whole page.")), .init("charactersDropped", .number(Double(droppedChars))), .init("entriesDropped", .number(Double(droppedItems)))]))
            let text = value.compact
            if fits(text) { return (true, text) }
            guard let field = value.fields?.filter({ $0.key != "truncatedOnTheWay" && ($0.value.string != nil || $0.value.elements != nil) }).max(by: { ((try? $0.value.encodedJSON().count) ?? 0) < ((try? $1.value.encodedJSON().count) ?? 0) }) else { break }
            if let string = field.value.string {
                let units = string.utf16.count, keep = Int(Double(units) * 0.66)
                var shortened = "", used = 0
                for scalar in string.unicodeScalars { let amount = scalar.value > 65535 ? 2 : 1; if used + amount > keep { break }; shortened.unicodeScalars.append(scalar); used += amount }
                droppedChars += units - shortened.utf16.count; value = value.setting(field.key, .string(shortened))
            } else if let items = field.value.elements {
                let keep = Int(Double(items.count) * 0.66); droppedItems += items.count - keep
                value = value.setting(field.key, .array(Array(items.prefix(keep))))
            }
        }
        return refuse("that answer was too large to send between the two computers, and could not be shortened. Ask again for less of it — a `selector` for the one part you need, or a smaller `textChars`.")
    }
}
