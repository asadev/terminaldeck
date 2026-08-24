/**
 * The Mac's dev servers, on the phone, with a button that starts one.
 *
 * This is the answer to the thing the localhost list could never say. `ports`
 * lists what is *already* listening and `tunnel.open` puts one of those on this
 * phone; neither has ever had anything to offer for the far more common case —
 * the port is not there, because the dev server is not running, and the machine
 * it would run on is in another room. So the row for a project that is not
 * serving anything is not an absence any more, it is a Start button.
 *
 * ## Keyed by folder, because there is no such thing as *the* dev server
 *
 * A dev server is a script in one project's `package.json`, run in that
 * project's directory. A machine with four checkouts has four of them, or none,
 * and the port does not exist until the thing is up — which is the state this
 * whole feature exists to get out of. So the unit here is a **folder** the
 * desktop has granted this device, and the rows are in the order the desktop
 * offered them, most relevant first.
 *
 * ## Five states, five different things to draw
 *
 * | state | what the row says | the tap | the trailing control |
 * |---|---|---|---|
 * | `no-dev-script` | *nothing — there is no row* | – | – |
 * | `idle` | the command it would run | start it | **Start** |
 * | `starting` | the server's own latest line | open its session | a spinner |
 * | `ready` | `localhost:<port>` | open the page | open its session |
 * | `failed` | why, in the desktop's words | open its session | **Try again** |
 *
 * `no-dev-script` never becomes a row, and that is a rule rather than a
 * simplification: it means "there is nothing to press, and there never will be
 * for this folder". A row for one could only carry a button whose single
 * possible outcome is a refusal. `failed` is not folded into `idle` either — the
 * session that failed is still there with the reason printed in it, and the
 * useful thing to offer somebody is that session.
 *
 * ## While it is starting, something moves
 *
 * Asad, on this feature: *"if it's not [quick] then we can show some animation,
 * loading or 'activating'"*. That is the spinner, and under it the `note` — the
 * last line the server itself printed, pushed as it changes, so the wait shows
 * `installing dependencies` and then `compiling` rather than a bar that could be
 * doing anything. It is process output and it is drawn as text: `Text` has no
 * markup to be injected with, and `WireCodec.displayLine` has already taken the
 * control characters out so one line stays one line.
 *
 * ## There is no Stop button, and that is not an omission
 *
 * The dev server's session is an **ordinary session** — it is in the list
 * directly above this one, it can be attached to, read and Ctrl-C'd exactly like
 * any other. There is no stop verb on the wire because there is no separate kind
 * of process, and a Stop button here would have to invent one.
 */

import SwiftUI

/**
 * One project's dev server.
 *
 * Two hit targets at most, and only when they are two genuinely different
 * actions — the same shape `MachineRow` uses, and for the same reason: one of
 * them is the thing you came to do and the other is the thing you occasionally
 * need. Where a state has only one action the whole row is that action, rather
 * than a row that does nothing beside a button that does everything.
 */
