import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendStaysFixedEngineHome: Sendable {
    public let dir: URL, bin: URL
    public let version, versionNote: String
}
public struct BackendStaysFixedRunResult: Sendable {
    public let code: Int32?
    public let stdout, stderr: String
    public let timedOut, cancelled: Bool
}
public enum BackendStaysFixedEngineFiles {
    public static func candidates(resources: String?, appPath: String, cwd: String, override: String?) -> [String] {
        var paths: [String] = []; if let override, !override.isEmpty { paths.append(override) }
        if let resources { paths.append(resources + "/app.asar.unpacked/node_modules/staysfixed") }
        paths += [appPath.replacingOccurrences(of: "app\\.asar$", with: "app.asar.unpacked", options: .regularExpression) + "/node_modules/staysfixed", appPath + "/node_modules/staysfixed", cwd + "/node_modules/staysfixed"]
        var unique: [String] = []; for path in paths where !unique.contains(path) { unique.append(path) }; return unique
    }
    public static func locate(resources: String?, appPath: String, cwd: String, override: String? = nil) throws -> BackendStaysFixedEngineHome {
        var packed = false
        for path in candidates(resources: resources, appPath: appPath, cwd: cwd, override: override) {
            let dir = URL(fileURLWithPath: path), bin = dir.appendingPathComponent("bin/staysfixed.js")
            guard FileManager.default.fileExists(atPath: bin.path) else { continue }
            if path.contains("app.asar/") && !path.contains("app.asar.unpacked/") { packed = true; continue }
            let pkg = (try? Data(contentsOf: dir.appendingPathComponent("package.json"))).flatMap { try? NativeRPCValue.parseJSON($0) }
            let version = pkg?["version"].string ?? ""
            return .init(dir: dir, bin: bin, version: version, versionNote: version == "0.15.0" ? "" : "This build carries Stays Fixed \(version.isEmpty ? "of an unknown version" : version), and was made for 0.15.0.")
        }
        throw NativeRPCError(code: "unavailable", message: packed ? "Stays Fixed is inside this app's archive, where it cannot run. This build is missing a packaging step." : "Stays Fixed is not part of this build.")
    }
    public static func nodeShimText(_ executable: String) -> String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/sh\n# Written by the app that carries Stays Fixed: its own executable, run as Node.\nELECTRON_RUN_AS_NODE=1 exec \(quoted) \"$@\"\n"
    }
    public static func ensureShim(_ dir: URL, executable: String) -> String? {
        let file = dir.appendingPathComponent("node"), text = nodeShimText(executable)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != text { try BackendAccountFiles.writeAtomic(Data(text.utf8), to: file) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path); return file.path
        } catch { return nil }
    }
    public static func environment(base: [String: String], path: String, shim: String?, keep: String?) -> [String: String] {
        var env = base; env["ELECTRON_RUN_AS_NODE"] = "1"; env["NO_COLOR"] = "1"
        env["PATH"] = [path, shim.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
        env["TD_SF_EXEC_PATH"] = shim; env["TD_SF_KEEP"] = keep?.isEmpty == false ? keep : nil; return env
    }
    public static func lastJSON(_ stdout: String) -> NativeRPCValue? {
        func parse(_ text: String) -> NativeRPCValue? {
            guard let value = try? NativeRPCValue.parseJSON(Data(text.utf8)), value.fields != nil else { return nil }; return value
        }
        if let whole = parse(stdout) { return whole }
        for line in stdout.components(separatedBy: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("{"), let value = parse(text) { return value }
        }
        return nil
    }
}

