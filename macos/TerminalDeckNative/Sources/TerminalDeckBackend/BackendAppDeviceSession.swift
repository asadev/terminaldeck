import Foundation
import TerminalDeckNativeCore

public protocol BackendAppDeviceSessionServing: AnyObject, Sendable {
    var events: AsyncStream<BackendAppDeviceSessionEvent> { get }
    func info() async -> NativeRPCValue?
    func screenConfiguration() async -> Data?
    func isOpen() async -> Bool
    func open() async throws -> NativeRPCValue
    func setPreview(_ on: Bool) async throws
    func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws
    func touch(phase: String, x: Double, y: Double) async throws
    func swipe(from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double) async throws
    func type(_ text: String) async throws
    func key(_ key: String, modifiers: [String]) async throws
    func button(_ button: String) async throws
    func rotate(to: String?) async throws -> String
    func screenshot() async throws -> BackendAppDeviceScreenshot
    func foreground() async throws -> NativeRPCValue
    func elementAt(x: Double, y: Double) async throws -> NativeRPCValue?
    func tree(scope: String) async throws -> NativeRPCValue
    func close() async
}

public enum BackendAppDeviceSessionEvent: Sendable { case screen(Data), closed(String) }

/// One device opened by Terminal Deck's own engine (28 Oct 2026; before, a bundled third-party engine process per
/// device). The driver (`BackendAppDeviceDrivers`) does the work with Apple's and Google's tools and the app's own helper;
/// this keeps one open shared by everyone who asks meanwhile, the live picture while someone watches, and the turn.
public actor BackendAppDeviceSession: BackendAppDeviceSessionServing {
    public nonisolated let id: String
    public nonisolated let events: AsyncStream<BackendAppDeviceSessionEvent>
    private let emit: AsyncStream<BackendAppDeviceSessionEvent>.Continuation
    private let driver: any BackendAppDeviceDriving
    private let clock: any BackendAppSessionClock
    /// The one open in progress, shared by everyone who asks meanwhile; it lets go of itself when it ends.
    private var opening: (id: UUID, work: Task<NativeRPCValue, any Error>)?
    /// How long a caller waits for an open.
    public static let openWithin: Double = 180
    private var details: NativeRPCValue?
    private var picture: Task<Void, Never>?
    private var pictureGeneration = 0
    private var previewing = false
    private var lastConfig: Data?
    private var orientation = "portrait"

    public init(engine: BackendAppDeviceEngine, id: String, platform: BackendAppDevicePlatform,
                clock: any BackendAppSessionClock = BackendAppSessionSystemClock(), driver: (any BackendAppDeviceDriving)? = nil) {
        self.id = id; self.clock = clock
        self.driver = driver ?? BackendAppDeviceDrivers.make(id: id, platform: platform, engine: engine)
        var sink: AsyncStream<BackendAppDeviceSessionEvent>.Continuation!
        events = AsyncStream { sink = $0 }; emit = sink
    }

    public func info() -> NativeRPCValue? { details }
    public func screenConfiguration() -> Data? { lastConfig }
    public func isOpen() async -> Bool { details != nil }

    public func open() async throws -> NativeRPCValue {
        if let details { return details }
        let current: (id: UUID, work: Task<NativeRPCValue, any Error>)
        if let opening { current = opening }
        else {
            let id = UUID(), driver = self.driver
            let work = Task { () async throws -> NativeRPCValue in
                do { let value = try await driver.open(); self.opened(id, value); return value }
                catch { self.openingEnded(id); throw error }
            }
            current = (id, work); opening = current
        }
        // Devices freeze (26 Oct): a caller whose tool call gave up stops waiting at once, and nobody waits past
        // the deadline; an open stuck past it is let go, so the next caller starts a fresh one.
        do {
            return try await BackendAppDeviceDeadline.run(within: Self.openWithin, "Opening the device") { try await current.work.value }
        } catch let expired as BackendAppDeviceDeadline.Expired {
            if opening?.id == current.id { opening = nil; current.work.cancel() }
            throw expired
        }
    }
    private func opened(_ id: UUID, _ value: NativeRPCValue) { if opening?.id == id { opening = nil }; details = value }
    private func openingEnded(_ id: UUID) { if opening?.id == id { opening = nil } }

    private func ready() async throws { if details == nil { _ = try await open() } }

    /// The live picture on or off. On again while it runs: the configuration goes out once more and the picture
    /// restarts, so a screen that joins late gets a keyframe.
    public func setPreview(_ on: Bool) async throws {
        try await ready()
        if on {
            previewing = true
            startPicture()
        } else {
            previewing = false
            picture?.cancel(); picture = nil
        }
    }

    private func startPicture() {
        picture?.cancel()
        pictureGeneration += 1
        let generation = pictureGeneration, driver = self.driver
        // One ordered pump: coded pictures reach the panel in the order the device made them, never thinned.
        let (stream, sink) = AsyncStream.makeStream(of: Data.self)
        picture = Task { [weak self] in
            let pump = Task { [weak self] in for await packet in stream { await self?.received(packet, generation: generation) } }
            defer { sink.finish(); pump.cancel() }
            do {
                try await driver.pictures { sink.yield($0) }
                if !Task.isCancelled { await self?.pictureEnded(generation, reason: "The device went away.") }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { await self?.pictureEnded(generation, reason: error.localizedDescription) }
            }
        }
    }

    private func received(_ packet: Data, generation: Int) {
        guard generation == pictureGeneration, previewing else { return }
        if packet.first == 0x10 { lastConfig = packet }
        emit.yield(.screen(packet))
    }

    private func pictureEnded(_ generation: Int, reason: String) {
        guard generation == pictureGeneration else { return }
        picture = nil; previewing = false; lastConfig = nil; details = nil
        emit.yield(.closed(reason))
    }

    public func tap(x: Double, y: Double, holdMilliseconds: Double? = nil) async throws { try await ready(); try await driver.tap(x: x, y: y, holdMilliseconds: holdMilliseconds) }
    public func touch(phase: String, x: Double, y: Double) async throws { try await ready(); try await driver.touch(phase: phase, x: x, y: y) }
    public func swipe(from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double = 300) async throws {
        guard let fromX = from["x"].number, let fromY = from["y"].number, let toX = to["x"].number, let toY = to["y"].number else {
            throw BackendAppSessionError("A swipe needs a start and an end point.")
        }
        try await ready()
        try await driver.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMilliseconds: durationMilliseconds)
    }
    public func type(_ text: String) async throws { guard !text.isEmpty else { return }; try await ready(); try await driver.type(text) }
    public func key(_ key: String, modifiers: [String] = []) async throws { try await ready(); try await driver.key(key, modifiers: modifiers) }
    public func button(_ button: String) async throws { try await ready(); try await driver.button(button) }
    public func rotate(to: String? = nil) async throws -> String {
        try await ready()
        let next = to ?? (orientation == "portrait" ? "landscape-left" : "portrait")
        try await driver.rotate(to: next)
        orientation = next
        return next
    }
    public func screenshot() async throws -> BackendAppDeviceScreenshot { try await ready(); return try await driver.screenshot() }
    public func foreground() async throws -> NativeRPCValue { try await ready(); return try await driver.foreground() }
    public func elementAt(x: Double, y: Double) async throws -> NativeRPCValue? { try await ready(); return try await driver.elementAt(x: x, y: y) }
    public func tree(scope: String = "visible") async throws -> NativeRPCValue { try await ready(); return try await driver.tree(scope: scope) }

    public func close() async {
        opening?.work.cancel(); opening = nil
        picture?.cancel(); picture = nil
        previewing = false; lastConfig = nil; details = nil
    }
}
