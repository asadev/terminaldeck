import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Calls

    /// One `tasks:local-detail` call; never a throw — a failure is a sentence.
    /// F3: the same `BackendCrmDetailClient` the shared-parity tests run, over the app's bridge.
    /// Its sentences are today's; an absent optional argument keeps its explicit null slot.
    func call(_ fn: String, _ args: [Any?]) async -> Result<[String: Any], TasksProblem> {
        let arguments: [NativeRPCValue]
        do { arguments = try args.map { $0 == nil ? NativeRPCValue.null : try NativeRPCValue.fromFoundation($0) } }
        catch { return .failure(TasksProblem(error.localizedDescription)) }
        if let threadTransport {
            do { return CrmDecode.ok(try await threadTransport.invoke(fn, arguments).foundation) }
            catch { return .failure(TasksProblem(error.localizedDescription)) }
        }
        if let connected {
            return CrmDecode.ok(await ConnectedTasksStore.shared.popupCall(connected.connection, fn, arguments).foundation)
        }
        let client = BackendCrmDetailClient(isReady: EngineBridge.shared.isReady) { @MainActor function, values in
            let answer = try await EngineBridge.shared.invoke("tasks:local-detail", [function, NativeRPCValue.array(values).foundation])
            return try NativeRPCValue.fromFoundation(answer)
        }
        return CrmDecode.ok(await client.call(fn, arguments).foundation)
    }

    /// A write whose answer is only ok or a refusal.
    @discardableResult
    func write(_ fn: String, _ args: [Any?], label: String? = nil) async -> Bool {
        switch await call(fn, args) {
        case .success: return true
        case .failure(let problem):
            if let label { error = "\(label): \(problem.message)" }
            return false
        }
    }

}
