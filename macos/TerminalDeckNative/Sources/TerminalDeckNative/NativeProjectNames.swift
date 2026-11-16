import Foundation
import TerminalDeckNativeCore

/// LANDING-FIX-3 (Owner, 14 Nov): a session started in a project's folder is titled after the FOLDER ("ClaudeCRM")
/// while the project is called "CRM" everywhere else (the side panel's projects, the phones, the Cloud). Wherever the
/// Mac names the project — the window title's part after the dash, and a session still named after its project's
/// folder in the strip, the side panel's rows and the window title — it uses the project's own name. Display only:
/// no stored name, title or folder changes.
@MainActor
enum NativeProjectNames {
    /// The registered project a folder belongs to, by name; nil for no project (Independent) or a non-folder id.
    static func project(folder: String?) -> String? {
        guard let folder, folder.hasPrefix("/") else { return nil }
        let registry = SHELLRoutes.registry
        let id = PROJProjects.resolve(projectID: nil, folder: folder, projects: registry)
        guard id != PROJProjects.independentID, let name = registry.first(where: { $0.id == id })?.name,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    /// A session still named after its project's own folder reads as the project; any other name (one he gave, an
    /// AI's title, a subfolder's name, "Session 1") stays as it is.
    static func sessionTitle(_ title: String, folder: String?, registry: [PROJProject]? = nil) -> String {
        guard let folder, folder.hasPrefix("/") else { return title }
        let path = PROJProjects.normalize(folder)
        guard title == URL(fileURLWithPath: path).lastPathComponent,
              let project = (registry ?? SHELLRoutes.registry).first(where: { $0.folders.map(PROJProjects.normalize).contains(path) }),
              project.id != PROJProjects.independentID, !project.name.isEmpty else { return title }
        return project.name
    }

    /// The side panel's Projects row for an open folder: the registered project's name when the folder IS one of that
    /// project's folders, else the folder's own name (a plain folder, or a subfolder opened on its own).
    static func folderRowName(_ path: String, registry: [PROJProject]) -> String {
        let folder = PROJProjects.normalize(path)
        if let project = registry.first(where: { $0.id != PROJProjects.independentID && $0.folders.map(PROJProjects.normalize).contains(folder) }),
           !project.name.trimmingCharacters(in: .whitespaces).isEmpty { return project.name }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    /// Display names for the sessions of a rail whose title is still their project's folder name (id → name), for
    /// `SessionNames.applied`.
    static func folderNamed(_ tabs: [TabItem], in sidebar: SidebarState?) -> [String: String] {
        guard let sidebar else { return [:] }
        var names: [String: String] = [:]
        for tab in tabs where tab.kind == "session" {
            guard let group = sidebar.projects.first(where: { $0.sessions.contains { $0.id == tab.id } }) else { continue }
            let shown = sessionTitle(tab.title, folder: group.id)
            if shown != tab.title { names[tab.id] = shown }
        }
        return names
    }
}
