import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsTourWindow: Sendable {
    /// Must deliver DriveTour.channel to the actual native window; false if none.
    func send(_ tour: TourMessage) async -> Bool
    func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID
    func unwatch(_ id: UUID) async
}

/// tour-stage.ts. Inert until asked to play/list/forget. A pending offer is
/// never driving; a reload/close/shutdown ends it rather than resuming it.
public actor BackendDeckToolsTourStage {
    public static let acknowledgementTimeoutMS = 4000
    public static let maxToursKept = 50
    private struct Live {
        var record: NativeRPCValue
        var continuation: CheckedContinuation<NativeRPCValue, Never>?
        var watch: UUID?
        var timeout: UUID?
        var offer: Task<Void, Never>?
        var canAcknowledge = false
    }
    private var live: Live?
    private let directory: URL
    private let window: any BackendDeckToolsTourWindow
    private let now: @Sendable () -> Double
    private let clock: any BackendDeckCoreEventsClock
    private let timeoutMS: Int
    private let writeFailure: @Sendable (String) -> Void
    public init(logDirectory: URL, window: any BackendDeckToolsTourWindow,
                acknowledgementTimeoutMS: Int = 4000,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock(),
                writeFailure: @escaping @Sendable (String) -> Void) {
        directory = logDirectory.appendingPathComponent("tours", isDirectory: true)
        self.window = window; self.now = now; self.clock = clock
        timeoutMS = acknowledgementTimeoutMS; self.writeFailure = writeFailure
    }
    public func driving() -> Bool { live != nil && live?.continuation == nil }
    public func current() -> NativeRPCValue { driving() ? live!.record : .null }
    public func play(_ validated: BackendDeckToolsTour.Validated, cancellation: BackendMCPCancellation? = nil) async -> NativeRPCValue {
        if Task.isCancelled || cancellation?.isCancelled == true { return failure("caller-gone") }
        if live != nil { return failure("already-driving") }
        let record = BackendDeckToolsTour.openRecord(validated, at: now())
        write(record)
        let envelope = BackendDeckToolsSupport.object([("record", record), ("stops", validated.plan["stops"])])
        guard let decoded = DriveTour.read(envelope.foundation) else {
            write(record.setting("endedAt", .number(now())))
            return failure("no-window")
        }
        return await withCheckedContinuation { continuation in
            live = Live(record: record, continuation: continuation)
            let id = record["id"].string ?? "", timeout = timeoutMS
            // The window seam is async in Swift. Its send/watch cannot remove
            // the source's four-second ceiling by hanging before it is armed.
            live?.timeout = clock.schedule(after: Double(timeout)) { [weak self] in
                Task { await self?.expire(id) }
            }
            live?.offer = Task { [weak self] in
                if Task.isCancelled || cancellation?.isCancelled == true { await self?.stop(tourID: id); return }
                await self?.offer(decoded, id: id)
            }
        }
    }
    private func offer(_ message: TourMessage, id: String) async {
        guard !Task.isCancelled, live?.record["id"].string == id else { return }
        // Source send/watch are synchronous in one turn. With async Swift
        // bridges, install the watcher first so an immediate ack cannot leave
        // a driving tour without a close/reload subscription.
        let watch = await window.watch { [weak self] in Task { await self?.stop(tourID: id) } }
        guard live?.record["id"].string == id else { await window.unwatch(watch); return }
        live?.watch = watch
        guard !Task.isCancelled else { await finish(); return }
        live?.canAcknowledge = true
        let sent = await window.send(message)
        guard live?.record["id"].string == id else { return }
        if !sent { await finish(why: "no-window"); return }
    }
    private func expire(_ id: String) async {
        if live?.record["id"].string == id, live?.continuation != nil { await finish(why: "no-answer") }
    }
    public func acknowledge(_ tourID: String) -> Bool {
        guard live?.record["id"].string == tourID, live?.canAcknowledge == true,
              let continuation = live?.continuation else { return false }
        live?.continuation = nil
        if let timeout = live?.timeout { clock.cancel(timeout) }
        live?.timeout = nil
        continuation.resume(returning: BackendDeckToolsSupport.object([("ok", .bool(true)), ("record", live!.record)]))
        return true
    }
    public func progress(_ tourID: String, update: NativeRPCValue) -> NativeRPCValue {
        guard live?.record["id"].string == tourID else { return .null }
        let merged = BackendDeckToolsTour.mergeProgress(live!.record, update: update)
        live?.record = merged; write(merged); return merged
    }
    public func end(_ tourID: String, update: NativeRPCValue = .object([])) async -> NativeRPCValue {
        guard live?.record["id"].string == tourID else { return .null }
        return await finish(record: BackendDeckToolsTour.mergeProgress(live!.record, update: update))
    }
    public func stop() async { _ = await finish() }
    /// A delayed callback/cancel from an earlier call must not stop a later tour.
    public func stop(tourID: String) async {
        guard live?.record["id"].string == tourID else { return }
        _ = await finish()
    }
    @discardableResult private func finish(record: NativeRPCValue? = nil, why: String = "no-answer") async -> NativeRPCValue {
        guard let previous = live else { return .null }
        live = nil
        if let timeout = previous.timeout { clock.cancel(timeout) }
        previous.offer?.cancel()
        let closed = (record ?? previous.record).setting("endedAt", .number(now()))
        write(closed)
        previous.continuation?.resume(returning: failure(why))
        if let watch = previous.watch { await window.unwatch(watch) }
        return closed
    }
    public func quietly(_ validated: BackendDeckToolsTour.Validated) -> NativeRPCValue {
        let at = now(), record = BackendDeckToolsTour.openRecord(validated, at: at, shown: "background").setting("endedAt", .number(at))
        write(record); return record
    }
    public func list(limit: Int = 50) -> [NativeRPCValue] {
        guard let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return names.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let record = try? NativeRPCValue.parseJSON(data), record["v"].number == 1, record["id"].string != nil else { return nil }
            return record
        }.sorted { ($0["startedAt"].number ?? 0) > ($1["startedAt"].number ?? 0) }.prefix(max(1, limit)).map { $0 }
    }
    public func forget(_ tourID: String) -> Bool {
        guard tourID.range(of: #"^tour_[0-9]+_[0-9a-f]+$"#, options: .regularExpression) != nil else { return false }
        let file = directory.appendingPathComponent(tourID + ".json")
        do { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }; return true }
        catch { return false }
    }
    private func failure(_ why: String) -> NativeRPCValue { BackendDeckToolsSupport.object([("ok", .bool(false)), ("why", .string(why))]) }
    private func write(_ record: NativeRPCValue) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent((record["id"].string ?? "") + ".json")
            var data = try record.encodedJSON(pretty: true); data.append(0x0a)
            try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let names = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in names.prefix(max(0, names.count - Self.maxToursKept)) { try FileManager.default.removeItem(at: old) }
        } catch { writeFailure("[deck-control] could not write the tour record: \(error.localizedDescription)") }
    }
}

