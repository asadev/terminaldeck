import Foundation
import CoreFoundation
@preconcurrency import JavaScriptCore

/// Helper-process VM lifecycle. NEVER use this interpreter in the native app's
/// process: arbitrary JS may never return. The app owns BackendPluginsProcess,
/// whose separate timeout owner kills the helper with SIGKILL.
///
/// A VM's deferred work permanently belongs to the initializer thread's run
/// loop (JSVirtualMachine.h). A serial DispatchQueue can move threads, so this
/// implementation creates/uses/releases the VM on the helper's main thread.
public final class BackendJSCoreRuntimeVM: @unchecked Sendable {
    private let configuration: BackendJSCoreRuntimeConfiguration
    private let bootstrap: any BackendJSCoreRuntimeBootstrap
    private let output: @Sendable (Data) -> Void
    private let stderr: @Sendable (Data) -> Void
    private let terminate: @Sendable (Int32) -> Void
    private let loop: CFRunLoop
    private var machine: JSVirtualMachine?
    private var context: JSContext?
    private var bridge: BackendJSCoreRuntimeBridge?
    private var inputHandler: ((Data) -> Void)?
    private var endHandler: (() -> Void)?
    private var timers: [Int: Timer] = [:]
    private var nextTimer = 1
    private var started = false
    private var stopped = false
    private let inputLock = NSLock()
    private var queuedBytes = 0
    private var inputEnded = false
    private var hardStopped = false
    public init(configuration: BackendJSCoreRuntimeConfiguration, bootstrap: any BackendJSCoreRuntimeBootstrap,
                output: @escaping @Sendable (Data) -> Void, stderr: @escaping @Sendable (Data) -> Void,
                exit: @escaping @Sendable (Int32) -> Void) throws {
        guard Thread.isMainThread else { throw BackendPluginsError(-32003, "JavaScriptCore requires the isolated helper's main VM thread.") }
        self.configuration = configuration; self.bootstrap = bootstrap; self.output = output; self.stderr = stderr; terminate = exit
        loop = CFRunLoopGetCurrent()
    }
    public func start() throws {
        requireOwner()
        guard !started, !stopped else { throw BackendPluginsError(-32000, "plugins: a process is started once") }
        started = true
        let candidate: JSVirtualMachine? = JSVirtualMachine()
        guard let machine = candidate, let context = JSContext(virtualMachine: machine) else {
            throw BackendPluginsError(-32003, "The JavaScriptCore VM is unavailable in this helper.")
        }
        self.machine = machine; self.context = context
        let bridge = BackendJSCoreRuntimeBridge(runtime: self, output: output, stderr: stderr, exit: terminate)
        self.bridge = bridge
        context.exceptionHandler = { context, exception in
            // Keep the normal JSC propagation. Setting the handler to nil would
            // silently catch callback exceptions, which is an empty success.
            context?.exception = exception
        }
        do {
            try bootstrap.install(context: context, configuration: configuration, bridge: bridge)
            try checkException()
            try bootstrap.loadEntry(context: context, configuration: configuration, bridge: bridge)
            try checkException()
        } catch { shutdown(); throw error }
    }
    /// Called by the helper's independent input reader, never by its VM thread.
    /// Admission does not wait for JS; a blocked VM cannot stop the pipe draining.
    public func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let admitted = inputLock.withLock {
            guard !hardStopped, !inputEnded else { return 0 }
            guard bytes.count <= BackendJSCoreRuntimeLimits.queuedInputBytes - queuedBytes else { hardStopped = true; return -1 }
            queuedBytes += bytes.count; return 1
        }
        guard admitted == 1 else {
            // Do not attempt a diagnostic write here: a hostile VM may be
            // holding stderr while the parent is applying pipe backpressure.
            // Hard exit must remain independent of every VM/output lock.
            if admitted < 0 { terminate(1) }
            return
        }
        enqueue(BackendJSCoreRuntimeWork { [weak self] in
            guard let self else { return }
            defer { self.inputLock.withLock { self.queuedBytes -= bytes.count } }
            guard !self.stopped else { return }
            self.inputHandler?(bytes)
            self.failIfUncaught()
        })
    }
    public func endInput() {
        let first = inputLock.withLock { if inputEnded || hardStopped { return false }; inputEnded = true; return true }
        guard first else { return }
        enqueue(BackendJSCoreRuntimeWork { [weak self] in
            guard let self, !self.stopped else { return }
            self.endHandler?(); self.failIfUncaught()
            // Node stdin EOF is not itself process.exit: the compatibility
            // process 'end' listeners decide. Parent has the 1s stop deadline.
        })
    }
    public func shutdown() {
        requireOwner()
        guard !stopped else { return }; stopped = true
        inputLock.withLock { hardStopped = true }
        for timer in timers.values { timer.invalidate() }; timers.removeAll()
        inputHandler = nil; endHandler = nil
        if let context, let bridge { bootstrap.shutdown(context: context, configuration: configuration, bridge: bridge); context.exceptionHandler = nil; context.exception = nil }
        bridge = nil; context = nil; machine = nil
    }
    func enqueue(_ work: BackendJSCoreRuntimeWork) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { work.run() }
        CFRunLoopWakeUp(loop)
    }
    func setInputHandlers(data: @escaping (Data) -> Void, end: @escaping () -> Void) {
        requireOwner(); guard !stopped else { return }; inputHandler = data; endHandler = end
    }
    func schedule(delayMS: Double, repeatMS: Double?, callback: @escaping () -> Void) -> Int {
        requireOwner()
        // Bound the native owner too: guest code can invoke the exported
        // timer block directly and bypass the compatibility shim.
        guard !stopped, timers.count < BackendJSCoreRuntimeLimits.maximumTimers else { return 0 }
        let id = nextTimer; nextTimer += 1
        // Node floors timer delays to 1ms for NaN/<1/>Int32.max.
        func delay(_ value: Double) -> TimeInterval { value.isFinite && value >= 1 && value <= Double(Int32.max) ? floor(value) / 1000 : 0.001 }
        let work = BackendJSCoreRuntimeTimerWork(callback)
        let repeating = repeatMS != nil
        let timer = Timer(fire: Date(timeIntervalSinceNow: delay(delayMS)), interval: repeatMS.map(delay) ?? 0,
                          repeats: repeating) { [weak self] _ in
            guard let self, !self.stopped, self.timers[id] != nil else { return }
            if !repeating { self.timers[id] = nil }
            work.run(); self.failIfUncaught()
        }
        timers[id] = timer; RunLoop.current.add(timer, forMode: .default); return id
    }
    func cancelTimer(_ id: Int) { requireOwner(); timers.removeValue(forKey: id)?.invalidate() }
    private func requireOwner() { precondition(Thread.isMainThread, "JavaScriptCore values must stay on the helper's main VM thread") }
    private func checkException() throws {
        if let exception = context?.exception {
            let message = exception.toString() ?? "the plugin threw an exception"
            context?.exception = nil
            throw BackendPluginsError(-32000, message)
        }
    }
    private func failIfUncaught() {
        do { try checkException() }
        catch { stderr(Data((error.localizedDescription + "\n").utf8)); shutdown(); terminate(1) }
    }
}
private final class BackendJSCoreRuntimeTimerWork: @unchecked Sendable {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { action() }
}
