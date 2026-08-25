/**
 * The six doors into a machine that the desktop has always had and the phone
 * did not: **Files, Source control, Artifacts, Store, AI readiness, MCP
 * servers**.
 *
 * > *"what about files, artifacts, source control, store, ai readiness, mcp
 * > servers in ios app too for server"*
 *
 * > *"all what i asked for so many times, i need all no exceptions."*
 *
 * All six, in one section, in the order he said them — because the order a
 * person asked for things in is the order they look for them in, and reordering
 * them by capability group would put Source control between Store and MCP for
 * no reason a reader could see.
 *
 * ## A section rather than a screen
 *
 * It is drawn on `MachineDetailView` today, which is the page about one machine.
 * It is a section and not a screen so the same six rows can also hang off a
 * server's page, or a session's folder, without a second copy of the list
 * drifting out of step with this one.
 *
 * ## Three capabilities gate six rows, and an absent row is the answer
 *
 * `files`, `git` and `panels` are all **owner-device only** on the host — a
 * guest holding them could read a private key out of a folder it was lent, or a
 * credential out of an MCP config. A phone that is not the owner's therefore
 * gets a shorter list, and that is the app working.
 *
 * A row is **not drawn** rather than drawn and refused, which is the rule every
 * gated control in this app follows: a button whose only outcome is a refusal
 * is not a button. The reason is not guessed at here either — `MachineDetailView`
 * prints the machine's own capability list a few sections up, so somebody
 * surprised by a missing row has the machine's answer rather than a hunch about
 * their own device kind.
 *
 * ## Why the two destinations come in as closures
 *
 * Files and Source control are their own screens, owned by their own lanes;
 * the four panels are `PanelView` and are built here. Taking the first two as
 * `@ViewBuilder` closures keeps this file from depending on the exact name and
 * initialiser of two screens being written beside it — the caller, which knows
 * both, says what to push. It is also the honest seam: this section owns *the
 * list and its gates*, not what is behind each row.
 */

import SwiftUI

struct MachineToolsSection<FilesDestination: View, SourceDestination: View>: View {
    let model: DeckModel
    /**
     * The folder the six doors open onto.
     *
     * `nil` is a real answer and not a missing one: a machine that has granted
     * this phone no folder still has a Store and a readiness check, and the host
     * answers `panel.read` with no path from its own default. Files and Source
     * control are the two that genuinely need one, and the closures that build
     * them decide what to do about it — they were handed the same value.
     */
    var path: String?

    @ViewBuilder let filesDestination: () -> FilesDestination
    @ViewBuilder let sourceDestination: () -> SourceDestination

    var body: some View {
        // Nothing at all when no door is open — not a caption over an empty
        // card, which reads as a section that failed to load.
        if model.canReadFiles || model.canReadGit || model.canReadPanels {
            caption
            card {
                if model.canReadFiles {
                    link("Files", icon: "folder", id: "files") { filesDestination() }
                }
                if model.canReadGit {
                    if model.canReadFiles { line }
                    link("Source control", icon: "arrow.triangle.branch", id: "git") { sourceDestination() }
                }
                if model.canReadPanels {
                    if model.canReadFiles || model.canReadGit { line }
                    panelLink("Artifacts", icon: "shippingbox", panel: .artifacts)
                    line
                    panelLink("Store", icon: "square.grid.2x2", panel: .store)
                    line
                    panelLink("AI readiness", icon: "checkmark.seal", panel: .readiness)
                    line
                    panelLink("MCP servers", icon: "point.3.connected.trianglepath.dotted", panel: .mcp)
                }
            }
        }
    }

    // MARK: - Rows

    /// One of the four panels, all of which are the same screen with a different
    /// id and a different word on the title bar. See `PanelView`.
    /// `PanelKind` rather than a string: a panel this build cannot draw becomes a
    /// compile error here rather than a refused frame, and a refused frame closes
    /// the socket — which reads to a person as the network dropping.
    private func panelLink(_ title: String, icon: String, panel: PanelKind) -> some View {
        link(title, icon: icon, id: panel.rawValue) {
            PanelView(panel: panel, title: title, model: model, path: path)
        }
    }

    /**
     * A row, at the settings screen's own two numbers.
     *
     * A `NavigationLink` with a destination rather than a routed value, which is
     * what `LocalhostListView` and `WatchView` already do for pushed screens
     * that no other surface deep-links to. Six new cases on
     * `DeckModel.SettingsRoute` would each need a `navigationDestination` arm
     * inside `DeckTabs`, and none of the six is ever pushed from anywhere but
     * this list.
     */
    private func link<Destination: View>(
        _ title: String,
        icon: String,
        id: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                /*
                 * Monoline: 19 points at light weight in a 24-point column.
                 * SF Symbols' default is regular at 15, which is what every iOS
                 * app that has not thought about it looks like — the exact
                 * complaint. `SettingsRowBody` carries the full argument.
                 */
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("machine.tools.\(id)")
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed: `SectionCaption`, `SettingsGroup` and
     * `SettingsDivider` are **private to `DeckTabs.swift`**, so a screen that
     * reached for them would have to live in that file — the argument
     * `AppLockScreen` and `MachineDetailView` both make about the same three
     * names. Same metrics: an 11pt kerned caption, a `Theme.surface` card at
     * radius 20, and a hairline inset to the label.
     *
     * 52 here rather than `MachineDetailView`'s 16, and it is arithmetic: these
     * rows have an icon column, so the words start at 16 + 24 + 12. A line at 16
     * would cut through the gutter the icons stand in.
     */
    private var caption: some View {
        HStack(spacing: 4) {
            Text("LOOK INSIDE")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
            // The one sentence this section is allowed, and it is behind the ⓘ:
            // *"I don't want any kind of long descriptions anywhere."* It earns
            // its place because read-only is the non-obvious half — six rows
            // that look like the desktop's panels, none of which will change
            // anything on the machine.
            InfoDot(
                about: "Look inside",
                text: "Everything here is read-only. These six read the machine — its folders, "
                    + "what git says, and its four panels — and none of them change anything on it."
            )
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }
}
