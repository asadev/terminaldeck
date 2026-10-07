import Foundation
import SwiftTerm
import TerminalDeckNativeCore

/// Event-fed shadow screens and far conversations. Start before any attach/replay.
public actor BackendDeckToolsMachinesWatch {
    public static let maximumScreens = 16
    public static let maximumMessages = 200
    private final class Shadow: TerminalDelegate {
        var terminal: Terminal!
        init(cols: Int, rows: Int) { terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, termName: "xterm-256color", scrollback: 200)) }
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func text() -> String { (0..<terminal.getDims().rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n") }
    }
    private struct Screen { let shadow: Shadow; var cols: Int; var rows: Int; var live: Bool; var lastOutput: Double?; var touched: Double }
    private struct Conversation: Sendable { var run: String?; var messages: [NativeRPCValue] = []; var state: NativeRPCValue = .null; var changed: Double? }
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?
        func complete(_ value: Bool) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard answer == nil else { return nil }; answer = value; let pending = continuation; continuation = nil; return pending
            }
            pending?.resume(returning: value)
        }
        func value() async -> Bool {
            await withCheckedContinuation { pending in
                let ready = lock.withLock { () -> Bool? in
                    if let answer { return answer }; continuation = pending; return nil
                }
                if let ready { pending.resume(returning: ready) }
            }
        }
    }
    private struct Waiter { let machine: String; let since: String?; let settle: Int?; let result: Result; var timeout: UUID?; var settled: UUID?; var settleGeneration: UUID? }
    private let now: @Sendable () -> Double
    private let clock: any BackendDeckCoreEventsClock
    private let maximumScreens: Int
    private var screens: [String: Screen] = [:]
    private var held: [String: Conversation] = [:]
    private var subscriptions: [NativeRPCSubscription] = []
    private var waiting: [UUID: Waiter] = [:]
    public init(maximumScreens: Int = BackendDeckToolsMachinesWatch.maximumScreens,
                now: (@Sendable () -> Double)? = nil, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) {
        self.maximumScreens = max(1, maximumScreens); self.clock = clock; self.now = now ?? { clock.now() }
    }
    public func start(registry: NativeChannelRegistry) async throws {
        guard subscriptions.isEmpty else { return }
        for channel in ["machines:output", "machines:copilot:chat", "machines:copilot:state"] {
            subscriptions.append(try await registry.subscribe(channel, ownerID: "deck-tools-machine-watch") { [weak self] event in await self?.pushed(event.channel, event.arguments.first ?? .missing) })
        }
    }
    private func key(_ machine: String, _ session: String) -> String { machine + "\u{0}" + session }
    /// Invoke from every UI and tool call, before forwarding attach/resize/detach/close/forget.
    public func invoked(_ channel: String, _ args: [NativeRPCValue]) {
        guard let machine = args.first?.string, !machine.isEmpty else { return }
        if channel == "machines:forget" { screens = screens.filter { !$0.key.hasPrefix(machine + "\u{0}") }; held[machine] = nil; return }
        guard args.count > 1, let session = args[1].string, !session.isEmpty else { return }
        let id = key(machine, session)
        func size(_ index: Int, _ fallback: Int) -> Int { guard args.count > index, let n = args[index].number, n.isFinite, n >= 1 else { return fallback }; return Int(min(n.rounded(.towardZero), 1_000)) }
        switch channel {
        case "machines:attach":
            screens[id] = nil
            while screens.count >= maximumScreens { if let oldest = screens.min(by: { $0.value.touched < $1.value.touched })?.key { screens[oldest] = nil } }
            let cols = size(2, 120), rows = size(3, 30)
            screens[id] = Screen(shadow: Shadow(cols: cols, rows: rows), cols: cols, rows: rows, live: true, touched: now())
        case "machines:resize":
            guard var screen = screens[id] else { return }; screen.cols = size(2, screen.cols); screen.rows = size(3, screen.rows)
            screen.shadow.terminal.resize(cols: screen.cols, rows: screen.rows); screens[id] = screen
        case "machines:detach": screens[id]?.live = false
        case "machines:close": screens[id] = nil
        default: break
        }
    }
    public func pushed(_ channel: String, _ value: NativeRPCValue) {
        guard let machine = value["machineId"].string, !machine.isEmpty else { return }
        if channel == "machines:output" {
            guard let session = value["sessionId"].string, let bytes = value["data"].string, var screen = screens[key(machine, session)] else { return }
            screen.shadow.terminal.feed(byteArray: Array(bytes.utf8)); screen.lastOutput = now(); screen.touched = screen.lastOutput!; screens[key(machine, session)] = screen; return
        }
        var into = held[machine] ?? Conversation()
        if channel == "machines:copilot:chat" {
            let chat = value["chat"]
            guard let messages = chat["messages"].elements else { return }
            let run = chat["run"].string.flatMap { $0.isEmpty ? nil : $0 }
            if chat["reset"].bool == true { into.run = run; into.messages = [] }
            else if let old = into.run, let run, run != old { return }
            else if into.run == nil { into.run = run }
            for message in messages {
                guard let id = message["id"].string, message["text"].string != nil else { continue }
                into.messages.removeAll { $0["id"].string == id }; into.messages.append(message)
            }
            if into.messages.count > Self.maximumMessages { into.messages.removeFirst(into.messages.count - Self.maximumMessages) }
        } else if channel == "machines:copilot:state" {
            guard value["state"].fields != nil else { return }; into.state = value["state"]
        } else { return }
        into.changed = now(); held[machine] = into
        for id in waiting.keys.filter({ waiting[$0]?.machine == machine }) { changed(id) }
    }
    public func screen(_ machine: String, _ session: String) -> NativeRPCValue {
        let id = key(machine, session)
        guard var screen = screens[id] else { return .null }
        screen.touched = now(); screens[id] = screen
        return BackendDeckToolsMachinesShared.object(["text": .string(screen.shadow.text()), "live": .bool(screen.live), "cols": .number(Double(screen.cols)), "rows": .number(Double(screen.rows)), "lastOutputAt": screen.lastOutput.map(NativeRPCValue.number) ?? .null])
    }
    public func attached(_ machine: String, _ session: String) -> Bool { screens[key(machine, session)]?.live == true }
    public func conversation(_ machine: String) -> NativeRPCValue {
        let value = held[machine] ?? Conversation()
        return BackendDeckToolsMachinesShared.object(["run": value.run.map(NativeRPCValue.string) ?? .null, "messages": .array(value.messages), "state": value.state, "changedAt": value.changed.map(NativeRPCValue.number) ?? .null])
    }
    public static func answeredAfter(_ messages: [NativeRPCValue], since: String?) -> Bool {
        let index = since.flatMap { baseline in messages.firstIndex { $0["id"].string == baseline } } ?? -1
        let after = Array(messages.dropFirst(index + 1))
        guard let ours = after.firstIndex(where: { $0["role"].string == "you" }), let last = after.last else { return false }
        return after.count - 1 > ours && last["role"].string == "agent" && !(last["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func changed(_ id: UUID) {
        guard var waiter = waiting[id] else { return }
        guard let settle = waiter.settle else { finish(id, true); return }
        if let timer = waiter.settled { clock.cancel(timer) }; waiter.settled = nil; waiter.settleGeneration = nil
        if Self.answeredAfter(held[waiter.machine]?.messages ?? [], since: waiter.since) {
            let generation = UUID(); waiter.settleGeneration = generation
            waiter.settled = clock.schedule(after: Double(settle)) { [weak self] in
                Task { await self?.settled(id, generation: generation) }
            }
        }
        waiting[id] = waiter
    }
    private func finish(_ id: UUID, _ answer: Bool) { guard let waiter = waiting.removeValue(forKey: id) else { return }; if let timer = waiter.timeout { clock.cancel(timer) }; if let timer = waiter.settled { clock.cancel(timer) }; waiter.result.complete(answer) }
    private func settled(_ id: UUID, generation: UUID) {
        guard waiting[id]?.settleGeneration == generation else { return }; finish(id, true)
    }
    private func ceiling(_ id: UUID, machine: String, since: String?, isReply: Bool) {
        finish(id, isReply ? Self.answeredAfter(held[machine]?.messages ?? [], since: since) : false)
    }
    private func install(_ id: UUID, machine: String, since: String?, ceilingMS: Int, settleMS: Int?) -> Result {
        let result = Result()
        var waiter = Waiter(machine: machine, since: since, settle: settleMS, result: result)
        waiter.timeout = clock.schedule(after: Double(ceilingMS)) { [weak self] in
            Task { await self?.ceiling(id, machine: machine, since: since, isReply: settleMS != nil) }
        }
        waiting[id] = waiter
        return result
    }
    /// The waiter is installed before after runs; completion never hides an attach/refresh refusal.
    public func nextChange(_ machine: String, ceilingMS: Int, after: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        let id = UUID()
        let result = install(id, machine: machine, since: nil, ceilingMS: ceilingMS, settleMS: nil)
        do {
            return try await withTaskCancellationHandler {
                try await after(); try Task.checkCancellation(); return await result.value()
            } onCancel: { Task { await self.finish(id, false) } }
        } catch { finish(id, false); throw error }
    }
    public func replied(_ machine: String, since: String?, ceilingMS: Int, settleMS: Int = 2_500) async -> Bool {
        if Task.isCancelled { return false }
        let id = UUID()
        let result = install(id, machine: machine, since: since, ceilingMS: ceilingMS, settleMS: settleMS)
        return await withTaskCancellationHandler { await result.value() } onCancel: { Task { await self.finish(id, false) } }
    }
    public func dispose() async { for token in subscriptions { await token.cancelAndWait() }; subscriptions = []; screens = [:]; held = [:]; for id in Array(waiting.keys) { finish(id, false) } }
}
