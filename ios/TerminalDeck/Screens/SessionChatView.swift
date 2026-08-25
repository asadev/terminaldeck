/**
 * The session, as a conversation, on the phone — and somewhere to answer it.
 *
 * The specification is one sentence of his, followed literally:
 *
 *   > *"my message should start from the right, should be on the other side like
 *   > this one, just like Claude… The left side will be the agent… here we don't
 *   > see any name, agent or whatever. So no need to give a name actually on
 *   > both sides. Not even you, for me also not you. Just start it from the
 *   > right side, give the time and all that. Just the text only and time only
 *   > will be good enough. And give the copy button wherever it's possible."*
 *
 * Right, left, time, copy, no names. Nothing else is on this screen: no role
 * label, no "thinking", no date separator. An empty conversation used to be
 * drawn as an empty screen and is not any more — see *"Nothing to read, and
 * why"* below, which is the one thing this screen says that nobody said.
 *
 * ## What a bubble is made of
 *
 * > *"if we are on chat mode, this copilot should be able to show the structural
 * > data and whatever it needs to show and things."*
 *
 * An agent's turn is not flat text, and drawing it as one paragraph makes a
 * patch and a shell transcript unreadable at 15 points. `ChatDocument` splits
 * each bubble into prose, fenced code and unified patches, and pulls the file
 * paths out of it; this file draws those. A code block is monospaced, scrolls
 * sideways rather than wrapping, and takes the **terminal scheme's** paper and
 * ink rather than the app palette's — the same colours the same text has in the
 * other half of this screen, so switching modes is a change of layout and not a
 * change of theme.
 *
 * ## What it deliberately does not draw, and why
 *
 * **Tool calls, tool results and attachments are not on this wire.** They are
 * not missing from the phone, they are removed by the desktop before the frame
 * is built: `src/main/chat-transcript.ts` keeps `type: 'text'` blocks and drops
 * every other kind, and refuses any `user` line carrying a `tool_result`. Its
 * header is explicit — *"This module throws all of that away and keeps the
 * prose, because the chat view exists precisely to hide it."*
 *
 * So there is no fold to open here and no image to preview: `files.read`, the
 * one verb that brings a file's contents to this phone, answers `binary: true`
 * with **no bytes at all** for anything that is not UTF-8 text (`server.ts`,
 * `readFileFor`). A picture of a file this app cannot fetch would be a drawing
 * of a file, so instead a path is a chip that opens the machine's real reader,
 * which says what the file is and how big it is when it is not text. That chip
 * is where the fact is stated on screen; everything else on this view is the
 * conversation.
 *
 * There used to be an `i` beside the mode button saying the same thing in words.
 * It is gone — *"why do we have this i button, it is completely extra, the
 * information button, remove this"* — and the chip is the better statement
 * anyway: it is on the file it is about rather than on the whole screen.
 *
 * ## The composer, which the browser client still does not have
 *
 * Reading without being able to answer means going back to the terminal to type
 * one line, which is the whole reason to be in this view undone. The message is
 * written into the session's own pty, because that IS where the agent is
 * listening — chat mode is a different view of one session, not a second
 * channel — so an answer typed here appears in the terminal view too and there
 * is no second transport to keep in step.
 *
 * **It cannot be one write.** The CLI classifies each stdin chunk before it
 * looks at the keys in it, and a chunk of 64 bytes or more is *pasted text*,
 * where a carriage return is a newline rather than submit. Measured boundary:
 * 57 bytes in one write submits, 64 does not. So the return travels as its own
 * write after a gap — `HostLink.sendChatMessage`, which is the one place that
 * sequence exists on this client.
 *
 * ## When the far side is not ready for prose
 *
 * > *"here it is showing previous replies. But if I turn it to terminal mode,
 * > it will show the actual state because I need to log in. But it should
 * > actually show the same situation here or some message like that… now if I
 * > send it, nothing will happen because the terminal is not ready for it. So
 * > it should be clearly stating something or saying something here to log in
 * > or stuff… in chat mode I don't know anything. First of all, this is the
 * > biggest problem."*
 *
 * Because a message goes into the session's own pty, what the pty is doing
 * decides whether it lands. At a login menu it does not: the keys are being read
 * one at a time by whatever dialog is on screen, the field clears, and the
 * conversation carries on showing an afternoon-old transcript. The terminal half
 * of this same screen was showing the login the whole time.
 *
 * So this view reads the one fact that half already draws — `RemoteSession.status`,
 * classified on the machine by `session-activity.ts` — and where it says a
 * sentence would go nowhere, says so where the newest thing is and greys the
 * arrow. `Unready` is the whole of the rule, including which of the six words
 * count and why the other four are left alone. Nothing is added to a session
 * that has a conversation and a working prompt: no badge, no banner, no empty
 * row.
 *
 * **The way through is named rather than repeated.** Switching modes is
 * `chatMode`, which belongs to `TerminalScreen`, and its toggle — `terminal.mode`
 * — is in this screen's own navigation bar for as long as the conversation is on
 * it. A button in the notice would be a second control for a press that is
 * already one tap away and already on screen, so the sentence names that toggle
 * instead of growing another one.
 *
 * ## Nothing to read, and why
 *
 * > *"if we have this chat box, and now I'm turning it to terminal mode. So
 * > what about this thing? Because you said all of that is fixed, but this one
 * > is still there. So if I turn it to chat, it feels normal. When I turn it to
 * > this, it delivers the actual message. **So reality should be on both side,
 * > one thing.**"*
 *
 * The round above keyed that notice on `input` and `exited` and argued its way
 * out of `idle` on the grounds that the classifier's fall-through is not a
 * state worth a sentence. He then filmed a session whose status was `idle`,
 * whose terminal was full of a live agent conversation, and whose chat was
 * **completely empty with a live composer**. The argument was right about what
 * `idle` means and wrong about what this screen owed him: the lie was never the
 * missing word for `idle`, it was the blank page under it.
 *
 * So there are two notices, answering two different questions. `Unready` answers
 * *would a sentence typed here land* — status, unchanged, and it is what greys
 * the arrow. `Silence` answers *why is there no conversation on this screen*,
 * and it is drawn whenever there is none, whatever the status. `idle` with
 * nothing to read is spoken for by the second rather than by a guess bolted
 * onto the first.
 *
 * **Five reasons, and they are not interchangeable.** An empty conversation
 * means exactly one of: this machine never serves one, so nothing was ever
 * asked (`chat` absent from the welcome — `SessionBarLink.askChat` returns at
 * its guard); the bar is following another session, so what is held is not this
 * one's; the machine has not answered yet; it answered and found no transcript
 * for the folder at all (`chat-serve.ts`, `pathFor` → `null` → `found: false`);
 * or it found one and there is no prose in it, which is a real outcome because
 * `chat-transcript.ts` keeps `type: 'text'` and drops every tool call, so a
 * busy transcript can collapse to nothing. The screen said the same nothing for
 * all five. Each says which it is now, and the three that are not about to
 * resolve on their own name the terminal, because that is the half holding the
 * truth — *"reality should be on both side, one thing."*
 *
 * **What none of them says is what the terminal is showing.** This view cannot
 * see the emulator, and `idle` is the machine saying it could not recognise the
 * screen either, so a notice claiming a login, a prompt or a running command
 * would be this app inventing the fact it is here to stop inventing. The
 * sentence stops at *there is nothing here, the terminal has it*.
 *
 * ## The conversation is only drawn when the bar is pointed at this session
 *
 * `bar` holds one session per machine and two `TerminalScreen`s can be alive at
 * once, so `bar.sessionID` and this view's `sessionID` are two different facts.
 * They disagree for the frame after the other tab's terminal claimed the bar,
 * and drawing through that gap would put one session's conversation under
 * another session's title. `reload` is what closes it — see
 * `TerminalScreen.reclaimBar`, and `SessionBarLink.release` for the trace of the
 * defect that made this necessary.
 */

