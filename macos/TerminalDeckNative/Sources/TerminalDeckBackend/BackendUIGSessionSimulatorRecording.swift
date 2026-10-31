import Foundation
import TerminalDeckNativeCore

/// Testable owned-process boundary, not a second device engine. No arbitrary PID or output path.
public protocol BackendUIGSessionSimulatorRecordingProcess: Sendable {
    var running: Bool { get }
    func interrupt()
    /// Ends a recorder that ignored `interrupt()`.
    func terminate()
    func finished() async -> Int32
}
public extension BackendUIGSessionSimulatorRecordingProcess {
    func terminate() { interrupt() }
    /// Stop: interrupt, and end the recorder outright if it still runs after `grace`, so Stop always returns (#123).
    func stop(grace: Duration = .seconds(10)) async -> Int32 {
        interrupt()
        let watchdog = Task { try await Task.sleep(for: grace); if running { terminate() } }
        defer { watchdog.cancel() }
        return await finished()
    }
}
/// The recorder runs through the standard child runner (`NativeChild`) in its own process group, so
/// interrupt and terminate reach whatever it started too. No deadline: the person (or `stop`) ends it.
///
/// Recording that "isn't happening" (Asad, 26 Oct 2026): simctl recordVideo writes a frame only when the screen
/// changes, so a still screen gave a video of one frame, 0.067 s long, and a still tail before Stop was lost. Its
/// frames keep their true times (a still stretch in the middle is the last frame held), and once it has finished
/// the video is now held to the Stop moment: the same samples rewritten with the session ending at Stop, never
/// re-encoded. Every iOS recorder gets it: the session panel's Record, devices_record and the floating window.
public final class BackendUIGSessionSimulatorOwnedRecordingProcess: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let child: NativeChild
    /// The video this recorder writes, held to the Stop moment once it has finished (nil: nothing is held).
    private let held: URL?
    private let began = Date()
    private let lock = NSLock()
    private var stoppedAt: Date?
    private var ending: Task<Int32, Never>?
    public var running: Bool { child.isRunning }
    /// simctl recordVideo (the only use of this form): its video, the last argument, is held to the Stop moment.
    public convenience init(arguments: [String]) throws {
        try self.init(executable: "/usr/bin/xcrun", arguments: arguments, holding: Self.heldFile(arguments))
    }
    /// PFRAME: the same owned process for another fixed tool (adb for Android recording, which holds its own video).
    public init(executable: String, arguments: [String], holding file: URL? = nil) throws {
        // RecordVideo writes only the app-chosen file. Discard its progress output to avoid a blocked pipe.
        child = try NativeChild.start(.init(URL(fileURLWithPath: executable).path, arguments, output: .discard, errors: .discard))
        held = file
    }
    /// The video a simctl recordVideo command writes; nil for any other command.
    public static func heldFile(_ arguments: [String]) -> URL? {
        guard arguments.first == "simctl", arguments.contains("recordVideo"), let last = arguments.last, last.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: last)
    }
    /// SIGINT: the recorder finishes its file. The Stop moment is the video's end.
    public func interrupt() { noteStop(); child.signal(SIGINT) }
    public func terminate() { noteStop(); child.kill() }
    private func noteStop() { lock.withLock { if stoppedAt == nil { stoppedAt = Date() } } }
    /// Its exit status as Foundation's Process gave it (the exit code, or the signal that ended it), once the
    /// finished video has been held to the Stop moment.
    public func finished() async -> Int32 {
        let work = lock.withLock { () -> Task<Int32, Never> in
            if let ending { return ending }
            let made = Task { [self] in
                let end = await child.exited()
                let status = end.signal ?? end.code
                if status == 0, let held {
                    let stop = lock.withLock { stoppedAt } ?? Date()
                    await BackendAndroidScreenRecord.extend(held, toSeconds: stop.timeIntervalSince(Self.captureStart(held, launched: began)),
                                                            minimumGain: Self.minimumGain)
                }
                return status
            }
            ending = made; return made
        }
        return await work.value
    }
    /// A tail shorter than this is not worth rewriting the file for (as on Android): most recordings end on a
    /// change and skip the rewrite after Stop.
    static let minimumGain = 0.5
    /// When the picture began: the video file's creation (the recorder creates it as it starts capturing), if that
    /// falls in the first seconds after launch; otherwise the launch itself.
    static func captureStart(_ file: URL, launched: Date) -> Date {
        guard let created = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date,
              created >= launched, created.timeIntervalSince(launched) < 3 else { return launched }
        return created
    }
}

