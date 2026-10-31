import Foundation

/// relay-client.ts `relayUrl` + `relayEnabled`: the relay this Mac dials. The
/// relay is the network for phones and other machines, so it is ON unless the
/// environment switches it off, and its address is the compiled-in default unless
/// the environment names another. There is no settings key for either (the
/// TS app had none); 0.19.0/0.19.1 read a "remote.relayUrl" setting that never
/// exists, so no relay was dialled and phones could not connect.
public enum BackendRelayAddress {
    public static let urlEnvironmentKey = "TERMINALDECK_RELAY_URL"
    public static let enabledEnvironmentKey = "TERMINALDECK_RELAY"
    private static let off: Set<String> = ["off", "0", "false", "no"]

    /// The relay URL to dial, or nil when the environment switched the relay off.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let said = text(environment[enabledEnvironmentKey]), off.contains(said.lowercased()) { return nil }
        return text(environment[urlEnvironmentKey]) ?? BackendRelayPacketCodec.defaultRelayURL
    }

    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
