/**
 * The servers this phone holds, and the sign-ins it holds for them.
 *
 * Against a real Keychain in a drawer of this test's own — the pattern
 * `CredentialStoreTests` set, and for its reason: a fake store would prove the
 * shape of this file's own logic and nothing about the platform underneath it,
 * which is where the interesting failures are.
 */

import XCTest
@testable import TerminalDeck

final class ServerStoreTests: XCTestCase {

    private var store: ServerStore!

    override func setUp() {
        super.setUp()
        store = ServerStore(service: "dev.terminaldeck.ios.tests.servers.\(UUID().uuidString)")
    }

    override func tearDown() {
        store.eraseEverythingForTesting()
        store = nil
        super.tearDown()
    }

    func testKeepsAServerAndTheSignInBesideIt() throws {
        let server = try store.add(name: "Box", address: "example.com", port: nil,
                                   username: "root", secret: "hunter2", kind: .password,
                                   hostKey: SSHHostKey(algorithm: "ssh-ed25519",
                                                       fingerprint: "SHA256:abc"))
        XCTAssertEqual(store.all().map(\.id), [server.id])
        XCTAssertEqual(store.load(server.id)?.address, "example.com")
        XCTAssertEqual(store.load(server.id)?.credential, .password)
        XCTAssertEqual(store.load(server.id)?.hostKey?.fingerprint, "SHA256:abc")
        XCTAssertEqual(store.secret(for: server.id), "hunter2")
    }

    /**
     * The port, which is the field this form shipped without.
     *
     * Asad's own machine listens on **2222**, and a form that assumed 22 told
     * him the server was off or firewalled about a number the app had chosen
     * silently. Empty still means 22 — that is what makes it three questions for
     * everyone else — but a number that was given has to survive the round trip.
     */
    func testRemembersANonStandardPortAndShowsItInTheAddress() throws {
        let server = try store.add(name: "", address: "10.0.0.5", port: 2222,
                                   username: "asad", secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(store.load(server.id)?.port, 2222)
        XCTAssertEqual(server.where_, "10.0.0.5:2222")
    }

    func testTheUsualPortIsNotPrinted() throws {
        let server = try store.add(name: "", address: "10.0.0.5", port: nil,
                                   username: "asad", secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(server.port, 22)
        XCTAssertEqual(server.where_, "10.0.0.5")
    }

    func testAServerWithNoNameIsCalledByItsAddress() throws {
        let server = try store.add(name: "   ", address: "example.com", port: nil,
                                   username: "root", secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(server.name, "example.com")
    }

    func testRefusesADraftThatCannotBeDialled() {
        XCTAssertThrowsError(try store.add(name: "", address: "  ", port: nil, username: "root",
                                           secret: "x", kind: .password, hostKey: nil)) { error in
            XCTAssertEqual(error as? ServerDraftProblem, .noAddress)
        }
        XCTAssertThrowsError(try store.add(name: "", address: "example.com", port: nil,
                                           username: " ", secret: "x", kind: .password,
                                           hostKey: nil)) { error in
            XCTAssertEqual(error as? ServerDraftProblem, .noUsername)
        }
        XCTAssertThrowsError(try store.add(name: "", address: "example.com", port: 70000,
                                           username: "root", secret: "x", kind: .password,
                                           hostKey: nil)) { error in
            XCTAssertEqual(error as? ServerDraftProblem, .badPort)
        }
    }

    /// Both items go together: a record with no secret asks for a password
    /// nobody typed, and a secret with no record is a password for a machine
    /// nothing can name.
    func testForgettingTakesTheSignInWithIt() throws {
        let server = try store.add(name: "Box", address: "example.com", port: nil,
                                   username: "root", secret: "hunter2", kind: .password,
                                   hostKey: nil)
        store.forget(server.id)
        XCTAssertNil(store.load(server.id))
        XCTAssertNil(store.secret(for: server.id))
        XCTAssertTrue(store.all().isEmpty)
    }

    /// One item per server, so a record this build cannot read costs that one
    /// server rather than every server on the phone.
    func testOneUnreadableRecordDoesNotHideTheOthers() throws {
        let good = try store.add(name: "Good", address: "a.example", port: nil, username: "root",
                                 secret: "x", kind: .password, hostKey: nil)
        let other = try store.add(name: "Also good", address: "b.example", port: nil,
                                  username: "root", secret: "x", kind: .password, hostKey: nil)
        // Whatever a future build writes here, this one cannot decode it.
        store.saveRawForTesting(id: good.id, data: Data("{\"shape\":\"from the future\"}".utf8))
        XCTAssertEqual(store.all().map(\.id), [other.id])
    }

    /**
     * The same login twice is one server.
     *
     * Found by looking: three test runs against one box left three identical
     * rows on the machines list. Signing in again is a normal thing to do and
     * must not cost a duplicate.
     */
    func testSigningInAgainUpdatesTheServerRatherThanAddingASecond() throws {
        let first = try store.add(name: "Box", address: "example.com", port: 2222,
                                  username: "root", secret: "old", kind: .password,
                                  hostKey: SSHHostKey(algorithm: "ssh-ed25519",
                                                      fingerprint: "SHA256:one"))
        var named = try XCTUnwrap(store.load(first.id))
        named.name = "The box"
        store.save(named)
        let again = try store.add(name: "example.com", address: "example.com", port: 2222,
                                  username: "root", secret: "new", kind: .key,
                                  hostKey: SSHHostKey(algorithm: "ssh-ed25519",
                                                      fingerprint: "SHA256:two"))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.all().count, 1)
        // What the new sign-in proved is refreshed…
        XCTAssertEqual(store.secret(for: first.id), "new")
        XCTAssertEqual(store.load(first.id)?.credential, .key)
        XCTAssertEqual(store.load(first.id)?.hostKey?.fingerprint, "SHA256:two")
        // …and what the person chose is kept.
        XCTAssertEqual(store.load(first.id)?.name, "The box")
    }

    /// Two accounts on one box are two servers, and stay two rows.
    func testASecondAccountOnTheSameBoxIsItsOwnServer() throws {
        _ = try store.add(name: "", address: "example.com", port: nil, username: "root",
                          secret: "x", kind: .password, hostKey: nil)
        _ = try store.add(name: "", address: "example.com", port: nil, username: "deploy",
                          secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(store.all().count, 2)
    }

    /// A different port on the same address is a different server too — one box
    /// can hold several, and 2222 is not 22.
    func testTheSameAddressOnADifferentPortIsItsOwnServer() throws {
        _ = try store.add(name: "", address: "example.com", port: nil, username: "root",
                          secret: "x", kind: .password, hostKey: nil)
        _ = try store.add(name: "", address: "example.com", port: 2222, username: "root",
                          secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(store.all().count, 2)
    }

    func testKeepsTheOrderTheyWereAddedIn() throws {
        let first = try store.add(name: "One", address: "a.example", port: nil, username: "root",
                                  secret: "x", kind: .password, hostKey: nil)
        let second = try store.add(name: "Two", address: "b.example", port: nil, username: "root",
                                   secret: "x", kind: .password, hostKey: nil)
        XCTAssertEqual(store.all().map(\.name), ["One", "Two"])
        XCTAssertNotEqual(first.id, second.id)
    }
}
