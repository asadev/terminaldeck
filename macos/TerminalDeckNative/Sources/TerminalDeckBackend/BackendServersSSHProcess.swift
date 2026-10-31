import Foundation
import Darwin
import TerminalDeckNativeCore

final class BackendServersSSHEvents<Value: Sendable>: @unchecked Sendable {
    private let lock = NSCondition()
    private let delivery = NSRecursiveLock()
    private var listeners: [UUID: @Sendable (Value) -> Void] = [:]
    private var pending: [Value] = []
    private let retainBeforeSubscription: Bool
    private let replayLatest: Bool
    private var subscribed = false, stopped = false
    private var latest: Value?
    init(retainBeforeSubscription: Bool = false, replayLatest: Bool = false) { self.retainBeforeSubscription = retainBeforeSubscription; self.replayLatest = replayLatest }
    func send(_ value: Value) {
        lock.lock()
        // Bound the gap before a caller installs its first stream listener.
        // Blocking the reader applies pipe backpressure; bytes are not dropped.
        while retainBeforeSubscription && !subscribed && pending.count >= 128 && !stopped { lock.wait() }
        lock.unlock(); delivery.lock(); defer { delivery.unlock() }; lock.lock()
        if replayLatest { latest = value }
        if !subscribed && retainBeforeSubscription && !stopped { pending.append(value) }
        let callbacks = Array(listeners.values); lock.unlock()
        for callback in callbacks { callback(value) }
    }
    func listen(_ callback: @escaping @Sendable (Value) -> Void) -> BackendServersUnsubscribe {
        let id = UUID(); delivery.lock(); defer { delivery.unlock() }; lock.lock(); listeners[id] = callback; subscribed = true; let backlog = pending.isEmpty && replayLatest ? latest.map { [$0] } ?? [] : pending; pending = []; lock.broadcast(); lock.unlock()
        for value in backlog { callback(value) }
        return { [weak self] in guard let self else { return }; lock.lock(); listeners[id] = nil; lock.unlock() }
    }
    func stop() { lock.lock(); stopped = true; pending = []; lock.broadcast(); lock.unlock() }
}
final class BackendServersSSHOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []
    func finish(_ answer: Result<Value, Error>) { let pending = lock.withLock { () -> [CheckedContinuation<Value, Error>] in guard result == nil else { return [] }; result = answer; let old = waiters; waiters = []; return old }; for waiter in pending { waiter.resume(with: answer) } }
    func value() async throws -> Value { try await withCheckedThrowingContinuation { continuation in let answer = lock.withLock { () -> Result<Value, Error>? in if let result { return result }; waiters.append(continuation); return nil }; if let answer { continuation.resume(with: answer) } } }
}
struct BackendServersSSHExit: Sendable { let code: Int?; let signal: String? }

/// Where Foundation's Process stood: the folder a caller may set before `start()`,
/// and whether the child still runs.
final class BackendServersSSHLaunch: @unchecked Sendable {
    let executable: URL, arguments: [String], environment: [String: String]
    private let lock = NSLock()
    private var folder: URL?, running: NativeChild?
    init(executable: URL, arguments: [String], environment: [String: String]) { self.executable = executable; self.arguments = arguments; self.environment = environment }
    var currentDirectoryURL: URL? { get { lock.withLock { folder } } set { lock.withLock { folder = newValue } } }
    var child: NativeChild? { get { lock.withLock { running } } set { lock.withLock { running = newValue } } }
    var isRunning: Bool { child?.isRunning == true }
}

