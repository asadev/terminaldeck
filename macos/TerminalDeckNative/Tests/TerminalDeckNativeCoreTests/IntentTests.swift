import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): the pure half of the App Intents.

@Suite("Intents: phrases and parameters")
struct IntentPhraseTests {
    @Test func everyPhraseNamesTheApp() {
        for (intent, phrases) in IntentPhrases.byIntent {
            #expect(!phrases.isEmpty, "\(intent) has no phrase")
            for phrase in phrases {
                #expect(phrase.contains(IntentPhrases.applicationName), "\(intent): “\(phrase)” lacks the app name")
            }
        }
    }

    @Test func phrasesNameOnlyEntityParameters() {
        for (intent, phrases) in IntentPhrases.byIntent {
            for phrase in phrases {
                for token in IntentPhrases.tokens(in: phrase) where token != "applicationName" {
                    #expect(IntentPhrases.phraseParameters.contains(token), "\(intent): “\(phrase)” names \(token)")
                }
            }
        }
    }

    @Test func noPhraseBelongsToTwoIntents() {
        let all = IntentPhrases.byIntent.values.flatMap { $0 }.map { $0.lowercased() }
        #expect(Set(all).count == all.count)
    }

    @Test func intentsThatNeedAValueCanStillBeCalledWithoutOne() {
        // Siri asks for the project or goal when the phrase did not say it.
        for intent in ["StartSessionIntent", "GoalStatusIntent", "AskHootIntent", "AddTaskIntent"] {
            let phrases = IntentPhrases.byIntent[intent] ?? []
            #expect(phrases.contains { IntentPhrases.tokens(in: $0) == ["applicationName"] }, "\(intent)")
        }
    }

    @Test func tokensAreRead() {
        #expect(IntentPhrases.tokens(in: "Start a ${applicationName} session in ${project}") == ["applicationName", "project"])
        #expect(IntentPhrases.tokens(in: "no tokens") == [])
    }

    @Test func everyAgentIsOffered() {
        #expect(IntentAgent.allCases.map(\.providerId) == ["claude", "codex", "gemini", "shell"])
    }

    @Test func spokenAgentNamesMapToAgents() {
        #expect(IntentAgent.parse("Claude Code") == .claude)
        #expect(IntentAgent.parse("claude") == .claude)
        #expect(IntentAgent.parse("OpenAI") == .codex)
        #expect(IntentAgent.parse("Codex") == .codex)
        #expect(IntentAgent.parse("Gemini CLI") == .gemini)
        #expect(IntentAgent.parse("a plain shell") == .shell)
        #expect(IntentAgent.parse("zsh") == .shell)
        #expect(IntentAgent.parse("") == nil)
        #expect(IntentAgent.parse("something else") == nil)
        #expect(IntentAgent.fromProvider("gemini") == .gemini)
        #expect(IntentAgent.fromProvider("custom:mine") == nil)
        #expect(IntentAgent.fromProvider(nil) == nil)
    }
}

@Suite("Intents: projects")
struct IntentProjectTests {
    let projects = [
        IntentProject(path: "/Users/a/Projects/td-native-shell", name: "td-native-shell", lastOpenedAt: 3),
        IntentProject(path: "/Users/a/Projects/shop", name: "shop", lastOpenedAt: 5),
        IntentProject(path: "/Users/a/Projects/Café Menu", name: "Café Menu", lastOpenedAt: 1),
        IntentProject(path: "/Users/a/Projects/shop-admin", name: "shop-admin", lastOpenedAt: 4),
    ]

    @Test func spokenNamesFindFolders() {
        #expect(IntentProjects.match("td native shell", in: projects).first?.name == "td-native-shell")
        #expect(IntentProjects.match("TD-Native-Shell", in: projects).first?.name == "td-native-shell")
        #expect(IntentProjects.match("native shell", in: projects).first?.name == "td-native-shell")
        #expect(IntentProjects.match("cafe menu", in: projects).first?.name == "Café Menu")
    }

    @Test func exactBeatsPrefix() {
        #expect(IntentProjects.match("shop", in: projects).map(\.name) == ["shop", "shop-admin"])
    }

    @Test func nothingSaidListsAllAndNoMatchListsNone() {
        #expect(IntentProjects.match("  ", in: projects).count == 4)
        #expect(IntentProjects.match("zebra", in: projects).isEmpty)
    }

