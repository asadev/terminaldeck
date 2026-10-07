import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("host-package.test.ts case parity")
struct BackendServersHostPortPackageTests {
    private func present(_ files: Set<String>) -> (String) -> Bool { { files.contains($0) } }
    @Test("finds both files under a packaged app’s resources") func packagedResources() {
        let directory = "/App/Contents/Resources/headless", tar = directory + "/" + BackendServersHostPackages.tarball, script = directory + "/" + BackendServersHostPackages.installer
        let found = BackendServersHostPackages.find(version: "0.9.1", resources: "/App/Contents/Resources", tree: nil, exists: present([tar, script]))
        #expect(found?.tarball == tar); #expect(found?.version == "0.9.1")
    }
    @Test("finds them under out/ when running from a checkout") func checkoutPackage() {
        let tar = "/repo/out/headless-package/" + BackendServersHostPackages.tarball, script = "/repo/out/headless-package/" + BackendServersHostPackages.installer
        #expect(BackendServersHostPackages.find(version: "0.9.1", resources: nil, tree: "/repo", exists: present([tar, script]))?.installer == script)
    }
    @Test("answers null when only one of the two is there") func halfPackage() {
        #expect(BackendServersHostPackages.find(version: "0.9.1", resources: nil, tree: "/repo", exists: present(["/repo/out/headless-package/" + BackendServersHostPackages.installer])) == nil)
    }
    @Test("answers null when there is nothing at all, rather than guessing at npm") func noRegistryGuess() {
        #expect(BackendServersHostPackages.find(version: "0.9.1", resources: nil, tree: nil, exists: { _ in true }) == nil)
        #expect(BackendServersHostPackages.noPackage.contains("npm run dist:headless"))
    }
}
