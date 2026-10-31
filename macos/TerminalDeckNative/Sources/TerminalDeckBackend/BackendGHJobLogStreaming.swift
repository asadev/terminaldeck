import Foundation
import TerminalDeckNativeCore

/// One downloaded job snapshot, consumed incrementally by the visible view.
/// GitHub REST does not expose a live push feed for a still-running job.
/// Cancel the stream task when the view disappears; no timer or watcher remains.
public protocol BackendGHJobLogStreaming: Sendable {
    func streamJobLogs(arguments: NativeRPCValue) async -> AsyncThrowingStream<NativeRPCValue, Error>
}
