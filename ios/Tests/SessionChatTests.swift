/**
 * The conversation: who owns the bar, and what a bubble is made of.
 *
 * ## The defect these were written for
 *
 * > *"Make sure chat mode is properly working. Most of the time when we switch
 * > between chat mode and terminal — when we switch in terminal we can see the
 * > whole chat; when we switch on chat mode we don't see the chat. So this
 * > happens a lot, on all the versions."*
 *
 * The terminal full, the conversation empty, on every build. The cause is not in
 * the wire and not on the desktop: it is that `SessionBarLink` holds **one**
 * session per machine while **two** `TerminalScreen`s can be alive at once — the
 * Sessions stack's and the Copilot stack's — and the leaving screen's
 * `onDisappear` used to wipe it unconditionally.
 *
 * The lifecycle order was measured on the Simulator rather than assumed, against
 * a harness with this app's exact shape (a `TabView` of two `NavigationStack`s
 * with a screen pushed on each):
 *
 *     appear:leftRoot → push → appear:left-1 → tab to right → appear:rightRoot
 *     → push → appear:right-9 → tab back to left → *nothing at all*
 *     → pop → disappear:left-1
 *
 * Two facts fall out of that trace and both are load bearing. A tab swap fires
 * the **arriving** screen's `onAppear` and never the leaving screen's
 * `onDisappear`; and coming back to a tab fires nothing at all, so a screen that
 * is being looked at again has no callback in which to claim anything. So the
 * sequence that empties the chat is:
 *
 *  1. Sessions tab, session `s1`. `bar.follow("s1")`.
 *  2. Copilot tab, which has `s2` pushed on it. Its `onAppear` runs
 *     `bar.follow("s2")` → `forget()` → the bar is on `s2`.
 *  3. Back to the Sessions tab. **No callback fires.** The bar is still on `s2`.
 *  4. The toggle is pressed on the Sessions screen. `askChat` asks about the
 *     wrong session — or, once the leaving screen's `forget()` has landed, about
 *     no session at all, returning at its `guard let sessionID` so that no frame
 *     ever leaves. Pressing it again does the same nothing.
 *
 * `release(_:)`, `follow`'s re-read and `TerminalScreen.reclaimBar` are the fix;
 * the first four cases below are that sequence, and `testABareForgetIsTheDefect`
 * is the old behaviour kept as a test so the fix cannot be undone by reverting
 * one call site.
 *
 * ## And what a bubble is made of
 *
 * The rest is `ChatDocument`, which is the whole of the second half of the same
 * review — *"this copilot should be able to show the structural data"*. Those
 * cases are mostly about what it must **not** find: a URL is not a path, a glob
 * is not a path, and `+++ b/src/x.ts` names a file in git's spelling rather than
 * the filesystem's.
 */

import XCTest
@testable import TerminalDeck

final class SessionChatTests: XCTestCase {