    @Test func projectListIsNamedLikeTheSidebar() {
        let raw: [Any] = [
            ["path": "/x/old", "lastOpenedAt": 1],
            ["path": "/x/new", "lastOpenedAt": 9],
            ["path": "/x/new", "lastOpenedAt": 2],
            ["path": "relative/path", "lastOpenedAt": 5],
            ["nope": true],
        ]
        let parsed = IntentProjects.parse(raw, headings: ["/x/new": "New Thing"])
        #expect(parsed.map(\.path) == ["/x/new", "/x/old"])
        #expect(parsed.map(\.name) == ["New Thing", "old"])
        #expect(IntentProjects.parse("not a list").isEmpty)
    }

    @Test func homeIsShortened() {
        #expect(IntentProjects.displayPath("/Users/a/code/x", home: "/Users/a") == "~/code/x")
        #expect(IntentProjects.displayPath("/Users/a", home: "/Users/a") == "~")
        #expect(IntentProjects.displayPath("/Users/ab/x", home: "/Users/a") == "/Users/ab/x")
    }

    @Test func headingsAreOnlyFolders() {
        let sidebar = SidebarState(groups: [], projects: [
            SidebarProject(id: "/x/a", title: "A", expanded: true, sessions: []),
            SidebarProject(id: "machine:1", title: "Office PC", expanded: true, sessions: []),
        ], selectedId: nil)
        #expect(IntentProjects.headings(from: sidebar) == ["/x/a": "A"])
    }
}

@Suite("Intents: asking Hoot")
struct IntentHootTests {
    @Test func theQuestionIsOneSafeLine() {
        #expect(IntentHoot.question("  what's\nbroken\r\nin the build?  ") == "what's broken in the build?")
        #expect(IntentHoot.question("rm\u{1B}[2J -rf\u{07}") == "rm [2J -rf")
        #expect(IntentHoot.question("a\u{2028}b") == "a b")
        #expect(IntentHoot.question(" \n\t ") == nil)
        #expect(IntentHoot.question(String(repeating: "x", count: 5000))?.count == IntentHoot.maxQuestion)
    }

    @Test func typedAsTextThenEnter() {
        #expect(IntentHoot.writes(for: "status?") == ["status?", "\r"])
        #expect(IntentHoot.writes(for: "ask @shop") == ["ask @shop ", "\r"])
    }

    @Test func copilotStateIsRead() {
        let state = IntentHoot.copilot(["status": "running", "sessionId": "s1", "paths": ["root": "/u/copilot"], "problem": NSNull()])
        #expect(state == IntentCopilot(status: "running", sessionId: "s1", folder: "/u/copilot", problem: nil))
        #expect(state?.isRunning == true)
        #expect(IntentHoot.copilot(["status": "stopped", "sessionId": "", "problem": "No Claude Code"])?.isRunning == false)
        #expect(IntentHoot.copilot(["nothing": 1]) == nil)
        // Pointed at a folder of its own: read where it actually runs.
        let moved = IntentHoot.copilot(["status": "running", "sessionId": "s1", "paths": ["root": "/u/copilot"],
                                        "folder": ["runningIn": "/u/work", "home": "/u/work"]])
        #expect(moved?.folder == "/u/work")
    }

    @Test func conversationLinesAreRead() {
        let raw: [String: Any] = ["found": true, "messages": [
            ["id": "1", "role": "you", "text": "hi"],
            ["id": "2", "role": "agent", "text": "  "],
            ["id": "3", "role": "tool", "text": "x"],
            ["id": "4", "role": "agent", "text": "hello"],
        ]]
        let read = IntentHoot.lines(raw)
        #expect(read.found)
        #expect(read.lines.map(\.id) == ["1", "4"])
        #expect(IntentHoot.lines(["found": false, "messages": []]).found == false)
    }

    @Test func statusPushesAreRead() {
        #expect(IntentHoot.statusEvent(["s1", "waiting"])! == ("s1", "waiting"))
        #expect(IntentHoot.statusEvent(["s1"]) == nil)
        #expect(IntentHoot.isTurnOver("waiting") && IntentHoot.isTurnOver("input") && !IntentHoot.isTurnOver("working"))
    }

    @Test func theAnswerIsWhatFollowsTheQuestion() {
        let before = [IntentChatLine(id: "a", role: .you, text: "old question"),
                      IntentChatLine(id: "b", role: .agent, text: "old answer")]
        let known = Set(before.map(\.id))
        let after = before + [
            IntentChatLine(id: "c", role: .you, text: "Is the build green? "),
            IntentChatLine(id: "d", role: .agent, text: "Checking."),
            IntentChatLine(id: "e", role: .agent, text: "Yes — all 212 tests pass."),
        ]
        let reply = IntentHoot.reply(to: "is the build green?", in: after, known: known)
        #expect(reply == IntentHootReply(asked: true, answer: ["Checking.", "Yes — all 212 tests pass."]))
        // Not in the conversation yet: nothing is taken from before it.
        #expect(IntentHoot.reply(to: "is the build green?", in: before, known: known) == IntentHootReply(asked: false, answer: []))
        // Asked, not answered yet.
        #expect(IntentHoot.reply(to: "is the build green?", in: Array(after.prefix(3)), known: known) == IntentHootReply(asked: true, answer: []))
    }

