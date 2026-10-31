import Foundation
import TerminalDeckNativeCore

/// An ask contains names/IDs, never cookie/storage values. Only the native app
/// may answer it. An agent that files an ask cannot approve its own request.
public actor BackendBrowserWorkersLiftRequests {
    private struct Ask: Sendable { let owner: String; let value: NativeRPCValue }
    private var asks: [String: Ask] = [:]
    private var answering: Set<String> = []
    private let profiles: @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile]
    private let authorize: BackendBrowserScrapingAuthorize
    private let changed: @Sendable () async -> Void
    /// Leave nil until an exact-origin, profile-owned WebKit transfer service is
    /// implemented. Success must report the number of real injected workers.
    private let transfer: (@Sendable (BackendBrowserScrapingCaller, NativeRPCValue) async throws -> Int)?
    public init(profiles: @escaping @Sendable (BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile],
                authorize: @escaping BackendBrowserScrapingAuthorize, changed: @escaping @Sendable () async -> Void,
                transfer: (@Sendable (BackendBrowserScrapingCaller, NativeRPCValue) async throws -> Int)? = nil) {
        self.profiles = profiles; self.authorize = authorize; self.changed = changed; self.transfer = transfer
    }
    public func file(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller, workers: NativeRPCValue) async throws -> NativeRPCValue {
        guard !caller.remote, caller.attended else { throw BackendBrowserScrapingError.denied("A session lift request needs an attended local caller. Do not retry unattended or through a paired device.") }
        try await authorize(caller, "browser.lift_request", nil, nil, args)
        // browser-lift-requests.ts fileLiftRequest (L148-245): a refused ask is
        // `{ok: false, reason}` in the desk's own sentences (lift-ask-tool.ts
        // L175 turns it into the not-permitted refusal; the scraping MCP door
        // marks ok:false isError), and a filed/re-found ask carries the
        // resolved fromName/intoNames so the asker never maps ids back.
        let available = try await profiles(caller), name = try args["from"].requireString("from profile", nonempty: true)
        guard let source = Self.findRef(available.map { (id: $0.id, name: $0.name) }, name) else {
            return Self.notFiled("there is no profile called \(Self.quoted(name)) on this browser. browser.workers lists the workers; the person can name the others.")
        }
        let rows = (workers["workers"].elements ?? []).compactMap { row -> (id: String, name: String)? in
            guard let id = row["profileId"].string else { return nil }
            return (id, row["name"].string ?? id)
        }
        let named = try args["into"].isNullish ? [] : args["into"].requireArray("into workers").map { try $0.requireString("worker name", nonempty: true) }
        var destinations: [(id: String, name: String)] = []
        if named.isEmpty { destinations = rows.filter { $0.id != source.id } }
        else {
            for name in named {
                guard let worker = Self.findRef(rows, name) else {
                    return Self.notFiled("\(Self.quoted(name)) is not a worker profile. A lift only ever lands in workers — browser.workers lists them.")
                }
                if worker.id != source.id && !destinations.contains(where: { $0.id == worker.id }) { destinations.append(worker) }
            }
        }
        guard !destinations.isEmpty else {
            return Self.notFiled(rows.isEmpty ? "there is no worker profile to lift into. The person adds them in the browser’s profile menu, under Workers."
                : "the only worker named is the profile the session would come from, which is already signed in.")
        }
        try await authorize(caller, "browser.lift_request", source.id, nil, args)
        for worker in destinations { try await authorize(caller, "browser.lift_request", worker.id, nil, args) }
        let ordered = destinations.map(\.id).sorted(), intoNames = NativeRPCValue.array(destinations.map { .string($0.name) })
        if let existing = asks.values.first(where: { $0.owner == caller.holder && $0.value["fromProfileId"].string == source.id && $0.value["intoProfileIds"].elements?.compactMap(\.string).sorted() == ordered }) {
            return .object([.init("ok", .bool(true)), .init("request", existing.value), .init("fromName", .string(source.name)), .init("intoNames", intoNames),
                .init("repeated", .bool(true)), .init("pending", .bool(true))])
        }
        guard asks.count < Self.maxOpenRequests else {
            return Self.notFiled("there are already \(Self.maxOpenRequests) asks waiting for the person. Do not retry; they answer in the browser’s Scraping panel.")
        }
        let id = UUID().uuidString
        // cleanReason (L131-134): whitespace collapsed, trimmed, 200 UTF-16 units.
        let collapsed = (args["reason"].string ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let reason = String(collapsed.utf16.prefix(Self.maxReasonLength)) ?? String(collapsed.prefix(Self.maxReasonLength))
        let row = NativeRPCValue.object([.init("id", .string(id)), .init("askedBy", .string(caller.sessionID ?? caller.ownerID)),
            .init("fromProfileId", .string(source.id)), .init("intoProfileIds", .array(destinations.map { .string($0.id) })),
            .init("reason", .string(reason)), .init("at", .number(BackendBrowserScrapingIO.now()))])
        asks[id] = Ask(owner: caller.holder, value: row); await changed()
        return .object([.init("ok", .bool(true)), .init("request", row), .init("fromName", .string(source.name)), .init("intoNames", intoNames),
            .init("repeated", .bool(false)), .init("pending", .bool(true)),
            .init("transferAvailable", .bool(transfer != nil)), .init("message", .string("The person must answer in the browser's Scraping panel. No login data was copied."))])
    }
    /// browser-lift-requests.ts MAX_OPEN_REQUESTS (L84) and MAX_REASON_LENGTH (L87).
    static let maxOpenRequests = 8, maxReasonLength = 200
    /// browser-lift-requests.ts findRef (L116-124): the name a person reads
    /// (case-insensitive, trimmed) first, the id as the fallback, first match on
    /// a duplicate name.
    static func findRef(_ list: [(id: String, name: String)], _ nameOrID: String) -> (id: String, name: String)? {
        let trimmed = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines), wanted = trimmed.lowercased()
        guard !wanted.isEmpty else { return nil }
        return list.first { $0.name.lowercased() == wanted } ?? list.first { $0.id == trimmed }
    }
    private static func notFiled(_ reason: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("reason", .string(reason))]) }
    /// JSON.stringify of a string, as the desk's sentences quote names.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default: out += scalar.value < 0x20 ? String(format: "\\u%04x", scalar.value) : String(scalar)
            }
        }
        return out + "\""
    }
    public func list(_ caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try await authorize(caller, "browser-worker:lift-requests", nil, nil, .object([]))
        var visible: [NativeRPCValue] = []
        for ask in asks.values.sorted(by: { ($0.value["at"].number ?? 0) < ($1.value["at"].number ?? 0) }) {
            guard caller.rpc?.caller == .nativeApp || ask.owner == caller.holder else { continue }
            try await authorize(caller, "browser-worker:lift-requests", ask.value["fromProfileId"].string, nil, ask.value)
            for id in ask.value["intoProfileIds"].elements?.compactMap(\.string) ?? [] {
                try await authorize(caller, "browser-worker:lift-requests", id, nil, ask.value)
            }
            visible.append(ask.value)
        }
        return .array(visible)
    }
    public func answer(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        guard caller.rpc?.caller == .nativeApp, !caller.remote else { throw BackendBrowserScrapingError.denied("Only the person in the native app may approve or decline a login transfer request.") }
        let id = try args["requestId"].requireString("requestId", nonempty: true)
        try await authorize(caller, "browser-worker:lift-answer", nil, nil, args)
        guard let ask = asks[id], !answering.contains(id) else { throw BackendBrowserScrapingError.invalid("That request has been answered, is being answered or did not survive a restart.") }
        if args["approve"].bool != true {
            asks[id] = nil; await changed()
            return .object([.init("ok", .bool(true)), .init("message", .string("Declined. Nothing was copied.")), .init("count", .null)])
        }
        guard let transfer else {
            return .object([.init("ok", .bool(false)), .init("message", .string("Authorized WebKit cookie/storage transfer is not wired. The request remains pending; no login data was copied.")), .init("count", .null)])
        }
        answering.insert(id); defer { answering.remove(id) }
        try await authorize(caller, "browser-worker:lift-answer", ask.value["fromProfileId"].string, nil, ask.value)
        for id in ask.value["intoProfileIds"].elements?.compactMap(\.string) ?? [] { try await authorize(caller, "browser-worker:lift-answer", id, nil, ask.value) }
        let count = try await transfer(caller, ask.value)
        guard count > 0 else { throw NativeRPCError(code: "lift-empty", message: "No workers received the authorized session. The ask remains pending.") }
        asks[id] = nil; await changed()
        return .object([.init("ok", .bool(true)), .init("message", .string("Copied the authorized session into \(count) workers.")), .init("count", .number(Double(count)))])
    }
    public func disconnect(_ holder: String) async { asks = asks.filter { $0.value.owner != holder }; await changed() }
}
