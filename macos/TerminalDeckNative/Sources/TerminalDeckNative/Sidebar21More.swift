import SwiftUI
import TerminalDeckNativeCore

/// Shared by the live popover and the offscreen frames.
struct Sidebar21More: View {
    let pages: [Sidebar21Page]
    let pins: Sidebar21Store
    let choose: (String) -> Void
    let dismiss: () -> Void
    @State private var highlighted: String?
    @State private var hovered: String?
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(pages) { page in
                    HStack(spacing: 0) {
                        Button { open(page.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol).foregroundStyle(.secondary).frame(width: 20)
                                Text(page.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 34)
                                .contentShape(.rect)
                        }.buttonStyle(.plain)
                        Button { pins.toggle(page.id, pages: pages) } label: {
                            Image(systemName: pins.isPinned(page.id) ? "pin.fill" : "pin")
                                .foregroundStyle(.secondary).frame(width: 32, height: 34).contentShape(.rect)
                        }.buttonStyle(.plain)
                            .opacity(page.id == Sidebar21Pages.projectsID || pins.isPinned(page.id) || hovered == page.id || highlighted == page.id ? 1 : 0)
                            .help(pins.isPinned(page.id) ? "Unpin from side panel" : "Pin to side panel")
                            .accessibilityLabel((pins.isPinned(page.id) ? "Unpin " : "Pin ") + page.title)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(highlighted == page.id ? DeckTokens.cardHover : .clear))
                    .onHover { on in hovered = on ? page.id : nil; if on { highlighted = page.id } }
                }
            }.padding(8)
        }
        .frame(width: 248, height: min(CGFloat(pages.count) * 36 + 16, 560))
        .font(.system(size: 13))
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .focusable().focusEffectDisabled().focused($keyboardFocus)
        .onAppear { highlighted = pages.first?.id; keyboardFocus = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { if let highlighted { open(highlighted) }; return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .accessibilityLabel("More pages")
    }
    private func move(_ delta: Int) { highlighted = Sidebar21Pages.stepped(highlighted, delta: delta, pages: pages) }
    private func open(_ id: String) { _ = Sidebar21MoreActions.open(id, pages: pages, choose: choose, dismiss: dismiss) }
}

enum Sidebar21MoreActions {
    @discardableResult static func open(_ id: String, pages: [Sidebar21Page], choose: (String) -> Void, dismiss: () -> Void) -> Bool {
        guard pages.contains(where: { $0.id == id }) else { return false }
        choose(id); dismiss(); return true
    }
}

struct Sidebar21ProjectsScreen: View {
    private let store = SIDEBARProjectStore.shared
    var body: some View {
        DeckPage(title: "Projects", actions: { Button("New project…") { PROJGuideWindow.open() } }) {
            let projects = (store.projects.isEmpty ? PROJProjects.defaults : store.projects).filter { $0.id != PROJProjects.independentID }
            if projects.isEmpty {
                ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Create a project to keep its sessions together."))
            }
            ForEach(projects) { project in
                if let folder = project.folders.first {
                    Button { AppModel.shared.select("project:" + folder) } label: {
                        HStack(spacing: 12) {
                            ProjectLogoView(project: project, name: project.name, size: 24)
                            Text(project.name); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(12).contentShape(.rect)
                    }.buttonStyle(DeckSidebarRowStyle())
                }
            }
        }.task { store.start() }
    }
}