public protocol BackendStaysFixedEngineRunning: Sendable {
    var home: BackendStaysFixedEngineHome { get }
    func cli(_ args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult
    func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult
}
public struct BackendStaysFixedEngine: BackendStaysFixedEngineRunning, Sendable {
    public let home: BackendStaysFixedEngineHome
    public let executable: String, shim: String?, path: String, environment: [String: String]
    private let execution: BackendStaysFixedExecution
    public init(home: BackendStaysFixedEngineHome, executable: String, shim: String?, path: String, environment: [String: String], execution: @escaping BackendStaysFixedExecution = BackendStaysFixedEngine.nativeExecution) {
        self.home = home; self.executable = executable; self.shim = shim; self.path = path; self.environment = environment
        self.execution = execution
    }
    public func cli(_ args: [String], cwd: String, timeout: Int, keep: String? = nil, onEvent: @escaping @Sendable (NativeRPCValue) -> Void = { _ in }) async -> BackendStaysFixedRunResult {
        await run([home.bin.path] + args, cwd: cwd, timeout: timeout, keep: keep, onEvent: onEvent)
    }
    public func script(_ source: String, args: [String], cwd: String, timeout: Int, keep: String? = nil, onEvent: @escaping @Sendable (NativeRPCValue) -> Void = { _ in }) async -> BackendStaysFixedRunResult {
        await run(["--input-type=module", "-e", source, "--", home.dir.path] + args, cwd: cwd, timeout: timeout, keep: keep, onEvent: onEvent)
    }
    private func run(_ entry: [String], cwd: String, timeout: Int, keep: String?, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) async -> BackendStaysFixedRunResult {
        let plan = BackendStaysFixedProcessPlan(command: executable, arguments: ["--import", BackendStaysFixedScripts.preloadURL] + entry, cwd: cwd, environment: BackendStaysFixedEngineFiles.environment(base: environment, path: path, shim: shim, keep: keep), timeoutMilliseconds: timeout)
        return await execution(plan, onEvent)
    }
    public static let nativeExecution: BackendStaysFixedExecution = { plan, event in
        let job = BackendStaysFixedRunJob(command: plan.command, args: plan.arguments, cwd: plan.cwd, env: plan.environment, timeout: plan.timeoutMilliseconds, onEvent: event)
        return await withTaskCancellationHandler { await job.run() } onCancel: { job.cancel() }
    }
}

/// All pipe/process state lives on one queue; progress callbacks never run user
/// code in the app. SIGTERM allows the engine 15 seconds to tidy its children.
private final class BackendStaysFixedRunJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.terminaldeck.staysfixed.run")
    private let command: String, args: [String], cwd: String, env: [String: String], timeout: Int
    private let onEvent: @Sendable (NativeRPCValue) -> Void
    private var child: Process?, out: Pipe?, err: Pipe?, continuation: CheckedContinuation<BackendStaysFixedRunResult, Never>?
    private var stdout = Data(), output = BackendStaysFixedOutputParser()
    private var timedOut = false, cancelled = false, finished = false
    private var processExited = false, stdoutClosed = false, stderrClosed = false
    private var processCode: Int32?
    private var deadline: DispatchWorkItem?, killer: DispatchWorkItem?
    private var readers: [DispatchSourceRead] = []
    init(command: String, args: [String], cwd: String, env: [String: String], timeout: Int, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) {
        self.command = command; self.args = args; self.cwd = cwd; self.env = env; self.timeout = timeout; self.onEvent = onEvent
    }
    func run() async -> BackendStaysFixedRunResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                if cancelled { finish(nil); return }
                let process = Process(), stdoutPipe = Pipe(), stderrPipe = Pipe()
                child = process; out = stdoutPipe; err = stderrPipe
                process.executableURL = URL(fileURLWithPath: command); process.arguments = args; process.environment = env
                process.currentDirectoryURL = URL(fileURLWithPath: cwd); process.standardInput = FileHandle.nullDevice
                process.standardOutput = stdoutPipe; process.standardError = stderrPipe
                for (fd, isError) in [(stdoutPipe.fileHandleForReading.fileDescriptor, false), (stderrPipe.fileHandleForReading.fileDescriptor, true)] {
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                    reader.setEventHandler { [weak self] in
                        guard let self else { reader.cancel(); return }
                        if drain(fd, errorStream: isError) { reader.cancel(); markClosed(errorStream: isError) }
                    }
                    readers.append(reader); reader.resume()
                }
                process.terminationHandler = { [weak self] process in
                    let code: Int32? = process.terminationReason == .uncaughtSignal ? nil : process.terminationStatus
                    self?.queue.async { [weak self] in self?.didExit(code) }
                }
                do { try process.run() } catch { receive(Data(error.localizedDescription.utf8)); finish(nil); return }
                let timer = DispatchWorkItem { [weak self] in self?.timedOut = true; self?.stop() }; deadline = timer
                queue.asyncAfter(deadline: .now() + .milliseconds(timeout), execute: timer)
            }
        }
    }
    func cancel() { queue.async { [self] in cancelled = true; stop() } }
    private func stop() {
        guard let child, child.isRunning else { return }; child.terminate()
        if killer == nil {
            let timer = DispatchWorkItem { [weak self] in if let child = self?.child, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }; killer = timer
            queue.asyncAfter(deadline: .now() + .seconds(15), execute: timer)
        }
    }
    private func receive(_ bytes: Data) {
        for event in output.receive(bytes) { onEvent(event) }
    }
    private func finish(_ code: Int32?) {
        guard !finished else { return }; finished = true; deadline?.cancel(); killer?.cancel()
        readers.forEach { $0.cancel() }; readers.removeAll()
        output.finish()
        continuation?.resume(returning: .init(code: code, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: output.stderr, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)); continuation = nil
    }
    private func didExit(_ code: Int32?) {
        guard !finished else { return }; processExited = true; processCode = code
        if let fd = out?.fileHandleForReading.fileDescriptor, drain(fd, errorStream: false) { stdoutClosed = true }
        if let fd = err?.fileHandleForReading.fileDescriptor, drain(fd, errorStream: true) { stderrClosed = true }
        finishWhenClosed()
    }
    private func markClosed(errorStream: Bool) {
        if errorStream { stderrClosed = true } else { stdoutClosed = true }; finishWhenClosed()
    }
    private func finishWhenClosed() {
        // Node's child 'close' waits for process exit AND both stream EOFs.
        // A descendant can still own a write end after the immediate child exits.
        if processExited && stdoutClosed && stderrClosed { finish(processCode) }
    }
    private func drain(_ fd: Int32, errorStream: Bool) -> Bool {
        guard !finished else { return true }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { return true }
            if count < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }
            let bytes = Data(buffer.prefix(count)); if errorStream { receive(bytes) } else { stdout.append(bytes) }
        }
    }
}