struct DevServerRow: View {
    let report: DevServerReport
    /**
     * What this phone calls it, if anybody has said, instead of the folder's own
     * name.
     *
     * Only ever set on the localhost screen, where the port a `ready` server is
     * on may have been named — see `PortBook`. Nil everywhere else, which is the
     * normal state: the folder's last path component is what a person calls the
     * project and it comes from the machine rather than from a preference.
     */
    var name: String?
    /**
     * Whether this machine will also put a port on the phone.
     *
     * `devserver` and `localhost` are separate capabilities and genuinely come
     * apart, so a `ready` row on a machine offering only the first has an
     * address it cannot open. It says the address instead of drawing an Open
     * button that would refuse — a control that can only produce a refusal is
     * not a control.
     */
    let canTunnel: Bool
    let start: () -> Void
    let openPort: (Int) -> Void
    let openSession: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primary) {
                content
            }
            .accessibilityIdentifier("devserver.\(report.folder)")

            trailing
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - The body of the row

    private var content: some View {
        /*
         * Two alignments, and the nesting is what makes them possible.
         *
         * The glyph belongs beside the folder's **name**, so the inner stack is
         * top-aligned. The accessory — a pill, a spinner, a chevron — belongs
         * beside the **row**, so the outer stack is centred. Rendered with one
         * top-aligned stack for both, a `failed` row put its chevron level with
         * the title and its Try again button level with the middle of the card,
         * two controls at two heights for one row.
         */
        HStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // The app's row glyph — monoline at 19, in a 24-point column —
                // so a dev server sits in the same icon column as the ports it
                // is drawn among on the Browser tab. The one-point nudge that
                // used to be here went with the size: it existed to drop a
                // 15-point glyph onto a 16-point title's cap height, and a
                // 19-point one already meets it.
                Image(systemName: glyph)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name ?? Self.folderName(report.folder))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    // Mono where it is data — a command somebody would type, an
                    // address somebody would read off — and proportional where
                    // it is a sentence this app or the desktop wrote. The same
                    // line the rest of the app draws.
                    //
                    // Three lines for a failure and two for everything else: the
                    // desktop's sentence about *why* is the whole content of that
                    // row, and cutting it at "The comm…" — which is what two
                    // lines did to "The command exited" — leaves a row that says
                    // something went wrong and not what.
                    Text(detail)
                        .font(.system(size: 12, weight: .regular,
                                      design: detailIsData ? .monospaced : .default))
                        .foregroundStyle(detailTint)
                        .lineLimit(report.status == .failed ? 3 : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("devserver.detail.\(report.folder)")

                    // The server's own latest line, while it comes up. Only ever
                    // under a spinner, so it reads as progress rather than as a
                    // second permanent caption.
                    if report.status == .starting, let note = report.note {
                        Text(note)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("devserver.note.\(report.folder)")
                    }
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /**
     * What the row's own tap looks like, **inside** the button.
     *
     * Inside rather than beside it, and that is the whole reason this is split
     * from `trailing`. A pill that says Start, sitting outside the control that
     * starts things, is a dead click on the one word somebody will aim at — and
     * a dead click on a phone reads as a broken app rather than as a decoration.
     * Everything here is drawn by the button it belongs to; `trailing` holds only
     * the controls that do a genuinely *different* thing.
     */
    @ViewBuilder
    private var accessory: some View {
        switch report.status {
        case .idle:
            Pill(text: "Start", tone: .accent)

        case .starting:
            // The animation Asad asked for: *"if it's not [quick] then we can
            // show some animation, loading or 'activating'"*. It runs for as
            // long as the far machine says it is starting and stops when a
            // pushed state says otherwise — it is not a timer, so it cannot be
            // spinning over something that finished.
            ProgressView()
                .controlSize(.small)
                .tint(Theme.warning)
                .accessibilityIdentifier("devserver.spinner.\(report.folder)")

        case .ready:
            if canTunnel, report.port != nil {
                Pill(text: "Open", tone: .accent)
            } else if report.sessionId != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }

        case .failed:
            // With a session there is somewhere to go and read why, and Try
            // again is the deliberate second press beside it. With no session
            // nothing ever started, so another attempt is the only thing left
            // and the row itself is it.
            if report.sessionId == nil {
                Pill(text: "Try again", tone: .plain)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }

        case .noDevScript:
            EmptyView()
        }
    }

    /**
     * The second action, where there genuinely is one.
     *
     * Outside the row's button so it is its own hit target, in the shape
     * `MachineRow` uses. Only two states have one: a server that is up, whose
     * page and whose session are two different places worth reaching; and one
     * that failed with a session to read, where the row leads to the reason and
     * this offers another attempt.
     */
    @ViewBuilder
    private var trailing: some View {
        switch report.status {
        case .ready:
            // Only when the row's own tap is the *page*. Without a tunnel the
            // row already opens the session, and a second control doing the same
            // thing is the duplication he objected to on the desktop.
            if canTunnel, report.port != nil, let session = report.sessionId {
                Button {
                    openSession(session)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open the session running \(name ?? Self.folderName(report.folder))")
                .accessibilityIdentifier("devserver.session.\(report.folder)")
                .padding(.trailing, 4)
            }

        case .failed:
            // Not a Start button drawn as though nothing had happened — the row
            // leads to the failure — but a deliberate second press. `dev.start`
            // re-reads the folder from disk, so a `package.json` fixed since the
            // failure is picked up rather than the old answer being replayed.
            if report.sessionId != nil {
                Button(action: start) {
                    Text("Try again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("devserver.retry.\(report.folder)")
                .padding(.trailing, 6)
            }

        case .idle, .starting, .noDevScript:
            EmptyView()
        }
    }

    // MARK: - What each state does and says

    private func primary() {
        switch report.status {
        case .idle:
            start()
        case .starting:
            if let session = report.sessionId { openSession(session) }
        case .ready:
            if canTunnel, let port = report.port {
                // The tap *is* the consent, exactly as it is on a port row:
                // nothing on the machine was reachable until now, and closing
                // the page makes it unreachable again.
                openPort(port)
            } else if let session = report.sessionId {
                openSession(session)
            }
        case .failed:
            if let session = report.sessionId {
                openSession(session)
            } else {
                // Nothing ever started, so there is no session to read. The
                // sentence is already on the row and the only thing left to
                // offer is another attempt.
                start()
            }
        case .noDevScript:
            break
        }
    }

    /// The line under the name. Never the same sentence in two states, which is
    /// how a server that is coming up is told apart from one that is up.
    private var detail: String {
        switch report.status {
        case .idle:
            // The command rather than the word "idle": it is the thing about to
            // be run, and seeing it is how somebody notices the folder has a
            // `dev` script that does something other than what they expected.
            return report.command ?? "Not running"
        case .starting:
            return "Starting…"
        case .ready:
            // `url` is what the desktop composed; the port is the fallback,
            // because the address is the point of the row and a `ready` with no
            // url still has a proven port.
            return report.url ?? report.port.map { "localhost:\($0)" } ?? "Running"
        case .failed:
            return report.message ?? "That did not start."
        case .noDevScript:
            return ""
        }
    }

    /// Mono for the two states whose line is a literal — a command and an
    /// address — and proportional for the two whose line is prose.
    private var detailIsData: Bool {
        report.status == .idle || report.status == .ready
    }

    private var detailTint: Color {
        switch report.status {
        case .ready: return Theme.positive
        case .failed: return Theme.warning
        default: return Theme.faint
        }
    }

    private var glyph: String {
        switch report.status {
        case .idle: return "play.circle"
        case .starting: return "hourglass"
        case .ready: return "globe"
        case .failed: return "exclamationmark.triangle.fill"
        case .noDevScript: return "circle"
        }
    }

    private var tint: Color {
        switch report.status {
        case .idle: return Theme.secondary
        case .starting: return Theme.warning
        case .ready: return Theme.positive
        case .failed: return Theme.critical
        case .noDevScript: return Theme.faint
        }
    }

    /// The folder's own name. A full path does not fit on a phone row, and the
    /// last component is what a person calls the project — the same choice the
    /// desktop's `folderLabel` makes.
    ///
    /// One implementation, in `SessionDetails`, rather than a copy here: this
    /// row and the session sheet name the same folders, and two functions that
    /// must agree about what a project is called are two functions that will one
    /// day disagree about a Windows path.
    static func folderName(_ path: String) -> String {
        SessionDetails.folderName(path)
    }
}

/**
 * A small capsule label. Not a `Button` — the row it sits on is the button, and
 * a control inside a control is two hit targets for one action.
 */
private struct Pill: View {
    enum Tone { case accent, plain }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tone == .accent ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tone == .accent ? Theme.accent.opacity(0.15) : Theme.surfaceHigh,
                        in: Capsule())
    }
}
