import Foundation
import XCTest

final class DKTLiveInventoryCollectorTests: XCTestCase {
    func testFullInventoryCapturesEveryResourceClassWithoutSecrets() throws {
        let result = try DKTLiveInventoryCollector.collect(input())
        XCTAssertEqual(Set(result.resources.map(\.kind)), [.container, .image, .volume, .network, .app, .database, .backup, .caddyRoute, .serverFolder])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("DUMMY_ENV_SECRET"))
        XCTAssertFalse(encoded.contains("DUMMY_CADDY_SECRET"))
        XCTAssertTrue(encoded.contains("existing-data"))
        XCTAssertEqual(result.protectedCaddySHA256.count, 64)
    }

    func testInvalidOrMissingInventoryFailsClosed() throws {
        let valid = input()
        for broken in [
            DKTLiveInventoryCollector.Input(containers: Data(#"[{"Id":"id"}]"#.utf8), images: valid.images, volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths),
            DKTLiveInventoryCollector.Input(containers: valid.containers, images: Data("not-json".utf8), volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths),
            DKTLiveInventoryCollector.Input(containers: valid.containers, images: Data(#"[{"Id":"image","RepoTags":"bad"}]"#.utf8), volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths),
            DKTLiveInventoryCollector.Input(containers: valid.containers, images: valid.images, volumes: Data(#"{"Volumes":"unknown"}"#.utf8), networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths),
            DKTLiveInventoryCollector.Input(containers: valid.containers, images: valid.images, volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: "UNKNOWN /tmp/td-test-data"),
        ] { XCTAssertThrowsError(try DKTLiveInventoryCollector.collect(broken)) }
    }

    func testImageTagAndContainerAliasChangesBreakCleanupProof() throws {
        let valid = input()
        let before = try DKTLiveInventoryCollector.collect(valid)
        let retagged = DKTLiveInventoryCollector.Input(containers: valid.containers,
            images: Data(#"[{"Id":"image-id","RepoTags":["td-test-retagged:1"]}]"#.utf8),
            volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths)
        XCTAssertThrowsError(try before.cleanupProof(after: DKTLiveInventoryCollector.collect(retagged)))
        let renamed = DKTLiveInventoryCollector.Input(containers: Data(#"[{"Id":"container-id","Names":["/renamed"],"Image":"postgres:17"}]"#.utf8),
            images: valid.images, volumes: valid.volumes, networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths)
        XCTAssertThrowsError(try before.cleanupProof(after: DKTLiveInventoryCollector.collect(renamed)))
    }

    func testPinnedDatabaseImagesAreIdentifiedThroughImageInventory() throws {
        let valid = input()
        let pinned = DKTLiveInventoryCollector.Input(containers: Data(#"[{"Id":"db","Names":["/td-test-db"],"Image":"sha256:pinned"}]"#.utf8),
            images: Data(#"[{"Id":"sha256:pinned","RepoTags":["postgres:17"]}]"#.utf8), volumes: valid.volumes,
            networks: valid.networks, caddy: valid.caddy, serverPaths: valid.serverPaths)
        let result = try DKTLiveInventoryCollector.collect(pinned)
        XCTAssertTrue(result.resources.contains { $0.kind == .database && $0.id == "db" })
    }

    private func input() -> DKTLiveInventoryCollector.Input {
        .init(containers: Data(#"[{"Id":"container-id","Names":["/existing-db","/existing-alias"],"Image":"postgres:17","Command":"DUMMY_ENV_SECRET"}]"#.utf8),
              images: Data(#"[{"Id":"image-id","RepoTags":["existing-image:1"],"RepoDigests":[]}]"#.utf8),
              volumes: Data(#"{"Volumes":[{"Name":"existing-data"}]}"#.utf8),
              networks: Data(#"[{"Id":"network-id","Name":"bridge"}]"#.utf8),
              caddy: Data(#"{"apps":{"http":{"servers":{"srv0":{"routes":[{"@id":"protected-route","match":[{"host":["178-105-239-176.sslip.io"]}],"handle":[],"secret":"DUMMY_CADDY_SECRET"}]}}}}}"#.utf8),
              serverPaths: "APP td-test-app\nFOLDER /var/lib/terminaldeck/apps/td-test-app\nBACKUP /var/lib/terminaldeck/apps/td-test-app/backups/td-test-dump.sql")
    }
}
