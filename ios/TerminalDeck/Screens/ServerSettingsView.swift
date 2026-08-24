/**
 * The "This server" section of Settings — the two settings this machine owns.
 *
 * The view half of `ServerSettingsLink`, and a port of the drawing in
 * `pwa/src/server-settings.ts`. It draws nothing at all over a machine whose
 * welcome did not name `settings` — an older desktop or a guest gets a Settings
 * screen exactly as it was, never a section explaining what it lacks. The value
 * shown is always the machine's own re-read, so a refused apply reverts by
 * construction; while an apply is in flight the pressed control reads "Working…".
 *
 * Self-contained so it can drop into `DeckSettingsView` without reaching that
 * file's private row components. Renders an `EmptyView` when there is nothing to
 * show, so a caller can place it unconditionally.
 */

import SwiftUI

struct ServerSettingsSection: View {
    let settings: ServerSettingsLink

    var body: some View {
        Group {
            if settings.offered {
                VStack(alignment: .leading, spacing: 0) {
                    Text("This server")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                        .padding(.top, 22)
                        .padding(.bottom, 8)

                    if let rows = settings.rows {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                                if index > 0 { Divider().background(Theme.hairline).padding(.leading, 16) }
                                switch row.key {
                                case .defaultProvider: providerRow(row)
                                case .restoreSessions: toggleRow(row)
                                }
                            }
                        }
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let notice = settings.notice {
                            Text(notice.text)
                                .font(.system(size: 12))
                                .foregroundStyle(notice.ok ? Theme.secondary : Theme.critical)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                                .padding(.top, 8)
                        }

                        Text("These belong to the machine, not this phone — every device that reaches it sees the same two.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                    } else {
                        Text("Reading this machine’s settings…")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.faint)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .onAppear { settings.ensureRead() }
                /*
                 * And again whenever a connection throws the rows away.
                 *
                 * `ServerSettingsLink.welcomed` nils them on **every** welcome —
                 * the machine on the other end can change — but `onAppear` does
                 * not fire a second time for a screen that never left. So a
                 * reconnect while somebody is standing on Settings left this
                 * section reading *"Reading this machine's settings…"* for the
                 * rest of that connection, and the read that was in flight when
                 * the socket went was dropped with the request id it was waiting
                 * on. One line, and the section catches up on its own.
                 */
                .onChange(of: settings.rows == nil) { _, unknown in
                    if unknown { settings.ensureRead() }
                }
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Rows

    private func providerRow(_ row: ServerSettingWire) -> some View {
        let working = settings.busy == row.key
        // The ids the host said it can start; if it sent none, the current value
        // is still offered so the control is never empty.
        let ids = (row.options?.isEmpty == false) ? row.options! : [row.value]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Default coding tool")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                if working {
                    Text("Working…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
            }
            FlowRow(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    let on = id == row.value
                    Button {
                        settings.apply(.defaultProvider, id)
                    } label: {
                        Text(ServerSettingsText.providerLabel(id))
                            .font(.system(size: 14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.onAccent : Theme.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? Theme.accent : Theme.surfaceHigh)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(working || on)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                    // By provider id rather than by label, because the label is
                    // a product's name and the id is the thing the wire and the
                    // machine both use. A walk that has just been told "choose a
                    // different one in its settings" has to be able to find the
                    // one it means.
                    .accessibilityIdentifier("serverSetting.provider.\(id)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /**
     * The switch, in three states rather than two.
     *
     * *"Ticked in one frame, unticked moments later, with no interaction
     * between them."* It had not toggled: this row used to read
     * `row.value == "true"`, which draws an empty circle — a definite **Off** —
     * for every value that is not that exact word, the empty string included.
     * See `ServerSettingWire.flag`.
     *
     * So an unknown value draws a dash and refuses the press. A control that
     * would send `apply` from a state it does not know is a control that can
     * turn a setting off by being tapped once while it was still catching up,
     * and this particular setting decides whether somebody's work comes back
     * after a restart.
     */
    private func toggleRow(_ row: ServerSettingWire) -> some View {
        let flag = row.flag
        let working = settings.busy == row.key
        return Button {
            guard let flag else { return }
            settings.apply(.restoreSessions, flag ? "false" : "true")
        } label: {
            HStack {
                Text("Restore sessions at launch")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                if working {
                    Text("Working…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                } else if let flag {
                    Image(systemName: flag ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(flag ? Theme.accent : Theme.faint)
                } else {
                    // Not a third icon: an icon is a state, and "not told" is
                    // the absence of one. A dash reads as a blank rather than as
                    // an answer.
                    Text("—")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working || flag == nil)
        .accessibilityIdentifier("settings.restoreSessions")
        .accessibilityValue(flag == nil ? "Not known yet" : (flag == true ? "On" : "Off"))
    }
}

/// A minimal wrapping row for the provider chips — a couple of chips that must
/// fall to a second line on a narrow phone rather than clip. Kept tiny and local
/// because it is the only place this section needs one.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