/// Identity and settings come from the authenticated control owner. Local is
/// not inferred from attendance; an attended remote/key still cannot drive.
public protocol BackendDeckToolsTourRuntime: BackendDeckToolsTourEvidence {
    func callerKind(_ context: BackendMCPCallContext) async throws -> String
    func interactiveSetting() async throws -> NativeRPCValue
    func authorize(_ context: BackendMCPCallContext, tier: BackendMCPTier, summary: String) async throws
    func completed(_ context: BackendMCPCallContext, summary: NativeRPCValue) async throws
}

public enum BackendDeckToolsTourTool {
    public static func definitions(stage: BackendDeckToolsTourStage, runtime: any BackendDeckToolsTourRuntime) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsCatalogue.entries().filter { $0.module == "tour-tool" }.map { entry in
            BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index) { caller, args in
                await BackendDeckToolsSupport.reply {
                if try await runtime.callerKind(caller) != "local" { throw NativeRPCError(code: "not-granted", message: "tour.play only runs for the person sitting at this machine. Driving moves the desktop screen and hides most of it, so a paired device cannot ask for it however it was granted. Answer in words instead — you can say everything a tour would have shown.") }
                if !caller.attended { throw NativeRPCError(code: "not-permitted-unattended", message: "tour.play needs somebody watching the screen, and this run has nobody at the machine. Do not retry and do not look for another way. Say what you would have shown; if it is worth waking them for, ask with start: \"offer\", which posts a notification and waits for a click.") }
                let plan = try BackendDeckToolsTour.parse(args), count = args["stops"].elements?.count ?? 0
                try await runtime.authorize(caller, tier: .act, summary: "Drive the screen through \(count) stop\(count == 1 ? "" : "s"): \"\(BackendDeckToolsSupport.slice(args["question"].string ?? "", 0, 80))\"")
                let validated = try await BackendDeckToolsTour.validate(plan, evidence: runtime)
                let kept = validated.plan["stops"].elements?.count ?? 0, dropped = validated.dropped.count
                func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
                let value: NativeRPCValue, summary: NativeRPCValue
                if kept == 0 {
                    value = o([("played", .bool(false)), ("why", .string("every stop was dropped")), ("dropped", .array(validated.dropped)), ("advice", .string("Nothing in that plan could be stood behind. Re-read the sessions you are quoting: the text has to be there and the reason has to be true right now. Then answer in words, or send a smaller tour of the stops you can source."))])
                    summary = o([("playing", .number(0)), ("dropped", .number(Double(dropped)))])
                } else if try await runtime.interactiveSetting() == .bool(false) {
                    let record = await stage.quietly(validated)
                    value = o([("played", .bool(false)), ("shown", .string("background")), ("tourId", record["id"]), ("found", .number(Double(kept))), ("dropped", .number(Double(dropped))), ("droppedDetail", .array(validated.dropped)), ("note", .string("Interactive mode is off, so nothing was driven on their screen — but everything you sent was checked and recorded, and it is in Hoot’s own window as the answer. Say what you found, session by session, in your reply. Do not apologise for not driving and do not ask for it: they chose this."))])
                    summary = o([("found", .number(Double(kept))), ("dropped", .number(Double(dropped))), ("shown", .string("background"))])
                } else {
                    let offeredID = plan["id"].string ?? ""
                    let cancelOffer = caller.cancellation.observe { Task { await stage.stop(tourID: offeredID) } }
                    defer { caller.cancellation.removeObserver(cancelOffer) }
                    let outcome = await stage.play(validated, cancellation: caller.cancellation)
                    if caller.cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                    if outcome["ok"].bool != true {
                        let why = outcome["why"].string ?? "no-answer"
                        let advice = why == "no-window" ? "There is no window open to play it in, so nothing was shown. Answer in words instead — the headline you wrote is the answer." : why == "already-driving" ? "A tour is already playing on that screen. Two at once is not a thing a person can watch. Wait for it to finish." : "The window was given the tour and did not start it. Nothing is on screen and nothing was changed. Say so, and answer in words."
                        value = o([("played", .bool(false)), ("why", .string(why)), ("advice", .string(advice))]); summary = o([("playing", .number(0)), ("dropped", .number(Double(dropped))), ("failed", .string(why))])
                    } else {
                        value = o([("played", .bool(true)), ("tourId", outcome["record"]["id"]), ("playing", .number(Double(kept))), ("dropped", .number(Double(dropped))), ("droppedDetail", .array(validated.dropped)), ("note", .string("The tour is on their screen now. It plays without you — do not narrate it, do not call this again, and wait: tools that change anything are refused until it ends."))])
                        summary = o([("playing", .number(Double(kept))), ("dropped", .number(Double(dropped))), ("tourId", outcome["record"]["id"])])
                    }
                }
                try await runtime.completed(caller, summary: summary)
                return .value(value)
                }
            }
        }
    }
    public static func area(stage: BackendDeckToolsTourStage, runtime: any BackendDeckToolsTourRuntime) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "tour", definitions: definitions(stage: stage, runtime: runtime))
    }
}
