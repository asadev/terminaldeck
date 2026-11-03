import Foundation

// Optional values in measured records are explicit nulls on the existing wire.
// The store's summary has different rules: an unasked host key is omitted.
extension BackendServersListenerFact {
    private enum WireKeys: String, CodingKey { case address, port, program, pid, unit }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(address, forKey: .address); try c.encode(port, forKey: .port); try c.encode(program, forKey: .program)
        try c.encode(pid, forKey: .pid); try c.encode(unit, forKey: .unit)
    }
}
extension BackendServersAgentFact {
    private enum WireKeys: String, CodingKey { case id, path, version, signedIn, account }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(id, forKey: .id); try c.encode(path, forKey: .path); try c.encode(version, forKey: .version)
        try c.encode(signedIn, forKey: .signedIn); try c.encode(account, forKey: .account)
    }
}
extension BackendServersAgentInstallRoom {
    private enum WireKeys: String, CodingKey { case downloader, npm, memoryAvailableKb, homeFreeKb }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(downloader, forKey: .downloader); try c.encode(npm, forKey: .npm)
        try c.encode(memoryAvailableKb, forKey: .memoryAvailableKb); try c.encode(homeFreeKb, forKey: .homeFreeKb)
    }
}
