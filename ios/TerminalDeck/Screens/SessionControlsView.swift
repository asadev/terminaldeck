/**
 * The session's control cluster on a phone — model, effort, fast mode,
 * permission — as a sheet raised from the terminal.
 *
 * The view half of `SessionControlsLink`, and a port of the drawing in
 * `pwa/src/session-controls.ts`. A chip shows a control's current value; tapping
 * it opens the rows underneath. A blocked chip *still opens* — onto the far
 * end's own sentence, never onto a dead menu, which is the rule stated most
 * often about this surface. The ticked row is whatever the far end re-read after
 * the change settled, so a refused apply reverts by construction; a failure
 * keeps its sentence, a confirmation clears itself.
 *
 * Fast mode lives at the end of the model sheet — where the desktop keeps it —
 * because the CLI couples them: switching model turns fast mode off.
 *
 * The sheet is only ever raised when `SessionControls.clusterShown` is true (a
 * live session with an agent drawing it); a plain shell gets no button, the same
 * way the desktop withdraws its own cluster over `/bin/zsh`.
 */

import SwiftUI

struct SessionControlsView: View {
    let controls: SessionControlsLink
    let dismiss: () -> Void

    /// Which chip's rows are open. `fast` is never here — its switch lives in the
    /// model sheet.
    @State private var open: ControlName?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                Group {
                    if let reading = controls.reading, SessionControls.clusterShown(reading) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                chip(.model, reading)
                                chip(.effort, reading)
                                chip(.permission, reading)
                                if let notice = controls.notice { noticeRow(notice) }
                            }
                            .padding(16)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    } else {
                        // The session went quiet, exited, or is a plain shell —
                        // nothing honest to show, so the sheet says so rather
                        // than drawing empty chips.
                        ContentUnavailableView("No controls here",
                                               systemImage: "slider.horizontal.3",
                                               description: Text("This session has no agent to set a model, effort or permission on."))
                    }
                }
            }
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                        .accessibilityIdentifier("controls.done")
                }
            }
        }
    }

    // MARK: - One chip and its rows

    @ViewBuilder
    private func chip(_ control: ControlName, _ reading: ControlsReadingWire) -> some View {
        let blocked = SessionControls.blocked(control, reading)
        let working = controls.busy == control || (control == .model && controls.busy == .fast)
        let isOpen = open == control
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open = isOpen ? nil : control
            } label: {
                HStack(spacing: 10) {
                    Text(ControlCatalog.name(control))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Text(working ? "Working…" : SessionControls.chipText(control, reading))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(blocked == nil ? Theme.primary : Theme.faint)
                        .lineLimit(1)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            // A chip mid-change is genuinely disabled — there is a queue behind
            // it, not a sentence to open onto — unless it is the one working.
            .disabled(controls.busy != nil && !working)
            .accessibilityLabel(blocked ?? "\(ControlCatalog.name(control)): \(SessionControls.chipText(control, reading))")

            if isOpen {
                Divider().background(Theme.hairline)
                if let blocked {
                    // Never a dead menu: a blocked chip opens onto the reason.
                    Text(blocked)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(ControlCatalog.rows(for: control)) { option in
                        if let group = option.group { caption(group) }
                        optionRow(control, option, current: SessionControls.chosen(reading.reading(control), option))
                    }
                    if control == .model { fastSection(reading) }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func optionRow(_ control: ControlName, _ option: ControlOption, current: Bool) -> some View {
        Button {
            controls.apply(control, option.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark" : "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.primary)
                    if let hint = option.hint {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }

    /// Fast mode, at the end of the model sheet: the far end's sentence when
    /// barred, a switch when its state has been read, and the two rows under a
    /// caption when nothing has said which it is — never a switch at a position
    /// nobody established.
    @ViewBuilder
    private func fastSection(_ reading: ControlsReadingWire) -> some View {
        let fast = reading.fast
        let barred = SessionControls.blocked(.fast, reading)
        caption(ControlCatalog.name(.fast))
        if let barred {
            Text(barred)
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if fast.value == "on" || fast.value == "off" {
            let on = fast.value == "on"
            Button {
                controls.apply(.fast, SessionControls.fastFlip(fast))
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ControlCatalog.name(.fast))
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.primary)
                        Text("off if you switch model")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 8)
                    if controls.busy == .fast {
                        Text("Working…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.faint)
                    } else {
                        // A real Toggle would fight the button; this is a
                        // read-only picture the whole row flips.
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(on ? Theme.accent : Theme.faint)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controls.busy != nil && controls.busy != .fast)
        } else {
            ForEach(ControlCatalog.fast) { option in
                optionRow(.fast, option, current: false)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.faint)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ notice: SessionControlsLink.Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(notice.text)
                .font(.system(size: 13))
                .foregroundStyle(notice.ok ? Theme.secondary : Theme.critical)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                controls.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
