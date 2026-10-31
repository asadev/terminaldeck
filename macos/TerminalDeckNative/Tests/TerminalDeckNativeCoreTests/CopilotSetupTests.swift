import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors copilot-identity.test.ts, copilot-setup-model.test.ts and consent-model.test.ts.
// The fixture is the real TypeScript's output (withCopilotIdentity), so the bytes match.

private let fixture = ####"{"out":[{"text":"","id":{"name":null,"callThem":null,"addressNote":null},"once":"## Who you are\n\nThey have not given you a name of their own, so you go by the one this app\ngives you: **Hoot**. Do not pick a different name for yourself; if\nthey give you one, it replaces this paragraph.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\n---\n","again":"## Who you are\n\nYour name is **Zed**. This app reads it from this line — change the\nname here and it changes in the sidebar, on the tab and in Settings.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\n---\n"},{"text":"# Hoot\n\nYou are a developer's copilot.\nMore prose.\n\n## Rules\n- one\n","id":{"name":"Nova","callThem":"Asad","addressNote":"short answers"},"once":"# Hoot\n\n## Who you are\n\nYour name is **Nova**. This app reads it from this line — change the\nname here and it changes in the sidebar, on the tab and in Settings.\n\nCall them **Asad**.\n\nAddress them like this: short answers\n\n---\n\nYou are a developer's copilot.\nMore prose.\n\n## Rules\n- one\n","again":"# Hoot\n\n## Who you are\n\nYour name is **Zed**. This app reads it from this line — change the\nname here and it changes in the sidebar, on the tab and in Settings.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\n---\n\nYou are a developer's copilot.\nMore prose.\n\n## Rules\n- one\n"},{"text":"no title here\n\n","id":{"name":"A*b_c`d","callThem":null,"addressNote":"line\none"},"once":"## Who you are\n\nYour name is **Abcd**. This app reads it from this line — change the\nname here and it changes in the sidebar, on the tab and in Settings.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\nAddress them like this: line one\n\n---\n\nno title here\n\n","again":"## Who you are\n\nYour name is **Zed**. This app reads it from this line — change the\nname here and it changes in the sidebar, on the tab and in Settings.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\n---\n\nno title here\n\n"}],"block":"## Who you are\n\nThey have not given you a name of their own, so you go by the one this app\ngives you: **Hoot**. Do not pick a different name for yourself; if\nthey give you one, it replaces this paragraph.\n\nThey have not told you what to call them. If the folder you work in says,\nfollow that; otherwise ask, rather than guessing a name out of what you\nfind in their files.\n\n---\n"}"####

private struct Case { let text: String; let id: CopilotIdentity; let once: String; let again: String }

private func cases() -> (cases: [Case], block: String) {
    let root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
    let out = (root["out"] as! [[String: Any]]).map { entry -> Case in
        let id = entry["id"] as! [String: Any]
        return Case(text: entry["text"] as! String,
                    id: CopilotIdentity(name: id["name"] as? String, callThem: id["callThem"] as? String, addressNote: id["addressNote"] as? String),
                    once: entry["once"] as! String, again: entry["again"] as! String)
    }
    return (out, root["block"] as! String)
}

@Test func identityBlockIsByteForByteTheWebOne() {
    let (all, block) = cases()
    #expect(CopilotIdentity.block(CopilotIdentity()) == block)
    for each in all {
        let once = CopilotIdentity.writing(each.id, into: each.text)
        #expect(once == each.once)
        #expect(CopilotIdentity.writing(CopilotIdentity(name: "Zed"), into: once) == each.again)
    }
}

@Test func identityWritingIsIdempotentAndReadsBack() {
    let identity = CopilotSetupRules.identity(name: " Nova ", callThem: "Asad", addressNote: "short answers")
    let once = CopilotIdentity.writing(identity, into: "# Hoot\n\nprose\n")
    #expect(CopilotIdentity.writing(identity, into: once) == once)
    let read = CopilotIdentity.read(once)
    #expect(read.ran)
    #expect(read.identity == identity)
    // All skipped is still a finished run.
    #expect(CopilotIdentity.read(CopilotIdentity.writing(CopilotIdentity(), into: "")).ran)
}

