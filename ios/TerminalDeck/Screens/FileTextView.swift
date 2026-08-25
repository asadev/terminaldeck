/**
 * One file off the machine, read on the phone.
 *
 * The other half of {@link FilesView}: that screen answers *what is in this
 * folder*, this one answers *what is in this file*. On a rented Linux box with
 * nobody in front of it, those two questions are the whole of "look at the
 * disk", and until they existed the answer to both was to start a pty and type.
 *
 * ## It has to be honest about three different answers, and it is
 *
 * `files.text` is not a string. It is one of three things, and a screen that
 * drew all three the same way would be lying about two of them:
 *
 *  - **Text.** Draw it.
 *  - **Truncated.** The host reads a bounded window — 64KB unless asked
 *    otherwise — so what came back may be the *front* of a 200MB log. Showing
 *    that and stopping, with nothing on screen to say so, is the shape of defect
 *    where somebody concludes their log is empty after the first page. So the
 *    bar at the bottom says how much is in hand and reads the next window from
 *    `at + the bytes that came back`, which is why the offset travels on the
 *    frame at all.
 *  - **Binary.** The host decides this **from the bytes** — a NUL in the block
 *    it read, the test every editor uses and the only one that is right about a
 *    `.log` that is really a core dump — and sends no text at all rather than
 *    mojibake. Drawing an empty screen there would read as a bug in this app.
 *    It says what the file is instead.
 *
 * ## Why it scrolls sideways
 *
 * Because a wrapped minified bundle, a wrapped log line or a wrapped stack trace
 * is soup. Code has columns and they carry meaning — indentation is structure,
 * and a 400-character line that has been folded into thirty phone-width rows has
 * had that structure destroyed rather than presented. So the text is laid out at
 * its natural width and the screen moves under it, which is what every editor on
 * a small screen does and what a terminal does by default.
 *
 * ## What it is not
 *
 * Not an editor. There is no write verb on this wire and there deliberately
 * isn't one: `files` is a read capability, owner-device only, and a phone that
 * could edit a file on a server would be a much larger decision than a screen.
 * Selection and copy are the whole of what a person can take away from here.
 */

import SwiftUI
import UIKit

struct FileTextView: View {
    let model: DeckModel
    let path: String

    /// What the listing row said this file weighs, when it said anything. Used
    /// only to put the part in hand in proportion — *"first 64 KB of 12 MB"* —
    /// and absent rather than guessed when the host could not `stat` the file.
    let size: Int?

    /// Spelled out rather than left to the memberwise initialiser, which the
    /// private state below would otherwise pull down to `private` and put out of
    /// reach of `FilesView`.
    init(model: DeckModel, path: String, size: Int? = nil) {
        self.model = model
        self.path = path
        self.size = size
    }

    /**
     * The windows read so far, in order, joined for display.
     *
     * Kept as pieces rather than one growing string because that is what
     * arrives: each answer is a window starting at a byte offset, and appending
     * is the only operation this screen performs on them. Nothing here re-reads
     * or re-orders — a window that does not continue exactly where the last one
     * ended is dropped rather than spliced into the middle of somebody's file.
     */
    @State private var windows: [String] = []

    /// The byte offset immediately after everything in `windows`. The next read
    /// starts here, and an arriving answer must say it starts here or it is not
    /// the continuation this screen asked for.
    @State private var readTo = 0

    @State private var truncated = false
    @State private var binary = false
    /// Whether anything at all has come back for this file. Distinguishes an
    /// empty file — a real, common answer — from a read still in flight.
    @State private var answered = false
    @State private var waiting = false
    /// Long enough with no answer that a spinner has stopped being informative.
    /// A refusal from the host is an `error` frame that lands in the
    /// connection's error path, not here, so silence is all this screen sees.
    @State private var silent = false
    /// Bumped on every read this screen starts, and the only thing the silence
    /// timer keys on. A counter rather than the offset, because a reload of a
    /// file already read from zero would not change the offset and the timer
    /// would never restart.
    @State private var attempt = 0

    /**
     * Where reading on stops.
     *
     * One `Text` holding a megabyte of monospaced glyphs is already close to
     * what a phone will lay out in a frame; a *Read more* that kept going would
     * eventually be a button whose only effect is a beachball and then a crash.
     * Stopping is said out loud on the bar rather than by the button quietly
     * disappearing, because "there is more and this screen will not fetch it" is
     * a fact the person needs in order to go and use `tail` in a session.
     */
    private let ceiling = 1_000_000

