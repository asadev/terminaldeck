import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct SessionChatWireTests {
    @Test func replacementEventsKeepTheActualChatKind() {
        var chat = BackendFoundationTestsSessionsFixtures.meta("check-chat")
        chat.chat = true
        #expect(BackendCompositionSuppliers.sessionWire(chat)["chat"].bool == true)
        let terminal = BackendFoundationTestsSessionsFixtures.meta("check-terminal")
        #expect(BackendCompositionSuppliers.sessionWire(terminal)["chat"].isNullish)
    }
}