    @Test func spokenAnswerIsShortAndPlain() {
        let long = "## Result\n**Yes.** The build is green.\n```\nnpm test\n```\n- 212 tests passed\n- see [the log](https://x.y/z)\n"
            + String(repeating: "More detail here. ", count: 30)
        let answer = IntentHoot.answer(IntentHootReply(asked: true, answer: ["first", long]), assistant: "Hoot")
        #expect(answer.spoken.hasPrefix("Result. Yes. The build is green. 212 tests passed. see the log."))
        #expect(!answer.spoken.contains("npm test") && !answer.spoken.contains("**") && !answer.spoken.contains("https"))
        #expect(answer.spoken.count <= IntentSpeech.spokenLimit)
        #expect(answer.detail.count == 2)
        #expect(answer.detail[1].contains("npm test"))
    }

    @Test func aQuestionBackIsSaid() {
        let answer = IntentHoot.answer(IntentHootReply(asked: true, answer: ["May I run the tests?"]), assistant: "Hoot", askingYou: true)
        #expect(answer.spoken.hasSuffix("Hoot is waiting for your answer in Terminal Deck."))
    }

    @Test func codeOnlyAnswersAreNotReadAloud() {
        let answer = IntentHoot.answer(IntentHootReply(asked: true, answer: ["```\nls -la\n```"]), assistant: "Owl")
        #expect(answer.spoken.contains("Owl's conversation"))
    }

    @Test func lateAnswersAreDeferredToANotification() {
        #expect(IntentHoot.deferred(assistant: "Hoot", asked: true).spoken
                == "I asked Hoot. It's still working on it — I'll send you a notification with the answer.")
        #expect(IntentHoot.deferred(assistant: "Hoot", asked: false).spoken.hasPrefix("Hoot is starting up."))
        let note = IntentHoot.notification(IntentAnswer(spoken: "s", detail: ["**Done.**"]), assistant: "Hoot")
        #expect(note.title == "Hoot answered")
        #expect(note.body == "Done.")
    }
}

@Suite("Intents: speech")
struct IntentSpeechTests {
    @Test func shortensOnASentence() {
        let text = "First sentence here. Second one is a bit longer. Third goes past the limit for sure."
        #expect(IntentSpeech.shorten(text, limit: 55) == "First sentence here. Second one is a bit longer.")
    }

    @Test func shortensOnAWordWhenNoSentenceEnds() {
        let text = String(repeating: "word ", count: 100)
        let short = IntentSpeech.shorten(text, limit: 30)
        #expect(short.hasSuffix("…") && short.count <= 30 && !short.contains("  "))
    }

    @Test func shortTextIsLeftAlone() {
        #expect(IntentSpeech.shorten("  Fine.  ") == "Fine.")
    }

    @Test func listsAndCounts() {
        #expect(IntentSpeech.list([]) == "")
        #expect(IntentSpeech.list(["A"]) == "A")
        #expect(IntentSpeech.list(["A", "B"]) == "A and B")
        #expect(IntentSpeech.list(["A", "B", "C"]) == "A, B and C")
        #expect(IntentSpeech.list(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more")
        #expect(IntentSpeech.count(1, "task") == "1 task")
        #expect(IntentSpeech.count(2, "task") == "2 tasks")
    }

    @Test func engineErrorsBecomeSentences() {
        #expect(IntentSpeech.cleanError("Error invoking remote method 'tasks:state': Error: tasks: only the app’s own window may change task settings")
                == "only the app’s own window may change task settings")
        #expect(IntentProblem.refused("Error: The title is too long").sentence == "The title is too long.")
        #expect(IntentProblem.from(.notReady).sentence == "Terminal Deck is still starting. Try again in a moment.")
        #expect(IntentProblem.down("The engine exited with code 1 before it was ready.").sentence
                == "Terminal Deck isn't running. The engine exited with code 1 before it was ready.")
        #expect(IntentProblem.from(.http(500)).sentence == "Terminal Deck didn't answer (error 500).")
    }
}

