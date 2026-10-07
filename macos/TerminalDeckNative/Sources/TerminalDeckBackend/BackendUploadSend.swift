import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

public struct BackendUploadProgress: Sendable {
    public let id: String, name: String, path: String, phase: String, message: String
    public let size: Int64, sent: Int64
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name)), .init("size", .number(Double(size))),
        .init("sent", .number(Double(sent))), .init("path", .string(path)), .init("phase", .string(phase)), .init("message", .string(message))]) }
}

/// Real streaming sender with 24 KiB chunks and a 256 KiB ACK window. The pane
/// sees acknowledged bytes; sending to a socket never counts as progress.
public actor BackendUploadSend {
    public typealias Authorize = @Sendable (URL, NativeRPCContext) async throws -> URL
    private let authorize: Authorize
    private let progress: @Sendable (BackendUploadProgress) async -> Void
    private var active: Transfer?
    private struct Waiter { let condition: Condition; let continuation: CheckedContinuation<Void, Error>; let deadline: Task<Void, Never> }
    private enum Condition { case ready, credit, done }
    private final class Transfer {
        let id = UUID().uuidString.lowercased()
        let name: String
        let size: Int64
        let guest: BackendRemoteGuest
        var path = "", phase = "opening", message = ""
        var read: Int64 = 0, acked: Int64 = 0
        var hash = ""
        var finished = false
        var failure: Error?
        var waiters: [UUID: Waiter] = [:]
        init(name: String, size: Int64, guest: BackendRemoteGuest) { self.name = name; self.size = size; self.guest = guest }
        var snapshot: BackendUploadProgress { .init(id: id, name: name, path: path, phase: phase, message: message, size: size, sent: acked) }
    }
    public init(authorize: @escaping Authorize, onProgress: @escaping @Sendable (BackendUploadProgress) async -> Void) { self.authorize = authorize; progress = onProgress }
    public func send(file: URL, directory: String?, guest: BackendRemoteGuest, context: NativeRPCContext) async throws -> String {
        guard active == nil else { throw NativeRPCError(code: "upload-running", message: "One file at a time — wait for the one already going, or cancel it.") }
        let resolved = try await authorize(file, context)
        // upload-send.ts:299-320: each refusal is that file's own sentence, in its order.
        var pre = stat()
        guard stat(resolved.path, &pre) == 0 else { throw NativeRPCError(code: "upload-source", message: "That file could not be read.") }
        guard pre.st_mode & S_IFMT == S_IFREG else { throw NativeRPCError(code: "upload-source", message: "Only files can be sent, not folders.") }
        guard pre.st_size > 0 else { throw NativeRPCError(code: "upload-source", message: "That file is empty.") }
        guard pre.st_size <= 536870912 else { throw NativeRPCError(code: "upload-source", message: "That file is too big to send. The limit is \(BackendSharedText.byteSize(536870912)).") }
        let fd = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeRPCError(code: "upload-source", message: "That file could not be opened.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 536870912 else { throw NativeRPCError(code: "upload-source", message: "That file could not be read.") }
        let transfer = Transfer(name: resolved.lastPathComponent, size: Int64(info.st_size), guest: guest)
        let transferID = transfer.id
        active = transfer
        defer { if active === transfer { active = nil } }
        return try await withTaskCancellationHandler {
            do {
                await emit(transfer)
                do {
                    try await guest.send(type: "upload.begin", fields: [.init("id", .string(transfer.id)), .init("name", .string(transfer.name)),
                        .init("size", .number(Double(transfer.size))), .init("dir", directory.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .missing)], capability: "upload")
                } catch { throw NativeRPCError(code: "upload-offline", message: "That machine is not connected.") }  // upload-send.ts:367
                try await wait(.ready, transfer: transfer)
                transfer.phase = "sending"; await emit(transfer)
                var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 24576)
                while transfer.read < transfer.size {
                    try Task.checkCancellation()
                    try await wait(.credit, transfer: transfer)
                    let wanted = min(buffer.count, Int(transfer.size - transfer.read))
                    let amount = Darwin.read(fd, &buffer, wanted)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw NativeRPCError(code: "upload-source", message: "The file stopped reading before all its bytes were sent") }
                    let chunk = Data(buffer.prefix(amount)); digest.update(data: chunk); transfer.read += Int64(amount)
                    try await guest.send(type: "upload.data", fields: [.init("id", .string(transfer.id)), .init("data", .string(chunk.base64EncodedString()))], capability: "upload")
                }
                var finalInfo = stat()
                guard fstat(fd, &finalInfo) == 0, finalInfo.st_size == info.st_size, finalInfo.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                      finalInfo.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw NativeRPCError(code: "upload-source", message: "The file changed while it was being sent") }
                transfer.hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                transfer.phase = "finishing"; await emit(transfer)
                try await guest.send(type: "upload.end", fields: [.init("id", .string(transfer.id)), .init("sha256", .string(transfer.hash))], capability: "upload")
                try await wait(.done, transfer: transfer)
                return transfer.path
            } catch {
                await fail(transfer, error: error, cancelRemote: true)
                throw error
            }
        } onCancel: { Task { await self.cancel(id: transferID) } }
    }
    public func handle(_ frame: NativeRPCValue) async {
        guard let transfer = active, frame["id"].string == transfer.id else { return }
        switch frame["t"].string {
        case "upload.ready":
            guard let path = frame["path"].string, !path.isEmpty else { await fail(transfer, error: NativeRPCError.malformed("The receiver did not give a file path"), cancelRemote: true); return }
            transfer.path = path; wake(transfer)
        case "upload.ack":
            guard let number = frame["bytes"].number, number.rounded() == number, number > 0, number <= 262144,
                  transfer.acked + Int64(number) <= transfer.read else { await fail(transfer, error: NativeRPCError.malformed("The receiver acknowledged bytes that were never sent"), cancelRemote: true); return }
            transfer.acked += Int64(number); wake(transfer); await emit(transfer)
        case "upload.done":
            guard frame["bytes"].number == Double(transfer.size), frame["sha256"].string?.lowercased() == transfer.hash,
                  let path = frame["path"].string, path == transfer.path else { await fail(transfer, error: NativeRPCError.malformed("The receiver's finished file does not match this transfer"), cancelRemote: true); return }
            transfer.finished = true; transfer.acked = transfer.size; transfer.phase = "landed"; wake(transfer); await emit(transfer)
        case "upload.failed": await fail(transfer, error: NativeRPCError(code: "upload-remote", message: frame["message"].string ?? "The receiver refused this upload"), cancelRemote: false)
        default: break
        }
    }
    public func cancel() async -> Bool { guard let active, !active.finished, active.failure == nil else { return false }; await fail(active, error: CancellationError(), cancelRemote: true); return true }
    private func cancel(id: String) async { if let active, active.id == id { await fail(active, error: CancellationError(), cancelRemote: true) } }
    public func disconnected() async { if let active { await fail(active, error: NativeRPCError(code: "upload-offline", message: "The machine disconnected while sending the file"), cancelRemote: false) } }
    private func satisfied(_ condition: Condition, _ transfer: Transfer) -> Bool {
        switch condition { case .ready: return !transfer.path.isEmpty; case .credit: return transfer.read - transfer.acked + 24576 <= 262144; case .done: return transfer.finished }
    }
    private func wait(_ condition: Condition, transfer: Transfer) async throws {
        if let failure = transfer.failure { throw failure }
        if satisfied(condition, transfer) { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self, transferID = transfer.id] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }; await self?.expired(transferID) }
            transfer.waiters[id] = Waiter(condition: condition, continuation: continuation, deadline: deadline)
        }
    }
    private func wake(_ transfer: Transfer) {
        for (id, waiter) in transfer.waiters where transfer.failure != nil || satisfied(waiter.condition, transfer) {
            transfer.waiters[id] = nil; waiter.deadline.cancel()
            if let failure = transfer.failure { waiter.continuation.resume(throwing: failure) } else { waiter.continuation.resume() }
        }
    }
    private func expired(_ id: String) async { if let active, active.id == id { await fail(active, error: NativeRPCError(code: "upload-timeout", message: "The receiver stopped acknowledging this file"), cancelRemote: true) } }
    private func fail(_ transfer: Transfer, error: Error, cancelRemote: Bool) async {
        guard transfer.failure == nil && !transfer.finished else { return }
        transfer.failure = error; transfer.phase = "failed"; transfer.message = error is CancellationError ? "Cancelled." : error.localizedDescription
        wake(transfer); await emit(transfer)
        if cancelRemote { try? await transfer.guest.send(type: "upload.cancel", fields: [.init("id", .string(transfer.id))], capability: "upload") }
    }
    private func emit(_ transfer: Transfer) async { await progress(transfer.snapshot) }
}