    /// The wire, recorded. A local copy rather than a shared one because
    /// `SessionBarTests` keeps its own and two suites sharing a fake is two
    /// suites that have to agree about what it does next.
    @MainActor
    private final class RecordingWire: CopilotWire {
        var sent: [ClientMessage] = []
        var accepting = true
        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            guard accepting else { return false }
            sent.append(message)
            return true
        }
    }

    @MainActor
    private func barWithAConversation(_ wire: RecordingWire, session: String) -> SessionBarLink {
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.chat])
        bar.follow(session)
        bar.chatting = true
        bar.askChat(tail: false)
        guard case let .chatRead(rid, _, _) = wire.sent.last else {
            XCTFail("expected a chat.read")
            return bar
        }
        _ = bar.receive(.chatRows(rid: rid, id: session,
                                  rows: [CopilotChatMessage(id: "m1", role: .agent,
                                                            text: "done", at: 1, truncated: false)],
                                  reset: true, found: true))
        return bar
    }

    // MARK: - 1. Who owns the bar

    /**
     * Step 3 of the trace, and the reported symptom in one assertion.
     *
     * The Copilot stack's screen has claimed the bar for `s2`; the Sessions
     * stack's screen then goes away and says so. Its `onDisappear` must not take
     * `s2` with it — the screen that is actually in front of somebody is the one
     * holding it.
     */
    @MainActor
    func testALeavingScreenDoesNotWipeABarAnotherScreenHasClaimed() {
        let wire = RecordingWire()
        let bar = barWithAConversation(wire, session: "s1")
        // The other tab's terminal appears and claims the bar.
        bar.follow("s2")
        bar.chatting = true

        // Now the first screen leaves, late, the way a `TabView` fires it.
        bar.release("s1")

        XCTAssertEqual(bar.sessionID, "s2", "the screen in front keeps the bar")
        XCTAssertTrue(bar.chatting, "and keeps reading the conversation")
    }

    /// And the ask that follows still reaches the wire, which is the half the
    /// person sees: a `chat.read` that never leaves is an empty screen no number
    /// of presses recovers.
    @MainActor
    func testTheToggleStillAsksAfterAnotherScreensRelease() {
        let wire = RecordingWire()
        let bar = barWithAConversation(wire, session: "s1")
        bar.follow("s2")
        bar.chatting = true
        bar.release("s1")

        wire.sent.removeAll()
        bar.askChat(tail: false)
        guard case let .chatRead(_, id, tail) = wire.sent.last else {
            return XCTFail("the frame must leave — this is the empty chat")
        }
        XCTAssertEqual(id, "s2")
        XCTAssertFalse(tail, "opening the conversation asks for the whole of it")
    }

    /**
     * The old behaviour, kept as a test.
     *
     * `forget()` is still the right thing when the bar really is this screen's,
     * and this pins what it costs when it is not: no session id, therefore no
     * frame, therefore an empty conversation that pressing the toggle cannot
     * fix. If someone puts a bare `forget()` back into `onDisappear`, the case
     * above goes red and this one explains why.
     */
    @MainActor
    func testABareForgetIsTheDefect() {
        let wire = RecordingWire()
        let bar = barWithAConversation(wire, session: "s1")
        bar.forget()
        wire.sent.removeAll()
        bar.askChat(tail: false)
        XCTAssertTrue(wire.sent.isEmpty, "with no session on the bar, nothing is asked")
        XCTAssertTrue(bar.chat.isEmpty)
    }

    /// A screen leaving while it *is* the one on the bar still tears everything
    /// down. The narrowing is about ownership, not about holding on.
    @MainActor
    func testTheScreenThatOwnsTheBarStillReleasesIt() {
        let wire = RecordingWire()
        let bar = barWithAConversation(wire, session: "s1")
        bar.release("s1")
        XCTAssertNil(bar.sessionID)
        XCTAssertTrue(bar.chat.isEmpty)
        XCTAssertFalse(bar.chatting)
    }

    // MARK: - 2. A conversation that was asked for is asked for again

    /**
     * The socket died between the question and the answer.
     *
     * `dropped()` throws the pending requests away so a late answer cannot land
     * against a request id minted on a dead connection — correct, and it leaves
     * the conversation with nothing coming. Nothing else would ever ask: the
     * tail read rides `output`, and a session somebody wants to *read* is by
     * definition one that has stopped printing. So the re-follow on reconnect
     * has to carry it.
     */
    @MainActor
    func testAReconnectAsksForTheConversationAgainWhileItIsOnScreen() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.chat])
        bar.follow("s1")
        bar.chatting = true
        bar.askChat(tail: false)
        bar.dropped()

        wire.sent.removeAll()
        bar.follow("s1")
        let asked = wire.sent.contains { if case .chatRead = $0 { return true }; return false }
        XCTAssertTrue(asked, "a reconnect re-asks for what the screen is showing")
    }

    /// And does not, when the conversation is not what is on screen. A terminal
    /// somebody is typing into must not read a transcript across a relay on
    /// every reconnect.
    @MainActor
    func testAReconnectDoesNotAskForAConversationNobodyIsReading() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.chat])
        bar.follow("s1")
        bar.dropped()

        wire.sent.removeAll()
        bar.follow("s1")
        let asked = wire.sent.contains { if case .chatRead = $0 { return true }; return false }
        XCTAssertFalse(asked)
    }

    /// Leaving chat mode stops the reading. The tail task goes with it, so a
    /// debounce already waiting cannot spend a round trip on a transcript that
    /// is no longer on screen.
    @MainActor
    func testStopChattingEndsTheReading() {
        let wire = RecordingWire()
        let bar = barWithAConversation(wire, session: "s1")
        bar.stopChatting()
        XCTAssertFalse(bar.chatting)
        XCTAssertEqual(bar.chat.count, 1, "the bubbles stay — leaving the view does not unsay them")
    }

    // MARK: - 3. What the conversation admits about itself

    /// A whole-conversation answer at the wire's own cap is the **end** of a
    /// longer file. Said once, at the top, because nothing on the frame names
    /// what was dropped and there is no verb to page backwards with.
    @MainActor
    func testAFullReadAtTheCapSaysTheTopIsMissing() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.chat])
        bar.follow("s1")
        bar.askChat(tail: false)
        guard case let .chatRead(rid, _, _) = wire.sent.last else { return XCTFail("expected a chat.read") }

        let rows = (0 ..< Copilot.maxChatRows).map {
            CopilotChatMessage(id: "m\($0)", role: .agent, text: "x", at: 0, truncated: false)
        }
        _ = bar.receive(.chatRows(rid: rid, id: "s1", rows: rows, reset: true, found: true))
        XCTAssertTrue(bar.atCap)
    }

    /// A *tail* read carrying that many rows is that many things that happened,
    /// not the front of the file being dropped.
    @MainActor
    func testATailAtTheCapIsNotATruncatedConversation() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.chat])
        bar.follow("s1")
        bar.askChat(tail: true)
        guard case let .chatRead(rid, _, _) = wire.sent.last else { return XCTFail("expected a chat.read") }

        let rows = (0 ..< Copilot.maxChatRows).map {
            CopilotChatMessage(id: "m\($0)", role: .agent, text: "x", at: 0, truncated: false)
        }
        _ = bar.receive(.chatRows(rid: rid, id: "s1", rows: rows, reset: false, found: true))
        XCTAssertFalse(bar.atCap)
    }
}

