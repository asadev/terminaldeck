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
 * label, no "thinking", no date separator, no empty-state paragraph. An empty
 * conversation is drawn as an empty screen.
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
 */

import SwiftUI

struct SessionChatView: View {
    let bar: SessionBarLink
    /// Absent when nothing can be typed into this session right now — a dead
    /// socket. The composer is then not drawn, rather than drawn and refusing.
    let send: ((String) -> Void)?

    @State private var typed = ""
    @State private var copied: String?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(bar.chat) { message in
                            bubble(message).id(message.id)
                        }
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
        .background(Theme.background)
        .accessibilityIdentifier("session.chat")
    }

    private static let bottom = "chat-bottom"

    // MARK: - Bubbles

    private func bubble(_ message: CopilotChatMessage) -> some View {
        // The side, and the only thing that says whose message this is. No
        // label above it and no name inside it.
        let mine = message.role == .you
        return HStack {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(mine ? Theme.accent.opacity(0.14) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(spacing: 8) {
                    let stamp = SessionChatView.time(message.at)
                    if !stamp.isEmpty {
                        Text(stamp)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                            .monospacedDigit()
                    }
                    Button {
                        UIPasteboard.general.string = message.text
                        copied = message.id
                        // Two seconds of a tick on the button itself. A toast
                        // saying "Copied" would be a sentence about something
                        // the finger already knows it did.
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if copied == message.id { copied = nil }
                        }
                    } label: {
                        Image(systemName: copied == message.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(copied == message.id ? Theme.positive : Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy")
                    .accessibilityIdentifier("chat.copy")
                }
                .padding(.horizontal, 2)
            }
            if !mine { Spacer(minLength: 44) }
        }
        // Combined so VoiceOver reads one turn, and labelled with the side that
        // the screen carries as position rather than as a word.
        .accessibilityElement(children: .contain)
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
     * One field and one button.
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
            HStack(alignment: .bottom, spacing: 8) {
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
        .background(Theme.background)
    }

    private var sendable: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
