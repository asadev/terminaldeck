#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import Testing
@testable import TerminalDeckBackend

/// 18 Oct (#107): a real refusal from the session host is reported, never answered with this Mac's own login as if
/// the host were older than the app.
@Suite("HOST older host: only a host that does not know an account question is treated as older")
struct HOSTOlderHostRefusalTests {
    private let refusedAuthentication = BackendHOSTFailure.remote("The persistent host service could not complete account.facade: "
        + (BackendHOSTFailure.authentication.errorDescription ?? ""))

    @Test func aHostThatAnswersTheTypedCodeIsOlderOnlyWhenItSaysSo() {
        #expect(!BackendHOSTAccountControlFrontend.refusedByOlderHost(refusedAuthentication, typed: true))
        #expect(!BackendHOSTAccountControlFrontend.refusedByOlderHost(BackendHOSTFailure.authentication, typed: true))
        #expect(!BackendHOSTAccountControlFrontend.refusedByOlderHost(
            BackendHOSTFailure.remote("The persistent host service could not complete account.facade: That account is not on this Mac any more."), typed: true))
        #expect(BackendHOSTAccountControlFrontend.refusedByOlderHost(
            BackendHOSTUnknownChannel("This session host is from an older build and does not know \"profiles:effective\"."), typed: true))
    }
    @Test func aHostFromBeforeTheCodeIsStillReadByItsWords() {
        #expect(BackendHOSTAccountControlFrontend.refusedByOlderHost(refusedAuthentication, typed: false))
        #expect(!BackendHOSTAccountControlFrontend.refusedByOlderHost(BackendHOSTFailure.remote("The session host is busy. Try again in a moment."), typed: false))
    }
    @Test func theCodeTravelsAndOlderPeersReadNothingNew() throws {
        let sent = BackendHOSTProtocol.Response(error: "does not know", errorCode: BackendHOSTUnknownChannel.code)
        let read = try JSONDecoder().decode(BackendHOSTProtocol.Response.self, from: JSONEncoder().encode(sent))
        #expect(read.errorCode == "unknown-channel"); #expect(read.error == "does not know")
        let old = try JSONDecoder().decode(BackendHOSTProtocol.Response.self, from: Data(#"{"error":"could not be authenticated"}"#.utf8))
        #expect(old.errorCode == nil)
        let hello = try JSONDecoder().decode(BackendHOSTProtocol.Hello.self,
            from: Data(#"{"protocolVersion":2,"hostVersion":"old","hostPID":1,"instance":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#.utf8))
        #expect(hello.accountUnknownChannel == nil)
    }
}
#endif
