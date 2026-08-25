/**
 * The session's control cluster on a phone — model, effort, fast mode,
 * permission — as a sheet raised from the terminal.
 *
 * The view half of `SessionControlsLink`, and a port of the drawing in
 * `pwa/src/session-controls.ts`. A chip shows a control's current value; tapping
 * it opens the rows underneath. The ticked row is whatever the far end re-read
 * after the change settled, so a refused apply reverts by construction; a
 * failure keeps its sentence, a confirmation clears itself.
 *
 * ## A blocked chip opens onto its rows, with the reason above them
 *
 * The rule stated most often about this surface used to be the opposite: *"a
 * blocked chip still opens — onto the far end's own sentence, never onto a dead
 * menu."* Asad opened Controls, tapped **Model**, and got a paragraph about
 * unsent text where the list of models should have been:
 *
 *   > *"they are also not control they are just descriptions which i dont want
 *   > always"*
 *
 * He is right, and the old rule was solving the wrong half of it. Prose instead
 * of a menu is not the cure for a dead menu; it is a second way of being one. A
 * sheet called **Controls** whose rows open onto descriptions is not a control
 * panel.
 *
 * So the rows are drawn whether or not the control is blocked — he opened Model
 * to pick a model, and the ticked row is worth seeing even in a moment he cannot
 * change it — and the reason rides above them as one short line. Two things had
 * to be true for that to be honest rather than merely tidier:
 *
 *  - Most blocks are no longer blocks. `agent-controls.ts` now *lifts* a draft
 *    at the far prompt, runs the command and types the draft back unsent, so the
 *    commonest reason a chip ever greyed out — the very one in his screenshot —
 *    simply does not arrive any more.
 *  - What is left is short. The far end sends a line rather than a paragraph for
 *    the four states it genuinely cannot clear: mid-turn, a dialog on screen, a
 *    prompt that cannot be read, and a draft too big to lift. A desktop that has
 *    not been updated yet still sends its old paragraph, and this draws it — the
 *    length is the far end's to fix, and the rows are here either way.
 *
 * Blocked rows are drawn but not pressable, because a press would be answered
 * with a refusal, and that is the dead click this app is repeatedly audited for.
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
        // One question, asked once: why this control cannot be changed at this
        // instant. It decides the chip's colour, the line above the rows and
        // whether the rows are pressable — never whether they are drawn.
        let blocked = SessionControls.blocked(control, reading)
        let working = controls.busy == control || (control == .model && controls.busy == .fast)
        let isOpen = open == control
        // The value first and the reason after it, because the value is what the
        // chip is for; a reader who wants only the state should not have to sit
        // through a sentence to reach it. Built here rather than inline so the
        // view builder is handed a plain String.
        let head = "\(ControlCatalog.name(control)): \(SessionControls.chipText(control, reading))"
        let spoken = blocked.map { "\(head). \($0)" } ?? head
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
            // A chip mid-change is genuinely disabled — there is a change in
            // flight and a second one would queue behind it — unless it is the
            // one working. This is the only state where the chip itself refuses
            // to open; a blocked chip opens, onto rows it cannot press.
            .disabled(controls.busy != nil && !working)
            .accessibilityLabel(spoken)

            if isOpen {
                Divider().background(Theme.hairline)
                // The reason above the rows, never in their place. See the note
                // at the top of this file for why that swapped round.
                if let blocked { reasonLine(blocked) }
                ForEach(ControlCatalog.rows(for: control)) { option in
                    if let group = option.group { caption(group) }
                    optionRow(control, option,
                              current: SessionControls.chosen(reading.reading(control), option),
                              usable: blocked == nil)
                }
                if control == .model { fastSection(reading, alreadySaid: blocked) }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// One option. `usable` false draws it and refuses the press: the row is
    /// still worth reading — it is where the tick is — and a press that would
    /// only be answered with a refusal is the dead click this app is audited for.
    private func optionRow(_ control: ControlName, _ option: ControlOption, current: Bool, usable: Bool = true) -> some View {
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
                        .foregroundStyle(usable ? Theme.primary : Theme.faint)
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
        .disabled(!usable)
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }

    /// The one short line a block gets, above the rows it does not replace.
    ///
    /// Deliberately quieter than the rows and deliberately not styled as an
    /// error: nothing has failed, and every state that reaches here — a turn in
    /// flight, a dialog on screen, an account without the credits for fast mode
    /// — is a fact about right now rather than about this control.
    private func reasonLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.faint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fast mode, at the end of the model sheet: a switch when its state has
    /// been read, and the two rows under a caption when nothing has said which
    /// it is — never a switch at a position nobody established.
    ///
    /// A block used to replace all of that with the far end's sentence, which is
    /// the same fault the chips above had and is fixed the same way: the reason
    /// goes above the control, the control stays on screen showing what is in
    /// force, and it does not accept a press. *"Fast mode requires usage
    /// credits"* is worth reading beside a switch that says Off; it is not worth
    /// reading instead of one.
    ///
    /// `alreadySaid` is the model chip's own reason, and it is passed in for one
    /// case: the session's typing gate blocks all four controls at once, so
    /// without it a mid-turn model sheet would print *"This session is
    /// mid-turn."* twice, a few rows apart, about the same session. An account
    /// refusal that belongs only to fast mode is never the same string, so it
    /// still gets its line.
    @ViewBuilder
    private func fastSection(_ reading: ControlsReadingWire, alreadySaid: String?) -> some View {
        let fast = reading.fast
        let barred = SessionControls.blocked(.fast, reading)
        caption(ControlCatalog.name(.fast))
        if let barred, barred != alreadySaid { reasonLine(barred) }
        if fast.value == "on" || fast.value == "off" {
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
                            .foregroundStyle(on && barred == nil ? Theme.accent : Theme.faint)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(barred != nil || (controls.busy != nil && controls.busy != .fast))
        } else {
            ForEach(ControlCatalog.fast) { option in
                optionRow(.fast, option, current: false, usable: barred == nil)
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
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