@Suite("Intents: what needs me")
struct IntentNeedsTests {
    func sidebar(_ sessions: [SidebarItem], alerts: String? = nil, hootStatus: String? = nil) -> SidebarState {
        var top = [SidebarItem(id: "hoot", title: "Hoot", kind: .hoot, status: hootStatus)]
        if let alerts { top.append(SidebarItem(id: "alerts", title: "Alerts", kind: .panel, unread: true, subtitle: alerts)) }
        return SidebarState(groups: [SidebarGroup(id: "top", title: nil, items: top)],
                            projects: [SidebarProject(id: "/p/shop", title: "shop", expanded: true, sessions: sessions)],
                            selectedId: nil)
    }

    @Test func aSessionAskingComesFirst() {
        let needs = IntentNeeds.from(sidebar: sidebar([
            SidebarItem(id: "1", title: "Session 2", kind: .session, unread: true, status: "input"),
            SidebarItem(id: "2", title: "API", kind: .session, unread: true, status: "waiting"),
            SidebarItem(id: "3", title: "Quiet", kind: .session, status: "idle"),
            SidebarItem(id: "held:k", title: "Old one", kind: .session, status: "held"),
        ], alerts: "3 new"))
        #expect(needs.newAlerts == 3)
        #expect(needs.held == ["Old one"])
        let answer = needs.answer()
        #expect(answer.spoken == "Session 2 in shop is asking you something. API in shop has something new. Old one didn't reopen.")
        #expect(answer.detail == ["Waiting for your answer: Session 2 in shop", "Something new: API in shop",
                                  "Didn't reopen: Old one", "New alerts: 3"])
    }

    @Test func severalAskingAreCounted() {
        let answer = IntentNeeds.from(sidebar: sidebar([
            SidebarItem(id: "1", title: "A", kind: .session, status: "input"),
            SidebarItem(id: "2", title: "B", kind: .session, status: "input"),
        ], hootStatus: "input")).answer()
        #expect(answer.spoken.hasPrefix("3 sessions are waiting for your answer: Hoot, A in shop and B in shop."))
    }

    @Test func nothingNeedsYou() {
        var needs = IntentNeeds.from(sidebar: sidebar([SidebarItem(id: "1", title: "A", kind: .session, status: "working")]))
        needs.tasks = []
        #expect(needs.answer().spoken == "Nothing needs you right now.")
    }

    @Test func unknownIsNotNothing() {
        #expect(IntentNeeds(sessions: nil).answer().spoken == "I can't see Terminal Deck's sessions or tasks yet.")
        #expect(IntentNeeds(sessions: nil, tasks: []).answer().spoken == "No tasks need you. I can't see your sessions yet.")
    }

    @Test func stalledAndHandedTasksAreSaid() throws {
        let state: [String: Any] = ["tasks": [
            ["id": "t1", "title": "Fix login", "stalled": ["text": "It went quiet for 20 minutes."], "assignee": "builder"],
            ["id": "t2", "title": "Review copy", "assignee": "me", "handedFrom": "Writer"],
            ["id": "t3", "title": "Done one", "stalled": ["text": "x"], "completedAt": 12],
            ["id": "t4", "title": "Binned", "stalled": ["text": "x"], "deletedAt": 5],
        ], "goals": []]
        let tasks = try #require(IntentTasks.parse(state)).tasks
        let answer = IntentNeeds(sessions: [], tasks: tasks).answer()
        #expect(answer.spoken == "The task “Fix login” stalled. Writer handed you “Review copy”.")
        #expect(answer.detail == ["Stalled task: Fix login — It went quiet for 20 minutes.", "Handed to you by Writer: Review copy"])
    }
}

@Suite("Intents: tasks and goals")
struct IntentTaskTests {
    @Test func aNewTaskUsesTheTasksPageDefaults() throws {
        let payload = try IntentTasks.newTask(title: "  Ship\nit ", projectPath: nil).get()
        #expect(payload == ["title": "Ship it", "instructions": "", "project": "", "assignee": "none"])
        #expect(try IntentTasks.newTask(title: "x", projectPath: "/p/shop").get()["project"] == "/p/shop")
    }

    @Test func aNewTaskNeedsATitleAndAFullPath() {
        #expect(throws: IntentProblem.plain("The task needs a title.")) { try IntentTasks.newTask(title: "  ", projectPath: nil).get() }
        #expect(throws: IntentProblem.plain("shop isn't a full folder path.")) { try IntentTasks.newTask(title: "x", projectPath: "shop").get() }
    }

