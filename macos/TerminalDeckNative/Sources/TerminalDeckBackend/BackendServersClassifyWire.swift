import Foundation

extension BackendServersCard {
    private enum WireKeys: String, CodingKey { case id, kind, name, detail, running, managedBy, url, engine, repoDir }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(name, forKey: .name); try c.encode(detail, forKey: .detail)
        try c.encode(running, forKey: .running); try c.encode(managedBy, forKey: .managedBy); try c.encode(url, forKey: .url)
        try c.encode(engine, forKey: .engine); try c.encode(repoDir, forKey: .repoDir)
    }
}
