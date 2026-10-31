import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor ChatBind21Calls {
    var calls: [(String, NativeRPCValue)] = []
    func record(_ method: String, _ args: NativeRPCValue) -> Int { calls.append((method, args)); return calls.count }
    func snapshot() -> [(String, NativeRPCValue)] { calls }
}

final class ChatBind21Tests: XCTestCase, @unchecked Sendable {
    private var arguments: NativeRPCValue {
        .object([.init("input", .object([.init("chat", .bool(true)), .init("profileId", .string("signed-in-scratch")), .init("cwd", .string("/scratch/work"))])),
            .init("scope", .object([.init("isAppComposed", .bool(false)), .init("rememberTab", .bool(true)), .init("appFenceID", .string("original-fence"))])),
            .init("privateContext", .object([.init("environmentOverrides", .object([.init("SCRATCH", .string("original"))]))]))])
    }
    private let answer = NativeRPCValue.object([.init("handle", .string("actual-reservation"))])
    private func refusal(_ reason: String) -> BackendHOSTFailure {
        .remote("The persistent host service could not complete account.chat.resolve: " + reason)
    }
    func testNewHostKeepsOrdinaryChatReservation() async throws {
        let calls = ChatBind21Calls(), expected = answer
        let result = try await BackendHOSTChatAccountCompatibility.resolve(chat: true, arguments: arguments) { method, args in
            _ = await calls.record(method, args); return expected
        }
        XCTAssertEqual(result, answer)
        let seen = await calls.snapshot()
        XCTAssertEqual(seen.count, 1); XCTAssertEqual(seen[0].0, "account.chat.resolve"); XCTAssertEqual(seen[0].1, arguments)
    }
    func testOlderHostRefusalUsesItsAppComposedReservationWithoutChangingLoginOrScope() async throws {
        for reason in ["Unknown persistent account operation.", "The private session host could not be authenticated."] {
            let calls = ChatBind21Calls(), expected = answer, error = refusal(reason)
            let result = try await BackendHOSTChatAccountCompatibility.resolve(chat: true, arguments: arguments) { method, args in
                if await calls.record(method, args) == 1 { throw error }; return expected
            }
            XCTAssertEqual(result, answer)
            let seen = await calls.snapshot()
            XCTAssertEqual(seen.map { $0.0 }, ["account.chat.resolve", "account.resolve"])
            XCTAssertEqual(seen[1].1, arguments.setting("scope", arguments["scope"].setting("isAppComposed", .bool(true))))
        }
    }
    func testTerminalNeverUsesChatNegotiation() async throws {
        let calls = ChatBind21Calls(), expected = answer
        _ = try await BackendHOSTChatAccountCompatibility.resolve(chat: false, arguments: arguments) { method, args in
            _ = await calls.record(method, args); return expected
        }
        let seen = await calls.snapshot(); XCTAssertEqual(seen.map { $0.0 }, ["account.resolve"]); XCTAssertEqual(seen[0].1, arguments)
    }
    func testAccountFailureConnectionFailureAndOtherAuthenticationFailureDoNotFallBack() async throws {
        let errors: [any Error] = [refusal("The account is unavailable."), BackendHOSTFailure.io(5), BackendHOSTFailure.authentication,
            BackendHOSTFailure.remote("The persistent host service could not complete account.status: The private session host could not be authenticated.")]
        for expectedError in errors {
            let calls = ChatBind21Calls()
            do {
                _ = try await BackendHOSTChatAccountCompatibility.resolve(chat: true, arguments: arguments) { method, args in
                    _ = await calls.record(method, args); throw expectedError
                }
                XCTFail("A refused account must not report a successful reservation.")
            } catch { XCTAssertEqual(error.localizedDescription, expectedError.localizedDescription) }
            let seen = await calls.snapshot(); XCTAssertEqual(seen.count, 1)
        }
    }
    func testCancellationDoesNotFallBack() async throws {
        let calls = ChatBind21Calls()
        do {
            _ = try await BackendHOSTChatAccountCompatibility.resolve(chat: true, arguments: arguments) { method, args in
                _ = await calls.record(method, args); throw CancellationError()
            }
            XCTFail("Cancelled chat was resolved.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let seen = await calls.snapshot(); XCTAssertEqual(seen.count, 1)
    }
    func testFallbackFailureIsReturnedAndNeverRetried() async throws {
        let calls = ChatBind21Calls(), refused = refusal("Unknown persistent account operation.")
        do {
            _ = try await BackendHOSTChatAccountCompatibility.resolve(chat: true, arguments: arguments) { method, args in
                if await calls.record(method, args) == 1 { throw refused }
                throw BackendHOSTFailure.remote("The selected account cannot be used.")
            }
            XCTFail("Failed fallback reported success.")
        } catch { XCTAssertEqual(error.localizedDescription, "The selected account cannot be used.") }
        let seen = await calls.snapshot(); XCTAssertEqual(seen.count, 2)
    }
}
