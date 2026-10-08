import Foundation
import TerminalDeckNativeCore

public enum AWAgentsWatchMachines {
    /// Input must be the existing machine owner's caller-authorized view.
    /// This projection never connects, starts a stream or changes machine grants.
    public static func project(_ view: NativeRPCValue) -> AWWatchSnapshot {
        let machines = view["machines"].elements ?? [], links = view["links"].elements ?? []
        var agents: [AWWatchAgent] = [], notices: [String] = []
        for link in links {
            guard let id = link["id"].string else { continue }
            let name = machines.first { $0["id"].string == id }?["name"].string ?? "Connected machine"
            let online = link["state"].string == "online"
            agents += AWWatchProjection.inventory(sessions: link["sessions"].elements ?? [], tasks: [],
                machineID: id, machineName: name, connected: online)
            if !online { notices.append("\(name) is \(link["state"].string ?? "offline"); live activity is unavailable.") }
        }
        return AWWatchSnapshot(agents: AWWatchProjection.sorted(agents), tasks: [], notices: notices)
    }
}