import SwiftUI
import UIKit

/// Which out-of-process picker a press on the paperclip asks for. The two the
/// terminal already offers; see `FilePickers.swift`.
enum ChatAttachSource {
    case photos
    case files
}

/// A file chosen on the phone and not yet sent, with the two things that can be
/// done to it. `send` is nil while another transfer is running, because the
/// machine takes one at a time and a second press would be refused.
struct ChatAttachment {
    let file: PickedFile
    let send: (() -> Void)?
    let discard: () -> Void
}

struct SessionChatView: View {
    let bar: SessionBarLink
    /// The session this screen is drawing. See the header: not the same fact as
    /// `bar.sessionID`, and the conversation is drawn only while they agree.
    let sessionID: String
    /// The folder the session runs in, which is what the agent's relative paths
    /// are relative to. Nil until the machine has described the session, and
    /// then a relative path simply gets no chip.
    let cwd: String?
    /**
     * What the far session's terminal is doing, in the machine's own word for it
     * — the same string `TerminalScreen`'s header draws beside the status dot,
     * and the same one the session list colours a row by.
     *
     * A fact about `sessionID` rather than about the bar, so it is read whether
     * or not the bar is pointed here; see `Unready`, which is the only thing that
     * reads it. Nil while nothing has been said about this session yet, and an
     * unknown state draws nothing rather than a guess about somebody's terminal.
     */
    var status: String?
    /// Point the machine's bar back at this session and ask for the conversation
    /// again. Called on appear, and whenever the bar is found following somebody
    /// else.
    let reload: () -> Void
    /// Open one of the machine's files. Nil when this device may not read them —
    /// `files` is owner-device only — and then a path is drawn as plain text
    /// inside the message rather than as a chip that could not open.
    let openFile: ((String) -> Void)?
    /// Raise a picker. Nil when the machine cannot receive a file.
    let attach: ((ChatAttachSource) -> Void)?
    /// What is staged and not yet on its way.
    let attachment: ChatAttachment?
    /// Absent when nothing can be typed into this session right now — a dead
    /// socket. The composer is then not drawn, rather than drawn and refusing.
    let send: ((String) -> Void)?