    private var text: String { windows.joined() }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = path
                    } label: {
                        Label("Copy path", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("filetext.copypath")

                    if !text.isEmpty {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("Copy what is shown", systemImage: "doc.on.clipboard")
                        }
                        .accessibilityIdentifier("filetext.copytext")
                    }

                    Button {
                        start()
                    } label: {
                        Label("Read again", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("filetext.reload")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("filetext.more")
            }
        }
        .safeAreaInset(edge: .bottom) { moreBar }
        .onAppear {
            // A matching answer may already be in hand — the same file opened a
            // moment ago, or an answer that landed before this view was on
            // screen. Taking it is the difference between an instant screen and
            // a round trip somebody watches.
            if let already = model.fileText, already.path == path, already.at == 0 {
                absorb(already)
            } else {
                start()
            }
        }
        .onChange(of: model.fileText) { _, answer in absorb(answer) }
        .task(id: attempt) {
            silent = false
            guard !answered else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            silent = !answered
        }
    }

    // MARK: - Reading

    private func start() {
        windows = []
        readTo = 0
        truncated = false
        binary = false
        answered = false
        waiting = true
        silent = false
        attempt += 1
        model.readFile(path, at: 0)
    }

    private func more() {
        guard truncated, readTo < ceiling, !waiting else { return }
        waiting = true
        attempt += 1
        model.readFile(path, at: readTo)
    }

    /**
     * Take an answer, or refuse it.
     *
     * Three things are checked and each of them is a real case rather than
     * defensiveness. The **path**, because this screen may be pushed twice in a
     * row and a late answer for the file behind must not be drawn as this one.
     * The **offset**, because only a window that begins exactly where the last
     * one ended is a continuation — anything else would be spliced into the
     * middle of somebody's file and read as corruption. And **binary**, which
     * ends the read: there is nothing to continue and no more to ask for.
     */
    private func absorb(_ answer: FileText?) {
        guard let answer, answer.path == path else { return }
        waiting = false

        if answer.binary {
            windows = []
            readTo = 0
            truncated = false
            binary = true
            answered = true
            return
        }

        if answer.at == 0 {
            windows = [answer.text]
            readTo = answer.text.utf8.count
        } else if answer.at == readTo {
            windows.append(answer.text)
            readTo += answer.text.utf8.count
        } else {
            // A window from an offset this screen is not standing at. Dropped
            // rather than appended: a gap in a file drawn as continuous text is
            // worse than the window never arriving.
            return
        }

        binary = false
        truncated = answer.truncated
        answered = true
    }

    // MARK: - The screen

    /// The path in full, above the text rather than inside it, so it stays put
    /// while the file scrolls under it in both directions. `FilesView` and
    /// `FolderPickerView` put the same line in the same place.
    private var header: some View {
        VStack(spacing: 0) {
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .accessibilityIdentifier("filetext.path")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        if binary {
            notText
        } else if answered && text.isEmpty {
            empty
        } else if !windows.isEmpty {
            fileBody(text)
        } else if silent {
            noAnswer
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /**
     * The file itself.
     *
     * `fixedSize(horizontal: true)` is the line that makes it a file viewer
     * rather than a paragraph: it lays the text out at its natural width and
     * lets the scroll view carry it, so a 400-column line stays one line. Take
     * that away and every long line folds into soup.
     *
     * Selection is on, because copying an error message out of a log on a server
     * is most of the reason anybody opens this screen on a phone.
     */
    private func fileBody(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityIdentifier("filetext.body")
        }
    }

    /**
     * The bar that says how much of the file is in hand, and reads on.
     *
     * Drawn only when the host said `truncated`, so a file that came back whole
     * has nothing at the bottom of the screen at all. Past the ceiling it keeps
     * the sentence and drops the button — the fact that there is more does not
     * stop being true because this screen has stopped fetching it.
     */
    @ViewBuilder
    private var moreBar: some View {
        if truncated && !binary {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(readSoFar)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                        if readTo >= ceiling {
                            Text("This screen stops here. Use a session and `tail` for the rest.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    Spacer(minLength: 8)
                    if readTo < ceiling {
                        Button {
                            more()
                        } label: {
                            if waiting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Read more")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(waiting)
                        .accessibilityIdentifier("filetext.more.read")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.bar)
        }
    }

    /// *"First 64 KB of 12 MB"* when the listing knew the size, and the honest
    /// shorter sentence when it did not.
    private var readSoFar: String {
        if let size, size > 0 {
            return "First \(byteSize(readTo)) of \(byteSize(size))"
        }
        return "First \(byteSize(readTo)) — there is more"
    }

    // MARK: - The two answers that are not text

    /**
     * Not text, said in as much detail as this side honestly has.
     *
     * The machine's word for what the file *is not*; this side's guess, from the
     * name, at what it might be — labelled as the extension it came from so
     * nobody reads it as the machine's answer — and the size, which is real. An
     * empty screen with no explanation was the alternative and it reads as a
     * failure.
     */
    private var notText: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24)
                    Text("This is not a text file")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 8)
                    InfoDot(
                        about: "Binary files",
                        text: "The machine decided this from the bytes themselves — a zero byte in "
                            + "the block it read — rather than from the file's name. That is the test "
                            + "every editor uses, and the only one that is right about a .log that is "
                            + "really a crash dump. It sent no text at all rather than sending nonsense."
                    )
                }
                Text(kind)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .padding(.leading, 36)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("filetext.binary")
    }

    /// What little can be said about a file nobody can read here: its extension,
    /// named as an extension, and its size.
    private var kind: String {
        var parts: [String] = []
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty { parts.append(".\(ext) file") }
        if let size { parts.append(byteSize(size)) }
        return parts.isEmpty ? "Nothing more is known about it from here." : parts.joined(separator: "  ·  ")
    }

    private var empty: some View {
        VStack(spacing: 0) {
            Text("This file is empty.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("filetext.empty")
    }

    /**
     * Nothing came back.
     *
     * It says *no answer*, not *that file does not exist*, because this screen
     * cannot tell those apart — a refusal is an `error` frame on the connection
     * and never reaches here. Both remedies a person has are on the card.
     */
    private var noAnswer: some View {
        ContentUnavailableView {
            Label("No answer from the machine", systemImage: "doc.questionmark")
        } description: {
            Text("It did not send anything back for this file. It may not have been able to read it.")
        } actions: {
            Button("Try again") { start() }
                .accessibilityIdentifier("filetext.retry")
        }
    }
}
