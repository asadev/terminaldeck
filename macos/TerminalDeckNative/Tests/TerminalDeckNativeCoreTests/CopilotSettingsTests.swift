import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Settings → Hoot and Settings → Tools, native. Mirrors the pure half of
// CopilotSection.test.tsx (hasNeverStarted, logTrustLine, the bridge narrowing,
// routines, badges) and VoiceKeyRow's narrowing.

private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

private let stateText = #"""
{"status": "running", "sessionId": "s1", "startedAt": 1000,
 "paths": {"root": "/data/copilot", "instructions": "/l/instructions.md", "layer": {"dir": "/l", "yours": "/l/instructions.md"}},
 "folder": {"home": "/data/copilot", "isDefault": true},
 "records": {"kind": "seatbelt", "enforced": false, "paths": ["/r/routines", "/r/log"]},
 "profile": {"id": "p1"}, "instructions": "edited",
 "startupFiles": [{"path": "/w/CLAUDE.md", "owner": "folder", "exists": true, "purpose": "Instructions"}, {"nopath": 1}],
 "layerFiles": [{"path": "/l/tools.md", "owner": "app", "exists": true}]}
"""#

@Test func copilotStateReadsTheWireAndSurvivesJunk() throws {
    let state = try #require(CopilotState.from(json(stateText)))
    #expect(state.status == .running && state.instructions == .edited)
    #expect(state.profile?.name == "p1")
    #expect(state.records.paths.count == 2 && state.records.kind == "seatbelt")
    #expect(state.startupFiles.map(\.path) == ["/w/CLAUDE.md"])
    #expect(state.layerFiles.first?.owner == .app)
    #expect(state.paths.layerYours == "/l/instructions.md")
    #expect(CopilotState.from(json(#"{"status":"running"}"#)) == nil)
    #expect(CopilotState.from(json(#"{"status":"flying","paths":{"root":"/x"},"instructions":"odd"}"#))?.status == .stopped)
    #expect(CopilotState.from(json(#"{"paths":{"root":"/x"},"instructions":"odd"}"#))?.instructions == .missing)
    // A refusal it could not read is never invented.
    #expect(CopilotState.from(json(#"{"paths":{"root":"/x"}}"#))?.records == CopilotState.Records(kind: "none", enforced: false, reason: nil, paths: []))
}

@Test func copilotNeverStartedNeedsBothHalvesAbsent() throws {
    let missing = try #require(CopilotState.from(json(#"{"paths":{"root":"/x"},"instructions":"missing"}"#)))
    let written = try #require(CopilotState.from(json(#"{"paths":{"root":"/x"},"instructions":"current"}"#)))
    let noMemory = CopilotMemoryReport.from(json(#"{"dir":"/m","exists":false}"#))
    let memory = CopilotMemoryReport.from(json(#"{"dir":"/m","exists":true,"facts":[{"name":"a.md"},{"x":1}]}"#))
    #expect(CopilotState.neverStarted(missing, noMemory))
    #expect(CopilotState.neverStarted(missing, nil))
    #expect(!CopilotState.neverStarted(missing, memory))
    #expect(!CopilotState.neverStarted(written, noMemory))
    #expect(!CopilotState.neverStarted(nil, nil))
    #expect(memory?.facts.map(\.name) == ["a.md"])
    #expect(CopilotFilesWords.memoryBadge(memory) == "1 file")
    #expect(CopilotFilesWords.memoryBadge(noMemory) == "none yet")
    #expect(CopilotFilesWords.memoryBadge(nil) == "not read")
}

@Test func copilotLogTrustLineReassuresOnlyWhenOutside() throws {
    let outside = try #require(CopilotActionLog.from(json(#"{"file":"/log/a.jsonl","outsideCopilotFolder":true,"rows":[{"at":"2026-10-06T01:00:00Z","action":"tool","tool":"sessions.list","confirmed":true,"confirmedBy":"desktop","ms":12},{"action":"x"}]}"#)))
    #expect(CopilotWords.logTrustLine(outside) == "Checked just now: this file is outside every path Hoot can write to.")
    #expect(outside.rows.count == 1)
    #expect(CopilotLogWords.confirmLine(outside.rows[0]) == "you confirmed it (desktop) · 12 ms")
    let inside = try #require(CopilotActionLog.from(json(#"{"file":"/x","outsideCopilotFolder":false}"#)))
    #expect(CopilotWords.logTrustLine(inside).hasPrefix("This file is inside Hoot’s own folder"))
    #expect(CopilotActionLog.from(json(#"{"dir":"/x"}"#)) == nil)
    #expect(CopilotLogWords.badge(nil, loading: true) == "reading")
    #expect(CopilotLogWords.badge(outside, loading: false) == "1 record")
}

@Test func copilotActionRowsSayWhoConfirmed() {
    func row(_ fields: String) -> CopilotLoggedAction { CopilotActionLog.from(json(#"{"file":"f","rows":[{"at":"t","action":"a",\#(fields)}]}"#))!.rows[0] }
    #expect(CopilotLogWords.confirmLine(row("\"x\":1")) == "Terminal Deck wrote this row itself")
    #expect(CopilotLogWords.confirmLine(row(#""confirmed":false,"confirmationRequired":false"#)) == "no confirmation needed at this tier")
    #expect(CopilotLogWords.confirmLine(row(#""confirmed":false,"refusedReason":"no window""#)) == "not confirmed — no window")
}

@Test func copilotRecordsAreNamedAndCounted() throws {
    let state = try #require(CopilotState.from(json(stateText)))
    #expect(CopilotLogWords.recordsBadge(state.records) == "not proven")
    #expect(CopilotLogWords.recordsLine(state) == "The running process is NOT inside that refusal.")
    #expect(CopilotLogWords.refusedMore(state.records).hasSuffix("On this machine: /r/routines, /r/log."))
    #expect(CopilotLogWords.recordsBadge(nil) == "not enforced here")
}

@Test func copilotFilesSayWhatTheirStateIs() {
    #expect(CopilotFilesWords.instructions(.missing).badge == "not written yet")
    #expect(CopilotFilesWords.instructions(.superseded).quiet == false)
    #expect(CopilotFilesWords.instructions(.edited).badge == "your words")
    // Never the same word twice on one row.
    #expect(CopilotFilesWords.distinct([("yours", true), ("Yours", false), ("generated", true)]).map(\.text) == ["yours", "generated"])
    #expect(CopilotFilesWords.resetBecause(.current) == "It already matches this build.")
    #expect(CopilotFilesWords.resetBecause(.edited) == nil)
    #expect(CopilotFilesWords.savedLine(backup: "/b", running: true) == "Saved. What was there is at /b. Hoot is still running with the old text — restart it to apply this.")
    #expect(CopilotFilesWords.savedLine(backup: nil, running: false) == "Saved. It applies the next time Hoot starts.")
    #expect(CopilotFilesWords.scaffoldLine(CopilotScaffoldResult.from(json(#"{"created":["a","b"]}"#))) == "Created 2 files. Nothing was started.")
}

@Test func copilotReadsItsNameFromItsInstructions() {
    let text = "# Hoot\n\n## Who you are\n\nYour name is **Owl**.\nCall them **Asad**.\nAddress them like this: plainly\n---\nYour name is **Not this**.\n"
    let reading = CopilotIdentity.read(text)
    #expect(reading.ran)
    #expect(reading.identity.name == "Owl" && reading.identity.callThem == "Asad" && reading.identity.addressNote == "plainly")
    #expect(reading.identity.line == "It is called Owl. It calls you Asad.")
    #expect(CopilotIdentity.read("# nothing here").ran == false)
    #expect(CopilotIdentity().line == "It goes by Hoot, the name this app gives it. It has not been told what to call you.")
    #expect(CopilotIdentity.clean("  a\u{0007}*b*  ", 32) == "a b")
}

@Test func copilotRoutinesReadAndSayTheirState() throws {
    let routines = CopilotRoutine.list(json(#"""
    [{"id":"r1","name":"Nightly","state":"paused","consecutiveFailures":3,"reason":"Stopped after 3 failures in a row.","triggers":["every day at 02:00"],"folder":"/w","refusedCalls":[{"at":1,"tool":"settings.set","reason":"no human"}]},
     {"id":"r2","state":"disabled","enabled":false},
     {"id":"r3","state":"martian","problems":["Line 2: no trigger"]},
     {"name":"no id"}]
    """#))
    #expect(routines.map(\.id) == ["r1", "r2", "r3"])
    let paused = routines[0]
    #expect(CopilotRoutineWords.brokenOff(paused) && !CopilotRoutineWords.armed(paused))
    #expect(CopilotRoutineWords.brokenLine(paused, when: { _ in "02:00" }) == "Stopped after 3 failures in a row. It will not run again until you resume it.")
    #expect(CopilotRoutineWords.triggers(paused) == "every day at 02:00 — in /w")
    #expect(CopilotRoutineWords.refused(paused) == "1 call was refused during its runs — a decision is waiting for you rather than the routine being broken.")
    #expect(CopilotRoutineWords.lastRun(paused, when: { _ in "x" }) == "It has never run.")
    #expect(CopilotRoutineWords.switchBecause(routines[1])?.hasSuffix("the switch never writes to the file.") == true)
    #expect(routines[2].state == .unarmed && CopilotRoutineWords.state(routines[2].state) == "nothing is listening")
    #expect(CopilotRoutineText.from(json(#"{"ok":false}"#)) == .problems(["That routine could not be read."]))
    #expect(CopilotRoutineWrite.from(json(#"{"ok":true,"id":"r1"}"#)) == .saved(id: "r1"))
    #expect(CopilotRoutineWords.runLine(json(#"{"started":false,"reason":"Busy."}"#), name: "Nightly") == "Busy.")
}

@Test func copilotShowingDefaultsOnAsTheMainProcessReadsIt() {
    #expect(CopilotShowing.interactive(json("{}")))
    #expect(CopilotShowing.interactive(json(#"{"values":{"copilot.interactive":false}}"#)) == false)
    #expect(CopilotShowing.interactive(json(#"{"copilot.interactive":false}"#)) == false)
    #expect(CopilotShowing.interactive(json(#"{"values":{"copilot.interactive":"no"}}"#)))
    #expect(CopilotShowing.interactive(json(#"{"values":{"hoot.interactive":false}}"#)) == false)
    #expect(CopilotShowing.interactive(json(#"{"hoot.interactive":false}"#)) == false)
    #expect(CopilotShowing.interactive(json(#"{"hoot.interactive":true,"copilot.interactive":false}"#)))
    #expect(CopilotShowing.interactive(json(#"{"values":{"hoot.interactive":false,"copilot.interactive":true}}"#)) == false)
    #expect(CopilotShowing.interactive(json(#"{"hoot.interactive":null,"copilot.interactive":false}"#)))
}

@Test func voiceKeyReadsProvidersAndStatus() {
    let providers = VoiceProvider.list(json(#"[{"id":"groq","label":"Groq","model":"whisper-large-v3","keysUrl":"https://console.groq.com/keys"},{"id":"x"},3]"#))
    #expect(providers.map(\.id) == ["groq"])
    #expect(providers[0].optionLabel == "Groq · whisper-large-v3")
    #expect(providers[0].getKeyLabel == "Get a Groq key")
    #expect(VoiceStatus.from(.null) == VoiceStatus(provider: nil, hasKey: false, canStore: true, reason: nil))
    #expect(VoiceStatus.from(json(#"{"canStore":false,"reason":"No keychain."}"#)).canStore == false)
    #expect(VoiceWords.storedHelp(providers[0]) == "Connected to Groq, transcribing with whisper-large-v3. The microphone is in the chat box.")
    #expect(VoiceWords.storedHelp(nil) == "A key is stored. The microphone is in the chat box.")
    #expect(VoiceWords.saveHelp(key: "  ") == "Paste a key first.")
    let saved = VoiceWords.saveResult(json(#"{"ok":true,"message":"Saved."}"#))
    #expect(saved.ok && saved.text == "Saved.")
}
