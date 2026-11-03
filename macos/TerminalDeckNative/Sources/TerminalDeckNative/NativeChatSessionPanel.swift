import SwiftUI
import TerminalDeckNativeCore

/// ⓘ Session (Asad, 20 Oct 2026, after Claude Code's side panel): one panel, a collapsible section per job, each remembered
/// open or closed. The lists are the chat's existing panels; a tool that opens one of them opens this panel at that list.
enum NativeChatSessionSection: String, CaseIterable, Identifiable {
    case environment, context, connections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .environment: "Environment"
        case .context: "Context"
        case .connections: "Connections"
        }
    }
}
/// The lists that fold out under a section's rows.
enum NativeChatSessionList: String, CaseIterable, Identifiable {
    case sources, excerpt, mentions, servers, skills
    var id: String { rawValue }
    var section: NativeChatSessionSection { self == .servers || self == .skills ? .connections : .context }
    var title: String {
        switch self {
        case .sources: "Instructions & sources"
        case .excerpt: "Open file excerpt"
        case .mentions: "Mentions"
        case .servers: "MCP servers"
        case .skills: "Skills"
        }
    }
    /// Whether a tool asked for this list, through its old panel's flag.
    @MainActor func asked(in model: NativeHootChatModel) -> Bool {
        switch self {
        case .sources: model.chatSourcesVisible || model.chatArtifactsVisible
        case .excerpt: model.chatEditorContextVisible
        case .mentions: model.chatFeaturePanels.contains("mentions")
        case .servers: model.chatConnectionsVisible || model.chatFeaturePanels.contains("mcp")
        case .skills: model.chatSkillsVisible
        }
    }
}
enum NativeChatSession {
    /// Folded open before anything is remembered: the three sections, no lists.
    static let defaultOpen = NativeChatSessionSection.allCases.map(\.rawValue).joined(separator: ",")
    /// The provider session's servers that are not connected (Claude Code's "n to reconnect").
    static func reconnect(_ servers: NativeRPCValue) -> Int {
        (servers.elements ?? []).filter { !["connected", "pending", "disabled"].contains($0["status"].string ?? "") }.count
    }
    static func providerName(_ provider: String?) -> String? { provider.map { ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"][$0] ?? $0 } }
    @MainActor static func mode(_ model: NativeHootChatModel) -> String {
        if model.source.isHoot { return "Hoot, your assistant" }
        return model.replyAgent.map { "Agent · \($0.name)" } ?? "Chat"
    }
}

struct NativeChatSessionPanel: View {
    @Bindable var model: NativeHootChatModel
    /// What is folded open, remembered across chats and launches.
    @AppStorage("chat.sessionPanel.open") private var open = NativeChatSession.defaultOpen
    @State private var height: CGFloat = 0
    @State private var account: NativeRPCValue?
    @State private var folder: String?
    @State private var sources: NativeRPCValue?
    @State private var skills: Int?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                section(.environment, figure: nil) { environment }
                section(.context, figure: model.chatContextReading?.share.map { "\(Int($0.rounded()))% used" }) { context }
                section(.connections, figure: reconnect.flatMap { $0 > 0 ? "\($0) to reconnect" : nil }) { connections }
            }
            .padding(10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(width: 660, height: min(max(height, 120), 680))
        .onAppear(perform: focus)
        .onChange(of: NativeChatSessionList.allCases.filter { $0.asked(in: model) }) { _, _ in focus() }
        .task { await load() }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("AI", [NativeChatSession.providerName(account?["provider"].string ?? model.reportedChatProvider) ?? model.source.agentName,
                       account?["account"].string].compactMap { $0 }.joined(separator: " · "))
            row("Project folder", folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not reported")
            row("Mode", NativeChatSession.mode(model))
            row("Permissions", model.composerDraft.permissionMode.fullName)
        }
    }
    private var context: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let panel = model.chatContextReading?.panel(now: Date().timeIntervalSince1970 * 1000) { ContextSection(panel: panel) }
            else { Text("This conversation has not reported a current context reading yet.").font(.callout).foregroundStyle(.secondary) }
            row("Messages", "\(model.rows.filter { $0.kind == .user || $0.kind == .message }.count)")
            row("Instructions & sources", sources?["filesPresent"].elements.map { "\($0.count) files" } ?? "…")
            row("Tools & connections", "\(model.catalogue.tools.count) tools")
            row("Skills", skills.map { "\($0) installed" } ?? "…")
            row("Memory", sources.map { $0["memoryOwner"].string ?? "No assigned seat" } ?? "…")
            list(.sources, figure: nil) { NativeChatSourcesPanel(model: model) }
            list(.excerpt, figure: "\(NativeChatEditorContexts.shared.snapshots.count) open") { NativeChatEditorContextPanel(model: model) }
            list(.mentions, figure: "\(model.composerDraft.activeMentions.count) in draft") {
                NativeChatFeaturePanelView(model: model, feature: "mentions", title: "Mentions").padding(16).frame(width: 560)
            }
        }
    }
    private var connections: some View {
        let servers = model.chatProviderMCPServers.elements
        return VStack(alignment: .leading, spacing: 8) {
            list(.servers, figure: servers.map { "\($0.count) · \(reconnect ?? 0) to reconnect" } ?? "Not reported by the AI") { NativeChatConnectionsPanel(model: model) }
            list(.skills, figure: skills.map { "\($0) installed" }) { NativeChatSkillsView(model: model) }
        }
    }
    private var reconnect: Int? {
        let servers = model.chatProviderMCPServers
        return servers.elements == nil ? nil : NativeChatSession.reconnect(servers)
    }

    private func section<Content: View>(_ section: NativeChatSessionSection, figure: String?, @ViewBuilder content: () -> Content) -> some View {
        let expanded = isOpen(section.rawValue)
        return VStack(alignment: .leading, spacing: 0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Text(section.title).font(.headline)
                    Spacer()
                    if let figure { Text(figure).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.title + (figure.map { ", " + $0 } ?? ""))
            .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            if expanded.wrappedValue { content().padding([.horizontal, .bottom], 10) }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func list<Content: View>(_ list: NativeChatSessionList, figure: String?, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isOpen(list.rawValue)) { content() } label: {
            HStack {
                Text(list.title)
                Spacer()
                if let figure { Text(figure).monospacedDigit().foregroundStyle(.secondary) }
            }.font(.callout)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(get: { open.split(separator: ",").contains(Substring(key)) }, set: { on in
            var keys = Set(open.split(separator: ",").map(String.init))
            if on { keys.insert(key) } else { keys.remove(key) }
            open = keys.sorted().joined(separator: ",")
        })
    }
    /// A tool that opened one of the old panels lands on its list, folded open with its section.
    private func focus() {
        for list in NativeChatSessionList.allCases where list.asked(in: model) {
            isOpen(list.section.rawValue).wrappedValue = true
            isOpen(list.rawValue).wrappedValue = true
        }
    }
    private func load() async {
        guard !model.fixtureMode else { return }
        account = try? await model.accountTool("read", request: nil)
        folder = try? await model.projectReferenceRoot()
        sources = try? await model.instructionSources()
        skills = (try? await model.installedChatSkills())?.count
    }
}
