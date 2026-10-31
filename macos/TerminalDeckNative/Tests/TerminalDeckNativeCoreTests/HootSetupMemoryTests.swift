import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Hoot setup memory")
struct HootSetupMemoryTests {
    private func scratch() -> UserDefaults {
        let name = "hoot-setup-memory-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func onlyThePersonsCloseIsRememberedAndNeverAnsweredAsDone() {
        let defaults = scratch()
        // The app's own close (another screen in front) leaves the next offer free to show.
        HootSetupMemory.answered(closing: true, byPerson: false, defaults: defaults)
        #expect(HootSetupMemory.answer(toOffer: defaults) == nil)
        HootSetupMemory.answered(closing: false, byPerson: true, defaults: defaults)
        #expect(HootSetupMemory.answer(toOffer: defaults) == nil)
        // The person's "not now" closes later offers; it never reports setup as finished.
        HootSetupMemory.answered(closing: true, byPerson: true, defaults: defaults)
        #expect(HootSetupMemory.answer(toOffer: defaults) == "close")
        // Asking again from Settings shows the questions again.
        HootSetupMemory.askAgain(defaults)
        #expect(HootSetupMemory.answer(toOffer: defaults) == nil)
    }
}
