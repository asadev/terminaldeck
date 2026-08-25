/**
 * The machine's disk, on the phone.
 *
 * > *"what about files … in ios app too for server."*
 *
 * On a Mac in the next room this is a convenience. On a rented Linux box it is
 * the **only** way to see the disk at all: there is no Finder over there, nobody
 * is sitting in front of it, and until this screen existed the answer to *what
 * is actually in that folder* was "start a session and type `ls`" — a pty, a
 * shell and a scrollback, to read four file names.
 *
 * ## Why this is not `FolderPickerView` with files added
 *
 * That screen is a **chooser**: it lists directories only, drops the dot-entries
 * and `node_modules` because none of them is somewhere a session gets started,
 * and ends in a button that hands one path back to a caller. Its whole shape is
 * "pick one and leave".
 *
 * This one is a **reader**, and every one of those decisions inverts. Files are
 * the point. Dot-entries are kept, because `.env` and `.gitignore` are usually
 * exactly what somebody came for — the host says as much in `listFiles`. There
 * is no bottom button, because arriving somewhere *is* the outcome. It is a
 * different verb on the wire (`files.list`, capability `files`) with a different
 * shape of row, and folding the two together would mean one screen that is
 * half-wrong whichever way it is opened.
 *
 * What it does keep, deliberately and to the point of copying the metrics, is
 * the *look*: the path in full at the top, the same 24pt icon column, the same
 * dimmed-with-a-lock row for something this account cannot open. Two screens
 * that walk the same filesystem should not feel like two apps.
 *
 * ## Unreadable rows are drawn, and they do not respond
 *
 * `/root` is on every Linux listing and openable by nobody but root; so is a
 * key file with mode 600 under an account that is not its owner. Hiding those
 * rows would mean somebody looking for a file they know is there, not finding
 * it, and going to look for a bug in this screen. The host carries `readable` on
 * every entry for exactly this reason. They are drawn dimmed with a lock and
 * they are not tappable — a row that is offered and then refused is worse than a
 * row that never pretended.
 *
 * ## One tap, two destinations
 *
 * A directory descends in place; a file pushes {@link FileTextView}. That is one
 * gesture with two outcomes, which is normally worth avoiding — here it is what
 * every file browser anybody has used does, and the two are told apart by an
 * icon, a chevron and a size, before the finger lands.
 */

import SwiftUI
import UIKit

// MARK: - What the wire answers with

/*
 * **These three types are the `files` frames, and they may already exist.**
 *
 * They are declared here because this screen cannot compile without them and
 * because they are read nowhere else yet. If the lane that wires `WireCodec`
 * declares its own `FileListing` / `FileRow` / `FileText`, delete this whole
 * section rather than renaming anything: the field names below are the wire's
 * field names, so two declarations would be the same struct twice and the
 * compiler would refuse both.
 */

// `FileListing` lives in `Protocol/PanelsWire.swift` — it is what the codec
// decodes into, so a second copy here would be two types with one name.

// `FileRow` is gone — `FileRow` in `Protocol/PanelsWire.swift` is what the
// codec decodes `files.rows` into, and one vocabulary beats two that must agree.


// `FileText` lives in `Protocol/PanelsWire.swift` — it is what the codec
// decodes into, so a second copy here would be two types with one name.

// MARK: - The screen

struct FilesView: View {
    let model: DeckModel

    /// Where the browser opens. A folder the machine has already named — the
    /// caller passes `model.current?.startableFolders.first`, which is the
    /// machine's own answer to *where does this device work* — rather than a
    /// path this phone invented. It does not know whether home over there is
    /// `/Users/apple`, `/root` or `C:\Users\asad`, and a guess that is wrong
    /// opens this screen on a failure.
    let start: String

    /// Spelled out rather than left to the memberwise initialiser, which the
    /// private state below would otherwise pull down to `private` and put out of
    /// reach of every caller.
    init(model: DeckModel, start: String) {
        self.model = model
        self.start = start
    }

