import SwiftUI
import Observation
import TerminalDeckNativeCore

/// A project with no lead whose folder already says who its AI is (its CLAUDE.md: "You are **Commander**"):
/// the Agents page offers that name as the project's lead, once, until the person makes it or says Not now
/// (13 Oct: iMatch showed only "ClaudeiMatch" session cards and no Commander). Read from the person's own
/// registered folders (CLAUDE.md, then AGENTS.md, then GEMINI.md); nothing is written to them.
@MainActor @Observable final class AGTDeclaredLeads {
    static let shared = AGTDeclaredLeads()
    /// Project id → what its folder declares.
    private(set) var found: [String: AGTDeclaredLead.Found] = [:]
    /// Offscreen pictures and tests set this instead of reading folders.
    var fixture: [String: AGTDeclaredLead.Found]?
    /// Bumped when an offer is set aside, so the page redraws.
    private(set) var dismissals = 0
    @ObservationIgnored private var readFolders: [String: [String]] = [:]
    private init() {}

    func declared(_ project: PROJProject) -> AGTDeclaredLead.Found? { (fixture ?? found)[project.id] }

    /// Reads each registered project's folders once (again when its folders change). Off the main thread.
    func refresh(_ projects: [PROJProject]) async {
        guard fixture == nil else { return }
        let wanted = projects.filter { $0.id != PROJProjects.independentID && !$0.folders.isEmpty }
        let changed = wanted.filter { readFolders[$0.id] != $0.folders }
        guard !changed.isEmpty else { return }
        let read = await Task.detached(priority: .utility) {
            changed.map { project in (project.id, project.folders, AGTDeclaredLead.find(folders: project.folders, read: AGTDeclaredLead.readHead)) }
        }.value
        for (id, folders, declared) in read {
            readFolders[id] = folders
            found[id] = declared
        }
    }

    /// The projects to offer a lead for: no lead yet, a name declared, not set aside.
    func offers(in projects: [PROJProject], projectID: String?) -> [(project: PROJProject, declared: AGTDeclaredLead.Found)] {
        _ = dismissals
        return projects.compactMap { project in
            guard project.id != PROJProjects.independentID, projectID == nil || project.id == projectID,
                  AGTSeats.lead(of: project) == nil, let declared = declared(project), !isSetAside(declared, project: project) else { return nil }
            return (project, declared)
        }
    }

    private func key(_ declared: AGTDeclaredLead.Found, project: PROJProject) -> String {
        "agt.declaredLead.notNow." + project.id + "." + declared.name.lowercased()
    }
    func isSetAside(_ declared: AGTDeclaredLead.Found, project: PROJProject) -> Bool {
        fixture == nil && UserDefaults.standard.bool(forKey: key(declared, project: project))
    }
    func setAside(_ declared: AGTDeclaredLead.Found, project: PROJProject) {
        if fixture == nil { UserDefaults.standard.set(true, forKey: key(declared, project: project)) }
        dismissals += 1
    }

    /// The confirmation's words, the same on the page and on a session's memory tab.
    static func confirmDetail(_ declared: AGTDeclaredLead.Found, project: PROJProject) -> String {
        let saved = AGTAgentsStore.shared.profiles.contains { $0.status != .archived && $0.name.caseInsensitiveCompare(declared.name) == .orderedSame }
        return (saved ? "" : "Terminal Deck saves an agent called \(declared.name) for \(project.name) (\(AGTDirectory.providerLabel(declared.provider)), in \(project.folders.first ?? project.name)). ")
            + "Every session you open in \(project.name) without picking an agent then works as \(declared.name), with the lead seat's memory. "
            + "Hoot gives \(project.name)'s goals to \(declared.name), and \(project.name)'s agents report to it. Nothing in the folder is changed."
    }
}

/// The offers, as slim cards above the agents on the Agents page.
struct AGTDeclaredLeadOffers: View {
    let projectID: String?
    var live = true
    @State private var busy: String?
    private var model: AGTDeclaredLeads { .shared }

    /// No rows (and so no gap in the page's stack) when there is nothing to offer; the page reads the
    /// folders with `.task(id: AGTDeclaredLeadOffers.readKey)` (see `AGFRAMEAllAgentsContent`).
    var body: some View {
        ForEach(model.offers(in: NativePROJLabels.shared.projects, projectID: projectID), id: \.project.id) { offer in
            row(offer.project, offer.declared)
        }
    }
    /// Changes when a project's lead or folders change: the folders are read again then.
    static var readKey: [String] { NativePROJLabels.shared.projects.map { $0.id + ":" + $0.lead + ":" + $0.folders.joined(separator: ",") } }
    static func read() async { await AGTDeclaredLeads.shared.refresh(NativePROJLabels.shared.projects) }

    private func row(_ project: PROJProject, _ declared: AGTDeclaredLead.Found) -> some View {
        DeckCard {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 22)).foregroundStyle(DeckTokens.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(project.name) has no lead. Its \(declared.file) says its AI is \(declared.name).")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Make \(declared.name) the lead, and every session you open in \(project.name) without picking an agent works as \(declared.name), with the lead's memory.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if busy == project.id { ProgressView().controlSize(.small) }
                Button("Not now") { model.setAside(declared, project: project) }
                    .buttonStyle(.borderless)
                    .help("Hide this. The lead can still be set on the project, on an agent or on a session.")
                Button("Make \(declared.name) the lead") {
                    AgentMenu.confirmChange(title: "Make \(declared.name) the lead of \(project.name)?",
                                            detail: AGTDeclaredLeads.confirmDetail(declared, project: project), button: "Make lead") {
                        busy = project.id
                        Task { _ = await AGTLeads.makeDeclaredLead(declared, of: project); busy = nil }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(busy != nil || !live)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(project.name) has no lead. Its \(declared.file) says its AI is \(declared.name).")
    }
}
