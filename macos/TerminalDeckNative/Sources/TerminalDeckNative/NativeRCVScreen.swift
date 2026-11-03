import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeRCVScreen: View {
    @State private var model: NativeRCVModel
    private let remembersProjectFilter: Bool
    init(model: NativeRCVModel? = nil, section: String? = nil) {
        let resolved = model ?? NativeRCVModel()
        if let section { resolved.showSection(section) }
        _model = State(initialValue: resolved)
        remembersProjectFilter = model == nil
    }
    var body: some View {
        // SceneStorage is instantiated only for the production branch. Injected
        // fixtures never construct, read or write a scene persistence wrapper.
        if remembersProjectFilter {
            NativeRCVRememberedProjectFilter(model: model) { receiver }
        } else { receiver }
    }
    private var receiver: some View {
        NativeRCVPageShell(model: model, section: Binding(get: { model.section }, set: { model.showSection($0) })) {
            if model.overview == nil {
                if let error = model.error, !model.loading {
                    NativePageEmpty(symbol: "exclamationmark.triangle", title: "The Receiver did not answer", action: PageEmptyAction(label: "Try Again", autoRetry: true, perform: { model.refresh() })) { Text(error) }
                } else {
                    VStack(spacing: 12) {
                        ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(height: 98) }
                    }.redacted(reason: .placeholder).accessibilityLabel("Loading Receiver")
                }
            } else {
                switch model.section {
                case "Flow": NativeRCVFlowGraph(model: model)
                case "Events": NativeRCVEventsPage(model: model).frame(minHeight: 0, maxHeight: .infinity)
                case "Rules": NativeRCVRulesPage(model: model)
                default: NativeRCVSourcesPage(model: model)
                }
            }
        }
        .sheet(item: $model.sheet) { sheet in NativeRCVSheetView(model: model, sheet: sheet) }
    }
}

/// Page filter only, scoped to this window's scene. This does not change the
/// global active project or call a project-registry mutation.
private struct NativeRCVRememberedProjectFilter<Content: View>: View {
    let model: NativeRCVModel
    @ViewBuilder let content: () -> Content
    @SceneStorage("receiver.projectFilter") private var rememberedProjectID = ""
    init(model: NativeRCVModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model; self.content = content
    }
    var body: some View {
        content()
            .onAppear {
                // Empty is All projects; the nonempty Independent id stays distinct.
                model.projectFilter = rememberedProjectID.isEmpty ? nil : rememberedProjectID
                model.start()
            }
            .onChange(of: model.projectFilter) { _, selected in rememberedProjectID = selected ?? "" }
            .onDisappear { model.stop() }
    }
}

/// Temporary adapter with the shared DeckPage contract; one shell seam changes at READY GLITCH.
struct NativeRCVPageShell<Content: View>: View {
    @Bindable var model: NativeRCVModel
    @Binding var section: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        DeckPage(title: "Receiver", subtitle: "\(model.overview?.eventCount ?? 0) events · \(model.overview?.unrouted ?? 0) not routed", scrolls: section != "Events",
                 switcher: { GlassSwitch(selection: $section, items: ["Flow", "Events", "Sources", "Rules"].map { DeckSwitchItem(id: $0, title: $0) }) },
                 actions: {
                    HStack(spacing: 8) {
                        ProjectPicker(projects: model.projects, selection: $model.projectFilter, openProject: { AppModel.shared.openProject() })
                        Button { model.openSheet(.addSource) } label: { Label("Add source", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    }
                 }) { content() }
    }
}

/// One sheet at a time over the page.
struct NativeRCVSheetView: View {
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