    @Test func theEnginesAnswerIsRead() {
        #expect(IntentTasks.refusal(["ok": true, "state": [:]]) == nil)
        #expect(IntentTasks.refusal(["ok": false, "message": "Tasks are not running on this computer right now."])?.sentence
                == "Tasks are not running on this computer right now.")
        #expect(IntentTasks.refusal("??") != nil)
        let answer: [String: Any] = ["ok": true, "state": ["tasks": [
            ["id": "old", "title": "Ship it", "createdAt": 1],
            ["id": "new", "title": "Ship it", "createdAt": 2],
            ["id": "other", "title": "Else", "createdAt": 3],
        ]]]
        #expect(IntentTasks.created(title: "Ship it", in: answer)?.id == "new")
        #expect(IntentTasks.added("Ship it", projectName: "shop").spoken == "Added “Ship it” to your tasks in shop.")
    }

    func goal(total: Int, done: Int, stalled: Int = 0, blocked: Int = 0, unverified: Int = 0, status: String = "active") -> IntentGoalSummary {
        IntentGoalSummary(id: "g", title: "Ship 0.18", status: status, project: nil, total: total, done: done,
                          verified: done - unverified, unverified: unverified, stalled: stalled, blocked: blocked)
    }

    @Test func goalProgressIsSaid() {
        #expect(IntentTasks.goalAnswer(goal(total: 0, done: 0), tasks: []).spoken == "Ship 0.18 has no tasks yet.")
        #expect(IntentTasks.goalAnswer(goal(total: 7, done: 3, stalled: 1, blocked: 2), tasks: []).spoken
                == "Ship 0.18: 3 of 7 tasks done. 1 stalled and 2 blocked.")
        #expect(IntentTasks.goalAnswer(goal(total: 2, done: 2, unverified: 1), tasks: []).spoken
                == "Ship 0.18: all 2 tasks done. 1 finished task not verified yet.")
        #expect(IntentTasks.goalAnswer(goal(total: 1, done: 0, status: "paused"), tasks: []).spoken == "Ship 0.18 (paused): 0 of 1 task done.")
    }

    @Test func goalDetailListsItsOpenTasks() throws {
        let state: [String: Any] = ["tasks": [
            ["id": "1", "title": "Build", "goalId": "g", "agent": "Builder"],
            ["id": "2", "title": "Test", "goalId": "g", "stalled": ["text": "quiet"]],
            ["id": "3", "title": "Done", "goalId": "g", "completedAt": 9],
            ["id": "4", "title": "Elsewhere", "goalId": "h"],
        ], "goals": [["id": "g", "title": "Ship 0.18", "status": "active",
                      "progress": ["total": 3, "done": 1, "verified": 1, "unverified": 0, "stalled": 1, "blocked": 0]]]]
        let parsed = try #require(IntentTasks.parse(state))
        let answer = IntentTasks.goalAnswer(try #require(parsed.goals.first), tasks: parsed.tasks)
        #expect(answer.detail == ["Ship 0.18: 1 of 3 tasks done.", "1 stalled.", "• Build — Builder", "• Test (stalled)"])
    }
}

@Suite("Intents: Siri's time")
struct IntentDeadlineTests {
    @Test func workInsideTheBudgetIsTheAnswer() async {
        let task = Task<Int, Never> { 42 }
        guard case .finished(let value) = await IntentDeadline.wait(for: task, upTo: .seconds(5)) else {
            Issue.record("expected the value"); return
        }
        #expect(value == 42)
    }

    @Test func lateWorkTimesOutAndCarriesOn() async {
        let task = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(300))
            return "late answer"
        }
        let started = ContinuousClock().now
        let outcome = await IntentDeadline.wait(for: task, upTo: .milliseconds(30))
        guard case .timedOut = outcome else { Issue.record("expected a time-out"); return }
        #expect(ContinuousClock().now - started < .milliseconds(250))
        // Not cancelled for being slow: the answer still arrives (for the notification).
        #expect(await task.value == "late answer")
        #expect(!task.isCancelled)
    }

    @Test func untilStopsWhenTrueOrAtTheLimit() async {
        let flag = Flag()
        Task { try? await Task.sleep(for: .milliseconds(50)); await flag.set() }
        #expect(await IntentDeadline.until(.seconds(2), every: .milliseconds(10)) { await flag.value })
        #expect(!(await IntentDeadline.until(.milliseconds(40), every: .milliseconds(10)) { false }))
    }

    @Test func aBudgetIsShared() async {
        let budget = IntentBudget(.milliseconds(200))
        #expect(budget.remaining(cap: .milliseconds(50)) == .milliseconds(50))
        #expect(budget.remaining() <= .milliseconds(200))
        try? await Task.sleep(for: .milliseconds(220))
        #expect(budget.isSpent)
        #expect(budget.remaining(cap: .seconds(1)) == .zero)
    }
}

private actor Flag {
    var value = false
    func set() { value = true }
}
