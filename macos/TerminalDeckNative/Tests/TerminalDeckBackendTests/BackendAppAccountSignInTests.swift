import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Account status evidence")
struct BackendAppAccountSignInTests {
    private func o(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendAppDeviceParsing.object(fields) }
    @Test func claudeRequiresABooleanAndToleratesAnUpdateNotice() {
        let answer = BackendAppAccountSignInParsing.claude("Update available\n{\"loggedIn\":true,\"email\":\"a@b.com\",\"subscriptionType\":\"max\"}\n")
        #expect(answer?.loggedIn == true)
        #expect(answer?.account == "a@b.com")
        #expect(answer?.plan == "max")
        for text in ["Not logged in · Please run /login", "{\"loggedIn\":", "{\"ok\":true}", "{\"loggedIn\":1}", ""] {
            #expect(BackendAppAccountSignInParsing.claude(text) == nil)
        }
    }
    @Test func claudeFallsBackToOrganizationAndAuthMethod() {
        let answer = BackendAppAccountSignInParsing.claude("{\"loggedIn\":true,\"orgName\":\"Acme\",\"authMethod\":\"apiKey\"}")
        #expect(answer?.account == "Acme")
        #expect(answer?.plan == "apiKey")
    }
    @Test func codexReadsItsOwnEnglishAndDoesNotReadAnEmailFromTokens() {
        #expect(BackendAppAccountSignInParsing.codex("Update available\nLogged in using ChatGPT\n")?.plan == "ChatGPT")
        #expect(BackendAppAccountSignInParsing.codex("Not logged in\n")?.loggedIn == false)
        #expect(BackendAppAccountSignInParsing.codex("Logged in using an API key - work")?.plan == "an API key - work")
        #expect(BackendAppAccountSignInParsing.codex("Logged in using personal access token")?.account == nil)
        #expect(BackendAppAccountSignInParsing.codex("Connexion établie") == nil)
        #expect(BackendAppAccountSignInParsing.codex("{\"loggedIn\":true}") == nil)
    }
    @Test func failedStatusCheckIsUnknownAndNamesActualCommand() {
        let report = BackendAppAccountSignInParsing.report(profileID: "work", provider: "claude", command: "claude auth status --json", probe: .init(stderr: "zsh: command not found: claude", exitCode: 127), now: 1)
        #expect(report.state == "unknown")
        #expect(report.detail.contains("command not found"))
        #expect(report.detail.contains("claude auth status --json"))
        #expect(report.checkedAt == 1)
    }
    @Test func timeoutAndEmptyStatusAreNotSignedOut() {
        let killed = BackendAppAccountSignInParsing.report(profileID: "work", provider: "codex", command: "codex login status", probe: .init(killed: true))
        #expect(killed.state == "unknown")
        #expect(killed.detail.contains("10 seconds"))
        let empty = BackendAppAccountSignInParsing.report(profileID: "work", provider: "codex", command: "codex login status", probe: .init(exitCode: 1))
        #expect(empty.detail.contains("answered nothing"))
    }
    @Test func signedOutAdviceNamesTheSameAgent() {
        let report = BackendAppAccountSignInParsing.report(profileID: "work", provider: "codex", command: "codex login status", probe: .init(stdout: "Not logged in", exitCode: 0))
        #expect(report.state == "signed-out")
        #expect(report.detail.contains("codex login"))
        #expect(!report.detail.contains("claude auth login"))
    }
    @Test func geminiHomeContainsDotGemini() {
        #expect(BackendAppAccountSignInParsing.geminiDirectory(environment: ["GEMINI_CLI_HOME": "/tmp/alt"], home: "/person") == "/tmp/alt/.gemini")
        #expect(BackendAppAccountSignInParsing.geminiDirectory(environment: ["GEMINI_CLI_HOME": "  "], home: "/person") == "/person/.gemini")
    }
    @Test func geminiChosenMethodAloneIsNotALogin() {
        let state = BackendAppAccountSignInParsing.gemini(environment: [:], accounts: .null, settings: o([("security", o([("auth", o([("selectedType", .string("oauth-personal"))]))]))]), credentialsFilePresent: false, keychainPresent: false)
        #expect(!state.signedIn)
        #expect(state.method == "Google account")
        #expect(state.evidence == "settings.json")
        #expect(state.description.contains("Press Sign in"))
    }
    @Test func geminiCredentialEvidencePrecedenceAndAddressArePreserved() {
        let state = BackendAppAccountSignInParsing.gemini(environment: ["GEMINI_API_KEY": "secret-value"], accounts: o([("active", .string(" a@b.com "))]), settings: .null, credentialsFilePresent: true, keychainPresent: true)
        #expect(state.signedIn)
        #expect(state.account == "a@b.com")
        #expect(state.evidence == "keychain")
        #expect(state.method == "an API key in GEMINI_API_KEY")
        #expect(!state.description.contains("secret-value"))
    }
    @Test func geminiAddressOrCredentialFileCountsButMalformedSettingsDoNot() {
        let address = BackendAppAccountSignInParsing.gemini(environment: [:], accounts: o([("active", .string("a@b.com"))]), settings: .null, credentialsFilePresent: false, keychainPresent: false)
        #expect(address.signedIn)
        let token = BackendAppAccountSignInParsing.gemini(environment: [:], accounts: .null, settings: .null, credentialsFilePresent: true, keychainPresent: false)
        #expect(token.evidence == "oauth_creds.json")
        let absent = BackendAppAccountSignInParsing.gemini(environment: [:], accounts: .null, settings: .string("bad"), credentialsFilePresent: false, keychainPresent: false)
        #expect(!absent.signedIn)
    }
}
