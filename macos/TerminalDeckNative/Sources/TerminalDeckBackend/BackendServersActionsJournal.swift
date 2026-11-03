import Foundation

/// Exact discriminated wire format used in server-waybacks.json. Persistence
/// remains the coordinator's local single-writer responsibility.
extension BackendServersWayBack: Codable {
    private enum Keys: String, CodingKey { case kind, at, container, imageId, imageRef, compose, backupPath, dir, commit, managedBy }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let at = try c.decode(Double.self, forKey: .at)
        let backup = try c.decodeIfPresent(String.self, forKey: .backupPath)
        switch try c.decode(String.self, forKey: .kind) {
        case "container-image": self = .containerImage(at: at, container: try c.decode(String.self, forKey: .container), imageId: try c.decode(String.self, forKey: .imageId), imageRef: try c.decode(String.self, forKey: .imageRef), compose: try c.decode(BackendServersComposeRef.self, forKey: .compose), backupPath: backup)
        case "repo-commit": self = .repoCommit(at: at, dir: try c.decode(String.self, forKey: .dir), commit: try c.decode(String.self, forKey: .commit), managedBy: try c.decodeIfPresent(BackendServersManagedBy.self, forKey: .managedBy), backupPath: backup)
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown way back")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .containerImage(let at, let container, let imageId, let imageRef, let compose, let backupPath):
            try c.encode("container-image", forKey: .kind); try c.encode(at, forKey: .at); try c.encode(container, forKey: .container)
            try c.encode(imageId, forKey: .imageId); try c.encode(imageRef, forKey: .imageRef); try c.encode(compose, forKey: .compose); try c.encode(backupPath, forKey: .backupPath)
        case .repoCommit(let at, let dir, let commit, let managedBy, let backupPath):
            try c.encode("repo-commit", forKey: .kind); try c.encode(at, forKey: .at); try c.encode(dir, forKey: .dir); try c.encode(commit, forKey: .commit)
            try c.encode(managedBy, forKey: .managedBy); try c.encode(backupPath, forKey: .backupPath)
        }
    }
}
