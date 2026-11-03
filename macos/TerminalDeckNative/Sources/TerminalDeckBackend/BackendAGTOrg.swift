import Foundation
import TerminalDeckNativeCore

/// AGT: the two organisation fields on a TAG profile (icon, reportsTo). They live
/// in the one profile store; this keeps them through saves that do not mention
/// them and refuses a reporting line that would loop.
public enum BackendAGTOrg {
    public static let fields = ["icon", "reportsTo", "seat", "toolUseRestrictions"]

    /// Editors written before AGT send whole rows without these fields: keep them.
    public static func carry(_ input: NativeRPCValue, existing: NativeRPCValue?) -> NativeRPCValue {
        guard let existing, input.fields != nil else { return input }
        var out = input
        for field in fields where !input.has(field) && !existing[field].isNullish { out = out.setting(field, existing[field]) }
        return out
    }

    /// Refuses reporting to itself, to an unknown agent, or around a loop.
    public static func check(_ input: NativeRPCValue, agents: [NativeRPCValue]) throws {
        guard let id = input["id"].string?.lowercased(), let boss = input["reportsTo"].string, !boss.isEmpty else { return }
        var managers: [String: String?] = [:], names: [String: String] = [:]
        for agent in agents {
            guard let other = agent["id"].string else { continue }
            managers[other] = agent["reportsTo"].string
            names[other] = agent["name"].string
        }
        if let name = input["name"].string { names[id] = name }
        if let problem = AGTOrgChart.refusal(id: id, reportsTo: boss, managers: managers, names: names) {
            throw NativeRPCError.invalidArguments(problem)
        }
    }

    /// When an agent is removed, the ones that reported to it become independent.
    public static func clearReports(to id: String, in agents: [NativeRPCValue]) -> [NativeRPCValue] {
        agents.map { $0["reportsTo"].string == id ? $0.removing("reportsTo") : $0 }
    }
}
