import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A page-local filter: nil means All projects; Independent remains an explicit stable ID.
struct ProjectPicker: View {
    let projects: [PROJProject]
    @Binding var selection: String?
    let openProject: () -> Void
    let compact: Bool

    init(projects: [PROJProject], selection: Binding<String?>,
         openProject: @escaping () -> Void, compact: Bool = false) {
        self.projects = projects
        _selection = selection
        self.openProject = openProject
        self.compact = compact
    }

    /// Registry order is retained. Independent has its one explicit row below the divider.
    private var projectRows: [PROJProject] {
        var seen: Set<String> = []
        return projects.filter {
            !$0.id.isEmpty && $0.id != PROJProjects.independentID && seen.insert($0.id).inserted
        }
    }

    private var selectedProject: PROJProject? {
        guard let selection else { return nil }
        return projects.first { $0.id == selection }
    }

    private var title: String {
        guard let selection else { return "All projects" }
        if selection == PROJProjects.independentID { return "Independent" }
        return selectedProject?.name ?? "Project unavailable"
    }

    private var helpText: String {
        guard selection != nil, selection != PROJProjects.independentID, selectedProject == nil else {
            return "Project filter: " + title
        }
        return "The selected project isn't in the current list. Choose a project or open one."
    }

    var body: some View {
        // A plain Button popping a real NSMenu: the label stays ordinary SwiftUI (dot colour,
        // title, light/dark), and the menu rows carry the project colours as images.
        Button { anchor.view.map(showMenu) } label: {
            HStack(spacing: DeckTokens.Spacing.s8) {
                ProjectPickerDot(project: selectedProject, all: selection == nil)
                if !compact {
                    Text(title).font(DeckTokens.Typography.rowTitle).foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down").font(DeckTokens.Typography.micro).foregroundStyle(.secondary)
            }
            .frame(minWidth: DeckTokens.Metrics.iconHit, minHeight: DeckTokens.Metrics.iconHit)
            .padding(.horizontal, DeckTokens.Spacing.s12)
            .contentShape(.capsule)
            // Glass behind the label (as in GlassSwitch) so the text keeps the page's light/dark ink.
            .background { Capsule().fill(.clear).glassEffect(.regular.interactive(), in: .capsule) }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(ProjectPickerAnchor(box: anchor))
        .accessibilityLabel("Project filter: " + title)
        .accessibilityHint("Choose all projects, a project, Independent, or open a project.")
        .help(helpText)
    }

    @State private var anchor = ProjectPickerAnchorBox()

    private func showMenu(_ view: NSView) {
        let binding = $selection
        let menu = Self.menu(projects: projectRows, selection: selection, choose: { binding.wrappedValue = $0 }, openProject: openProject)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// The filter's menu: All projects, each project, Independent, New project… (the guide). Every choice
    /// carries its picture (logo or letter tile, neutral marks for the two fixed rows) and asks
    /// to keep it: macOS 27 hides menu pictures otherwise (real-app test 11 Oct, item 13).
    static func menu(projects: [PROJProject], selection: String?, choose: @escaping (String?) -> Void,
                     openProject: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        let target = ProjectPickerMenuTarget()
        func add(_ title: String, image: NSImage?, checked: Bool, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ProjectPickerMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = ProjectPickerAction(run)
            item.state = checked ? .on : .off
            if let image { item.image = image; item.deckKeepsPicture() }
            menu.addItem(item)
        }
        add("All projects", image: DeckRowIcon.allProjects, checked: selection == nil) { choose(nil) }
        for project in projects {
            add(project.name, image: DeckRowIcon.project(project), checked: selection == project.id) { choose(project.id) }
        }
        menu.addItem(.separator())
        add("Independent", image: DeckRowIcon.independent, checked: selection == PROJProjects.independentID) { choose(PROJProjects.independentID) }
        menu.addItem(.separator())
        add("New project…", image: nil, checked: false, openProject)
        objc_setAssociatedObject(menu, &ProjectPickerMenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }
}

/// Keeps the NSView under the picker so the menu opens right below it.
@MainActor final class ProjectPickerAnchorBox { weak var view: NSView? }

private struct ProjectPickerAnchor: NSViewRepresentable {
    let box: ProjectPickerAnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = ProjectPickerAnchorView()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

private final class ProjectPickerAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ProjectPickerAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@MainActor private final class ProjectPickerMenuTarget: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? ProjectPickerAction)?.run() }
}

private struct ProjectPickerDot: View {
    let project: PROJProject?
    var all = false

    var body: some View {
        Group {
            if all {
                Circle().strokeBorder(Color.secondary, lineWidth: 1)
                    .frame(width: DeckTokens.Metrics.projectDot, height: DeckTokens.Metrics.projectDot)
            } else {
                // The project's logo (or letter tile) where its colour dot used to be.
                ProjectLogoView(project: project, name: project?.name, size: 14)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Convenience adapters use only DeckPage's public builder initializer.
/// The picker is immediately left of the owner's existing actions; it never changes active project.
extension DeckPage {
    init<Content: View>(title: String, subtitle: String? = nil,
                        paper: Bool = false, scrolls: Bool? = nil,
                        project: Binding<String?>, projects: [PROJProject],
                        openProject: @escaping () -> Void,
                        @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  project: project, projects: projects, openProject: openProject,
                  switcher: { EmptyView() }, actions: { EmptyView() }, content: content)
    }

    init<Content: View, Switcher: View>(title: String, subtitle: String? = nil,
                                      paper: Bool = false, scrolls: Bool? = nil,
                                      project: Binding<String?>, projects: [PROJProject],
                                      openProject: @escaping () -> Void,
                                      @ViewBuilder switcher: () -> Switcher,
                                      @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  project: project, projects: projects, openProject: openProject,
                  switcher: switcher, actions: { EmptyView() }, content: content)
    }

    init<Content: View, Actions: View>(title: String, subtitle: String? = nil,
                                     paper: Bool = false, scrolls: Bool? = nil,
                                     project: Binding<String?>, projects: [PROJProject],
                                     openProject: @escaping () -> Void,
                                     @ViewBuilder actions: () -> Actions,
                                     @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  project: project, projects: projects, openProject: openProject,
                  switcher: { EmptyView() }, actions: actions, content: content)
    }

    init<Content: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        project: Binding<String?>, projects: [PROJProject], openProject: @escaping () -> Void,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  switcher: switcher, actions: {
            HStack(spacing: DeckTokens.Spacing.s8) {
                ProjectPicker(projects: projects, selection: project, openProject: openProject)
                actions()
            }
        }, content: content)
    }
    /// The owner supplies a compact version of the SAME real actions, with help and accessibility names.
    /// No generic label guessing: Text-only buttons cannot be safely converted into icon-only actions.
    init<Content: View, Actions: View, CompactActions: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        project: Binding<String?>, projects: [PROJProject], openProject: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder compactActions: () -> CompactActions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  project: project, projects: projects, openProject: openProject,
                  switcher: { EmptyView() }, actions: actions, compactActions: compactActions,
                  content: content)
    }

    init<Content: View, Switcher: View, Actions: View, CompactActions: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        project: Binding<String?>, projects: [PROJProject], openProject: @escaping () -> Void,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder compactActions: () -> CompactActions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, paper: paper, scrolls: scrolls,
                  switcher: switcher, actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DeckTokens.Spacing.s8) {
                    ProjectPicker(projects: projects, selection: project, openProject: openProject)
                    actions()
                }
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: DeckTokens.Spacing.s8) {
                    ProjectPicker(projects: projects, selection: project, openProject: openProject,
                                  compact: true)
                    compactActions()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }, content: content)
    }
}
