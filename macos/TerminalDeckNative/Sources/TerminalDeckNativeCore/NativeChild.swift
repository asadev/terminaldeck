import Foundation
import Darwin

/// The app's one way to start a program over pipes (terminals and their probes use a PTY:
/// `BackendPTYProcess`, `BackendCommandRunner`). The child leads its own process group, so
/// stopping it stops everything it started: no grandchild is left running or holding a pipe.
/// `run` adds the standard limits to a program that runs to its end: a deadline, an output cap
/// and cancellation. A long-lived child (`start`) takes the same group stop and an optional deadline.
/// Never log what a child prints; it can hold secrets.
public final class NativeChild: @unchecked Sendable {
    public enum Input: Sendable { case none, pipe, descriptor(Int32) }
    public enum Output: Sendable { case discard, pipe, descriptor(Int32), inherit
        /// Standard error only: into the standard output pipe.
        case merged
    }
    public struct Spec: Sendable {
        public var command: String
        public var arguments: [String]
        /// nil: this process's own environment.
        public var environment: [String: String]?
        /// nil: this process's own folder.
        public var cwd: String?
        public var input: Input
        public var output: Output
        public var errors: Output
        public init(_ command: String, _ arguments: [String] = [], environment: [String: String]? = nil, cwd: String? = nil,
                    input: Input = .none, output: Output = .pipe, errors: Output = .pipe) {
            self.command = command; self.arguments = arguments; self.environment = environment; self.cwd = cwd
            self.input = input; self.output = output; self.errors = errors
        }
    }
    public struct Termination: Sendable, Equatable {
        /// The exit code, or 128 + the signal that ended it.
        public let code: Int32
        public let signal: Int32?
        /// It was stopped because its deadline passed.
        public let timedOut: Bool
    }
    public struct Outcome: Sendable {
        public let output: Data
        public let errors: Data
        public let code: Int32
        public let timedOut: Bool
        public let outputLimited: Bool
        public var succeeded: Bool { code == 0 && !timedOut && !outputLimited }
        public var outputText: String { String(decoding: output, as: UTF8.self) }
        public var errorsText: String { String(decoding: errors, as: UTF8.self) }
    }

    public let pid: pid_t
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var inputFD: Int32
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var paused = false
    private var watcher: DispatchSourceProcess?
    /// False only in tests: the kernel's exit notice is never armed, as when one is missed.
    private let exitNotices: Bool
    private var reaped: Int32?
    private var finished = false
    private var stopping: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var expired = false
    private let outputFD: Int32, errorsFD: Int32
    private let onOutput: @Sendable (Data) -> Void
    private let onErrors: @Sendable (Data) -> Void
    private let onExit: @Sendable (Termination) -> Void
    /// Held while it runs, as Foundation's Process is: dropping the handle never strands a child unreaped.
    private var keepAlive: NativeChild?

    private init(pid: pid_t, input: Int32, output: Int32, errors: Int32, queue: DispatchQueue, exitNotices: Bool,
                 onOutput: @escaping @Sendable (Data) -> Void, onErrors: @escaping @Sendable (Data) -> Void,
                 onExit: @escaping @Sendable (Termination) -> Void) {
        self.pid = pid; inputFD = input; outputFD = output; errorsFD = errors; self.queue = queue; self.exitNotices = exitNotices
        self.onOutput = onOutput; self.onErrors = onErrors; self.onExit = onExit
    }

    // MARK: Long-lived

    /// Starts `spec` and reports what it prints and how it ended, on `queue` (a serial queue; a
    /// private one when nil). `exit` comes once, after every byte it printed has been delivered.
    public static func start(_ spec: Spec, queue: DispatchQueue? = nil,
                             output: @escaping @Sendable (Data) -> Void = { _ in },
                             errors: @escaping @Sendable (Data) -> Void = { _ in },
                             exit: @escaping @Sendable (Termination) -> Void = { _ in }) throws -> NativeChild {
        try start(spec, queue: queue, exitNotices: true, output: output, errors: errors, exit: exit)
    }

