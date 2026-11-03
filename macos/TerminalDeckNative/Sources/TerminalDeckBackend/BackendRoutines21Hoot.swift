import Foundation
import TerminalDeckNativeCore

public extension BackendHootChatStore {
    /// Append through the existing chat writer, without starting or changing an AI turn.
    func postRoutineReport(routine: String, runTime: Double, status: String, report: String) throws {
        let row = NativeRPCValue.object([.init("id", .string(UUID().uuidString)), .init("revision", .string(UUID().uuidString)),
            .init("conversationId", snapshot()["conversationId"]), .init("status", .string("sent")), .init("routineReport", .bool(true)),
            .init("routine", .string(routine)), .init("runStatus", .string(status)), .init("at", .number(runTime)),
            .init("report", .object([.init("text", .string(report))]))])
        try recordRouting(row)
    }
}
