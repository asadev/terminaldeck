import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("agent-signin.test.ts case parity")
struct BackendServersAgentSigninPortTests {
    private func snippet(_ id: BackendServersAgentID) -> String { BackendServersAgentSignin.signInSnippet(id, binary: "b", state: "i", account: "e", codexHome: "CXH", geminiEnv: "GENV") }
    @Test("reads Codex’s exit status rather than its output") func codexExitStatus() {
        let s = snippet(.codex); #expect(s.contains("login status >/dev/null 2>&1")); #expect(s.contains("i=yes; else i=no; fi")); #expect(!s.contains("Not logged in"))
    }
    @Test("honours a CODEX_HOME the person set in their own shell") func customCodexHome() {
        let s = snippet(.codex); #expect(s.contains(#"CODEX_HOME="${CXH:-$HOME/.codex}" "$b" login status"#)); #expect(s.contains(#""${CXH:-$HOME/.codex}/auth.json""#))
    }
    @Test("takes only the address out of Codex’s token, and only from the public half of it") func publicEmailOnly() {
        let s = snippet(.codex); #expect(s.contains("cut -d. -f2")); #expect(s.contains(#""email":""#)); #expect(!s.contains("access_token")); #expect(!s.contains("refresh_token"))
    }
    @Test("pads base64url before decoding it, and tries more than one decoder") func paddingAndDecoders() {
        let s = snippet(.codex); for fragment in ["${#tdt} % 4", "base64 -d", "base64 -D", "openssl base64 -d -A"] { #expect(s.contains(fragment)) }
    }
    @Test("applies Gemini’s own stated rule for whether it is signed in") func geminiAuthRule() {
        let s = snippet(.gemini); for fragment in [#""selectedType""#, #""selectedAuthType""#, "tdg=$GENV"] { #expect(s.contains(fragment)) }
        for key in ["GEMINI_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"] { #expect(BackendServersAgentSignin.agentEnvProbe.contains(key)) }
    }
    @Test("never runs an agent to find out, because that would spend somebody’s quota") func noPromptProbe() {
        for id in BackendServersAgentID.allCases { #expect(!snippet(id).contains("-p ")) }
    }
    @Test("reads Gemini’s address only where there is one to read") func geminiAccountFile() {
        #expect(snippet(.gemini).contains("google_accounts.json")); #expect(snippet(.gemini).contains(#""active""#))
    }
    @Test("picks the version field the same way for all three") func sharedVersionField() {
        let s = BackendServersAgentSignin.agentVersionAWK; #expect(s.contains(#"^v?[0-9]+\.[0-9]"#)); #expect(!s.contains("print $1}")); #expect(!s.contains("print $NF"))
    }
    @Test("names the caller’s own variables, so one script can be spliced into two") func callerVariables() {
        let s = BackendServersAgentSignin.signInSnippet(.claude, binary: "ab", state: "ai", account: "ae", codexHome: "CXH", geminiEnv: "GENV")
        #expect(s.contains(#""$ab" auth status --json"#)); #expect(s.contains("ai=yes")); #expect(s.contains("ae=$("))
    }
    @Test("pulls the login shell’s settings out of one row rather than a second spawn") func singleEnvironmentRow() {
        let s = BackendServersAgentSignin.readAgentEnv(from: "ALOGIN", codexHome: "CXH", geminiEnv: "GENV")
        #expect(s.contains("grep '^TDENV'")); #expect(s.contains("CXH=$(printf")); #expect(s.contains("GENV=$(printf"))
    }
    @Test("is what the probe actually sends, rather than a second copy of it") func sharedProbeUsesSnippets() {
        let s = BackendServersAgentSignin.signInCases(agentVar: "a", binary: "ab", state: "ai", account: "ae", codexHome: "CXH", geminiEnv: "GENV")
        for line in s.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty { #expect(BackendServersProbe.script.contains(line)) }
        #expect(BackendServersProbe.script.contains(BackendServersAgentSignin.agentVersionAWK)); #expect(BackendServersProbe.script.contains(BackendServersAgentSignin.agentEnvProbe))
    }
    @Test("is what the second caller sends too, which is the whole point of one copy") func setupUsesSharedSnippets() {
        for id in BackendServersAgentID.allCases {
            let s = BackendServersSetupRules.findScript(id)
            #expect(s.contains(BackendServersAgentSignin.agentVersionAWK)); #expect(s.contains(BackendServersAgentSignin.agentEnvProbe))
            for line in snippet(id).components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty { #expect(s.contains(line)) }
        }
    }
}
