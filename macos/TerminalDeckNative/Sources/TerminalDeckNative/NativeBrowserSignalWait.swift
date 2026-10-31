import Foundation
import Observation
import AppKit

/// One observation registration and, when requested, one deadline. State
/// changes re-arm observation; there is no repeating timer or polling task.
@MainActor
final class NativeBrowserSignalWait {
    private var condition: (() -> Bool)?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?

    static func until(timeout: Duration? = nil, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let waiter = NativeBrowserSignalWait()
        waiter.condition = condition
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                if Task.isCancelled { waiter.finish(false); return }
                waiter.check()
                if waiter.continuation != nil, let timeout {
                    waiter.deadline = Task { [weak waiter] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        waiter?.finish(false)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(false) }
        }
    }

    private func check() {
        guard continuation != nil, let condition else { return }
        let ready = withObservationTracking { condition() } onChange: { [weak self] in
            Task { @MainActor in self?.check() }
        }
        if ready { finish(true) }
    }
    private func finish(_ value: Bool) {
        let waiting = continuation
        continuation = nil; condition = nil
        deadline?.cancel(); deadline = nil
        waiting?.resume(returning: value)
    }
}

/// A rendering host is never evidence that a page is visible to the person.
@MainActor
final class NativeBrowserCaptureWindow: NSWindow {
    func releasePage(_ view: NSView, previousSuperview: NSView?, previousFrame: NSRect) {
        // A visible host may adopt the page while snapshot awaits WebKit.
        if contentView === view, view.window === self {
            contentView = nil
            previousSuperview?.addSubview(view)
            view.frame = previousFrame
        }
        close()
    }
}
