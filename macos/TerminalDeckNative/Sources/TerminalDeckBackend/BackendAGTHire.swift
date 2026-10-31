import Foundation
import TerminalDeckNativeCore

/// What the New Agent screen does after a hire (`AGTNewAgentView.seated`), for a hire made through the app tools
/// (tasks_agents save / save-many, by Hoot, a session or an AI app): the role seat's memory folder exists, named
/// after the role (or after the agent when it has none). A seat that already exists is left exactly as it is, so a
/// new hire into an old role inherits its memory. The lead seat is filled with project_registry_set_lead.
public enum BackendAGTHire {
    public static func seated(_ hired: [NativeRPCValue]) async {
        for row in hired {
            guard let id = row["id"].string, !id.isEmpty else { continue }
            let role = row["seat"].string.flatMap { $0.isEmpty ? nil : $0 }
            let seat = AGTSeats.roleSeat(agentID: id, seat: role, projectID: row["projectId"].string)
            let title = role.map(AGTSeats.title(forRole:)) ?? row["name"].string
            // Memory not open yet (or in a test): the seat is made when its first session starts, as before.
            _ = try? await DeckMemory.store.ensureOwner(seat.owner, name: title)
        }
    }
}