public actor BackendUIGSessionSimulatorRecording {
    public typealias Launch = @Sendable ([String]) throws -> any BackendUIGSessionSimulatorRecordingProcess
    /// Android (PFRAME #57): the adb serial and the file to finish → the segmenting adb recorder.
    public typealias AndroidLaunch = @Sendable (String, URL) throws -> any BackendUIGSessionSimulatorRecordingProcess
    private struct Recording: Sendable {
        let ticket: BackendUIGSessionSimulatorTicket
        let file: URL
        let process: any BackendUIGSessionSimulatorRecordingProcess
    }
    private let attachments: BackendUIGSessionSimulatorAttachments
    private let service: any BackendDeckToolsMachinesDeviceService
    private let pictures: URL
    private let launch: Launch
    private let androidLaunch: AndroidLaunch
    /// Android: is the device (adb serial) connected and allowed ("device")? Used when the engine's list was unsure.
    private let androidReady: @Sendable (String) async -> Bool
    private var records: [String: Recording] = [:]
    private var busy: Set<String> = []
    private var closed = false
    public init(attachments: BackendUIGSessionSimulatorAttachments, service: any BackendDeckToolsMachinesDeviceService,
                picturesDirectory: URL, launch: @escaping Launch = { try BackendUIGSessionSimulatorOwnedRecordingProcess(arguments: $0) },
                androidLaunch: @escaping AndroidLaunch = { try BackendAndroidScreenRecordProcess.live(serial: $0, file: $1) },
                androidReady: @escaping @Sendable (String) async -> Bool = { await BackendAndroidScreenRecord.connected(serial: $0) }) {
        self.attachments = attachments; self.service = service; pictures = picturesDirectory; self.launch = launch; self.androidLaunch = androidLaunch
        self.androidReady = androidReady
    }
    public static func arguments(deviceID: String, file: URL) throws -> [String] {
        guard deviceID.hasPrefix("ios:"), UUID(uuidString: String(deviceID.dropFirst(4))) != nil else {
            throw NativeRPCError(code: "unavailable", message: "Recording is available only for iOS simulators on this Mac.")
        }
        return ["simctl", "io", String(deviceID.dropFirst(4)), "recordVideo", "--codec=h264", file.path]
    }
    private func capable(_ ticket: BackendUIGSessionSimulatorTicket) async throws -> Bool {
        try await attachments.validate(ticket)
        guard let id = ticket.deviceID else { return false }
        let ios = id.hasPrefix("ios:") && UUID(uuidString: String(id.dropFirst(4))) != nil
        guard ios || BackendAndroidScreenRecord.serial(id) != nil else { return false }
        let rows = try await service.list(); try await attachments.validate(ticket)
        // A running iOS simulator, or a running Android emulator or phone (adb screenrecord).
        if rows.contains(where: { $0["id"].string == id && $0["state"].string == "ready" && (!ios || $0["kind"].string == "simulator") }) { return true }
        // ANDROID (#57, live run 10 Oct): the device engine's list sometimes answers a busy, streaming emulator as
        // "unknown" (its probe timed out), which refused Record on a phone that was on screen. Ask adb itself then.
        guard !ios, let serial = BackendAndroidScreenRecord.serial(id), rows.contains(where: { $0["id"].string == id }) else { return false }
        return await androidReady(serial)
    }
    public func status(_ ticket: BackendUIGSessionSimulatorTicket) async throws -> NativeRPCValue {
        let available = try await capable(ticket), record = records[ticket.key]
        let current = record?.ticket == ticket
        return ticket.value.setting("canRecord", .bool(available)).setting("recording", .bool(current && record?.process.running == true))
            .setting("path", current ? record.map { .string($0.file.path) } ?? .null : .null)
    }
    public func start(_ ticket: BackendUIGSessionSimulatorTicket, cancellation: BackendMCPCancellation? = nil) async throws -> NativeRPCValue {
        let id = ticket.key
        guard busy.insert(id).inserted else { throw NativeRPCError(code: "recording-busy", message: "A recording operation is already pending for this session.") }
        defer { busy.remove(id) }
        guard !closed else { throw NativeRPCError(code: "closed", message: "The recorder has stopped.") }
        guard try await capable(ticket), let deviceID = ticket.deviceID else {
            throw NativeRPCError(code: "unavailable", message: "Start the simulator or emulator to record its screen.")
        }
        if let record = records[ticket.key], record.process.running {
            guard record.ticket == ticket else { throw BackendUIGSessionSimulatorAttachments.stale() }
            return try await status(ticket)
        }
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let file = pictures.appendingPathComponent("simulator-recording-" + UUID().uuidString + ".mp4")
        let android = BackendAndroidScreenRecord.serial(deviceID)
        let arguments = android == nil ? try Self.arguments(deviceID: deviceID, file: file) : []
        try await attachments.validate(ticket)
        if closed || Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
        let process = try android.map { try androidLaunch($0, file) } ?? launch(arguments)
        do { try await attachments.onInvalidated(ticket) { [self] in process.interrupt(); Task { await invalidated(ticket) } } }
        catch { process.interrupt(); _ = await process.finished(); throw error }
        guard !closed, !Task.isCancelled, cancellation?.isCancelled != true, process.running else {
            process.interrupt(); _ = await process.finished()
            throw NativeRPCError(code: "recording-failed", message: "The recording could not start.")
        }
        records[ticket.key] = Recording(ticket: ticket, file: file, process: process)
        return ticket.value.setting("canRecord", .bool(true)).setting("recording", .bool(process.running)).setting("path", .string(file.path))
    }
    public func stop(_ ticket: BackendUIGSessionSimulatorTicket) async throws -> NativeRPCValue {
        let id = ticket.key
        guard busy.insert(id).inserted else { throw NativeRPCError(code: "recording-busy", message: "A recording operation is already pending for this session.") }
        defer { busy.remove(id) }
        try await attachments.validate(ticket)
        guard let record = records[ticket.key], record.ticket == ticket else {
            throw NativeRPCError(code: "not-running", message: "This session has no recording to stop.")
        }
        let status = await record.process.stop()
        try await attachments.validate(ticket)
        guard status == 0, FileManager.default.fileExists(atPath: record.file.path) else {
            throw NativeRPCError(code: "recording-failed", message: "The recorder did not save a finished video.")
        }
        return ticket.value.setting("canRecord", .bool(true)).setting("recording", .bool(false)).setting("path", .string(record.file.path))
    }
    public func stopAll() async {
        closed = true
        let owned = Array(records.values); records.removeAll()
        for record in owned { record.process.interrupt() }
        for record in owned { _ = await record.process.finished() }
    }
    private func invalidated(_ ticket: BackendUIGSessionSimulatorTicket) async {
        guard let record = records[ticket.key], record.ticket == ticket else { return }
        records[ticket.key] = nil; _ = await record.process.finished()
    }
}
