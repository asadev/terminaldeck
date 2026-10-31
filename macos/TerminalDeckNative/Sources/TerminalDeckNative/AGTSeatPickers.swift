import SwiftUI
import TerminalDeckNativeCore

/// A seat to choose when hiring or moving an agent: a role that already exists (with whatever
/// memory it holds) or a new one. Used by the New agent page and the agent settings window.
struct AGTSeatChoice: Identifiable, Hashable {
    let seat: AGTSeat
    let title: String
    /// "12 notes · 2 topics" when the seat holds memory.
    let memory: String?
    /// Somebody sits in it already (more than one agent may share a role).
    let filledBy: [String]
    var id: String { seat.key }

    /// A seat has no face of its own: it shows its project's picture.
    @MainActor var image: NSImage { DeckRowIcon.project(id: seat.projectID ?? PROJProjects.independentID, in: NativePROJLabels.shared.projects) }

    var label: String {
        var text = title
        if filledBy.isEmpty { text += memory.map { " · vacant, has memory (\($0))" } ?? " · vacant" }
        else { text += " · " + filledBy.joined(separator: ", ") }
        return text
    }
}

extension AGTLeads {
    /// The role seats of one project (`nil` = outside any project): every role an agent holds now,
    /// plus every vacant one that still holds memory. Vacant seats with memory come first.
    static func seatChoices(projectID: String?, agents: [AGTAgent]) -> [AGTSeatChoice] {
        let project = projectID.flatMap { $0 == PROJProjects.independentID ? nil : $0 }
        var holders: [String: [String]] = [:]
        var seats: [String: AGTSeat] = [:]
        for agent in agents where agent.kind == .profile && agent.status != "archived" {
            guard let seat = roleSeat(agent), seat.projectID == project else { continue }
            holders[seat.key, default: []].append(agent.name); seats[seat.key] = seat
        }
        for info in AGTSeatsStore.shared.withMemory {
            guard let seat = AGTSeat(owner: info.owner), case .role = seat, seat.projectID == project else { continue }
            seats[seat.key] = seat
        }
        return seats.values.map { seat in
            AGTSeatChoice(seat: seat, title: AGTSeatsStore.shared.title(for: seat) ?? AGTSeats.title(forRole: seat.role ?? ""),
                          memory: AGTSeatsStore.shared.summary(for: seat), filledBy: holders[seat.key] ?? [])
        }.sorted { a, b in
            let rank: (AGTSeatChoice) -> Int = { $0.filledBy.isEmpty && $0.memory != nil ? 0 : $0.filledBy.isEmpty ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}

/// Agent settings → Role: which seat the agent sits in. Moving it never moves memory; the
/// memory stays with the seat it leaves and the agent picks up the new seat's.
struct AGTRolePicker: View {
    let agent: AGTAgent
    @State private var naming = false
    @State private var newRole = ""
    @State private var busy = false
    private var store: AGTAgentsStore { .shared }

    var body: some View {
        let current = AGTLeads.roleSeat(agent)
        let choices = AGTLeads.seatChoices(projectID: AGTLeads.projectID(agent), agents: store.agents)
        HStack(spacing: 8) {
            Menu {
                ForEach(choices) { choice in
                    Toggle(isOn: Binding(get: { choice.seat == current }, set: { _ in move(to: choice.seat.role, title: choice.title) })) {
                        DeckRowLabel(choice.label, image: choice.image)
                    }
                }
                Divider()
                Button { newRole = ""; naming = true } label: { Label("New role…", systemImage: "plus") }
            } label: {
                Text(current.map { AGTSeatsStore.shared.title(for: $0) ?? AGTSeats.title(forRole: $0.role ?? agent.id) } ?? "Choose a role")
            }
            .fixedSize().disabled(busy)
            .help("Memory belongs to the role. Moving \(agent.name) leaves this role's memory in place for the next hire.")
            .accessibilityLabel("Role")
            if busy { ProgressView().controlSize(.small) }
        }
        .onAppear { if store.fixture == nil { AGTSeatsStore.shared.start() } }
        .alert("New role", isPresented: $naming) {
            TextField("For example iOS engineer", text: $newRole)
            Button("Move here") {
                let slug = AGTSeats.slug(newRole)
                if !slug.isEmpty { move(to: slug, title: newRole.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(agent.name) moves into the new role and starts its memory. The role it leaves keeps its memory.")
        }
    }

    private func move(to role: String?, title: String?) {
        guard AGTLeads.roleSeat(agent)?.role != role else { return }
        busy = true
        Task { await AGTLeads.setRole(role, title: title, for: agent); busy = false }
    }
}
