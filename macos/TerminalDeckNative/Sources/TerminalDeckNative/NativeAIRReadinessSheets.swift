import SwiftUI
import TerminalDeckNativeCore

struct NativeAIRFixReview: View {
    let preview: AIRReadinessFixPreview
    let working: Bool
    let operation: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NativeSettingsHead(title: "Review the fix", blurb: preview.summary)
                    NativePageScope(path: preview.projectPath)
                    Text(preview.title).font(.body.weight(.semibold))
                    ForEach(preview.changes) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(change.path).font(.body.monospaced().weight(.medium))
                                .textSelection(.enabled)
                            if let action = change.action {
                                NativeSettingsProse(text: action)
                            }
                            if let after = change.after {
                                if change.action?.localizedCaseInsensitiveContains("append") == true {
                                    content(label: "Lines to add", text: after, empty: "No lines will be added.")
                                } else {
                                    content(label: "Current content", text: change.before,
                                        empty: change.before == nil ? "This file does not exist yet." : "This file is empty.")
                                    content(label: "After the fix", text: after, empty: "The file will be empty.")
                                }
                            }
                        }
                        if change.id != preview.changes.last?.id { Divider() }
                    }
                    NativeSettingsProse(text: "Confirm to request approval for these changes. Terminal Deck will re-check the project after the fix.")
                }
                .padding(20)
            }
            .frame(maxHeight: 600)
            Divider()
            HStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                    Text(operation ?? "Applying the fix and re-checking…")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(working ? "Working…" : "Confirm fix", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 640, maxWidth: 640)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func content(label: String, text: String?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let text, !text.isEmpty {
                // Long file lines scroll inside this component, never the page.
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            } else {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeAIRSessionSheet: View {
    @Bindable var model: NativeAIRSessionModel
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NativeSettingsHead(title: "Ask an AI to do it", blurb: model.checkTitle)
                    NativePageScope(path: model.projectPath)
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if !model.loading, model.providers.isEmpty {
                            Button("Try again") { Task { await model.load() } }
                        }
                    }
                    if model.loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading your AI and login choices…")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    } else {
                        choices
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready prompt").font(.body.weight(.medium))
                        Text("Review or edit the directions before opening the session.")
                            .font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $model.prompt)
                            .font(.body.monospaced())
                            .frame(minHeight: 240, maxHeight: 340)
                            .accessibilityLabel("AI readiness prompt")
                            .disabled(model.starting)
                    }
                    NativeSettingsProse(text: "The AI receives this prompt in the selected project. It is asked to review changes with you and re-check the result.")
                }
                .padding(20)
            }
            .frame(maxHeight: 660)
            Divider()
            HStack(spacing: 10) {
                if model.starting {
                    ProgressView().controlSize(.small)
                    Text("Opening the AI session…").font(.callout).foregroundStyle(.secondary)
                } else if model.resolvingLogin {
                    ProgressView().controlSize(.small)
                    Text("Choosing the project login…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.starting)
                Button(model.starting ? "Starting…" : "Start AI session") { Task { await model.start() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canStart)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 640, maxWidth: 640)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.load() }
        .onChange(of: model.request?.provider) { _, _ in Task { await model.changedProvider() } }
        .onChange(of: model.request?.profileId) { _, _ in Task { await model.checkSignIn() } }
    }

    @ViewBuilder private var choices: some View {
        if let problem = model.resolution.problem {
            Text(problem).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.resolution.notices) { notice in
            Text(notice.message).font(.callout).foregroundStyle(.secondary)
        }
        if model.availableProviders.count > 1 {
            NativeSettingRow(label: "AI") {
                Picker("AI", selection: Binding(get: { model.request?.provider ?? "" }, set: { model.provider = $0 })) {
                    ForEach(model.availableProviders) { row in Text(row.label).tag(row.id) }
                }
                .labelsHidden().fixedSize().disabled(model.starting)
            }
        } else if let provider = model.activeProvider {
            NativeSettingRow(label: "AI") { Text(provider.label) }
        }
        if let notice = model.loginNotice {
            NativeSettingsProse(text: notice)
        } else if !model.accountOptions.isEmpty {
            NativeSettingRow(label: "Login", help: model.resolvingLogin ? "Finding the login for this project…" : NewSessionLogin.line(model.signIn)) {
                if model.accountOptions.count > 1 {
                    Picker("Login", selection: Binding(get: { model.request?.profileId ?? "" }, set: { model.profileID = $0 })) {
                        ForEach(model.accountOptions) { account in
                            Text(NewSessionLogin.optionLabel(account, selectedId: model.request?.profileId, report: model.signIn)).tag(account.id)
                        }
                    }
                    .labelsHidden().fixedSize().disabled(model.starting || model.resolvingLogin)
                } else if let account = model.activeAccount {
                    Text(NewSessionLogin.optionLabel(account, selectedId: account.id, report: model.signIn))
                }
            }
        } else if model.activeProvider != nil {
            NativeSettingRow(label: "Login") { Text("The agent's own login") }
        }
    }
}
