import Foundation
import Darwin
import TerminalDeckNativeCore

/// macOS PTY ownership. All methods/events run on the manager's serial queue.
/// A child enters a new session/process group via forkpty. argv/env/cwd and
/// descriptor limits are prepared before the fork; the child uses C calls only.
final class BackendPTYProcess: @unchecked Sendable {
    let pid: pid_t
    private let queue: DispatchQueue
    private var master: Int32
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var watcher: DispatchSourceProcess?
    private var escalation: DispatchWorkItem?
    private var output: [UInt8] = []
    private var outputOffset = 0
    private(set) var exited = false
    private var terminationRequested = false
    private let secretStream: BackendAPISecretStream
    /// Claude Code's folder for whatever runs here (an AI session, or `claude` typed in a shell).
    let claudeFolder: String?
    var onData: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int) -> Void)?

    private init(pid: pid_t, master: Int32, queue: DispatchQueue, secret: String?, claudeFolder: String?) {
        self.pid = pid; self.master = master; self.queue = queue; self.claudeFolder = claudeFolder
        secretStream = BackendAPISecretStream(secret)
    }

    static func spawn(command: String, args: [String], environment: [String: String], cwd: String,
                      cols: Int, rows: Int, queue: DispatchQueue,
                      beforeExec: (@Sendable (Int32) throws -> Void)? = nil) throws -> BackendPTYProcess {
        guard command.hasPrefix("/"), cwd.hasPrefix("/"),
              !command.contains("\0"), !cwd.contains("\0"), args.allSatisfy({ !$0.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("A native PTY launch needs an absolute executable and working directory, with valid arguments.")
        }
        let arguments = try CStringVector([command] + args)
        let expanded = try BackendAPIAccountEnvironment.expand(environment, command: command)
        let env = try CStringVector(expanded.values.keys.sorted().map { "\($0)=\(expanded.values[$0]!)" })
        guard let executable = strdup(command) else {
            throw BackendSessionFailure.operatingSystem(operation: "prepare a terminal launch", code: ENOMEM)
        }
        guard let directory = strdup(cwd) else {
            free(executable)
            throw BackendSessionFailure.operatingSystem(operation: "prepare a terminal launch", code: ENOMEM)
        }
        defer { free(executable); free(directory) }
        let argumentPointers = arguments.base
        let environmentPointers = env.base
        let descriptors = try execErrorPipe()
        let errorRead = descriptors.read
        let errorWrite = descriptors.write
        var readOpen = true, writeOpen = true
        defer {
            if readOpen { Darwin.close(errorRead) }
            if writeOpen { Darwin.close(errorWrite) }
        }
        // HOST: prepare every descriptor before fork. The default path has no
        // extra gate; a supplied callback must durably record ownership first.
        let needsGate = beforeExec != nil
        var readinessRead: Int32 = -1, readinessWrite: Int32 = -1
        var releaseRead: Int32 = -1, releaseWrite: Int32 = -1
        defer {
            if readinessRead >= 0 { Darwin.close(readinessRead) }
            if readinessWrite >= 0 { Darwin.close(readinessWrite) }
            if releaseRead >= 0 { Darwin.close(releaseRead) }
            if releaseWrite >= 0 { Darwin.close(releaseWrite) }
        }
        if needsGate {
            let ready = try execErrorPipe()
            readinessRead = ready.read; readinessWrite = ready.write
            let release = try execErrorPipe()
            releaseRead = release.read; releaseWrite = release.write
            // Child death during the parent callback must return EPIPE, never
            // deliver SIGPIPE to the host and end its other live sessions.
            guard fcntl(releaseWrite, F_SETNOSIGPIPE, 1) == 0 else {
                throw BackendSessionFailure.operatingSystem(operation: "protect the terminal child release pipe", code: errno)
            }
        }
        let closeLimit = getdtablesize()
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var descriptor: Int32 = -1

        let child = forkpty(&descriptor, nil, nil, &size)
        if child < 0 { throw BackendSessionFailure.operatingSystem(operation: "create a terminal", code: errno) }
        if child == 0 {
            // No Foundation, strings, collections, dispatch or allocation here.
            // forkpty already made this child the controlling-terminal session
            // leader, so its process group is exactly its own pid.
            Darwin.close(errorRead)
            var fd: Int32 = 3
            while fd < closeLimit {
                if fd != errorWrite && fd != readinessWrite && fd != releaseRead { Darwin.close(fd) }
                fd += 1
            }
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            sigaction(SIGPIPE, &defaultAction, nil)
            sigaction(SIGINT, &defaultAction, nil)
            sigaction(SIGQUIT, &defaultAction, nil)
            sigaction(SIGTERM, &defaultAction, nil)
            sigaction(SIGHUP, &defaultAction, nil)
            sigaction(SIGCHLD, &defaultAction, nil)
            if chdir(directory) != 0 {
                var failure = errno
                _ = Darwin.write(errorWrite, &failure, MemoryLayout<Int32>.size)
                _exit(126)
            }
            if needsGate {
                // C only: forkpty/chdir/signal setup are complete. Tell the
                // parent, then require its explicit release before any exec.
                var ready: UInt8 = 1
                var sent: Int = 0
                repeat { sent = Darwin.write(readinessWrite, &ready, 1) } while sent == -1 && errno == EINTR
                Darwin.close(readinessWrite)
                if sent != 1 { _exit(126) }
                var permission: UInt8 = 0
                var received: Int = 0
                repeat { received = Darwin.read(releaseRead, &permission, 1) } while received == -1 && errno == EINTR
                Darwin.close(releaseRead)
                // Parent death or refusal closes the pipe: never exec then.
                if received != 1 || permission != 1 { _exit(126) }
            }
            _ = execve(executable, argumentPointers, environmentPointers)
            var failure = errno
            _ = Darwin.write(errorWrite, &failure, MemoryLayout<Int32>.size)
            _exit(127)
        }

        Darwin.close(errorWrite)
        writeOpen = false
        if needsGate {
            Darwin.close(readinessWrite); readinessWrite = -1
            Darwin.close(releaseRead); releaseRead = -1
        }
        // CLOEXEC closes the error writer on success. A failed exec writes its
        // errno first, allowing create() to fail accurately instead of returning
        // a supposedly live session that exits instantly with no explanation.
        do {
            if needsGate {
                try awaitChildReadiness(read: readinessRead, execError: errorRead)
                Darwin.close(readinessRead); readinessRead = -1
                try beforeExec?(child)
                var permission: UInt8 = 1
                var written: Int = 0
                repeat { written = Darwin.write(releaseWrite, &permission, 1) } while written == -1 && errno == EINTR
                guard written == 1 else {
                    throw BackendSessionFailure.operatingSystem(operation: "release the inventoried terminal child", code: written == 0 ? EPIPE : errno)
                }
                Darwin.close(releaseWrite); releaseWrite = -1
            }
            try awaitExec(read: errorRead)
            Darwin.close(errorRead)
            readOpen = false
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1,
                  fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
                throw BackendSessionFailure.operatingSystem(operation: "configure a terminal descriptor", code: errno)
            }
            return BackendPTYProcess(pid: child, master: descriptor, queue: queue, secret: expanded.secret,
                                     claudeFolder: NativeSignInRenewal.folder(environment: expanded.values))
        } catch {
            // Only this newly forked child/group can be targeted here. It has
            // not been reaped, so this pid cannot have been reused.
            Darwin.kill(-child, SIGKILL)
            Darwin.kill(child, SIGKILL)
            if descriptor >= 0 { Darwin.close(descriptor) }
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            throw error
        }
    }


    /// Set callbacks before starting; even an immediately exited child then
    /// has its final output/exit observed exactly once.
    func start() {
        guard reader == nil, watcher == nil, !exited else { return }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        reader = readSource
        readSource.resume()
        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        processSource.setEventHandler { [weak self] in self?.reap() }
        watcher = processSource
        processSource.resume()
    }

    /// 18 Oct (#48): a child that was released while the manager began shutting down is never started or listed;
    /// its group is ended and the child reaped here (it is still unreaped, so the pid cannot have been reused).
    func abandon() {
        guard !exited, reader == nil, watcher == nil else { return terminate() }
        Darwin.kill(-pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        exited = true
        if master >= 0 { Darwin.close(master); master = -1 }
    }

    func write(_ data: Data) throws {
        guard !exited, master >= 0 else { throw BackendSessionFailure.exitedSession }
        guard output.count - outputOffset + data.count <= 4 * 1024 * 1024 else {
            throw BackendSessionFailure.invalidInput("The session has too much pending input. Wait for it to consume input before writing again.")
        }
        if outputOffset > 0 {
            output.removeFirst(outputOffset)
            outputOffset = 0
        }
        output.append(contentsOf: data)
        try flushInput()
    }

    func resize(cols: Int, rows: Int) throws {
        guard !exited, master >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if ioctl(master, TIOCSWINSZ, &size) == -1 {
            if errno != EIO && errno != EBADF { throw BackendSessionFailure.operatingSystem(operation: "resize a terminal", code: errno) }
        }
    }

    /// Remove is immediate at the manager layer; process death is confirmed
    /// later by waitpid. Signal the entire original group, including children.
    /// A Claude Code sign-in renewal under way in its folder finishes first (stop, switch, quit and host
    /// swap all end sessions here): cutting one between its server call and its save signs that login out.
    func terminate() {
        guard !exited else { return }
        terminationRequested = true
        // Held strongly while it waits (at most NativeSignInRenewal.patience): the manager may already have let
        // this session go, and the hang-up must still be sent.
        NativeSignInRenewal.whenSettled(claudeFolder, on: queue, stillNeeded: { !self.exited }) { self.hangUp() }
    }

    private func hangUp() {
        guard !exited else { return }
        Darwin.kill(-pid, SIGHUP)
        Darwin.kill(pid, SIGHUP)
        escalation?.cancel()
        let term = DispatchWorkItem { [weak self] in
            guard let self, !self.exited else { return }
            Darwin.kill(-self.pid, SIGTERM)
            Darwin.kill(self.pid, SIGTERM)
            let force = DispatchWorkItem { [weak self] in
                guard let self, !self.exited else { return }
                NativeSignInRenewal.whenSettled(self.claudeFolder, on: self.queue, stillNeeded: { !self.exited }) {
                    guard !self.exited else { return }
                    Darwin.kill(-self.pid, SIGKILL)
                    Darwin.kill(self.pid, SIGKILL)
                }
            }
            self.escalation = force
            self.queue.asyncAfter(deadline: .now() + .milliseconds(700), execute: force)
        }
        escalation = term
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: term)
    }

    private func flushInput() throws {
        while outputOffset < output.count {
            let count = output.withUnsafeBytes { bytes in
                Darwin.write(master, bytes.baseAddress!.advanced(by: outputOffset), output.count - outputOffset)
            }
            if count > 0 { outputOffset += count; continue }
            if count == -1 && errno == EINTR { continue }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    source.setEventHandler { [weak self] in try? self?.flushInput() }
                    writer = source
                    source.resume()
                }
                return
            }
            let failure = errno
            output.removeAll(keepingCapacity: false); outputOffset = 0
            writer?.cancel(); writer = nil
            throw BackendSessionFailure.operatingSystem(operation: "write to a terminal", code: failure)
        }
        output.removeAll(keepingCapacity: true); outputOffset = 0
        writer?.cancel(); writer = nil
    }

    private func readAvailable() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress!, $0.count) }
            if count > 0 {
                let safe = secretStream.feed(Data(buffer.prefix(count)))
                if !safe.isEmpty { onData?(safe) }
                received += count
                // Yield to pending writes, removal and process events during a
                // continuous stream; the read source schedules remaining bytes.
                if received >= 1_048_576 { return }
                continue
            }
            if count == -1 && errno == EINTR { continue }
            if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF/EIO means the slave was closed. Keep the master until the
            // process event reaps the child and closes resources in one place.
            reader?.cancel(); reader = nil
            return
        }
    }

    private func reap() {
        guard !exited else { return }
        // The root is still unreaped here, so its original group identifier
        // cannot have been reused. A child that ignored HUP must not escape
        // teardown merely because the group's root exited first.
        if terminationRequested { Darwin.kill(-pid, SIGKILL) }
        var status: Int32 = 0
        var answer: pid_t
        repeat { answer = waitpid(pid, &status, WNOHANG) } while answer == -1 && errno == EINTR
        if answer == 0 {
            // The exit event can arrive a moment before the child is waitable, and it
            // arrives once: returning here left a zombie and an owner that never heard
            // the exit (a dev-server port scan hung for minutes). Ask again shortly.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.reap() }
            return
        }
        guard answer == pid || (answer == -1 && errno == ECHILD) else { return }
        readAvailable()
        let remaining = secretStream.finish()
        if !remaining.isEmpty { onData?(remaining) }
        exited = true
        escalation?.cancel(); escalation = nil
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        watcher?.cancel(); watcher = nil
        if master >= 0 { Darwin.close(master); master = -1 }
        output.removeAll(keepingCapacity: false); outputOffset = 0
        let signal = status & 0x7f
        let code = signal == 0 ? Int((status >> 8) & 0xff) : 128 + Int(signal)
        let callback = onExit
        onData = nil; onExit = nil
        callback?(answer == pid ? code : -1)
    }

    private static func execErrorPipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw BackendSessionFailure.operatingSystem(operation: "create the terminal launch pipe", code: errno) }
        for index in 0..<2 {
            if descriptors[index] < 3 {
                let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                if duplicate == -1 {
                    let failure = errno
                    Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
                    throw BackendSessionFailure.operatingSystem(operation: "protect the terminal launch pipe", code: failure)
                }
                Darwin.close(descriptors[index]); descriptors[index] = duplicate
            }
            guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) != -1 else {
                let failure = errno
                Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
                throw BackendSessionFailure.operatingSystem(operation: "protect the terminal launch pipe", code: failure)
            }
        }
        return (descriptors[0], descriptors[1])
    }

    private static func awaitChildReadiness(read descriptor: Int32, execError: Int32) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw BackendSessionFailure.operatingSystem(operation: "await terminal child readiness", code: ETIMEDOUT) }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, Int32(max(1, (deadline - now) / 1_000_000)))
            if ready == -1 && errno == EINTR { continue }
            guard ready > 0 else { throw BackendSessionFailure.operatingSystem(operation: "await terminal child readiness", code: ready == 0 ? ETIMEDOUT : errno) }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == -1 && errno == EINTR { continue }
            if count == 0 {
                // chdir/setup failed before readiness: retain the exact errno
                // from the existing exec error pipe rather than hide it.
                try awaitExec(read: execError)
            }
            guard count == 1, byte == 1 else { throw BackendSessionFailure.operatingSystem(operation: "read terminal child readiness", code: EIO) }
            return
        }
    }


    private static func awaitExec(read descriptor: Int32) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw BackendSessionFailure.operatingSystem(operation: "finish the terminal launch", code: ETIMEDOUT) }
            let remaining = Int32(max(1, (deadline - now) / 1_000_000))
            let ready = poll(&event, 1, remaining)
            if ready == -1 && errno == EINTR { continue }
            guard ready > 0 else { throw BackendSessionFailure.operatingSystem(operation: "finish the terminal launch", code: ready == 0 ? ETIMEDOUT : errno) }
            var failure: Int32 = 0
            let count = Darwin.read(descriptor, &failure, MemoryLayout<Int32>.size)
            if count == 0 { return }
            if count == -1 && errno == EINTR { continue }
            guard count == MemoryLayout<Int32>.size else { throw BackendSessionFailure.operatingSystem(operation: "read the terminal launch result", code: EIO) }
            throw BackendSessionFailure.operatingSystem(operation: "execute the terminal program", code: failure)
        }
    }

    private final class CStringVector {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        private let count: Int
        init(_ strings: [String]) throws {
            let count = strings.count
            let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
            base.initialize(repeating: nil, count: count + 1)
            for (index, string) in strings.enumerated() {
                guard let text = strdup(string) else {
                    for i in 0..<index { free(base[i]) }
                    base.deinitialize(count: count + 1); base.deallocate()
                    throw BackendSessionFailure.operatingSystem(operation: "prepare terminal arguments", code: ENOMEM)
                }
                base[index] = text
            }
            self.count = count
            self.base = base
        }
        deinit {
            for i in 0..<count { free(base[i]) }
            base.deinitialize(count: count + 1); base.deallocate()
        }
    }
}
