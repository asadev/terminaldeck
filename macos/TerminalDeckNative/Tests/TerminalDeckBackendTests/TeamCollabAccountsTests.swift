import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 30 Oct (Decker's collaboration problems 1 and 2): a seat's job never starts on a signed-out login, and a seat's
/// account written into profiles.json takes effect on the next job without restarting anything.
final class TeamCollabAccountsTests: XCTestCase, @unchecked Sendable {
    private typealias A = BackendTeamJobAccount
    private let work = A.Candidate(id: "work", name: "Work"), personal = A.Candidate(id: "personal", name: "Personal")
    private let system = A.Candidate(id: "system", name: "Default")

    private func states(_ map: [String: String]) -> @Sendable (String) async -> String? { { map[$0] } }

    func testTheSeatsAccountIsUsedWhenItIsSignedIn() async throws {
        let pick = try await A.choose(requested: nil, assigned: work, assignedSource: "seat", candidates: [system, work, personal],
                                      state: states(["work": "signed-in", "system": "signed-out"]))
        XCTAssertEqual(pick.id, "work")
        XCTAssertEqual(pick.why, "the seat's account")
    }
    func testASignedOutDefaultFallsToTheFirstSignedInAccountInOrder() async throws {
        let pick = try await A.choose(requested: nil, assigned: system, assignedSource: "system", candidates: [system, work, personal],
                                      state: states(["system": "signed-out", "work": "signed-out", "personal": "signed-in"]))
        XCTAssertEqual(pick.id, "personal")
        XCTAssertTrue(pick.why.contains("is signed out"), pick.why)
    }
    func testAnUnknownStateIsNotTreatedAsSignedOut() async throws {
        // The launch rule: only a definite "signed-out" passes an account over.
        let pick = try await A.choose(requested: nil, assigned: system, assignedSource: "system", candidates: [system, work],
                                      state: states([:]))
        XCTAssertEqual(pick.id, "system")
    }
    func testNoSignedInAccountStartsNothing() async {
        await BackendFoundationTestsAccountsExpectError("No signed-in account") {
            _ = try await A.choose(requested: nil, assigned: self.system, assignedSource: "system", candidates: [self.system, self.work],
                                   state: self.states(["system": "signed-out", "work": "signed-out"]))
        }
    }
    func testAChosenAccountThatIsSignedOutIsRefusedNotSwapped() async {
        await BackendFoundationTestsAccountsExpectError("is signed out, so the job was not started") {
            _ = try await A.choose(requested: self.work, assigned: self.personal, assignedSource: "seat", candidates: [self.work, self.personal],
                                   state: self.states(["work": "signed-out", "personal": "signed-in"]))
        }
    }
    func testAChosenSignedInAccountWins() async throws {
        let pick = try await A.choose(requested: personal, assigned: work, assignedSource: "seat", candidates: [work, personal],
                                      state: states(["work": "signed-in", "personal": "signed-in"]))
        XCTAssertEqual(pick.id, "personal")
        XCTAssertEqual(pick.why, "chosen for this job")
    }

    // MARK: Problem 2: account settings are live

    private func writeProfiles(_ fixture: BackendFoundationTestsAccountsFixture, _ fields: [(String, NativeRPCValue)]) throws {
        try BackendFoundationTestsAccountsRaw(fields).encodedJSON()
            .write(to: fixture.configuration.dataDirectory.appendingPathComponent("profiles.json"), options: .atomic)
    }

    func testASeatAccountWrittenToTheFileAppliesToTheNextRead() async throws {
        try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsRaw()) { f in
            let seat = "role:terminal-deck/shell-design"
            let before = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/w/app", provider: "claude", seat: seat)
            XCTAssertEqual(before.profile.id, "system")
            try writeProfiles(f, [("seatAccounts", BackendFoundationTestsAccountsObject([(seat, BackendFoundationTestsAccountsObject([("claude", .string("personal"))]))]))])
            let after = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/w/app", provider: "claude", seat: seat)
            XCTAssertEqual(after.profile.id, "personal")
            XCTAssertEqual(after.source, .seat)
        }
    }
    func testAWriteAfterAnOutsideEditKeepsThatEdit() async throws {
        try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsRaw()) { f in
            let seat = "lead:terminal-deck"
            try writeProfiles(f, [("seatAccounts", BackendFoundationTestsAccountsObject([(seat, BackendFoundationTestsAccountsObject([("claude", .string("work"))]))]))])
            try await f.profiles.setLevel(.app, provider: "claude", id: "personal")
            let reread = try BackendAccountProfileStore.load(file: f.configuration.dataDirectory.appendingPathComponent("profiles.json"), configuration: f.configuration)
            XCTAssertEqual(reread.levels.seats[seat]?["claude"], "work")
            XCTAssertEqual(reread.levels.app["claude"], "personal")
        }
    }
    func testAnUnreadableFileKeepsTheChoicesInMemory() async throws {
        try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsRaw([("providerDefaults", BackendFoundationTestsAccountsObject([("claude", .string("work"))]))])) { f in
            try Data("{not json".utf8).write(to: f.configuration.dataDirectory.appendingPathComponent("profiles.json"))
            let still = try await f.profiles.effective(sessionProfileID: nil, projectPath: nil, provider: "claude")
            XCTAssertEqual(still.profile.id, "work")
        }
    }
}
