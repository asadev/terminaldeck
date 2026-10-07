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

/// All system SSH subprocess creation resides in the owned SSH implementation.
/// Child channels disable authentication so a vanished master cannot fall back
/// to an independent credential-bearing connection.
final class BackendServersSSHProcess: BackendServersDuplex, @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe(), error = Pipe()
    private let lock = NSCondition()
    private let writes = DispatchQueue(label: "native.servers.ssh.write")
    let stdout = BackendServersSSHEvents<Data>(retainBeforeSubscription: true)
    let stderr = BackendServersSSHEvents<Data>(retainBeforeSubscription: true)
    let ending = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    let completion = BackendServersSSHOnce<BackendServersSSHExit>()
    private var stopped = false, paused = false, inputEnded = false, outputEnded = false, errorEnded = false
    private var exit: BackendServersSSHExit?
    private var bytesBeforeSubscription = 0
    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = error
    }
    func start() throws {
        process.terminationHandler = { [weak self] child in
            guard let self else { return }
            lock.lock(); exit = .init(code: child.terminationReason == .exit ? Int(child.terminationStatus) : nil,
                signal: child.terminationReason == .uncaughtSignal ? String(child.terminationStatus) : nil); lock.unlock(); finishIfDrained()
        }
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        DispatchQueue(label: "native.servers.ssh.stdout", qos: .userInitiated).async { [weak self] in self?.readOutput() }
        DispatchQueue(label: "native.servers.ssh.stderr", qos: .userInitiated).async { [weak self] in self?.readError() }
    }
    private func readOutput() {
        while true {
            lock.lock(); while paused && !stopped { lock.wait() }; let gone = stopped; lock.unlock(); if gone { break }
            do { guard let bytes = try output.fileHandleForReading.read(upToCount: 32768), !bytes.isEmpty else { break }; stdout.send(bytes) } catch { break }
        }
        lock.lock(); outputEnded = true; lock.unlock(); ending.send(false); finishIfDrained()
    }
    private func readError() {
        while true { do { guard let bytes = try error.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty else { break }; stderr.send(bytes) } catch { break } }
        lock.lock(); errorEnded = true; lock.unlock(); finishIfDrained()
    }
    private func finishIfDrained() {
        lock.lock(); guard outputEnded, errorEnded, let exit else { lock.unlock(); return }; stopped = true; lock.broadcast(); lock.unlock()
        completion.finish(.success(exit)); ending.send(true)
    }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { stdout.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { if !$0 { listener() } } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { if $0 { listener() } } }
    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                lock.lock(); let gone = inputEnded || stopped; lock.unlock()
                guard !gone else { continuation.resume(throwing: CancellationError()); return }
                do { try input.fileHandleForWriting.write(contentsOf: bytes); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func end() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in lock.lock(); let already = inputEnded; inputEnded = true; lock.unlock()
                if !already { try? input.fileHandleForWriting.close() }; continuation.resume() }
        }
    }
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.broadcast(); lock.unlock() }
    func close() {
        lock.lock(); let already = stopped; stopped = true; paused = false; lock.broadcast(); lock.unlock()
        guard !already else { return }
        stdout.stop(); stderr.stop()
        if process.isRunning { process.terminate(); let child = process; DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) { if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } } }
        // Terminate first: closing FileHandle can wait behind a blocked write.
        // Killing the reader releases that write, making cancellation bounded.
        try? input.fileHandleForWriting.close()
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
final class BackendServersSSHFollow: BackendServersFollow, @unchecked Sendable {
    private let child: BackendServersSSHProcess, complaint = BackendServersSSHBuffer(maximum: 8192)
    private let ended = BackendServersSSHEvents<BackendServersFollowEnd>(retainBeforeSubscription: true, replayLatest: true)
    private var subscriptions: [BackendServersUnsubscribe] = []
    init(_ child: BackendServersSSHProcess) {
        self.child = child
        subscriptions.append(child.stderr.listen { [complaint] in complaint.takeError($0) })
        Task { [weak self] in guard let self else { return }; let status = try? await child.wait(timeoutMilliseconds: nil); ended.send(.init(code: status?.signal == nil ? status?.code : nil, stderr: complaint.errorText.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { child.onBytes(listener) }
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe { ended.listen(listener) }
    func close() { child.close() }
    deinit { for cancel in subscriptions { cancel() }; child.close() }
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
    private let process = Process(), events = BackendServersSSHEvents<String>(retainBeforeSubscription: true), closed = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    private let decoder = BackendServersSSHUTF8(), lock = NSLock(), writes = DispatchQueue(label: "native.servers.pty.write")
    private var fd: Int32 = -1, stopped = false
    init(executable: URL, arguments: [String], environment: [String: String], size: BackendServersTerminalSize) throws {
        var master: Int32 = -1, slave: Int32 = -1, dimensions = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else { throw NativeRPCError(code: "unavailable", message: "The native SSH terminal could not be opened.") }
        var settings = termios(); if tcgetattr(slave, &settings) == 0 { cfmakeraw(&settings); _ = tcsetattr(slave, TCSANOW, &settings) }
        fd = master
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        // EOF owns completion, after the reader has drained the last PTY bytes.
        // A Process termination callback can precede those bytes.
        do { try process.run(); Darwin.close(slave) } catch { Darwin.close(slave); Darwin.close(master); fd = -1; throw error }
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
        lock.withLock { guard !stopped, fd >= 0 else { return }; var value = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0); _ = ioctl(fd, TIOCSWINSZ, &value); if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGWINCH) } }
    }
    func close() { finish(); let descriptor = lock.withLock { let old = fd; fd = -1; return old }; if descriptor >= 0 { Darwin.close(descriptor) }; if process.isRunning { process.terminate() } }
    deinit { close() }
}