    /// `start`, for tests: `exitNotices: false` never arms the kernel's exit notice, as when one is missed.
    static func start(_ spec: Spec, queue: DispatchQueue? = nil, exitNotices: Bool,
                      output: @escaping @Sendable (Data) -> Void = { _ in },
                      errors: @escaping @Sendable (Data) -> Void = { _ in },
                      exit: @escaping @Sendable (Termination) -> Void = { _ in }) throws -> NativeChild {
        let queue = queue ?? DispatchQueue(label: "dev.terminaldeck.native.child", qos: .utility)
        let spawned = try spawn(spec)
        let child = NativeChild(pid: spawned.pid, input: spawned.input, output: spawned.output, errors: spawned.errors, queue: queue,
                                exitNotices: exitNotices, onOutput: output, onErrors: errors, onExit: exit)
        child.keepAlive = child
        queue.async { child.watch() }
        return child
    }

    public var isRunning: Bool { lock.withLock { reaped == nil } }

    /// Writes all of `data` to its standard input; throws once the child stopped reading.
    public func write(_ data: Data) throws {
        let fd = lock.withLock { inputFD }
        guard fd >= 0 else { throw NativeRPCError(code: "process", message: "The program's input is closed.") }
        try data.withUnsafeBytes { raw in
            guard var at = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let wrote = Darwin.write(fd, at, left)
                if wrote < 0 {
                    if errno == EINTR || errno == EAGAIN { if errno == EAGAIN { usleep(1_000) }; continue }
                    throw NativeRPCError(code: "process", message: "The program stopped reading its input (POSIX status \(errno)).")
                }
                left -= wrote; at += wrote
            }
        }
    }

    /// Sends end-of-file on its standard input.
    public func closeInput() {
        let fd: Int32 = lock.withLock { let fd = inputFD; inputFD = -1; return fd }
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Sends `signal` to the whole group, once (a second SIGINT can make a recorder abort its file).
    public func signal(_ signal: Int32) {
        guard isRunning else { return }
        if Darwin.kill(-pid, signal) != 0 { Darwin.kill(pid, signal) }
        // It is ending for sure: collected even if its exit notice is missed or comes early.
        if signal == SIGKILL { queue.async { [weak self] in self?.reap(ending: .surely) } }
    }

    /// Asks the group to stop (SIGTERM) and ends it (SIGKILL) if it is still there after `grace`.
    public func terminate(grace: DispatchTimeInterval = .seconds(1)) { stop(first: SIGTERM, grace: grace) }

    /// Asks with `first` (SIGINT for a recorder that must close its file), then SIGKILL after `grace`.
    public func stop(first: Int32, grace: DispatchTimeInterval) {
        signal(first)
        let kill = DispatchWorkItem { [weak self] in self?.signal(SIGKILL) }
        lock.withLock { stopping?.cancel(); stopping = kill }
        queue.asyncAfter(deadline: .now() + grace, execute: kill)
    }

    /// Ends the group at once.
    public func kill() { signal(SIGKILL) }

    /// Stops the group once `interval` passes (SIGTERM, then SIGKILL after `grace`); its
    /// termination then says `timedOut`.
    public func endAfter(_ interval: DispatchTimeInterval, grace: DispatchTimeInterval = .seconds(1)) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // An end its exit notice missed is collected here, not taken for a program past its deadline.
            self.reap()
            guard self.isRunning else { return }
            self.lock.withLock { self.expired = true }
            self.terminate(grace: grace)
        }
        lock.withLock { deadline?.cancel(); deadline = item }
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Stops and starts reading its output (back-pressure); the program blocks once its pipe is full.
    public func pauseReading() { queue.async { [self] in guard !paused else { return }; paused = true; readers.values.forEach { $0.suspend() } } }
    public func resumeReading() { queue.async { [self] in guard paused else { return }; paused = false; readers.values.forEach { $0.resume() } } }

    /// Blocks the calling thread until it has ended. Never call it on this child's own queue.
    @discardableResult
    public func waitUntilExit() -> Termination {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Termination>()
        whenFinished { box.value = $0; done.signal() }
        done.wait()
        return box.value!
    }

    /// Waits until it has ended.
    public func exited() async -> Termination {
        await withCheckedContinuation { continuation in whenFinished { continuation.resume(returning: $0) } }
    }

    private var waiters: [@Sendable (Termination) -> Void] = []
    private var ended: Termination?
    private func whenFinished(_ waiter: @escaping @Sendable (Termination) -> Void) {
        queue.async { [self] in
            if let ended { waiter(ended) } else { waiters.append(waiter) }
        }
    }

    // MARK: Runs to its end

    /// Runs `spec` to its end within the standard limits: past `timeoutMilliseconds`, or once it has
    /// printed more than `outputLimit` bytes (both streams together), the whole group is killed.
    /// `input` is written to its standard input, which is then closed.
    public static func run(_ spec: Spec, input: Data? = nil, timeoutMilliseconds: Int, outputLimit: Int = 1 << 20) async throws -> Outcome {
        let cancelled = Box<Bool>(), started = Box<NativeChild>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let child = try run(spec, input: input, timeoutMilliseconds: timeoutMilliseconds, outputLimit: outputLimit) { outcome in
                        if cancelled.value == true { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(returning: outcome) }
                    }
                    started.value = child
                    if Task.isCancelled { cancelled.value = true; child.kill() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            cancelled.value = true
            started.value?.kill()
        }
    }

    /// The same, blocking the calling thread (for code that is synchronous already).
    public static func runBlocking(_ spec: Spec, input: Data? = nil, timeoutMilliseconds: Int, outputLimit: Int = 1 << 20) throws -> Outcome {
        let done = DispatchSemaphore(value: 0), box = Box<Outcome>()
        _ = try run(spec, input: input, timeoutMilliseconds: timeoutMilliseconds, outputLimit: outputLimit) { box.value = $0; done.signal() }
        done.wait()
        return box.value!
    }

    @discardableResult
    public static func run(_ spec: Spec, input: Data? = nil, timeoutMilliseconds: Int, outputLimit: Int,
                           completion: @escaping @Sendable (Outcome) -> Void) throws -> NativeChild {
        guard (1...3_600_000).contains(timeoutMilliseconds), (1...(256 << 20)).contains(outputLimit) else {
            throw NativeRPCError.invalidArguments("The program's time or output limit is out of range.")
        }
        var spec = spec
        if input != nil { spec.input = .pipe }
        let collected = Collected(limit: outputLimit)
        let holder = Box<NativeChild>()
        let child = try start(spec, output: { data in
            if !collected.add(data, errors: false) { holder.value?.kill() }
        }, errors: { data in
            if !collected.add(data, errors: true) { holder.value?.kill() }
        }, exit: { end in
            completion(Outcome(output: collected.output, errors: collected.errors, code: end.code, timedOut: end.timedOut, outputLimited: collected.limited))
        })
        holder.value = child
        child.endAfter(.milliseconds(timeoutMilliseconds), grace: .milliseconds(0))
        if let input {
            DispatchQueue.global(qos: .utility).async {
                try? child.write(input)
                child.closeInput()
            }
        } else if case .pipe = spec.input {
            child.closeInput()
        }
        return child
    }

    /// Starts a program that is meant to outlive this one (a relaunch, `open`): its own group,
    /// no pipes, nothing kept.
    public static func launchDetached(_ spec: Spec) throws {
        var spec = spec
        spec.input = .none
        if case .pipe = spec.output { spec.output = .discard }
        if case .pipe = spec.errors { spec.errors = .discard }
        let pid = try spawn(spec).pid
        // Reaped when it ends so it never lingers as a zombie of this process; no thread waits meanwhile.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        let held = Box<DispatchSourceProcess>()
        held.value = source
        source.setEventHandler {
            // It has exited: this wait returns as soon as it is waitable.
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            held.value?.cancel(); held.value = nil
        }
        source.resume()
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; if waitpid(pid, &status, WNOHANG) != 0 { held.value?.cancel(); held.value = nil } }
    }

    // MARK: Inside

    deinit {
        if paused { readers.values.forEach { $0.resume() } }
        readers.values.forEach { $0.cancel() }
        watcher?.cancel()
        if inputFD >= 0 { Darwin.close(inputFD) }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock(), limit: Int
        private var out = Data(), err = Data(), over = false
        init(limit: Int) { self.limit = limit }
        var output: Data { lock.withLock { out } }
        var errors: Data { lock.withLock { err } }
        var limited: Bool { lock.withLock { over } }
        /// False once the cap is passed.
        func add(_ data: Data, errors: Bool) -> Bool {
            lock.withLock {
                let room = max(0, limit - out.count - err.count)
                if errors { err.append(data.prefix(room)) } else { out.append(data.prefix(room)) }
                if data.count > room { over = true }
                return !over
            }
        }
    }
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Value?
        var value: Value? { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
    }

    private func watch() {
        for (fd, errors) in [(outputFD, false), (errorsFD, true)] where fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.read(fd, errors: errors) }
            reader.setCancelHandler { Darwin.close(fd) }
            readers[fd] = reader
            reader.resume()
        }
        if exitNotices {
            let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            watcher.setEventHandler { [weak self] in self?.reap(ending: .surely) }
            self.watcher = watcher
            watcher.resume()
        }
        // An exit before the watcher was armed sends no event.
        queue.async { [weak self] in self?.reap() }
    }

    private func read(_ fd: Int32, errors: Bool) {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while readers[fd] != nil {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count > 0 {
                let data = Data(bytes.prefix(count))
                if errors { onErrors(data) } else { onOutput(data) }
                continue
            }
            if count == 0 || errno != EAGAIN { closeReader(fd) }
            return
        }
    }

    private func closeReader(_ fd: Int32) {
        guard let reader = readers.removeValue(forKey: fd) else { return }
        if paused { reader.resume() }
        reader.cancel()
        // Both pipes at end-of-file and no exit seen yet: it has most likely ended, so ask (devices freeze, 26 Oct).
        if readers.isEmpty, lock.withLock({ reaped == nil }) { reap(ending: .likely) }
        finishIfDone()
    }

    /// Tests: an exit notice arrives now, as the kernel's does (possibly before the child can be collected).
    func exitNoticed() { queue.async { [weak self] in self?.reap(ending: .surely) } }

    /// Why the child is thought to be ending. `surely`: the kernel's exit notice or a SIGKILL sent, so it is asked
    /// again until collected (5 ms doubling to 1 s, then every second: timers, never a busy loop). `likely`: both
    /// pipes at end-of-file, which a running program can also do, so it is asked again `likelyLimit` times (about
    /// 5 s); after that the kernel's exit notice and the deadline still ask.
    enum Ending { case not, likely, surely }
    static let likelyLimit = 12
    static func recheckPause(_ attempt: Int) -> DispatchTimeInterval { .milliseconds(min(1_000, 5 << min(attempt, 8))) }

    /// Collects the child once it has ended. `ending`: something says it is ending (the kernel's exit
    /// notice, a SIGKILL sent, both pipes at end-of-file). Devices freeze (26 Oct 2026): macOS posts a child's
    /// exit notice a moment before the child can be collected, and this used to ask once (WNOHANG), hear "not
    /// yet" and never ask again (the notice comes once; the deadline only sends signals). An `adb devices`
    /// stayed a zombie of the app for hours, and everything waiting for its end waited forever. A "not yet"
    /// after a notice is now asked again until collected (see `Ending`); no polling otherwise.
    private func reap(ending: Ending = .not, attempt: Int = 0) {
        guard lock.withLock({ reaped == nil }) else { return }
        var status: Int32 = 0, result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        guard result == pid || (result == -1 && errno == ECHILD) else {
            if result == 0, ending == .surely || (ending == .likely && attempt < Self.likelyLimit) {
                queue.asyncAfter(deadline: .now() + Self.recheckPause(attempt)) { [weak self] in
                    self?.reap(ending: ending, attempt: attempt + 1)
                }
            }
            return
        }
        lock.withLock { reaped = result == pid ? status : 0 }
        watcher?.cancel(); watcher = nil
        // Whatever it started goes with it, so nothing is left holding a pipe; and a pipe some
        // other program still holds is let go after two seconds.
        Darwin.kill(-pid, SIGKILL)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            for fd in Array(self.readers.keys) { self.read(fd, errors: fd == self.errorsFD); self.closeReader(fd) }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard !finished, readers.isEmpty, let status = lock.withLock({ reaped }) else { return }
        finished = true
        lock.withLock { stopping?.cancel(); deadline?.cancel() }
        closeInput()
        let signal = status & 0x7f
        let end = Termination(code: signal == 0 ? (status >> 8) & 0xff : 128 + signal, signal: signal == 0 ? nil : signal,
                              timedOut: lock.withLock { expired })
        ended = end
        onExit(end)
        let waiting = waiters; waiters = []
        waiting.forEach { $0(end) }
        keepAlive = nil
    }

    private static func spawn(_ spec: Spec) throws -> (pid: pid_t, input: Int32, output: Int32, errors: Int32) {
        guard spec.command.hasPrefix("/"), !spec.command.contains("\0"), spec.arguments.allSatisfy({ !$0.contains("\0") }),
              spec.cwd.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              (spec.environment ?? [:]).allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw NativeRPCError.invalidArguments("The program, its folder or its environment is not valid to start.")
        }
        var opened: [Int32] = []
        func pipePair() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw NativeRPCError(code: "process", message: "A pipe for the program could not be made (POSIX status \(errno)).") }
            opened += fds
            return (fds[0], fds[1])
        }
        var keep: Set<Int32> = [], started = false
        defer { for fd in opened where !(started && keep.contains(fd)) { Darwin.close(fd) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw NativeRPCError(code: "process", message: "The program's start could not be prepared.")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var ok = true
        func onto(_ target: Int32, _ how: Output) throws -> Int32 {
            switch how {
            case .discard: ok = ok && posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0) == 0; return -1
            case .inherit: ok = ok && posix_spawn_file_actions_addinherit_np(&actions, target) == 0; return -1
            case .descriptor(let fd) where fd == target: ok = ok && posix_spawn_file_actions_addinherit_np(&actions, target) == 0; return -1
            case .descriptor(let fd): ok = ok && posix_spawn_file_actions_adddup2(&actions, fd, target) == 0; return -1
            case .merged: ok = ok && posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, target) == 0; return -1
            case .pipe:
                let pair = try pipePair()
                ok = ok && posix_spawn_file_actions_adddup2(&actions, pair.write, target) == 0
                keep.insert(pair.read); return pair.read
            }
        }
        var inputWriter: Int32 = -1
        switch spec.input {
        case .none: ok = ok && posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0
        case .descriptor(let fd) where fd == STDIN_FILENO: ok = ok && posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0
        case .descriptor(let fd): ok = ok && posix_spawn_file_actions_adddup2(&actions, fd, STDIN_FILENO) == 0
        case .pipe:
            let pair = try pipePair()
            ok = ok && posix_spawn_file_actions_adddup2(&actions, pair.read, STDIN_FILENO) == 0
            keep.insert(pair.write); inputWriter = pair.write
        }
        if case .merged = spec.output { throw NativeRPCError.invalidArguments("Only standard error can be merged.") }
        let output = try onto(STDOUT_FILENO, spec.output)
        let errors = try onto(STDERR_FILENO, spec.errors)
        if let cwd = spec.cwd { ok = ok && posix_spawn_file_actions_addchdir(&actions, cwd) == 0 }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, signal) }
        ok = ok && posix_spawnattr_setflags(&attributes, flags) == 0 && posix_spawnattr_setpgroup(&attributes, 0) == 0
            && posix_spawnattr_setsigmask(&attributes, &empty) == 0 && posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
        guard ok else { throw NativeRPCError(code: "process", message: "The program's start could not be prepared.") }
        let argv = CStrings([spec.command] + spec.arguments)
        var pid: pid_t = 0
        let status: Int32
        if let environment = spec.environment {
            let env = CStrings(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })
            status = posix_spawn(&pid, spec.command, &actions, &attributes, argv.pointer, env.pointer)
        } else {
            status = posix_spawn(&pid, spec.command, &actions, &attributes, argv.pointer, environ)
        }
        guard status == 0 else {
            throw NativeRPCError(code: status == ENOENT ? "missing" : "process",
                                 message: "\((spec.command as NSString).lastPathComponent) could not be started (POSIX status \(status)).")
        }
        started = true
        for fd in keep { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        if inputWriter >= 0 { _ = fcntl(inputWriter, F_SETNOSIGPIPE, 1) }
        return (pid, inputWriter, output, errors)
    }

    private final class CStrings {
        let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        private let count: Int
        init(_ strings: [String]) {
            count = strings.count
            pointer = .allocate(capacity: count + 1)
            for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
            pointer[count] = nil
        }
        deinit { for index in 0..<count { free(pointer[index]) }; pointer.deallocate() }
    }
}
