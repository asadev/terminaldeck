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

/// All run state lives on one queue, which the child (`NativeChild`) also reports on;
/// progress callbacks never run user code in the app. Stop and the time limit send
/// SIGTERM to the engine's group and allow 15 seconds to tidy up before SIGKILL. The
/// end, as Node's 'close', comes after both streams' last byte; whatever the engine
/// left in its group is ended with it, so no helper can hold the pipes open.
private final class BackendStaysFixedRunJob: @unchecked Sendable {
    /// Its answer is one JSON line; past this much stdout the run is a runaway, stopped and said so.
    static let stdoutLimit = 64 << 20
    private let queue = DispatchQueue(label: "dev.terminaldeck.staysfixed.run")
    private let command: String, args: [String], cwd: String, env: [String: String], timeout: Int
    private let onEvent: @Sendable (NativeRPCValue) -> Void
    private var child: NativeChild?, continuation: CheckedContinuation<BackendStaysFixedRunResult, Never>?
    private var stdout = Data(), output = BackendStaysFixedOutputParser()
    private var timedOut = false, cancelled = false, finished = false, overflowed = false
    init(command: String, args: [String], cwd: String, env: [String: String], timeout: Int, onEvent: @escaping @Sendable (NativeRPCValue) -> Void) {
        self.command = command; self.args = args; self.cwd = cwd; self.env = env; self.timeout = timeout; self.onEvent = onEvent
    }
    func run() async -> BackendStaysFixedRunResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                if cancelled { finish(nil); return }
                do {
                    child = try NativeChild.start(.init(URL(fileURLWithPath: command).path, args, environment: env, cwd: URL(fileURLWithPath: cwd).path),
                                                  queue: queue, output: { [weak self] in self?.take($0) }, errors: { [weak self] in self?.receive($0) },
                                                  exit: { [weak self] in self?.ended($0) })
                } catch { receive(Data(error.localizedDescription.utf8)); finish(nil); return }
                child?.endAfter(.milliseconds(timeout), grace: .seconds(15))
            }
        }
    }
    func cancel() { queue.async { [self] in cancelled = true; child?.terminate(grace: .seconds(15)) } }
    private func receive(_ bytes: Data) {
        for event in output.receive(bytes) { onEvent(event) }
    }
    private func take(_ bytes: Data) {
        guard !overflowed else { return }
        let room = Self.stdoutLimit - stdout.count
        stdout.append(bytes.prefix(room))
        if bytes.count > room { overflowed = true; child?.kill() }
    }
    private func ended(_ end: NativeChild.Termination) {
        if end.timedOut { timedOut = true }
        finish(end.signal == nil ? end.code : nil)
    }
    private func finish(_ code: Int32?) {
        guard !finished else { return }; finished = true; child = nil
        // The last stderr line is what the screen shows for a failed run.
        if overflowed { receive(Data("\nStays Fixed printed more than 64 MB of output, so it was stopped.\n".utf8)) }
        output.finish()
        continuation?.resume(returning: .init(code: code, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: output.stderr, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)); continuation = nil
    }
}