    /// The chosen terminal scheme, for the code blocks. Read here rather than
    /// handed in so a code block follows the picker for the same reason the
    /// terminal behind this view does.
    var themes: TerminalThemeStore = .shared

    @State private var typed = ""
    @State private var copied: String?
    @FocusState private var writing: Bool

    /// Whether the bar is pointed at the session this view is drawing.
    private var mine: Bool { bar.sessionID == sessionID }

    /// Why a message typed here would go nowhere, or nil when it would land.
    private var unready: Unready? { Unready(status: status) }

    /**
     * Why there is no conversation on screen, or nil when there is one.
     *
     * The order is the argument. A machine that never serves a conversation is
     * asked first because nothing else below it can ever become true on that
     * machine — `askChat` returns at its capability guard, so no frame leaves
     * and `transcript` stays nil for ever, and "the machine has not answered
     * yet" would be a sentence about a question nobody asked. A bar pointed
     * somewhere else comes next, because `transcript` and `chat` then belong to
     * a different session and neither is evidence about this one. Only under
     * both of those do the machine's own two answers mean what they say.
     */
    private var silence: Silence? {
        if mine, !bar.chat.isEmpty { return nil }
        if !bar.canReadChat { return .notServed }
        if !mine { return .elsewhere }
        guard let transcript = bar.transcript else { return .asking }
        return transcript ? .nothingSaid : .noTranscript
    }

    /**
     * Why a plain message typed into this session would not do anything.
     *
     * The vocabulary belongs to the desktop — `session-activity.ts` is what
     * produces it — so this reads the words rather than owning them, and only
     * the two it can be sure about:
     *
     * - `input`  — the agent asked something and is blocked on the answer: a
     *              login menu, a `(y/N)`, a numbered list. Whatever is drawing
     *              that dialog is reading single keys, so a sentence and its
     *              return are not an answer to it. This is the state he was
     *              sitting in.
     * - `exited` — the process is gone. There is nothing left to type into.
     *
     * The other four are left alone deliberately. `waiting` is an empty prompt
     * and, despite the name, *"the resting state of every healthy session"*;
     * `working` accepts a message and queues it behind the turn; `completed` has
     * its prompt back. `idle` is the classifier's fall-through, which its own
     * author describes as *"nothing recognisable on screen"*, and it stays out
     * of here for the reason it always did: a sentence about a login built on
     * top of *we could not tell* is this view guessing about somebody's
     * terminal, which is the failure it exists to fix rather than a second
     * helping of it. What changed when he filmed an `idle` session with an
     * empty chat is that the guess stopped being the only alternative to
     * silence — `Silence` speaks for that screen without claiming anything
     * about the far terminal. A word this build has never seen falls through
     * the same way, so a newer desktop cannot make this screen say anything.
     */
    enum Unready {
        case answering
        case ended

        init?(status: String?) {
            switch status {
            case "input": self = .answering
            case "exited": self = .ended
            default: return nil
            }
        }

