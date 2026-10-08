import SwiftUI
import TerminalDeckNativeCore

/// The simple view's New app sheet. Catalogs and all server work are supplied
/// by its owner, including the existing approval and GitHub access paths.
struct NativeAppsNewAppView: View {
    let repositories: [NativeAppsRepository]
    let templates: [NativeAppsTemplate]
    let catalogLoading: Bool
    let catalogProblem: String?
    let busy: Bool
    let problem: String?
    let canChange: Bool
    let writesUnavailableReason: String?
    let onReloadCatalog: () -> Void
    let onCancel: () -> Void
    let onCreate: (NativeAppsDraft) -> Void

    @State private var draft = NativeAppsDraft()
    @State private var portText = "3000"
    @State private var addressNameEdited = false

    init(repositories: [NativeAppsRepository], templates: [NativeAppsTemplate],
         catalogLoading: Bool, catalogProblem: String?, busy: Bool, problem: String?,
         canChange: Bool = false, writesUnavailableReason: String? = nil,
         onReloadCatalog: @escaping () -> Void, onCancel: @escaping () -> Void,
         onCreate: @escaping (NativeAppsDraft) -> Void) {
        self.repositories = repositories
        self.templates = templates
        self.catalogLoading = catalogLoading
        self.catalogProblem = catalogProblem
        self.busy = busy
        self.problem = problem
        self.canChange = canChange
        self.writesUnavailableReason = writesUnavailableReason
        self.onReloadCatalog = onReloadCatalog
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    // The owning model sets busy synchronously before starting server work.
    // A second local latch can miss a fast repeated failure and stay locked.
    private var pending: Bool { busy }
    private var unavailableReason: String {
        let reason = writesUnavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Creating apps is turned off because safe recovery is not ready." : reason
    }
    private var currentDraft: NativeAppsDraft {
        var value = draft
        value.port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return value
    }

    private var selectedTemplate: NativeAppsTemplate? { templates.first { $0.id == draft.templateID } }
    private var formProblem: String? {
        if draft.source == .template, catalogLoading { return "Wait for the templates to finish loading." }
        if let message = currentDraft.validationMessage { return message }
        if draft.source == .template, selectedTemplate == nil { return "Choose an available template." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: "New app", blurb: canChange
                               ? "Choose where to start. You’ll review the server change before it runs."
                               : "Browse the choices for a new app.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)

            Form {
                if !canChange {
                    Section { NativeCodingAINotice(tone: .warn, text: unavailableReason) }
                }
                if let problem, !problem.isEmpty {
                    Section { NativeCodingAINotice(tone: .error, text: problem) }
                }
                Section {
                    NativeSettingRow(label: "App name", help: "What to call it in your app list.") {
                        TextField("My app", text: Binding(get: { draft.name }, set: updateName))
                            .labelsHidden()
                            .frame(minWidth: 200, maxWidth: 260)
                    }
                    NativeSettingRow(label: "Address name", help: "Part of its web address. Start with a lowercase letter and end with a letter or number.") {
                        TextField("my-app", text: Binding(get: { draft.appID }, set: {
                            addressNameEdited = true
                            draft.appID = $0
                        }), prompt: Text(draft.suggestedAppID.isEmpty ? "my-app" : draft.suggestedAppID))
                        .labelsHidden()
                        .frame(minWidth: 200, maxWidth: 260)
                    }
                }

                Section("Start from") {
                    ForEach(NativeAppsDraft.Source.allCases, id: \.self) { source in
                        NativeAppsSourceChoice(title: sourceTitle(source), symbol: sourceSymbol(source), on: draft.source == source) {
                            draft.source = source
                        }
                    }
                }

                sourceFields
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(pending)
            .onSubmit(create)

            HStack(spacing: 8) {
                if pending {
                    NativePageNote("Creating app…", busy: true)
                        .frame(maxHeight: 24)
                        .accessibilityAddTraits(.updatesFrequently)
                } else if canChange, let formProblem {
                    Text(formProblem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(canChange && problem == nil ? "Cancel" : "Back to apps", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(pending)
                Button(pending ? "Creating…" : "Create app", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending || !canChange || formProblem != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 640, height: 660)
        .interactiveDismissDisabled(pending)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New app")
        .onChange(of: templates.map(\.id)) { _, _ in reconcileTemplates() }
        .onChange(of: catalogLoading, initial: true) { _, _ in reconcileTemplates() }
    }

    @ViewBuilder private var sourceFields: some View {
        switch draft.source {
        case .github:
            Section("GitHub repository") {
                catalogState
                NativeSettingRow(label: "Repository", help: "Choose one you already have access to, or paste its GitHub HTTPS address.") {
                    VStack(alignment: .trailing, spacing: 8) {
                        if !repositories.isEmpty {
                            Menu("Your repositories") {
                                ForEach(repositories, id: \.id) { repository in
                                    Button(repository.name) { use(repository) }
                                }
                            }
                            .fixedSize()
                            .disabled(catalogLoading)
                        }
                        TextField("owner/repository", text: $draft.repository)
                            .labelsHidden()
                            .frame(minWidth: 200, maxWidth: 300)
                    }
                }
                NativeSettingRow(label: "Branch", help: "Usually main. Choose another branch if needed.") {
                    TextField("main", text: $draft.branch)
                        .labelsHidden()
                        .frame(minWidth: 200, maxWidth: 260)
                }
                NativeSettingRow(label: "App port", help: "The port your app listens on, often 3000.") {
                    TextField("3000", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
                NativeSettingsProse(text: "The server uses your existing GitHub access. Private repositories need access from that sign-in.")
            }
        case .template:
            Section("Template") {
                catalogState
                if templates.isEmpty {
                    if catalogLoading {
                        NativeSettingRow(label: "Template") {
                            Text("Loading available templates")
                                .redacted(reason: .placeholder)
                                .accessibilityHidden(true)
                        }
                    } else {
                        NativePageEmpty(symbol: "square.grid.2x2", title: "No templates available",
                                        action: catalogProblem == nil ? PageEmptyAction(label: "Check again", perform: onReloadCatalog) : nil) {
                            Text(catalogProblem == nil ? "The reviewed catalogue returned no templates." : "The template list has not been read successfully.")
                        }
                        .frame(minHeight: 180)
                    }
                } else {
                    NativeSettingRow(label: "Template") {
                        if templates.count == 1, let only = templates.first {
                            Text(only.name)
                        } else {
                            Picker("Template", selection: $draft.templateID) {
                                Text("Choose a template").tag("")
                                ForEach(templates, id: \.id) { template in
                                    Text(template.name).tag(template.id)
                                }
                            }
                            .labelsHidden()
                            .disabled(catalogLoading)
                        }
                    }
                    if let selectedTemplate, !selectedTemplate.description.isEmpty {
                        NativeSettingsProse(text: selectedTemplate.description)
                    }
                    if let selectedTemplate {
                        if let appLicense = selectedTemplate.applicationLicense, !appLicense.isEmpty {
                            NativeSettingsProse(text: "App license: " + appLicense)
                                .font(.caption)
                        }
                        if let appSource = NativeAppsRules.safeAddress(selectedTemplate.applicationSourceURL) {
                            Link("App source", destination: appSource).font(.caption)
                        }
                        if let credit = selectedTemplate.credit {
                            NativeSettingsProse(text: credit + (selectedTemplate.license.map { " · " + $0 } ?? ""))
                                .font(.caption)
                        }
                        if let source = NativeAppsRules.safeAddress(selectedTemplate.sourceURL) {
                            Link("Template source", destination: source).font(.caption)
                        }
                    }
                }
            }
        case .database:
            Section("Database") {
                NativeSettingRow(label: "Database", help: "Add a database for your apps on this server.") {
                    Picker("Database", selection: $draft.databaseEngine) {
                        Text("Postgres").tag("postgres")
                        Text("MySQL").tag("mysql")
                        Text("Redis").tag("redis")
                        Text("MongoDB").tag("mongodb")
                    }
                    .labelsHidden()
                }
                NativeSettingsProse(text: "You can manage backups and restore saved data from the app page.")
            }
        }
    }

    @ViewBuilder private var catalogState: some View {
        if catalogLoading {
            NativePageNote(draft.source == .github ? "Loading your repositories…" : "Loading templates…", busy: true)
                .frame(height: 28)
        }
        if let catalogProblem, !catalogProblem.isEmpty {
            NativeCodingAINotice(tone: .warn, text: catalogProblem)
            Button("Check again", action: onReloadCatalog)
                .disabled(catalogLoading)
        }
    }

    private func create() {
        guard canChange, !pending, formProblem == nil else { return }
        onCreate(currentDraft.normalized)
    }

    private func updateName(_ name: String) {
        draft.name = name
        if !addressNameEdited { draft.appID = draft.suggestedAppID }
    }

    private func reconcileTemplates() {
        guard !catalogLoading else { return }
        let ids = templates.map(\.id)
        guard !ids.contains(draft.templateID) else { return }
        draft.templateID = ids.count == 1 ? (ids.first ?? "") : ""
    }

    private func use(_ repository: NativeAppsRepository) {
        // Preserve the supplied host for validation. Choosing by owner/name
        // alone would turn an enterprise URL into a github.com deployment.
        draft.repository = repository.url.isEmpty ? repository.name : repository.url
        draft.branch = repository.defaultBranch.isEmpty ? "main" : repository.defaultBranch
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateName(repository.name.split(separator: "/").last.map(String.init) ?? repository.name)
        }
    }

    private func sourceTitle(_ source: NativeAppsDraft.Source) -> String {
        switch source {
        case .github: "GitHub repository"
        case .template: "Ready-made template"
        case .database: "Database"
        }
    }

    private func sourceSymbol(_ source: NativeAppsDraft.Source) -> String {
        switch source {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .template: "square.grid.2x2"
        case .database: "externaldrive"
        }
    }
}

/// The Store rail's native row pattern, with an SF Symbol instead of its count.
/// A candidate for the shared set; no additional colours or button style.
private struct NativeAppsSourceChoice: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if on { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(on ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
