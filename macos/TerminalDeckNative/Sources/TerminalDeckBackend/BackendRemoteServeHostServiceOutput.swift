import Foundation
import TerminalDeckNativeCore

/// Per-peer FIFO with one actual socket write outstanding. NWConnection's
/// callbacks may arrive after teardown; tokens prevent double settlement.
final class BackendRemoteServeHostServiceOutput: @unchecked Sendable {
    typealias Write = @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    private struct Entry {
        let id: UUID, data: Data, completion: CheckedContinuation<Void, Error>
    }
    private let queue = DispatchQueue(label: "native.remote.peer.output", qos: .userInitiated)
    private let write: Write
    private var pending: [Entry] = []
    private var current: Entry?
    private var ended: Error?
    init(write: @escaping Write) { self.write = write }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) -> Void in
            queue.async { [self] in
                if let ended { completion.resume(throwing: ended); return }
                pending.append(.init(id: UUID(), data: data, completion: completion)); advance()
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { completion in
            queue.async { [self] in
                let error = NativeRPCError(code: "disconnected", message: "The remote socket closed")
                ended = error
                let old = pending; pending = []
                let active = current; current = nil
                active?.completion.resume(throwing: error)
                for entry in old { entry.completion.resume(throwing: error) }
                completion.resume()
            }
        }
    }
    private func advance() {
        guard current == nil, ended == nil, !pending.isEmpty else { return }
        let entry = pending.removeFirst(); current = entry
        write(entry.data) { [weak self] error in
            guard let self else { return }
            self.queue.async { [self] in
                guard current?.id == entry.id else { return }
                current = nil
                if let error {
                    ended = error; entry.completion.resume(throwing: error)
                    let old = pending; pending = []; for next in old { next.completion.resume(throwing: error) }
                } else { entry.completion.resume(); advance() }
            }
        }
    }
}