        /// What is happening, and what to do about it. Two short sentences,
        /// because the complaint is that this screen said nothing at all — and
        /// the second one names `terminal.mode`, which is on screen already.
        var sentence: String {
            switch self {
            case .answering:
                return "This session is waiting for an answer in the terminal — a login, a prompt, "
                    + "a confirmation. Switch to terminal mode to answer it."
            case .ended:
                return "This session has ended. Nothing typed here reaches it."
            }
        }
    }

    /**
     * Why there is no conversation to draw.
     *
     * Five states that were one blank page. Each is a fact this client already
     * holds and none of them is a guess about the far terminal — see the
     * header, *"Nothing to read, and why"*, for his sentence and for what the
     * phone may and may not claim.
     *
     * - `notServed`   — the welcome did not carry `chat`, so `askChat` never
     *                   sent a frame and never will on this machine.
     * - `elsewhere`   — the bar is following another session, or none at all.
     *                   One bar per machine, two `TerminalScreen`s; `reload` is
     *                   already on its way to close the gap, and until it lands
     *                   what is held belongs to somebody else. Both halves are
     *                   in the sentence, because a bar left with no session by
     *                   a `forget` is the same blank page as a bar taken by the
     *                   other tab.
     * - `asking`      — asked, nothing back. A file read on the far side, which
     *                   is milliseconds, or a socket that dropped in between.
     * - `noTranscript`— the machine looked and there is no transcript for this
     *                   session's folder in any store it writes to. A session
     *                   running a shell, or an agent that files nothing.
     * - `nothingSaid` — a transcript, with no prose in it. `chat-transcript.ts`
     *                   keeps `type: 'text'` and drops every tool call, so this
     *                   is what a session that has only run tools looks like.
     */
    enum Silence {
        case notServed
        case elsewhere
        case asking
        case noTranscript
        case nothingSaid

        /**
         * One short sentence, and the terminal named in three of the five.
         *
         * Named rather than offered, for the reason the header gives about
         * `Unready`: `terminal.mode` is already in this screen's navigation bar
         * and a button in the notice would be a second control for the same
         * press. `elsewhere` and `asking` do not name it because both are about
         * to resolve on their own, and sending somebody to the other mode for a
         * frame's wait would be worse advice than saying nothing.
         */
        var sentence: String {
            switch self {
            case .notServed:
                return "This machine cannot read a session as a conversation. "
                    + "Switch to terminal mode to see this one."
            case .elsewhere:
                return "This machine's conversation is not pointed at this session yet. "
                    + "Asking for it."
            case .asking:
                return "Nothing has come back for this session yet."
            case .noTranscript:
                return "The machine found no transcript for this session. "
                    + "Switch to terminal mode to see what it is doing."
            case .nothingSaid:
                return "There is nothing in this session's transcript. "
                    + "Switch to terminal mode to see what it is doing."
            }
        }

        /// One identifier per reason, in `chat.notready`'s shape, because which
        /// of the five is on screen is the whole of what this change is for — a
        /// test that only knew *some* notice was drawn could not tell the fix
        /// from the defect. Anything asserting "any of them" matches on the
        /// `chat.empty.` prefix, the way the browser rows are matched.
        var identifier: String {
            switch self {
            case .notServed: return "chat.empty.notserved"
            case .elsewhere: return "chat.empty.elsewhere"
            case .asking: return "chat.empty.asking"
            case .noTranscript: return "chat.empty.notranscript"
            case .nothingSaid: return "chat.empty.nothingsaid"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if mine {
                            if bar.atCap { cap }
                            ForEach(bar.chat) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        // In the place the conversation would be, because the
                        // absence of the conversation is what it explains. Above
                        // the notice below it and never instead of it: the two
                        // answer different questions and an exited session with
                        // no transcript is honestly both.
                        if let silence { nothing(silence) }
                        // Under the last turn, because what the far side is
                        // doing now is the newest thing on this screen — and
                        // above the anchor, so every scroll to the bottom ends
                        // on it rather than past it.
                        if let unready { stalled(unready) }
                        // An anchor rather than scrolling to the last row: a row
                        // is as tall as its text and scrolling *to* it puts its
                        // top at the bottom of the screen, which cuts a long
                        // answer off at its first line.
                        Color.clear.frame(height: 1).id(SessionChatView.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                /*
                 * The count *and* the last bubble's length.
                 *
                 * An agent's answer arrives as one message that grows — the same
                 * id, more text, read after read — so a view that followed the
                 * count alone would scroll once, at the first word, and then sit
                 * still while the paragraph filled the screen below it.
                 */
                .onChange(of: bar.chat.count + (bar.chat.last?.text.count ?? 0)) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scroll.scrollTo(SessionChatView.bottom, anchor: .bottom)
                    }
                }
                .onAppear { scroll.scrollTo(SessionChatView.bottom, anchor: .bottom) }
            }

            if let send { composer(send) }
        }
        /*
         * The terminal's ground, not the app's — because this is the same session
         * seen a different way, not a different screen.
         *
         * Asad, about the session screen: *"whatever the theme colour we decide to
         * keep… background, full page should be black."* Chat mode and terminal
         * mode are one screen with one navigation bar, and that bar takes the
         * scheme (see `TerminalChrome`); a conversation that kept `Theme.background`
         * underneath it put `#ffffff` directly below a `#000000` header on the one
         * scheme he named. The code blocks in here were already on this paper —
         * `codePaper` is the same call — so this is the page catching up with the
         * blocks rather than a new idea.
         */
        .background(TerminalChrome.paper(themes.selected))
        /*
         * Ask on appear, and ask again if the bar is found following somebody
         * else.
         *
         * This is the recovery half of the empty-chat fix. Opening the mode is
         * not the only way to arrive here — a screen can come back in front of
         * somebody with no lifecycle callback of any kind, measured — so the
         * view asking for what it is about to draw is the one event that cannot
         * be missed.
         */
        .onAppear { reload() }
        .onChange(of: bar.sessionID) { if !mine { reload() } }
        .accessibilityIdentifier("session.chat")
    }

