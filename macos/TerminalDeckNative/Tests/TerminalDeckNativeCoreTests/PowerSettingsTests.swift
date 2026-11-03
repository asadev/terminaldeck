import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — Settings → Power (mirrors PowerSection.test.tsx's wording and narrowing).

private func json(_ text: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

@Suite("Power settings")
struct PowerSettingsTests {
    @Test func stateIsNarrowedPessimistically() throws {
        let state = try #require(LidAwakeState.decode(json(#"{"supported":true,"on":"yes","known":1,"battery":{"present":true,"discharging":false,"percent":80},"detail":"","idleBlocked":true}"#)))
        #expect(state.supported)
        #expect(!state.on)
        #expect(!state.known)
        #expect(state.detail == nil)
        #expect(state.battery?.percent == 80)
        #expect(state.hasLid)
        #expect(state.idleBlocked)
        #expect(LidAwakeState.decode("x") == nil)
        let desktop = try #require(LidAwakeState.decode(json(#"{"battery":{"present":false}}"#)))
        #expect(!desktop.hasLid)
    }

    @Test func resultsDefaultToAFailureThatSaysSo() {
        let result = LidAwakeResult.decode(json(#"{"outcome":"weird"}"#))
        #expect(result.outcome == .failed)
        #expect(result.message == "The change finished without saying what happened.")
        #expect(result.isWarning)
        #expect(!LidAwakeResult.decode(json(#"{"outcome":"unchanged","message":"Already on."}"#)).isWarning)
    }

    @Test func cautionFollowsTheMachine() {
        #expect(PowerWords.caution(hasLid: false) == nil)
        #expect(PowerWords.caution(hasLid: true)?.hasPrefix("A closed lid means no airflow") == true)
    }
}
