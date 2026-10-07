import Foundation
import CoreFoundation
import Dispatch
import Darwin

/// Real helper-process stdio. No host capabilities are exposed by these pipes:
/// every JSON-RPC request still enters BackendPluginsHost's private dispatcher.
public enum BackendJSCoreHelperRunner {
    public static func configuration(arguments: [String], environment: [String: String], cwd: String) throws -> BackendJSCoreRuntimeConfiguration {
        guard arguments.count == 2, let entry = arguments.last, entry.hasPrefix("/"),
              let data = environment["HOME"], data.hasPrefix("/") else {
            throw BackendPluginsError(-32003, "The JavaScriptCore helper needs one absolute plugin main path and its own data home.")
        }
        return try .init(entryURL: URL(fileURLWithPath: entry), folderURL: URL(fileURLWithPath: cwd),
            dataURL: URL(fileURLWithPath: data), environment: environment)
    }
    public static func run(arguments: [String] = ProcessInfo.processInfo.arguments,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           cwd: String = FileManager.default.currentDirectoryPath,
                           bootstrap: any BackendJSCoreRuntimeBootstrap) -> Never {
        // Broken pipe is an exit in progress, not a crash of the Mac app.
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        do {
            let config = try configuration(arguments: arguments, environment: environment, cwd: cwd)
            let output = BackendJSCoreHelperPipe(fd: STDOUT_FILENO)
            let errors = BackendJSCoreHelperPipe(fd: STDERR_FILENO)
            let runtime = try BackendJSCoreRuntimeVM(configuration: config, bootstrap: bootstrap,
                output: { if !output.write($0) { Darwin._exit(1) } },
                stderr: { _ = errors.write($0) }, exit: { Darwin._exit($0) })
            // Read before loading arbitrary JS. This reader never waits for the
            // VM; input cannot block the parent's actor and its kill deadline.
            DispatchQueue.global(qos: .utility).async {
                var budget = BackendJSCoreTransportLineBudget()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    if count == 0 { runtime.endInput(); return }
                    if count < 0 {
                        _ = errors.write(Data("The JavaScriptCore helper could not read plugin stdin.\n".utf8)); Darwin._exit(1)
                    }
                    let bytes = Data(buffer.prefix(count))
                    do { try budget.accept(bytes) }
                    catch { _ = errors.write(Data((error.localizedDescription + "\n").utf8)); Darwin._exit(1) }
                    runtime.receive(bytes)
                }
            }
            try runtime.start()
            // A persistent source keeps an idle plugin alive, as process.stdin
            // does in Node. Timers and every JS callback share this run loop.
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            guard let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
                throw BackendPluginsError(-32003, "The JavaScriptCore helper run loop is unavailable.")
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, CFRunLoopMode.defaultMode)
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), keepAlive, CFRunLoopMode.defaultMode)
            runtime.shutdown()
            Darwin._exit(0)
        } catch {
            _ = BackendJSCoreHelperPipe(fd: STDERR_FILENO).write(Data((error.localizedDescription + "\n").utf8))
            Darwin._exit(1)
        }
    }
}
private final class BackendJSCoreHelperPipe: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    init(fd: Int32) { descriptor = fd }
    func write(_ data: Data) -> Bool {
        lock.withLock {
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
