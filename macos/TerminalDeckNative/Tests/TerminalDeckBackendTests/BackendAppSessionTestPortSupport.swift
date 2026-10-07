import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSessionTestPortClock: BackendAppSessionClock, @unchecked Sendable {
    private struct Sleep { let deadline: Double; let continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var milliseconds: Double = 0
    private var sleepers: [UUID: Sleep] = [:]
    private var cancelled: Set<UUID> = []
    private var registered = 0
    private var registrations: [(Int, CheckedContinuation<Void, Never>)] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: milliseconds / 1000) }
    func sleep(milliseconds duration: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelled.remove(id) != nil { lock.unlock(); answer.resume(throwing: CancellationError()); return }
                registered += 1; sleepers[id] = Sleep(deadline: milliseconds + Double(duration), continuation: answer)
                let ready = registrations.filter { $0.0 <= registered }; registrations.removeAll { $0.0 <= registered }
                lock.unlock(); for row in ready { row.1.resume() }
            }
        } onCancel: { self.cancel(id) }
    }
    private func cancel(_ id: UUID) {
        lock.lock(); let sleep = sleepers.removeValue(forKey: id); if sleep == nil { cancelled.insert(id) }; lock.unlock()
        sleep?.continuation.resume(throwing: CancellationError())
    }
    func advance(_ amount: Int) {
        lock.lock(); milliseconds += Double(amount)
        let ready = sleepers.filter { $0.value.deadline <= milliseconds }; for key in ready.keys { sleepers[key] = nil }; lock.unlock()
        for row in ready.values { row.continuation.resume() }
    }
    func registeredCount() -> Int { lock.lock(); defer { lock.unlock() }; return registered }
    func whenRegistered(_ count: Int) async {
        await withCheckedContinuation { answer in
            lock.lock(); if registered >= count { lock.unlock(); answer.resume() } else { registrations.append((count, answer)); lock.unlock() }
        }
    }
}
actor BackendAppSessionTestPortExecutor: BackendAppSessionCommandExecuting {
    struct Call: Sendable { let command: String; let arguments: [String]; let environment: [String: String]; let cwd: String; let timeout: Int; let maximumBytes: Int }
    private(set) var calls: [Call] = []
    private var answers: [BackendAppSessionCommandResult]
    init(_ answers: [BackendAppSessionCommandResult]) { self.answers = answers }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        calls.append(.init(command: command, arguments: arguments, environment: environment, cwd: cwd, timeout: timeoutMilliseconds, maximumBytes: maximumBytes))
        return answers.isEmpty ? .init(exitCode: 44) : answers.removeFirst()
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { throw BackendAppSessionError("No process may be detached in a unit fixture.") }
}
func BackendAppSessionTestPortObject(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendAppDeviceParsing.object(fields) }
