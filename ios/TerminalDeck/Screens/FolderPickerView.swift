/**
 * Walking the machine's folders on a phone, to start a session in one.
 *
 * > *"it is not giving me the option to choose the folder as well."*
 *
 * Said on an iPhone against a rented Linux server with nothing open on it. The
 * complaint is exactly right and the cause was not permission: one of the
 * owner's own devices has been allowed to start a session in **any** absolute
 * folder since device kinds arrived — `deviceReach` answers `unrestricted: true`
 * for it — and `welcome.folders` is a *suggestion* for that device rather than a
 * boundary. On a bare server the suggestion is one row, the account's home,
 * because nothing is open and nothing is running.
 *
 * So the phone could already start a session anywhere. What it had no way to do
 * was find out what was there. This screen is that one missing answer: it reads
 * directory names off the machine and hands the chosen path to the ordinary
 * `create`. It grants nothing and changes nothing.
 *
 * ## Why not a text field
 *
 * It was the obvious cheap answer and it is the wrong one. Typing
 * `/root/projects/api` on a phone keyboard, correctly, with no completion and no
 * way to see what is actually there, is a worse experience than the one being
 * fixed — and the first typo comes back as *that folder is not on this machine
 * any more*, which reads as a bug in the app. Somebody reaching for a folder on
 * a machine they cannot see needs to be shown what is on it.
 *
 * ## Unreadable folders are drawn, not hidden
 *
 * `/root` is on every Linux listing and openable by nobody but root. Dropping
 * the rows this account cannot enter would mean somebody looking for a folder
 * they know is there, not finding it, and going to look for a bug in the picker.
 * They are drawn dimmed with a lock, and they do not respond — the machine
 * carries `readable` on every row for exactly this.
 *
 * ## One tap means *go in*, and starting is a separate press
 *
 * A row that both descended and started would make every mis-tap a session on a
 * machine somewhere. Tapping a folder walks into it; the button at the bottom
 * starts a session in the folder you are standing in, and it names that folder.
 */

import SwiftUI

/**
 * What the button at the bottom is about to do, in the caller's terms.
 *
 * The screen's own note already says it *"does not know whether it is starting
 * one or picking a working directory for something else"* — and until the
 * copilot's setup existed, every caller was starting one, so the button could
 * say so. `CopilotControlView` is the first caller that is not: it asks which
 * folder the copilot should work in and stores the answer, and a button reading
 * *Start in ClaudeAsad* there would promise a session that is not started.
 *
 * Two cases rather than a free-form string, so the wording is decided here with
 * the button rather than at each call site — the failure a `verb: String`
 * parameter produces is three callers spelling three slightly different verbs
 * into the one control on the screen.
 */
enum FolderPickerAction: Equatable {
    /// A session begins in the chosen folder as soon as the callback returns.
    case start
    /// The path is the answer, and the caller keeps it. Nothing runs.
    case choose

    /// `name` is the folder's last component, empty at the root of a walk.
    func label(folder name: String) -> String {
        switch self {
        case .start: return name.isEmpty ? "Start here" : "Start in \(name)"
        case .choose: return name.isEmpty ? "Use this folder" : "Use \(name)"
        }
    }
}

struct FolderPickerView: View {
    @Bindable var model: DeckModel

    /// What pressing the button will do, which decides what it says. Defaulted
    /// to `.start` because that is what every caller but the copilot's setup
    /// does, and a default keeps those call sites unchanged.
    var action: FolderPickerAction = .start

    /// Called with the folder somebody chose. The caller starts the session —
    /// this screen does not know whether it is starting one or picking a
    /// working directory for something else.
    let chose: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Choose a folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("folders.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) { startBar }
        }
        // Asked for on appear rather than by the caller, so every way in — the
        // menu, the empty state — lands on a screen that is already loading
        // rather than on one that needs a second press to fill.
        .onAppear { if model.current?.browsed == nil { model.current?.browseFolders(nil) } }
        // The listing belongs to the screen, not to the connection: leaving with
        // it still set would show the last folder somebody walked to when the
        // picker is opened again an hour later, under a heading that may no
        // longer be true.
        .onDisappear { model.current?.endBrowsing() }
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let problem = model.current?.browseError {
            unavailable(problem)
        } else if let listing = model.current?.browsed {
            rows(listing)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rows(_ listing: FolderListing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Where you are, in full. The button at the bottom names the
                // folder it will start in, but it names the last component only
                // — this is the line that says which `web` you are standing in.
                Text(listing.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("folders.here")

                VStack(spacing: 0) {
                    if let parent = listing.parent {
                        row(name: "..",
                            icon: "arrow.turn.left.up",
                            dimmed: false,
                            trailing: nil,
                            id: "folders.up") {
                            model.current?.browseFolders(parent)
                        }
                        divider
                    }

                    if listing.entries.isEmpty {
                        Text("No folders in here.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                    }

                    ForEach(Array(listing.entries.enumerated()), id: \.element.id) { index, entry in
                        row(name: entry.name,
                            icon: entry.readable ? "folder" : "lock",
                            dimmed: !entry.readable,
                            trailing: entry.granted ? "Shared" : nil,
                            // By path: two projects called `web` under different
                            // parents are one name and two rows.
                            id: "folders.row.\(entry.path)") {
                            model.current?.browseFolders(entry.path)
                        }
                        if index < listing.entries.count - 1 { divider }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 46)
    }

    private func row(
        name: String,
        icon: String,
        dimmed: Bool,
        trailing: String?,
        id: String,
        tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(dimmed ? Theme.faint : Theme.secondary)
                    .frame(width: 24)
                Text(name)
                    .font(.system(size: 16))
                    .foregroundStyle(dimmed ? Theme.faint : Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                if !dimmed {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A folder this account cannot open does not respond. The row is here so
        // that somebody looking for it finds it rather than concluding the
        // picker is broken; it is not here to be pressed.
        .disabled(dimmed)
        .accessibilityIdentifier(id)
    }

    // MARK: - Start

    /**
     * Start in the folder on screen, named on the button.
     *
     * Pinned to the bottom rather than put in the toolbar because it is the
     * screen's one action and a thumb is at the bottom of a phone. It carries
     * the folder's own name so that pressing it is a decision about a folder
     * rather than about a screen.
     */
    @ViewBuilder
    private var startBar: some View {
        if let listing = model.current?.browsed {
            let name = (listing.path as NSString).lastPathComponent
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                Button {
                    chose(listing.path)
                    dismiss()
                } label: {
                    Text(action.label(folder: name))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .accessibilityIdentifier("folders.start")
            }
            .background(.bar)
        }
    }

    private func unavailable(_ problem: String) -> some View {
        ContentUnavailableView {
            Label("That folder could not be opened", systemImage: "folder.badge.questionmark")
        } description: {
            Text(problem)
        } actions: {
            // Back to the machine's own choice rather than retrying the folder
            // that just failed: the folder is the thing that did not work, and a
            // button whose only outcome is the same refusal is not a button.
            Button("Start again") { model.current?.browseFolders(nil) }
                .accessibilityIdentifier("folders.restart")
        }
    }
}