/// All system SSH subprocess creation resides in the owned SSH implementation.
/// Child channels disable authentication so a vanished master cannot fall back
/// to an independent credential-bearing connection. The child runs through the
/// standard runner (`NativeChild`): its own process group, stopped whole on close.
final class BackendServersSSHProcess: BackendServersDuplex, @unchecked Sendable {
    let process: BackendServersSSHLaunch
    private let lock = NSLock()
    /// Serial: both streams and the end arrive here, the end after the last byte.
    private let reports = DispatchQueue(label: "native.servers.ssh.read", qos: .userInitiated)
    private let writes = DispatchQueue(label: "native.servers.ssh.write")
    let stdout = BackendServersSSHEvents<Data>(retainBeforeSubscription: true)
    let stderr = BackendServersSSHEvents<Data>(retainBeforeSubscription: true)
    let ending = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    let completion = BackendServersSSHOnce<BackendServersSSHExit>()
    private var stopped = false, inputEnded = false
    init(executable: URL, arguments: [String], environment: [String: String]) {
        process = .init(executable: executable, arguments: arguments, environment: environment)
    }
    func start() throws {
        process.child = try NativeChild.start(.init(process.executable.path, process.arguments, environment: process.environment,
                                                    cwd: process.currentDirectoryURL?.path, input: .pipe), queue: reports,
            // After close() stdout is no longer read out, as before; stderr still is.
            output: { [weak self] bytes in guard let self, !self.lock.withLock({ self.stopped }) else { return }; Self.relay(bytes, to: self.stdout, 32768) },
            errors: { [weak self] bytes in guard let self else { return }; Self.relay(bytes, to: self.stderr, 8192) },
            exit: { [weak self] end in self?.finish(end) })
    }
    /// In the old read sizes, so the bound before a first listener (128 pieces) holds what it did.
    /// A listener that blocks holds back the other stream and the end too (one report queue).
    private static func relay(_ bytes: Data, to events: BackendServersSSHEvents<Data>, _ size: Int) {
        var at = bytes.startIndex
        while at < bytes.endIndex { let end = min(at + size, bytes.endIndex); events.send(Data(bytes[at..<end])); at = end }
    }
    /// The runner reports the end once every byte is out, so stdout's end and the close come together.
    private func finish(_ end: NativeChild.Termination) {
        lock.withLock { stopped = true }
        ending.send(false)
        completion.finish(.success(.init(code: end.signal == nil ? Int(end.code) : nil, signal: end.signal.map { String($0) }))); ending.send(true)
    }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { stdout.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { if !$0 { listener() } } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { if $0 { listener() } } }
    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                let gone = lock.withLock { inputEnded || stopped }
                guard !gone, let child = process.child else { continuation.resume(throwing: CancellationError()); return }
                do { try child.write(bytes); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func end() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in let already = lock.withLock { let old = inputEnded; inputEnded = true; return old }
                if !already { process.child?.closeInput() }; continuation.resume() }
        }
    }
    /// Back-pressure: the runner stops reading both streams until resume().
    func pause() { process.child?.pauseReading() }
    func resume() { process.child?.resumeReading() }
    func close() {
        let already = lock.withLock { let old = stopped; stopped = true; return old }
        guard !already else { return }
        stdout.stop(); stderr.stop()
        guard let child = process.child else { return }
        // Terminate first (the group: SIGTERM, SIGKILL after 500 ms); closing stdin
        // then also releases a write blocked on a full pipe, so cancellation stays bounded.
        child.resumeReading(); child.terminate(grace: .milliseconds(500)); child.closeInput()
    }
    func wait(timeoutMilliseconds: Int?) async throws -> BackendServersSSHExit {
        let deadline = timeoutMilliseconds.map { ms in Task { [weak self] in do { try await Task.sleep(for: .milliseconds(ms)); guard let self else { return }; self.completion.finish(.failure(BackendServersProblem("no-answer", "The server started that but never finished it, so it was stopped."))); self.close() } catch {} } }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler { try await completion.value() } onCancel: { self.completion.finish(.failure(CancellationError())); self.close() }
    }
    func ready(marker: String, standardOutput: Bool = false, timeoutMilliseconds: Int) async throws {
        let gate = BackendServersSSHOnce<Bool>(), buffer = BackendServersSSHBuffer(maximum: 65536)
        let one = (standardOutput ? stdout : stderr).listen { bytes in buffer.takeError(bytes); if buffer.errorText.contains(marker) { gate.finish(.success(true)) } }
        let two = onClose { gate.finish(.failure(BackendServersSSHSignal(message: buffer.errorText))) }
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)); gate.finish(.failure(BackendServersProblem("no-answer", "That address did not answer in time."))); self.close() } catch {} }
        defer { one(); two(); deadline.cancel() }
        _ = try await withTaskCancellationHandler { try await gate.value() } onCancel: { gate.finish(.failure(CancellationError())); self.close() }
    }
    func collect(stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        let buffer = BackendServersSSHBuffer(maximum: maximumOutputBytes)
        let one = stdout.listen { buffer.takeOutput($0) }, two = stderr.listen { buffer.takeError($0) }
        // The bound includes a blocked stdin write, not just the final wait.
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)); self.completion.finish(.failure(BackendServersProblem("no-answer", "The server started that but never finished it, so it was stopped."))); self.close() } catch {} }
        defer { one(); two(); deadline.cancel() }
        return try await withTaskCancellationHandler {
            if let stdin { try await write(stdin) }; try await end()
            let result = try await wait(timeoutMilliseconds: nil)
            return .init(code: result.code, signal: result.signal, stdout: buffer.outputText, stderr: buffer.errorText, truncated: buffer.truncated)
        } onCancel: { self.completion.finish(.failure(CancellationError())); self.close() }
    }
    deinit { close() }
}
final class BackendServersSSHBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var output = Data(), error = Data(), count = 0, cut = false
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
    func takeOutput(_ bytes: Data) { lock.withLock { if count >= maximum { cut = true; return }; output.append(bytes); count += bytes.count } }
    func takeError(_ bytes: Data) { lock.withLock { if count >= maximum { cut = true; return }; error.append(bytes); count += bytes.count } }
    var outputText: String { lock.withLock { String(decoding: output, as: UTF8.self) } }
    var errorText: String { lock.withLock { String(decoding: error, as: UTF8.self) } }
    var truncated: Bool { lock.withLock { cut } }
}

