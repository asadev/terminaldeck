/**
 * What was pointed at, and the one line about to be handed to an agent.
 *
 * ## One sheet, both browsers — which is the requirement, not a saving
 *
 * > *"in the page, if I click on something, I don't have something to, some
 * > option to specifically inspect one piece. Here I also don't have. And then in
 * > the own, in the own this phone page, we have it, but we don't have the rest
 * > of the options here… So everything should, all of them should be identical,
 * > and all of them should have all the options. Should not be that much of
 * > difference in all of them."*
 *
 * There are two ways an element reaches this screen and they have nothing in
 * common underneath:
 *
 *  - **a page on this phone** — `InspectScript` runs inside a real `WKWebView`,
 *    catches the touch before the page sees it, and `Inspect.parseCapture` works
 *    the selector out here;
 *  - **a window on the machine** — the phone is watching pixels, so the tap is a
 *    point, the point goes over as `browser.window.pick`, and the machine's own
 *    browser answers with the facts.
 *
 * Both fill in one `InspectedElement`, and this file draws that. Answering him
 * with two sheets that merely look alike would be the same defect one round
 * later: they drift, and neither screenshot shows it.
 *
 * ## What is different from the desktop's own panel, and why each one is a fact
 *
 * The desktop's `CapturePanel` does the same job beside the page. Three things
 * differ here and none of them is a preference:
 *
 *  - **It is a sheet, not a footer.** The desktop's panel sits under a native
 *    `WebContentsView` that nothing in its React tree can paint over. Here the
 *    page is either a `WKWebView` in the same window or a picture on a canvas, so
 *    a sheet is free — and a medium detent leaves the element visible above it,
 *    which a footer on a phone-sized screen would not.
 *  - **There is a target picker.** The desktop sends to the focused session
 *    because it has one. This screen was opened from a list, so the session is
 *    named rather than assumed, and the name is on screen before Send is pressed.
 *  - **There is a way to correct the element.** A fingertip has no hover and no
 *    second, more precise gesture; the tap lands on whatever wrapper is topmost.
 *    Walking up the ancestor chain is the correction, and it is the same two
 *    words on both kinds of window — locally it re-runs `InspectScript`, on a
 *    machine window it re-asks with `up + 1`.
 */

import SwiftUI

struct InspectSheet: View {

    /// What was pointed at. One type, filled in by either browser — see the
    /// header, and `InspectedElement` for why the label's source is a word
    /// rather than one of this phone's own seven cases.
    let element: InspectedElement

    /// Every session this line could be typed into. Empty is a real state: the
    /// machine may have nothing running.
    let targets: [RemoteSession]

    /// The chosen session, or nil when there is nothing to choose.
    @Binding var target: String?

    /// Walk the ancestor chain: +1 towards the document, -1 back to the tap.
    let step: (Int) -> Void

    /// Hand over the finished line. Returns the sentence to show.
    let send: (String, String) -> String

    let dismiss: () -> Void

    /**
     * Whether a correction is in flight, for a window where the answer is a round
     * trip.
     *
     * False on the page this phone holds, always: `InspectScript` answers in the
     * same runloop turn and there is no moment to describe. On a machine window
     * Wider is a frame over a wire and back, and the values on screen do not move
     * until it lands — so without a line saying so, a press looks like a control
     * that did nothing and the next press sends a second ask.
     */
    var pending: Bool = false

    @State private var instruction = ""
    @FocusState private var typing: Bool
    @State private var sent = false

    init(element: InspectedElement,
         targets: [RemoteSession],
         target: Binding<String?>,
         step: @escaping (Int) -> Void,
         send: @escaping (String, String) -> String,
         pending: Bool = false,
         dismiss: @escaping () -> Void) {
        self.element = element
        self.targets = targets
        self._target = target
        self.step = step
        self.send = send
        self.pending = pending
        self.dismiss = dismiss
    }

