import Foundation
import TerminalDeckNativeCore

/// One ordered queue per authenticated wire; independent peers never share a
/// send lock. The source socket's 8 MiB backpressure ceiling remains bounded.
actor BackendRemoteServeWireWriter {
    private let write: @Sendable (String) async throws -> Void
    private var tail: (UUID, Task<Void, Error>)?
    private var queuedBytes = 0
    private var closed = false
    init(write: @escaping @Sendable (String) async throws -> Void) { self.write = write }
    func send(_ text: String) async throws {
        guard !closed else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed.") }
        let bytes = text.utf8.count
        guard queuedBytes + bytes <= 8 * 1024 * 1024 else {
            throw NativeRPCError(code: "unavailable", message: "The remote connection is not reading its output.")
        }
        let id = UUID(), previous = tail?.1
        queuedBytes += bytes
        let task = Task { [self] in
            if let previous { try await previous.value }
            try Task.checkCancellation(); try await writeIfOpen(text)
        }
        tail = (id, task)
        defer { queuedBytes -= bytes; if tail?.0 == id { tail = nil } }
        try await task.value
    }
    private func writeIfOpen(_ text: String) async throws {
        guard !closed else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed.") }
        try await write(text)
    }
    func close() { closed = true; tail?.1.cancel(); tail = nil }
}
