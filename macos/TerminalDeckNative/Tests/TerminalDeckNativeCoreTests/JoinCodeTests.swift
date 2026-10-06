import Testing
@testable import TerminalDeckNativeCore

// Join a remote session, native. Mirrors JoinRemoteDialog.test.ts case for case.

@Suite("JoinCode alphabet") struct JoinCodeAlphabetTests {
    @Test func dropsTheFourCharactersCrockfordDrops() {
        for character in "ILOU" { #expect(!JoinCode.alphabet.contains(character)) }
    }
    @Test func hasNoDuplicates() {
        #expect(Set(JoinCode.alphabet).count == JoinCode.alphabet.count)
    }
}

@Suite("normalizeJoinCode") struct JoinCodeNormalizeTests {
    @Test func acceptsACodeWithTheDash() { #expect(JoinCode.normalizeCode("A1B2-C3D4") == "A1B2C3D4") }
    @Test func acceptsSpacesAndLowerCase() { #expect(JoinCode.normalizeCode(" a1b2 c3d4 ") == "A1B2C3D4") }
    @Test func readsTheGlyphsTheAlphabetDoesNotContain() { #expect(JoinCode.normalizeCode("O0I1L2") == "001112") }
    @Test func leavesUAloneSoItCanBeReported() { #expect(JoinCode.normalizeCode("UUUU") == "UUUU") }
}

@Suite("formatJoinCode") struct JoinCodeFormatTests {
    @Test func groupsAFullCodeIntoFours() { #expect(JoinCode.formatCode("A1B2C3D4") == "A1B2-C3D4") }
    @Test func noTrailingDashOnAPartialCode() {
        #expect(JoinCode.formatCode("A1B2") == "A1B2")
        #expect(JoinCode.formatCode("A1B2C") == "A1B2-C")
    }
    @Test func isIdempotent() { #expect(JoinCode.formatCode(JoinCode.formatCode("a1b2c3d4")) == "A1B2-C3D4") }
}

@Suite("validateJoinCode") struct JoinCodeValidateTests {
    @Test func acceptsAWellFormedCode() { #expect(JoinCode.validateCode("a1b2-c3d4") == .ok("A1B2C3D4")) }
    @Test func emptyIsEmpty() { #expect(JoinCode.validateCode("").problem == .empty) }
    @Test func namesTheOffendingCharacter() {
        let check = JoinCode.validateCode("A1B2C3DU")
        #expect(check.problem == .invalidCharacters)
        #expect(check.message?.contains("U") == true)
    }
    @Test func badCharacterBeatsWrongLength() { #expect(JoinCode.validateCode("UU").problem == .invalidCharacters) }
    @Test func listsEachBadCharacterOnce() {
        #expect(JoinCode.validateCode("UUUUUUUU").message?.filter { $0 == "U" }.count == 1)
    }
    @Test func countsDownTheCharactersStillMissing() {
        let check = JoinCode.validateCode("A1B2C3D")
        #expect(check.problem == .tooShort)
        #expect(check.message?.contains("1 more character ") == true)
    }
    @Test func pluralisesTheCountdown() { #expect(JoinCode.validateCode("A1").message?.contains("6 more characters") == true) }
    @Test func rejectsTooLong() {
        let check = JoinCode.validateCode("A1B2C3D4E")
        #expect(check.problem == .tooLong)
        #expect(check.message?.contains(String(JoinCode.codeLength)) == true)
    }
}

@Suite("validateJoinPin") struct JoinPinTests {
    @Test func acceptsSixDigits() { #expect(JoinCode.validatePin("012345") == .ok("012345")) }
    @Test func keepsALeadingZero() { #expect(JoinCode.validatePin("000123").value == "000123") }
    @Test func ignoresSeparators() { #expect(JoinCode.validatePin("012 345").isOK) }
    @Test func emptyIsEmpty() { #expect(JoinCode.validatePin("").problem == .empty) }
    @Test func countsDownTheDigitsStillMissing() {
        let check = JoinCode.validatePin("01234")
        #expect(check.problem == .tooShort)
        #expect(check.message?.contains("1 more digit ") == true)
    }
    @Test func rejectsMoreThanSix() {
        let check = JoinCode.validatePin("0123456")
        #expect(check.problem == .tooLong)
        #expect(check.message?.contains(String(JoinCode.pinLength)) == true)
    }
    @Test func dropsLetters() { #expect(JoinCode.normalizePin("12a34b") == "1234") }
}

@Suite("validateJoinRequest") struct JoinRequestTests {
    @Test func needsBothHalves() {
        #expect(JoinCode.validateRequest(code: "A1B2-C3D4", pin: "012345"))
        #expect(!JoinCode.validateRequest(code: "A1B2-C3D4", pin: "01234"))
        #expect(!JoinCode.validateRequest(code: "A1B2-C3D", pin: "012345"))
    }
    @Test func remoteSessionsCannotBeJoined() { #expect(JoinCode.remoteSessionsAvailable == false) }
    @Test func notesAndStatusSayWhatThePageSays() {
        #expect(JoinCode.codeNote("", touched: false) == ("8 characters.", false))
        #expect(JoinCode.codeNote("", touched: true) == ("Enter the code you were given.", true))
        #expect(JoinCode.codeNote("a1b2c3d4", touched: false) == ("A1B2-C3D4", false))
        #expect(JoinCode.pinNote("", touched: false) == ("6 digits, from the host.", false))
        #expect(JoinCode.pinNote("012345", touched: true) == ("Looks right.", false))
        #expect(JoinCode.status(code: "A1B2C3D4", pin: "012345") == "Well formed — but there is still nothing to connect to.")
        #expect(JoinCode.status(code: "", pin: "") == "Enabled when session sharing ships.")
    }
}
