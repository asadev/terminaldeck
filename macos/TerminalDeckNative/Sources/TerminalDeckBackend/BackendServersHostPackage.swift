import Foundation

public struct BackendServersHostPackage: Sendable, Equatable {
    public let tarball: String; public let installer: String; public let version: String
    public init(tarball: String, installer: String, version: String) { self.tarball = tarball; self.installer = installer; self.version = version }
}
public enum BackendServersHostPackages {
    public static let directory = "headless-package"
    public static let tarball = "terminaldeck-host.tgz"
    public static let installer = "install.sh"
    public static let noPackage = "This copy of the app does not carry the host package, so there is nothing here to install from. A packaged build carries it; from a checkout, `npm run dist:headless` builds it."
    /// The remote Linux server keeps its Node host. This only locates its own
    /// bundled receipts; it never substitutes the reserved registry package.
    public static func find(version: String, resources: String?, tree: String?,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> BackendServersHostPackage? {
        let folders = [resources.map { URL(fileURLWithPath: $0).appendingPathComponent("headless").path },
                       tree.map { URL(fileURLWithPath: $0).appendingPathComponent("out").appendingPathComponent(directory).path }].compactMap { $0 }
        for folder in folders {
            let root = URL(fileURLWithPath: folder), tar = root.appendingPathComponent(tarball).path, script = root.appendingPathComponent(installer).path
            if exists(tar) && exists(script) { return .init(tarball: tar, installer: script, version: version) }
        }
        return nil
    }
}