    /**
     * The folder that was last **asked** for.
     *
     * Not the same thing as the folder on screen, and the gap between them is
     * the load: an ask clears the listing, so for the length of a round trip
     * this is set and there is nothing to draw. Rows appear only once an answer
     * for *this* path is in hand, so a folder's contents are never drawn under
     * another folder's name.
     *
     * It is re-adopted from every answer that arrives, because the host
     * `resolve()`s what it was sent — ask for a path with a `..` or a trailing
     * slash in it and the answer comes back spelled differently. Following the
     * answer means the screen agrees with the machine rather than waiting
     * forever for a string it will never be sent.
     */
    @State private var asked = ""

    /// Set when an ask has gone unanswered long enough that a spinner has
    /// stopped being informative. There is no error channel in what this screen
    /// is given, and a permanent spinner is the one outcome worse than a
    /// sentence that says "no answer" — the host refuses an unreadable folder
    /// with an `error` frame, which lands nowhere near here.
    @State private var silent = false

    /// Bumped on every ask, and the only thing the silence timer keys on. A
    /// counter rather than the path, because pressing refresh on the folder
    /// already on screen does not change the path and the timer would never
    /// restart for it.
    @State private var attempt = 0

    private var listing: FileListing? { model.fileListing }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    ask(listing?.path ?? asked)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Read this folder again")
                .accessibilityIdentifier("files.refresh")
            }
        }
        /*
         * Resumed rather than reset.
         *
         * A listing already in hand is the folder this person walked to a moment
         * ago — they went into a file and came back, or they left the screen and
         * returned. Re-asking for `start` would take them back to the top of the
         * tree every time, which on a server with a real directory depth is the
         * difference between a browser and a toy.
         */
        .onAppear {
            if let here = listing?.path {
                asked = here
            } else {
                ask(start)
            }
        }
        // The machine's spelling of a path wins over this phone's. See `asked`.
        .onChange(of: model.fileListing) { _, answered in
            if let answered { asked = answered.path }
        }
        .task(id: attempt) {
            silent = false
            guard !asked.isEmpty else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            silent = listing?.path != asked
        }
    }

    private var title: String {
        let here = listing?.path ?? asked
        let name = (here as NSString).lastPathComponent
        return name.isEmpty ? "Files" : name
    }

    private func ask(_ path: String) {
        guard !path.isEmpty else { return }
        asked = path
        attempt += 1
        model.listFiles(path)
    }

    // MARK: - What is on screen

    @ViewBuilder
    private var content: some View {
        if let listing, listing.path == asked {
            rows(listing)
        } else if silent {
            noAnswer
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rows(_ listing: FileListing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                here(listing)

                VStack(spacing: 0) {
                    if let parent = listing.parent {
                        Button {
                            ask(parent)
                        } label: {
                            row(icon: "arrow.turn.left.up",
                                name: "..",
                                detail: nil,
                                dimmed: false,
                                chevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("files.up")
                        divider
                    }

                    if listing.entries.isEmpty {
                        Text("Nothing in here.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                    }

                    let sorted = ordered(listing.entries)
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry)
                        if index < sorted.count - 1 { divider }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)

                TabBarClearance()
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    /**
     * Where you are, in full, and the one explanation on the screen.
     *
     * The title bar carries the last component only, which is what a person
     * reads; this is the line that says which `src` you are standing in. Head
     * truncation, because the end of a path is the part that identifies it.
     */
    private func here(_ listing: FileListing) -> some View {
        HStack(spacing: 4) {
            Text(listing.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("files.here")
            InfoDot(
                about: "Files",
                text: "This is the machine's own disk, read over the connection. "
                    + "Rows this account cannot open are dimmed and do not respond — "
                    + "they are drawn so that something you know is there is not simply missing."
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    /**
     * Directories first, then names.
     *
     * The host already sorts this way and this sorts again, which is not
     * distrust — it is that the promise belongs to the screen. A listing whose
     * order changed between two visits is a listing nobody trusts, and the one
     * line that guarantees it here costs nothing on a folder of any size a
     * phone can draw.
     */
    private func ordered(_ entries: [FileRow]) -> [FileRow] {
        entries.sorted { left, right in
            left.directory == right.directory
                ? left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                : left.directory
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func entryRow(_ entry: FileRow) -> some View {
        if !entry.readable {
            // Not a Button and not a NavigationLink. A `.disabled` control still
            // reads to VoiceOver as a control, and this is not one — it is a
            // fact about the disk.
            row(icon: "lock",
                name: entry.name,
                detail: entry.directory ? "Cannot be opened by this account" : detail(entry),
                dimmed: true,
                chevron: false)
                .accessibilityIdentifier("files.row.\(entry.path)")
                .contextMenu { copyPath(entry.path) }
        } else if entry.directory {
            Button {
                ask(entry.path)
            } label: {
                row(icon: "folder", name: entry.name, detail: nil, dimmed: false, chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("files.row.\(entry.path)")
            .contextMenu { copyPath(entry.path) }
        } else {
            NavigationLink {
                FileTextView(model: model, path: entry.path, size: entry.size)
            } label: {
                row(icon: icon(for: entry.name),
                    name: entry.name,
                    detail: detail(entry),
                    dimmed: false,
                    chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("files.row.\(entry.path)")
            .contextMenu { copyPath(entry.path) }
        }
    }

    private func row(icon: String, name: String, detail: String?, dimmed: Bool, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(dimmed ? Theme.faint : Theme.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16))
                    .foregroundStyle(dimmed ? Theme.faint : Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 46)
    }

    private func copyPath(_ path: String) -> some View {
        Button {
            UIPasteboard.general.string = path
        } label: {
            Label("Copy path", systemImage: "doc.on.doc")
        }
    }

    // MARK: - The numbers on a file row

    /// Size and modified time, whichever of the two the machine sent. Absent
    /// stays absent: a file the host could not `stat` shows a name and nothing
    /// else, rather than a zero somebody would read as the truth.
    private func detail(_ entry: FileRow) -> String? {
        var parts: [String] = []
        if let size = entry.size { parts.append(byteSize(size)) }
        if let at = entry.at { parts.append(when(at)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// A modified time as short as it can be and still be unambiguous: a clock
    /// for today, a day and month for this year, a year as well for anything
    /// older. A full timestamp on every row is forty characters of noise on a
    /// phone-width row.
    private func when(_ date: Date) -> String {
        // The wire hands back a `Date`; `PanelsWire` did the milliseconds.
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /**
     * An icon from the name, and it is a **hint rather than a claim**.
     *
     * The host is the only side that knows what a file really is — it decides
     * text from binary by looking at the bytes, which is the one test that is
     * right about a `.log` that is really a core dump. Nothing here is allowed
     * to contradict that: an extension picks a glyph and never a behaviour, and
     * anything unrecognised gets the plain document rather than a guess.
     */
    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico": return "photo"
        case "mp4", "mov", "m4v", "webm", "mkv": return "film"
        case "mp3", "wav", "m4a", "aac", "flac": return "waveform"
        case "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar": return "shippingbox"
        case "pdf": return "doc.richtext"
        case "json", "yml", "yaml", "toml", "xml", "plist": return "curlybraces"
        case "ts", "tsx", "js", "jsx", "swift", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "md", "txt", "log", "csv": return "doc.text"
        default:
            // No extension at all is usually `Makefile`, `Dockerfile`, `LICENSE`
            // — text, and worth the text glyph rather than the blank one.
            return (name as NSString).pathExtension.isEmpty ? "doc.text" : "doc"
        }
    }

    // MARK: - When nothing came back

    /**
     * The machine has not answered, and after six seconds saying so is more use
     * than spinning.
     *
     * It says *no answer*, not *that folder does not exist*, because this screen
     * genuinely cannot tell those apart: a refusal from the host is an `error`
     * frame that lands in the connection's own error path, not here. Both
     * remedies are on this card.
     */
    private var noAnswer: some View {
        ContentUnavailableView {
            Label("No answer from the machine", systemImage: "questionmark.folder")
        } description: {
            Text("It did not send anything back for \(asked). It may not have been able to read that folder.")
        } actions: {
            Button("Try again") { ask(asked) }
                .accessibilityIdentifier("files.retry")
            Button("Back to \((start as NSString).lastPathComponent)") { ask(start) }
                .accessibilityIdentifier("files.restart")
        }
    }
}