/// UTF-8 decoding retains a partial code point across PTY chunks.
final class BackendServersSSHUTF8: @unchecked Sendable {
    private let lock = NSLock(); private var pending = Data()
    func decode(_ bytes: Data, final: Bool = false) -> String {
        lock.withLock {
            pending.append(bytes); var end = pending.count
            if !final && end > 0 {
                var at = end - 1
                while at > 0 && pending[at] & 0xc0 == 0x80 { at -= 1 }
                let first = pending[at], width = first < 0x80 ? 1 : first & 0xe0 == 0xc0 ? 2 : first & 0xf0 == 0xe0 ? 3 : first & 0xf8 == 0xf0 ? 4 : 1
                if end - at < width { end = at }
            }
            let text = String(decoding: pending.prefix(end), as: UTF8.self); pending = Data(pending.dropFirst(end)); return text
        }
    }
}
final class BackendServersSSHPty: BackendServersShell, @unchecked Sendable {
    private let events = BackendServersSSHEvents<String>(retainBeforeSubscription: true), closed = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    private let decoder = BackendServersSSHUTF8(), lock = NSLock(), writes = DispatchQueue(label: "native.servers.pty.write")
    private let child: NativeChild
    private var fd: Int32 = -1, stopped = false
    init(executable: URL, arguments: [String], environment: [String: String], size: BackendServersTerminalSize) throws {
        var master: Int32 = -1, slave: Int32 = -1, dimensions = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else { throw NativeRPCError(code: "unavailable", message: "The native SSH terminal could not be opened.") }
        var settings = termios(); if tcgetattr(slave, &settings) == 0 { cfmakeraw(&settings); _ = tcsetattr(slave, TCSANOW, &settings) }
        fd = master
        // The standard runner with the PTY slave as all three streams; no deadline (an interactive
        // shell), its group stop is the limit. EOF owns completion, after the reader has drained
        // the last PTY bytes: the runner's end report can precede those bytes.
        do {
            child = try NativeChild.start(.init(executable.path, arguments, environment: environment,
                                                input: .descriptor(slave), output: .descriptor(slave), errors: .descriptor(slave)))
            Darwin.close(slave)
        } catch { Darwin.close(slave); Darwin.close(master); fd = -1; throw error }
        DispatchQueue(label: "native.servers.pty.read", qos: .userInitiated).async { [weak self] in self?.readLoop(master) }
    }
    private func readLoop(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32768)
        while lock.withLock({ !stopped && fd == descriptor }) { let count = Darwin.read(descriptor, &buffer, buffer.count); if count < 0 && errno == EINTR { continue }; guard count > 0 else { break }; let text = decoder.decode(Data(buffer.prefix(count))); if !text.isEmpty && !lock.withLock({ stopped }) { events.send(text) } }
        let final = decoder.decode(Data(), final: true); if !final.isEmpty { events.send(final) }
        let old = lock.withLock { let previous = fd; fd = -1; return previous }; if old >= 0 { Darwin.close(old) }; finish()
    }
    private func finish() { let changed = lock.withLock { if stopped { return false }; stopped = true; return true }; if changed { closed.send(true) } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { events.listen(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in listener() } }
    func write(_ data: String) { writes.async { [weak self] in guard let self else { return }; let descriptor = lock.withLock { stopped ? -1 : fd }; guard descriptor >= 0 else { return }; try? BackendServersSSHAskpass.write(descriptor, Data(data.utf8)) } }
    func resize(_ size: BackendServersTerminalSize) {
        lock.withLock { guard !stopped, fd >= 0 else { return }; var value = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0); _ = ioctl(fd, TIOCSWINSZ, &value); child.signal(SIGWINCH) }
    }
    /// Closing the master ends ssh's terminal; the group then gets SIGTERM, and SIGKILL a second later.
    func close() { finish(); let descriptor = lock.withLock { let old = fd; fd = -1; return old }; if descriptor >= 0 { Darwin.close(descriptor) }; child.terminate(grace: .seconds(1)) }
    deinit { close() }
}