// MARK: - What a bubble is made of

final class ChatDocumentTests: XCTestCase {

    private func kinds(_ document: ChatDocument) -> [String] {
        document.blocks.map { block in
            switch block {
            case .prose: return "prose"
            case .code: return "code"
            case .diff: return "diff"
            }
        }
    }

    func testAFencedBlockIsCodeAndKeepsItsLanguage() {
        let document = ChatDocument.parse("""
        Here is the fix.

        ```swift
        let x = 1
        ```

        That is all.
        """)
        XCTAssertEqual(kinds(document), ["prose", "code", "prose"])
        guard case let .code(_, language, text) = document.blocks[1] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(text, "let x = 1")
    }

    /// An answer being streamed is an unclosed fence for as long as it takes to
    /// write the block. Drawing it as prose until the last line lands would make
    /// every long code answer reflow once, at the end.
    func testAnUnclosedFenceIsStillCode() {
        let document = ChatDocument.parse("Writing it now.\n\n```ts\nconst a = 1\nconst b = 2")
        XCTAssertEqual(kinds(document), ["prose", "code"])
        guard case let .code(_, _, text) = document.blocks[1] else { return XCTFail("expected code") }
        XCTAssertEqual(text, "const a = 1\nconst b = 2")
    }

    /// A longer fence contains a shorter one, which is how a markdown answer
    /// quotes a code fence.
    func testALongerFenceSwallowsAShorterOne() {
        let document = ChatDocument.parse("````md\n```\ninner\n```\n````")
        XCTAssertEqual(kinds(document), ["code"])
        guard case let .code(_, language, text) = document.blocks[0] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "md")
        XCTAssertEqual(text, "```\ninner\n```")
    }

    func testADiffTaggedFenceIsAPatch() {
        let document = ChatDocument.parse("```diff\n@@ -1 +1 @@\n-old\n+new\n```")
        XCTAssertEqual(kinds(document), ["diff"])
    }

    /// Agents tag a patch about half the time. The markers are unambiguous when
    /// they do not.
    func testAnUntaggedFenceThatIsAPatchIsAPatch() {
        let document = ChatDocument.parse("```\ndiff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-a\n+b\n```")
        XCTAssertEqual(kinds(document), ["diff"])
    }

    /// A patch pasted with no fence at all, which is what `git diff` output
    /// looks like in a turn. The sentence above it stays prose — drawing a
    /// paragraph in red and green bands is the failure mode this splits for.
    func testALoosePatchIsSplitFromTheSentenceAboveIt() {
        let document = ChatDocument.parse("""
        I changed one line:

        diff --git a/src/x.ts b/src/x.ts
        @@ -1,2 +1,2 @@
        -const a = 1
        +const a = 2
        """)
        XCTAssertEqual(kinds(document), ["prose", "diff"])
        guard case let .prose(_, text) = document.blocks[0] else { return XCTFail("expected prose") }
        XCTAssertEqual(text, "I changed one line:")
    }

    /**
     * And the sentence an agent writes *underneath* a patch stays prose.
     *
     * Found by looking at it rather than by reading it: the first version took
     * the patch to be everything after its first line, so "I also touched x."
     * was drawn inside the monospaced band in diff grey at 12 points.
     * Photographed on the Simulator, which is the only reason it was caught —
     * every parser test passed.
     */
    func testTheSentenceUnderAPatchIsNotPartOfIt() {
        let document = ChatDocument.parse("""
        Here is the patch:

        diff --git a/src/x.ts b/src/x.ts
        @@ -1,2 +1,2 @@
        -const a = 1
        +const a = 2

        I also touched `ios/App/Theme.swift`.
        """)
        XCTAssertEqual(kinds(document), ["prose", "diff", "prose"])
        guard case let .prose(_, tail) = document.blocks[2] else { return XCTFail("expected prose") }
        XCTAssertEqual(tail, "I also touched `ios/App/Theme.swift`.")
        guard case let .diff(_, patch) = document.blocks[1] else { return XCTFail("expected a patch") }
        XCTAssertFalse(patch.contains("I also touched"))
    }

    /// A blank line inside a hunk is a context line some tools strip the leading
    /// space from. It stays in the patch, because the line after it does.
    func testABlankLineInsideAHunkStaysInThePatch() {
        let document = ChatDocument.parse("""
        diff --git a/x b/x
        @@ -1,3 +1,3 @@
        -a

        +b
        """)
        XCTAssertEqual(kinds(document), ["diff"])
    }

    /// `@@` in a sentence about decorators, and a `---` that is a horizontal
    /// rule. Both were the reason the patch test needs three markers.
    func testProseThatMerelyLooksLikeAPatchIsProse() {
        XCTAssertEqual(kinds(ChatDocument.parse("Use @@ for the hunk header.")), ["prose"])
        XCTAssertEqual(kinds(ChatDocument.parse("One thing\n\n---\n\n+ another")), ["prose"])
    }

    // MARK: - Paths

    func testPathsComeOutOfInlineSpansAndAreMadeAbsolute() {
        let text = "I edited `src/main/index.ts` and `/etc/hosts`."
        XCTAssertEqual(ChatDocument.paths(in: text, cwd: "/Users/a/p"),
                       ["/Users/a/p/src/main/index.ts", "/etc/hosts"])
    }

    /// No folder means no way to resolve a relative path, and a chip that
    /// resolved to nothing would open onto a refusal. The absolute one still
    /// stands.
    func testWithoutAFolderOnlyAbsolutePathsSurvive() {
        let text = "See `src/main/index.ts` and `/etc/hosts`."
        XCTAssertEqual(ChatDocument.paths(in: text, cwd: nil), ["/etc/hosts"])
    }

    func testThingsThatAreNotPaths() {
        for token in ["https://example.com/x.ts",   // a URL belongs to a browser
                      "src/**/*.ts",                 // a glob names no single file
                      "@scope/package",              // a package name has a slash in it
                      "a/src/x.ts",                  // git's spelling of the old side
                      "b/src/x.ts",                  // and of the new one
                      "src/main/",                   // a folder
                      "-o/dev/null",                 // a flag with a slash in its argument
                      "and/or"] {                    // a sentence with a slash in it
            XCTAssertFalse(ChatDocument.isPath(token), "\(token) is not a file path")
        }
    }

    func testThingsThatArePaths() {
        for token in ["src/main/index.ts", "/etc/hosts", "./scripts/run.sh",
                      "ios/TerminalDeck/App/Theme.swift", "src/Makefile", "app/.env"] {
            XCTAssertTrue(ChatDocument.isPath(token), "\(token) is a file path")
        }
    }

    /// The extensionless list is names, not a shape. A token with no dot that is
    /// not on it stays out — `src/main` is a folder far more often than a file,
    /// and a chip on every folder anybody mentions is a chip that means nothing.
    func testAnExtensionlessNameThatIsNotOnTheListIsNotAPath() {
        XCTAssertFalse(ChatDocument.isPath("src/main"))
        XCTAssertFalse(ChatDocument.isPath("/Users/a/Projects"))
    }

    /// A refactor that touched forty files is a real turn and forty chips is a
    /// wall. The conversation itself is where the whole list is read.
    func testTheChipsAreCapped() {
        let text = (0 ..< 40).map { "`/tmp/f\($0).ts`" }.joined(separator: " ")
        XCTAssertEqual(ChatDocument.paths(in: text, cwd: nil).count, ChatDocument.maxPaths)
    }

    func testTheSamePathTwiceIsOneChip() {
        let text = "`/tmp/a.ts` then `/tmp/a.ts` again"
        XCTAssertEqual(ChatDocument.paths(in: text, cwd: nil), ["/tmp/a.ts"])
    }

    /// A path resolved out of the folder it was written against is a path to
    /// somewhere else. Dropped rather than normalised, because `..` past the
    /// session's own folder is not something a chip should reach.
    func testAPathThatClimbsOutOfTheFolderIsDropped() {
        XCTAssertNil(ChatDocument.absolute("../secrets.env", cwd: "/Users/a/p"))
        XCTAssertNil(ChatDocument.absolute("~/.ssh/id_rsa", cwd: "/Users/a/p"))
        XCTAssertEqual(ChatDocument.absolute("./src/x.ts", cwd: "/Users/a/p"), "/Users/a/p/src/x.ts")
    }

    // MARK: - Time and glyphs

    func testAnUndatedBubbleGetsNoTime() {
        XCTAssertEqual(SessionChatView.time(0), "")
        XCTAssertEqual(SessionChatView.time(.nan), "")
        XCTAssertFalse(SessionChatView.time(1_700_000_000_000).isEmpty)
    }

    /// A staged file that is not an image gets its own kind in the square the
    /// picture would have been, never an empty frame.
    func testAStagedFileGetsAGlyphForItsKind() {
        XCTAssertEqual(SessionChatView.glyph(for: "clip.mov"), "film")
        XCTAssertEqual(SessionChatView.glyph(for: "notes.pdf"), "doc.richtext")
        XCTAssertEqual(SessionChatView.glyph(for: "logs.tar"), "doc.zipper")
        XCTAssertEqual(SessionChatView.glyph(for: "anything.else"), "doc")
    }
}