@Test func setupStepsAndButtons() {
    #expect(CopilotSetupStep.allCases.map(\.rawValue) == ["name", "you", "folder", "account"])
    #expect(CopilotSetupStep.name.previous == .name)
    #expect(CopilotSetupStep.account.next == .account)
    #expect(CopilotSetupStep.account.isLast)
    let nova = CopilotIdentity(name: "Nova")
    #expect(CopilotSetupWords.advanceLabel(.name, answered: false, identity: nova, running: false) == "Skip")
    #expect(CopilotSetupWords.advanceLabel(.you, answered: true, identity: nova, running: false) == "Continue")
    #expect(CopilotSetupWords.advanceLabel(.account, answered: false, identity: nova, running: false) == "Start Nova")
    #expect(CopilotSetupWords.advanceLabel(.account, answered: false, identity: CopilotIdentity(), running: false) == "Start Hoot")
    #expect(CopilotSetupWords.advanceLabel(.account, answered: true, identity: nova, running: true) == "Save")
    #expect(CopilotSetupWords.title() == "Set up Hoot")
}

@Test func setupAnswersAndAccounts() {
    let blank = CopilotSetupRules.identity(name: "  ", callThem: "", addressNote: "\n")
    #expect(blank == CopilotIdentity())
    #expect(!CopilotSetupRules.answered(.name, identity: blank, folder: nil, accountChosen: false))
    #expect(CopilotSetupRules.answered(.you, identity: CopilotIdentity(addressNote: "x"), folder: nil, accountChosen: false))
    #expect(CopilotSetupRules.answered(.account, identity: blank, folder: nil, accountChosen: true))
    #expect(CopilotSetupRules.identity(name: String(repeating: "a", count: 40), callThem: "", addressNote: "").name?.count == 32)

    let snapshot = CodingAIAccountsParse.snapshot(CodingAIJSON.parse(#"""
    {"profiles":[{"id":"system","name":"Claude Code","provider":"claude","system":true,"configDir":"","color":""},
                 {"id":"work","name":"Work","provider":"claude","system":false,"configDir":"","color":""},
                 {"id":"cx","name":"Codex","provider":"codex","system":false,"configDir":"","color":""}],
     "defaultId":null,"projectDefaults":{"/Users/me/hoot/":"work"}}
    """#))
    #expect(CopilotSetupRules.accounts(snapshot).map(\.id) == ["system", "work"])
    #expect(CopilotSetupRules.currentAccountId(snapshot, home: "/Users/me/hoot") == "work")
    #expect(CopilotSetupRules.currentAccountId(snapshot, home: "/elsewhere") == nil)
    let system = CopilotSetupRules.accounts(snapshot)[0]
    #expect(CopilotSetupRules.note(system, signIn: nil, currentId: nil) == "in use now")
    #expect(CopilotSetupRules.note(system, signIn: nil, currentId: "work") == "")
}

@Test func consentCountdownAndQueue() {
    #expect(CopilotConsentWords.secondsLeft(expiresAt: 10_500, now: 0) == 11)
    #expect(CopilotConsentWords.secondsLeft(expiresAt: 0, now: 5_000) == 0)
    #expect(CopilotConsentWords.timeout(0) == "Time is up — this is being refused.")
    #expect(CopilotConsentWords.timeout(42) == "Refused automatically in 42s if nothing is answered.")
    #expect(CopilotConsentWords.urgent(10) && !CopilotConsentWords.urgent(11))
    #expect(CopilotConsentWords.waiting(0) == nil)
    #expect(CopilotConsentWords.waiting(1) == "One more question is waiting behind this one.")
    #expect(CopilotConsentWords.waiting(3) == "3 more questions are waiting behind this one.")
    let request = try? JSONDecoder().decode(CopilotConsentRequest.self, from: Data(#"""
    {"id":"q1","heading":"Write a setting","asker":"Hoot is asking to do this. It will not happen unless you allow it.",
     "summary":"Turn on notifications","rows":[{"name":"key","value":"notify"},{"name":"value","value":"true"}],
     "tier":"alter","tool":"settings_write","expiresAt":120000,"waiting":2}
    """#.utf8))
    #expect(request?.rows.map(\.name) == ["key", "value"])
    #expect(request?.waiting == 2)
}

@Test func railRowHoverWords() {
    #expect(CopilotEntryWords.help(name: "Hoot", stage: nil, problem: nil, parked: false) == CopilotEntryWords.blurb)
    #expect(CopilotEntryWords.help(name: "Hoot", stage: .stopped, problem: nil, parked: false) == "Hoot — Not running. Open it to start it.")
    #expect(CopilotEntryWords.help(name: "Hoot", stage: .stopped, problem: "No Claude CLI.", parked: false) == "Hoot — No Claude CLI.")
    #expect(CopilotEntryWords.help(name: "Nova", stage: .ready, problem: nil, parked: true) == "Nova’s panel is folded in here — click to bring it back")
}
