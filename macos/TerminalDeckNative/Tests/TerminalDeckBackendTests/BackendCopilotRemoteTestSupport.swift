import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

actor BackendCopilotRemoteTestRecorder {
    private var frames: [BackendRemoteServerMessage] = []
    private var unread: [BackendRemoteServerMessage.Kind: [BackendRemoteServerMessage]] = [:]
    private var waiting: [BackendRemoteServerMessage.Kind: [(id: UUID, continuation: CheckedContinuation<BackendRemoteServerMessage?, Never>)]] = [:]
    func receive(_ frame: BackendRemoteServerMessage) {
        frames.append(frame)
        if var entries = waiting[frame.kind], !entries.isEmpty {
            let one = entries.removeFirst(); waiting[frame.kind] = entries; one.continuation.resume(returning: frame)
        } else { unread[frame.kind, default: []].append(frame) }
    }
    func all(_ kind: BackendRemoteServerMessage.Kind) -> [BackendRemoteServerMessage] { frames.filter { $0.kind == kind } }
    /// The next frame of this kind, or nil when none came within `limit`: a missed file-change event fails the test
    /// instead of hanging the whole run (6 Nov, suite-0606).
    func next(_ kind: BackendRemoteServerMessage.Kind, within limit: Duration = .seconds(10)) async -> BackendRemoteServerMessage? {
        if var entries = unread[kind], !entries.isEmpty { let one = entries.removeFirst(); unread[kind] = entries; return one }
        let id = UUID()
        let timer = Task { try? await Task.sleep(for: limit); self.expire(kind, id) }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiting[kind, default: []].append((id, $0)) }
    }
    private func expire(_ kind: BackendRemoteServerMessage.Kind, _ id: UUID) {
        guard var entries = waiting[kind], let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let one = entries.remove(at: index); waiting[kind] = entries; one.continuation.resume(returning: nil)
    }
}