    private static let bottom = "chat-bottom"

    /// The conversation starts where the wire cut it, said once, at the top.
    /// `Copilot.maxChatRows` carries why there is nothing better to offer.
    private var cap: some View {
        Text("Earlier turns are not on this device.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat.cap")
    }

    /**
     * The far side's own state, said in the conversation.
     *
     * Full width and squared off against the bubbles rather than drawn as one of
     * them: this is not a turn, nobody said it, and giving it a side would put it
     * in the transcript as something the agent or he had written. The ground and
     * the corner are the agent bubble's, so it reads as part of the conversation
     * and not as a system alert dropped on top of it, and the one warning-tinted
     * glyph is the whole of the emphasis — *"the biggest problem"* was silence,
     * not a lack of colour.
     */
    private func stalled(_ unready: Unready) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text(unready.sentence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.notready")
    }

    /**
     * Why the page is blank, drawn where the conversation would be.
     *
     * `stalled`'s row, deliberately, down to the corner and the ground: these
     * are two sentences about one session and drawing them as two different
     * kinds of object would suggest they come from two different places. The
     * one difference is the glyph's colour. `Unready` is warning-tinted because
     * it is about a press that will not work; this is faint because nothing is
     * wrong — a session with no transcript is an ordinary session, and the only
     * fault was never saying so.
     *
     * Not `cap`'s treatment, which is 11-point and centred: that is a footnote
     * about where the transcript was clipped, said above a conversation that is
     * there. This is the only thing on the screen.
     */
    private func nothing(_ silence: Silence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
            Text(silence.sentence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(silence.identifier)
    }

    // MARK: - Bubbles

    private func bubble(_ message: CopilotChatMessage) -> some View {
        // The side, and the only thing that says whose message this is. No
        // label above it and no name inside it.
        let mine = message.role == .you
        let document = ChatDocument.parse(message.text, cwd: cwd)
        return HStack {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(document.blocks) { block in
                        switch block {
                        case let .prose(_, text): prose(text)
                        case let .code(_, language, text): code(language: language, text: text)
                        case let .diff(_, text): patch(text)
                        }
                    }
                    if message.truncated { truncation }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(mine ? Theme.accent.opacity(0.14) : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if !document.paths.isEmpty, let openFile { touched(document.paths, open: openFile) }

                HStack(spacing: 8) {
                    let stamp = SessionChatView.time(message.at)
                    if !stamp.isEmpty {
                        Text(stamp)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                            .monospacedDigit()
                    }
                    copyButton(message.id, text: message.text)
                }
                .padding(.horizontal, 2)
            }
            if !mine { Spacer(minLength: 44) }
        }
        // Combined so VoiceOver reads one turn, and labelled with the side that
        // the screen carries as position rather than as a word.
        .accessibilityElement(children: .contain)
    }

    private func prose(_ text: String) -> some View {
        Text(SessionChatView.inline(text))
            .font(.system(size: 15))
            .foregroundStyle(Theme.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /**
     * A paragraph with its inline markup applied, or the plain string.
     *
     * `` `src/main/index.ts` `` reaching the screen with its backticks still on
     * is the one thing that made this view look like it was showing raw text,
     * and it is the marking an agent uses most: photographed on the Simulator
     * before this existed, a single answer carried five of them.
     *
     * **`.inlineOnlyPreservingWhitespace`, and both halves of that name matter.**
     * Inline-only means the block syntax is left alone — a `#` at the start of a
     * shell comment stays a `#` rather than becoming a heading, and a `-` at the
     * start of a line stays a bullet character rather than becoming a list, which
     * is what full markdown parsing would do to a diff summary. Preserving
     * whitespace means the newlines survive; the default collapses a paragraph
     * onto one line, which for an agent's answer is the paragraphs gone.
     *
     * The plain string on a throw rather than an empty view: markdown is a
     * presentation of the text, and text that cannot be presented is still text.
     */
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        /*
         * Inline code, two points smaller than the sentence around it.
         *
         * SwiftUI draws a `.code` run monospaced at the paragraph's own size,
         * and a monospaced face at 15 points is visibly wider than the
         * proportional one it sits in — a path in the middle of a sentence took
         * two lines to itself and read as a heading. Thirteen is the size the
         * code blocks use, so a path quoted in a sentence and the same path in a
         * block are the same size.
         */
        // The ranges are collected before anything is written, because writing
        // into the string a `runs` view is being walked is a mutation of the
        // collection being iterated.
        let code = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in code { parsed[range].font = .system(size: 13, design: .monospaced) }
        return parsed
    }

    /// The desktop cut this bubble at `MAX_COPILOT_MESSAGE_CHARS`. Drawn,
    /// because a bubble that was shortened and does not say so misquotes an
    /// agent — the reason the flag is on the wire at all.
    private var truncation: some View {
        Text("Cut here — the rest is on the machine.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.faint)
            .accessibilityIdentifier("chat.truncated")
    }

    // MARK: - Code

    /**
     * A fenced block, in the terminal's own colours.
     *
     * It scrolls sideways and does not wrap, for the reason `FileTextView` gives
     * about the same decision: *"a wrapped minified bundle, a wrapped log line or
     * a wrapped stack trace is soup. Code has columns and they carry meaning."*
     * A 120-column line folded into eight phone-width rows has had its
     * indentation destroyed rather than presented.
     */
    private func code(language: String?, text: String) -> some View {
        let lines = SessionChatView.bounded(text)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let language {
                    Text(language)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
                copyButton("code-\(text.hashValue)", text: text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.shown, id: \.self) { line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(codeInk)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            if lines.dropped > 0 { more(lines.dropped) }
        }
        .background(codePaper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // A hairline as well as the ground, because the two can be the same
        // colour: `Theme.surface` and Deck Dark's terminal paper are both
        // `#191919`, so in the app's own dark theme a code block with only a fill
        // is invisible as a block. Measured on the Simulator — the ground was
        // there and nothing on screen said where the code began.
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .accessibilityIdentifier("chat.code")
    }

    /**
     * A unified patch, classified by the same parser the Source Control screen
     * uses.
     *
     * `DiffText` rather than a second classifier, because a line that reads as
     * *added* on one screen and as *context* on another is two opinions about one
     * file. The colours are `Theme`'s own two status inks, at the same tenth
     * strength `DiffView` washes with and for the same measured reason: at 12
     * points the hue difference on a thin glyph is not enough to find a changed
     * region at a glance.
     */
    private func patch(_ text: String) -> some View {
        let document = DiffText.parse(text)
        let shown = document.lines.prefix(ChatDocument.maxBlockLines)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if document.added > 0 {
                    Text("+\(document.added)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.positive)
                }
                if document.removed > 0 {
                    Text("−\(document.removed)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.critical)
                }
                Spacer(minLength: 0)
                copyButton("diff-\(text.hashValue)", text: text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ink(line.kind))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            // Every row the same width, so the tints read as
                            // bands rather than as a ragged coastline — the
                            // measurement `DiffView` records.
                            .frame(width: document.width, alignment: .leading)
                            .background(wash(line.kind))
                    }
                }
                .padding(.bottom, 8)
            }
            if document.lines.count > shown.count {
                more(document.lines.count - shown.count)
            } else if document.truncated {
                more(nil)
            }
        }
        .background(codePaper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The same hairline, for the same reason the code block carries one.
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .accessibilityIdentifier("chat.diff")
    }

    /// What was left out, counted where it can be counted. Never a silent cut.
    private func more(_ lines: Int?) -> some View {
        Text(lines.map { "\($0) more lines" } ?? "Longer than this view draws")
            .font(.system(size: 10))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier("chat.block.more")
    }

    private static func bounded(_ text: String) -> (shown: [String], dropped: Int) {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > ChatDocument.maxBlockLines else { return (all, 0) }
        return (Array(all.prefix(ChatDocument.maxBlockLines)), all.count - ChatDocument.maxBlockLines)
    }

    private func ink(_ kind: DiffText.Kind) -> Color {
        switch kind {
        case .added: return Theme.positive
        case .removed: return Theme.critical
        case .hunk, .meta: return Theme.faint
        case .context: return codeInk
        }
    }

    private func wash(_ kind: DiffText.Kind) -> Color {
        switch kind {
        case .added: return Theme.positive.opacity(0.1)
        case .removed: return Theme.critical.opacity(0.1)
        default: return .clear
        }
    }

    /// The chosen scheme's ground and ink, as one colour each that answers for
    /// both appearances — the arrangement `TerminalPalette.dynamicBackground`
    /// exists for, and the reason a code block does not go black inside a
    /// `#191919` bubble the moment somebody picks Pure Black.
    private var codePaper: Color {
        Color(TerminalPalette.dynamicBackground(themes.selected))
    }

    private var codeInk: Color {
        let scheme = themes.selected
        return Color(uiColor: UIColor { traits in
            TerminalPalette.color(TerminalPalette.resolved(scheme, style: traits.userInterfaceStyle).foreground,
                                  fallback: .label)
        })
    }

    // MARK: - Files this turn named

    /**
     * The paths in a turn, as chips that open the machine's own reader.
     *
     * Only drawn when this device may read files, and only for paths that could
     * be made absolute — see `ChatDocument.absolute`. A chip that resolved to
     * nothing would open a screen whose only content is a refusal, which is the
     * defect this app removes buttons for rather than explains.
     */
    private func touched(_ paths: [String], open: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(paths, id: \.self) { path in
                Button { open(path) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceHigh, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(path)")
                .accessibilityIdentifier("chat.path")
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Copy

    private func copyButton(_ id: String, text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copied = id
            // Two seconds of a tick on the button itself. A toast saying
            // "Copied" would be a sentence about something the finger already
            // knows it did.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if copied == id { copied = nil }
            }
        } label: {
            Image(systemName: copied == id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied == id ? Theme.positive : Theme.faint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy")
        .accessibilityIdentifier("chat.copy")
    }

    /**
     * `14:32`, in the reader's own locale and time zone.
     *
     * The time and nothing else — no date, no "yesterday", no relative wording.
     * Zero is *undated*, which the wire uses for a transcript line that carried
     * no timestamp, and an undated bubble gets no time rather than 01:00 on the
     * 1st of January 1970.
     */
    static func time(_ at: Double, formatter: DateFormatter? = nil) -> String {
        guard at.isFinite, at > 0 else { return "" }
        let shape = formatter ?? SessionChatView.clock
        return shape.string(from: Date(timeIntervalSince1970: at / 1000))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - The composer

    /**
     * One field and one button, with the paperclip and whatever it staged above
     * them.
     *
     * `safeAreaInset` is not used here and the reason is worth stating: this
     * view is already the bottom half of a `VStack` inside a screen that keeps
     * SwiftUI's keyboard avoidance, so the row rises with the keyboard on its
     * own. What it must not lose is the home indicator underneath it when the
     * keyboard is *down* — *"at the bottom we cannot see some stuff because of
     * the mobile's round corners"* — which is what the bottom padding below the
     * divider is for, and why it is a `safeAreaPadding` rather than a number.
     */
    private func composer(_ send: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if let attachment { staged(attachment) }
            HStack(alignment: .bottom, spacing: 8) {
                if let attach { paperclip(attach) }

                TextField("", text: $typed, axis: .vertical)
                    // No placeholder text. A field at the bottom of a
                    // conversation is a field you type in; a sentence in it
                    // saying so is the furniture this review is about removing.
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1...6)
                    .focused($writing)
                    .submitLabel(.send)
                    /*
                     * No autocapitalising and no autocorrect, and both are the
                     * same argument: what is typed here is written verbatim
                     * into an agent's prompt, where a path, a flag and a
                     * command name all begin with a lower-case letter. iOS
                     * capitalises the first word of every sentence by default,
                     * which turned `src/main/index.ts` into `Src/main/index.ts`
                     * on the first message sent from this field.
                     */
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("chat.field")

                Button {
                    let message = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    typed = ""
                    send(message)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(sendable ? Theme.accent : Theme.faint)
                }
                .buttonStyle(.plain)
                .disabled(!sendable)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        // The composer sits on the same paper as the conversation above it; a
        // strip of the app's grey across the bottom of a black page is the seam
        // this change exists to remove.
        .background(TerminalChrome.paper(themes.selected))
    }

    private func paperclip(_ attach: @escaping (ChatAttachSource) -> Void) -> some View {
        Menu {
            Button { attach(.photos) } label: {
                Label("Photo or Video", systemImage: "photo")
            }
            .accessibilityIdentifier("chat.attach.photo")
            Button { attach(.files) } label: {
                Label("File", systemImage: "doc")
            }
            .accessibilityIdentifier("chat.attach.file")
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 18))
                .foregroundStyle(Theme.faint)
                .frame(width: 32, height: 38)
        }
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("chat.attach")
    }

    /**
     * What is about to be sent, before it goes.
     *
     * > *"If we send the files we can have a preview and kind of things when we
     * > are on chat mode."*
     *
     * This is the one preview in this view that is a real picture of the real
     * bytes, and it is real precisely because the file is **on the phone**: the
     * picker has already staged a copy in this app's own temporary directory, so
     * `UIImage(contentsOfFile:)` is reading the thing that is going to be
     * uploaded. Anything that is not an image the phone can decode gets its
     * name, its kind and its size — never an empty frame.
     *
     * The send arrow is absent rather than dimmed while another transfer is
     * running, because `HostLink.send` refuses a second one outright and a
     * button whose only outcome is a refusal is not a button. The upload's own
     * progress is the row `TerminalScreen` draws above both modes, so it is not
     * repeated here.
     */
    private func staged(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 10) {
            thumbnail(attachment.file)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.file.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteSize(attachment.file.size))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let send = attachment.send {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send this file")
                .accessibilityIdentifier("chat.attachment.send")
            }
            Button(action: attachment.discard) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove this file")
            .accessibilityIdentifier("chat.attachment.discard")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .accessibilityIdentifier("chat.attachment")
    }

    @ViewBuilder
    private func thumbnail(_ file: PickedFile) -> some View {
        if let image = UIImage(contentsOfFile: file.url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            // Not a broken frame: the file's own kind, taken from its extension,
            // in the same square the picture would have occupied.
            Image(systemName: SessionChatView.glyph(for: file.name))
                .font(.system(size: 17))
                .foregroundStyle(Theme.secondary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// A glyph per family, and nothing invented: these are the SF Symbols the
    /// system itself uses for the same kinds in a document picker.
    static func glyph(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv": return "film"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        default: return "doc"
        }
    }

    /**
     * Whether the arrow does anything, which is now two facts rather than one.
     *
     * Something typed, and a far side that will take it. The second is the half
     * this screen was lying about: *"now if I send it, nothing will happen
     * because the terminal is not ready for it."* A grey arrow that refuses the
     * press is the composer saying the same thing the notice above it says, at
     * the moment the finger is on it.
     *
     * The field itself stays live on purpose. A sentence can be written while the
     * machine is being unblocked in the other mode, and clearing somebody's draft
     * because their session hit a prompt would lose the thing they came here to
     * send — see `agent-controls.ts`, which refuses to type at all rather than
     * over a draft, for the same rule at the other end of the wire.
     *
     * **An empty conversation does not grey it, and that is not an oversight.**
     * `Silence` and this are about opposite directions of the same wire: the
     * transcript is what you *read* and the pty is what you *write*, and a
     * session with no transcript takes a first message perfectly well — that is
     * how the transcript comes to exist. Greying the arrow because there is
     * nothing to read would refuse the one press this composer is for, on the
     * exact session that most needs it. The notice says the screen is empty; it
     * does not claim the far end is deaf.
     */
    private var sendable: Bool {
        unready == nil && !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
