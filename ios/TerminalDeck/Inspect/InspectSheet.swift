/**
 * What was tapped while inspecting, and the one line about to be handed to an
 * agent.
 *
 * The phone's `CapturePanel`. Same capture, same `composeSend`, same string on
 * the wire — three things are different, and each one is a fact about a phone
 * rather than a design preference:
 *
 *  - **It is a sheet, not a footer.** The desktop's panel sits under a native
 *    `WebContentsView` that nothing in its React tree can paint over. Here the
 *    page is a `WKWebView` in the same window, so a sheet is free — and a medium
 *    detent leaves the highlighted element visible above it, which a footer on a
 *    phone-sized screen would not.
 *  - **There is a target picker.** The desktop sends to the focused session
 *    because it has one. This screen was opened from a list, so the session is
 *    named rather than assumed, and the name is on screen before Send is pressed.
 *  - **There is a way to correct the target element.** A fingertip has no
 *    hover and no second, more precise gesture; the tap lands on whatever wrapper
 *    is topmost. Walking up the ancestor chain is the correction — see
 *    `InspectScript`.
 */

import SwiftUI

struct InspectSheet: View {
    let capture: ElementCapture
    /// Every session this line could be typed into. Empty is a real state: the
    /// Mac may have nothing running.
    let targets: [RemoteSession]
    /// The chosen session, or nil when there is nothing to choose.
    @Binding var target: String?
    /// Walk the ancestor chain: +1 towards the document, -1 back to the tap.
    let step: (Int) -> Void
    /// Hand over the finished line. Returns the sentence to show.
    let send: (String, String) -> String
    let dismiss: () -> Void

    @State private var instruction = ""
    @FocusState private var typing: Bool

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
        .preferredColorScheme(.dark)
    }

    // MARK: - What was tapped

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(capture.tag.isEmpty ? "element" : "<\(capture.tag)>")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 0)
            }

            // Selectable, because the most useful thing to do with a selector
            // that is *nearly* right is to copy it and fix it by hand.
            Text(capture.selector)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("inspect.selector")

            if !capture.label.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let source = Inspect.describeLabelSource(capture.labelSource)
                    if !source.isEmpty {
                        Text(source)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    Text(capture.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
                .accessibilityIdentifier("inspect.label")
            }

            Text(capture.url)
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
            .disabled(capture.ancestors == 0)
            .accessibilityIdentifier("inspect.wider")

            Button {
                step(-1)
            } label: {
                Label("Narrower", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(capture.depth == 0)
            .accessibilityIdentifier("inspect.narrower")

            Spacer(minLength: 0)

            if capture.depth > 0 {
                Text(capture.depth == 1 ? "1 level up" : "\(capture.depth) levels up")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
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
                Text(Inspect.composeSend(context: capture.context, instruction: instruction))
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

    @State private var sent = false

    private func hand() {
        guard let target else { return }
        _ = send(Inspect.composeSend(context: capture.context, instruction: instruction), target)
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
