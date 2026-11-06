import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Phone display identity and recovery")
struct MacDisplaySelectionTests {
    let main = MacDisplaySelection.Display(number: 4, uuid: UUID(uuidString: "8B687A30-C4E6-48DD-B8B3-6713BB0736BD"), main: true)
    let other = MacDisplaySelection.Display(number: 22, uuid: UUID(uuidString: "A76A1558-1D5D-48E3-B546-D31C7EDD13DD"), main: false)

    @Test func uuidSurvivesCoreGraphicsIDChange() throws {
        let before = MacDisplaySelection.Display(number: 2, uuid: other.uuid, main: false)
        #expect(try MacDisplaySelection.resolve(before.wireID, displays: [main, other]) == other)
    }
    @Test func missingUUIDFallsBackToMainNotAReusedNumber() throws {
        #expect(try MacDisplaySelection.resolve("mac:9B20D968-C375-4C3E-8A44-39359C44254A", displays: [other, main]) == main)
    }
    @Test func legacyNumberStillWorksAndRecoversWhenGone() throws {
        #expect(try MacDisplaySelection.resolve("mac:22", displays: [main, other]) == other)
        #expect(try MacDisplaySelection.resolve("mac:1", displays: [other, main]) == main)
    }
    @Test func mainAliasAndNoMainFlagHaveADefault() throws {
        #expect(try MacDisplaySelection.resolve("mac:main", displays: [other, main]) == main)
        #expect(try MacDisplaySelection.resolve("mac:99", displays: [other]) == other)
    }
    @Test func malformedIdentityIsRefused() {
        for id in ["ios:1", "mac:", "mac:random", "mac:-1", "mac:4294967296"] {
            #expect(throws: MacDisplaySelection.Failure.invalidID) { try MacDisplaySelection.resolve(id, displays: [main]) }
        }
    }
    @Test func noOnlineDisplaysHasAnExplicitOutcome() {
        #expect(throws: MacDisplaySelection.Failure.noDisplays) { try MacDisplaySelection.resolve(main.wireID, displays: []) }
    }
}
