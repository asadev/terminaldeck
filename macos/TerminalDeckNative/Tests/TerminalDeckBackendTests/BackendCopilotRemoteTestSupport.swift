import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

actor BackendCopilotRemoteTestRecorder {
    private var frames: [BackendRemoteServerMessage] = []
    private var unread: [BackendRemoteServerMessage.Kind: [BackendRemoteServerMessage]] = [:]
    private var waiting: [BackendRemoteServerMessage.Kind: [CheckedContinuation<BackendRemoteServerMessage, Never>]] = [:]
    func receive(_ frame: BackendRemoteServerMessage) {
        frames.append(frame)
        if var entries = waiting[frame.kind], !entries.isEmpty {
            let one = entries.removeFirst(); waiting[frame.kind] = entries; one.resume(returning: frame)
        } else { unread[frame.kind, default: []].append(frame) }
    }
    func all(_ kind: BackendRemoteServerMessage.Kind) -> [BackendRemoteServerMessage] { frames.filter { $0.kind == kind } }
    func next(_ kind: BackendRemoteServerMessage.Kind) async -> BackendRemoteServerMessage {
        if var entries = unread[kind], !entries.isEmpty { let one = entries.removeFirst(); unread[kind] = entries; return one }
        return await withCheckedContinuation { waiting[kind, default: []].append($0) }
    }
}
