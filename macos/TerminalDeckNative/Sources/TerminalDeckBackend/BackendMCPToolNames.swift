import Foundation

/// Internal ids and MCP wire names identify the same registered Hoot operation.
/// Retired copilot names confer no access to a Hoot operation.
public enum BackendMCPToolNames {
    private static let hootNames: [Set<String>] = ["state", "run", "instructions", "memory"].map {
        ["hoot." + $0, "hoot_" + $0]
    }
    public static func permits(_ name: String, granted: Set<String>) -> Bool {
        let candidates = hootNames.first { $0.contains(name) } ?? [name]
        return !candidates.isDisjoint(with: granted)
    }
}