    /**
     * The same sheet, handed the phone's own capture.
     *
     * An adapter on the way in rather than a second screen — `LocalhostBrowser`
     * holds an `ElementCapture` because that is what its inspector computes, and
     * making the tunnel browser build the shared value itself would be a change
     * to a file this work does not own. The conversion is `InspectedElement`'s
     * own initialiser, so there is exactly one place the two vocabularies meet.
     */
    init(capture: ElementCapture,
         targets: [RemoteSession],
         target: Binding<String?>,
         step: @escaping (Int) -> Void,
         send: @escaping (String, String) -> String,
         dismiss: @escaping () -> Void) {
        self.init(element: InspectedElement(capture),
                  targets: targets,
                  target: target,
                  step: step,
                  send: send,
                  pending: false,
                  dismiss: dismiss)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identity
                    ancestry
                    Divider().overlay(Theme.hairline)
                    ask
                }
                .padding(16)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Change this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("inspect.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - What was pointed at

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(element.tag.isEmpty ? "element" : "<\(element.tag)>")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 0)
            }

            // Selectable, because the most useful thing to do with a selector
            // that is *nearly* right is to copy it and fix it by hand.
            Text(element.selector)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("inspect.selector")

            if !element.label.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Printed as it stands, including a word this build has never
                    // seen. `PICK_LABEL_SOURCES` grows the day the machine's label
                    // rule learns a new fallback, and a chip that went blank on an
                    // unfamiliar one would be hiding the most useful half of the
                    // line — *where this name came from* is how somebody decides
                    // whether the element is the one they meant.
                    let source = Inspect.describeLabelSource(element.labelSource)
                    if !source.isEmpty {
                        Text(source)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    Text(element.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
                .accessibilityIdentifier("inspect.label")
            }

            Text(element.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /**
     * The correction.
     *
     * A tap on a phone lands on the topmost element, which on a modern site is
     * routinely a layout wrapper rather than the button somebody meant. Without
     * this the only recourse is to tap again and hope, so the two most useful
     * words on this sheet are Wider and Narrower.
     *
     * Both ends are read off the element rather than counted here, and on both
     * kinds of window they mean the same thing: `maxUp` is how many ancestors are
     * left above this one and `depth` is how far up from the tap it already is.
     * On a machine window those two numbers were counted by the page-side script
     * in the same pass that found the element, which is what makes greying Wider
     * at the top of the document exact rather than a guess — and what stops a
     * press walking onto nothing.
     */
    private var ancestry: some View {
        HStack(spacing: 10) {
            Button {
                step(1)
            } label: {
                Label("Wider", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(!element.canGoWider || pending)
            .accessibilityIdentifier("inspect.wider")

            Button {
                step(-1)
            } label: {
                Label("Narrower", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(!element.canGoNarrower || pending)
            .accessibilityIdentifier("inspect.narrower")

            Spacer(minLength: 0)

            if pending {
                // Only where an answer is a round trip. See `pending`.
                Text("Asking the machine\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .accessibilityIdentifier("inspect.waiting")
            } else if let line = element.depthLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .accessibilityIdentifier("inspect.depth")
            }
        }
    }

    // MARK: - What to do about it

    private var ask: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What should the agent do with it?", text: $instruction, axis: .vertical)
                .lineLimit(1 ... 4)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(hand)
                .accessibilityIdentifier("inspect.instruction")
                .accessibilityLabel("Instruction for the agent")

            targetRow

            Button(action: hand) {
                Text(sent ? "Sent" : "Send to agent")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(target == nil)
            .accessibilityIdentifier("inspect.send")

            if target == nil {
                // The desktop says this in a tooltip. A phone has no tooltips, so
                // it is a line — and it is the honest one: the button is not
                // broken, there is nowhere for the line to go.
                Text("Open a session to send this to.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            // The exact string, before it is sent. On the desktop the agent's own
            // pane shows what landed a moment later; here the terminal is a
            // screen away, so this is the only chance to read it.
            DisclosureGroup("What the agent will receive") {
                Text(Inspect.composeSend(context: element.context, instruction: instruction))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .accessibilityIdentifier("inspect.preview")
            }
            .font(.system(size: 12))
            .tint(Theme.faint)
        }
    }

    @ViewBuilder
    private var targetRow: some View {
        if targets.count > 1 {
            HStack(spacing: 8) {
                Text("Send to")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                Menu {
                    ForEach(targets) { session in
                        Button {
                            target = session.id
                        } label: {
                            Label(session.title, systemImage: session.id == target ? "checkmark" : "terminal")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(targetName)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .accessibilityIdentifier("inspect.target")
                Spacer(minLength: 0)
            }
        } else if let name = targets.first?.title {
            Text("Send to \(name)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .accessibilityIdentifier("inspect.target")
        }
    }

    private var targetName: String {
        targets.first { $0.id == target }?.title ?? "Pick a session"
    }

    private func hand() {
        guard let target else { return }
        _ = send(Inspect.composeSend(context: element.context, instruction: instruction), target)
        instruction = ""
        sent = true
        typing = false
        // Dismissed rather than left up saying "Sent". On the desktop the panel
        // is a footer beside the page and costs nothing to leave open; here it is
        // covering half the thing that was just described, and the next thing
        // anybody wants is to look at the page again — or tap the next element,
        // which needs the sheet gone.
        dismiss()
    }
}
