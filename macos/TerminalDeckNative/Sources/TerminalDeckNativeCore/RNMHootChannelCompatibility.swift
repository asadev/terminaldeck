import Foundation

/// Exact Phase A native routes already supported by the Mac. Normalize a
/// request/listener lookup only; never change published or outgoing channels.
public enum RNMHootChannelCompatibility {
    public static let legacyChannels: Set<String> = [
        "copilot:actions", "copilot:ensure", "copilot:files", "copilot:folder",
        "copilot:folder:clear", "copilot:folder:pick", "copilot:memory",
        "copilot:memory-delete", "copilot:memory-read", "copilot:memory-write",
        "copilot:read-composed", "copilot:read-contract", "copilot:read-folder-instructions",
        "copilot:read-instructions", "copilot:reset-instructions", "copilot:reveal",
        "copilot:scaffold", "copilot:signin", "copilot:state", "copilot:stop",
        "copilot:write-folder-instructions", "copilot:write-instructions",
        "machines:copilot:attach", "machines:copilot:chat", "machines:copilot:refresh",
        "machines:copilot:say", "machines:copilot:start", "machines:copilot:state"
    ]
    public static func incomingChannel(_ channel: String) -> String {
        let candidate: String
        if channel.hasPrefix("hoot:") { candidate = "copilot:" + channel.dropFirst(5) }
        else if channel.hasPrefix("machines:hoot:") { candidate = "machines:copilot:" + channel.dropFirst(14) }
        else { return channel }
        return legacyChannels.contains(candidate) ? candidate : channel
    }
    /// Native bridge/remote-panel request envelopes have one top-level channel
    /// field. Args and nested payload strings remain byte-for-byte untouched.
    public static func incomingRequestEnvelope(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let channel = value["channel"].string else { return value }
        let legacy = incomingChannel(channel)
        return legacy == channel ? value : value.setting("channel", .string(legacy))
    }
}
