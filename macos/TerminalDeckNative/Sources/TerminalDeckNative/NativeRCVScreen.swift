import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The Receiver (sidebar: Integrations → Receiver): everything that comes in — a
/// server, Sentry, WhatsApp, a CRM, GitHub, any webhook, or Terminal Deck's own
/// events — what came from where, which rule took it, where it went, and the
/// sources and rules that decide it.
///
/// Built like the Store page: a grey rail (Flow, Unrouted, Sources, Rules) beside
/// the content. The words come from `RCVPresentation` (Core); the calls are the
/// `receiver:<op>` channels (macos/round3/RCV.md).
struct NativeRCVScreen: View {
    @State private var model: NativeRCVModel

    init(model: NativeRCVModel = NativeRCVModel()) { _model = State(initialValue: model) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            NativeRCVRail(model: model)
                .frame(width: 200)
            Divider()
            NativeRCVContent(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $model.sheet) { sheet in
            NativeRCVSheetView(model: model, sheet: sheet)
        }
    }
}

/// The rail: the page's name, the four places with their counts, and the relay line.
private struct NativeRCVRail: View {
    let model: NativeRCVModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Receiver")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 8)
                .padding(.bottom, 12)
            ForEach(RCVPresentation.Place.allCases) { place in
                NativeRCVRailButton(title: place.title, symbol: place.symbol,
                                    count: model.overview.map { RCVPresentation.count(place, in: $0) },
                                    on: model.place == place) { model.go(place) }
            }
            Spacer(minLength: 16)
            if let overview = model.overview {
                Label {
                    Text(RCVPresentation.relayLine(connected: overview.relayConnected))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: overview.relayConnected ? "checkmark.circle" : "wifi.exclamationmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Receiver sections")
    }
}

/// The Store rail's button (NativeStoreScreen `RailButton`), with a grey symbol in front:
/// grey text, a light grey fill when chosen, never accent blue.
struct NativeRCVRailButton: View {
    let title: String
    var symbol: String? = nil
    var count: Int? = nil
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(title).font(.callout).foregroundStyle(on ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if let count {
                    Text("\(count)").font(.caption).foregroundStyle(Color.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(on ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What the content column shows: reading, a failure to read, or the chosen place.
private struct NativeRCVContent: View {
    let model: NativeRCVModel

    var body: some View {
        if model.overview == nil {
            if let error = model.error, !model.loading {
                NativePageEmpty(symbol: "exclamationmark.triangle", title: "The Receiver did not answer",
                                action: PageEmptyAction(label: "Try again", perform: { model.refresh() })) {
                    Text(error)
                }
            } else {
                NativePageNote("Reading the Receiver…", busy: true)
            }
        } else {
            switch model.place {
            case .flow, .unrouted: NativeRCVFlowPage(model: model)
            case .sources: NativeRCVSourcesPage(model: model)
            case .rules: NativeRCVRulesPage(model: model)
            }
        }
    }
}

/// One sheet at a time over the page.
private struct NativeRCVSheetView: View {
    let model: NativeRCVModel
    let sheet: NativeRCVSheet

    var body: some View {
        switch sheet {
        case .addSource:
            NativeRCVAddSourceSheet(model: model)
        case .reveal(let reveal, let help):
            NativeRCVRevealSheet(reveal: reveal, help: help, title: "The source’s secret") { model.openSheet(nil) }
        case .rule(let rule, let isNew):
            NativeRCVRuleEditor(model: model, original: rule, isNew: isNew)
        case .route(let eventID):
            NativeRCVRouteSheet(model: model, eventID: eventID)
        }
    }
}

// MARK: - Shared pieces

enum NativeRCVColors {
    /// Status colour, as the Hooks page: grey unless something needs a look.
    static func tone(_ tone: RCVPresentation.Tone) -> Color {
        switch tone {
        case .calm, .good: .secondary
        case .waiting, .attention: .orange
        case .bad: .red
        }
    }
}

/// A status word with its symbol, in its tone.
struct NativeRCVStatusLabel: View {
    let word: String
    let symbol: String
    let tone: RCVPresentation.Tone

    var body: some View {
        Label(word, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(NativeRCVColors.tone(tone))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Copy, then "Copied" for a moment (as the Tasks settings' copy button).
struct NativeRCVCopyButton: View {
    let value: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : label) {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setString(value, forType: .string)
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

/// A value in monospace with a quiet ground, selectable.
struct NativeRCVMonoBlock: View {
    let text: String
    var lineLimit: Int? = nil

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 6))
    }
}

/// The last action's failure or note, under the buttons that caused it.
struct NativeRCVActionLine: View {
    let model: NativeRCVModel

    var body: some View {
        if let error = model.actionError {
            NativeCodingAINotice(tone: .error, text: error)
        } else if let note = model.actionNote {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A section heading inside a page, as the Machines page's ("Your own devices").
struct NativeRCVHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The light grey selection of a list row (the sidebar's), with a hover tint.
struct NativeRCVPick: ViewModifier {
    let selected: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { hover = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sheets' bottom bar (the New app sheet's): a status on the left, the buttons on the right.
struct NativeRCVSheetBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// The secret, shown once: the secret and the address with it built in, each with
/// Copy, and the preset's sentence on where to paste them.
struct NativeRCVRevealSheet: View {
    let reveal: RCVSecretReveal
    let help: String
    let title: String
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: title, blurb: help)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                Section { NativeCodingAINotice(tone: .warn, text: RCVPresentation.revealWarning) }
                Section {
                    NativeRCVRevealRow(label: "Secret", help: "Paste it where the sender asks for a secret or a token.", value: reveal.secret)
                    if let address = reveal.addressWithSecret {
                        NativeRCVRevealRow(label: "Address with the secret built in",
                                           help: "For senders that only take an address. Keep it private: anyone with it can send.",
                                           value: address)
                    }
                }
            }
            .formStyle(.grouped)
            NativeRCVSheetBar {
                EmptyView()
            } trailing: {
                Button("I’ve copied it", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 600, height: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct NativeRCVRevealRow: View {
    let label: String
    let help: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                NativeRCVCopyButton(value: value)
            }
            NativeRCVMonoBlock(text: value, lineLimit: 3)
            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
