import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendMacAppHandoffFakeOpener {
    var arguments: [[String]] = [], requests: [(String, String?)] = []
    func open(_ args: [String]) -> Int { arguments.append(args); return 0 }
    func ask(_ url: String, _ session: String?, answer: String) -> String { requests.append((url, session)); return answer }
    func result() -> (arguments: [[String]], requests: [(String, String?)]) { (arguments, requests) }
}
final class BackendMacAppHandoffOpenShimTests: XCTestCase {
    func testSevenNonWebArgvShapesPassThroughUnchanged() async throws {
        let cases: [[String]] = [["."], ["-a", "Xcode", "file.swift"], ["-R", "file.txt"], ["report.pdf"], [], ["vscode://file/x"], ["https://a.example", "https://b.example"]]
        for args in cases {
            let fake = BackendMacAppHandoffFakeOpener()
            let result = try await BackendMacAppHandoffShimInvocation.run(arguments: args, sessionID: nil, ask: { url, session in await fake.ask(url, session, answer: "tab\nwrong") }, opener: { await fake.open($0) }), calls = await fake.result()
            BackendMacAppHandoffEqual(result.status, 0); BackendMacAppHandoffEqual(result.stdout, ""); BackendMacAppHandoffEqual(calls.arguments, [args]); XCTAssertTrue(calls.requests.isEmpty)
        }
    }
    func testWebURLCarriesRawBodyAndSessionAndDoesNotOpenTwice() async throws {
        let fake = BackendMacAppHandoffFakeOpener()
        let result = try await BackendMacAppHandoffShimInvocation.run(arguments: ["https://example.com/a?b=c"], sessionID: "session-7", ask: { url, session in await fake.ask(url, session, answer: "tab\nOpened in B2 — Terminal Deck.\n") }, opener: { await fake.open($0) }), calls = await fake.result()
        BackendMacAppHandoffEqual(result.status, 0); BackendMacAppHandoffEqual(result.stdout.trimmingCharacters(in: .newlines), "Opened in B2 — Terminal Deck."); BackendMacAppHandoffEqual(calls.requests.count, 1); BackendMacAppHandoffEqual(calls.requests[0].0, "https://example.com/a?b=c"); BackendMacAppHandoffEqual(calls.requests[0].1, "session-7"); XCTAssertTrue(calls.arguments.isEmpty)
        let script = BackendMacAppHandoffOpenShimScript.make(realOpener: "/fixture/open", configPath: "/fixture/endpoint.conf")
        XCTAssertTrue(script.contains("content-type: text/plain")); XCTAssertTrue(script.contains("x-terminaldeck-session: $TERMINALDECK_SESSION_ID")); XCTAssertTrue(script.contains("--data-binary @-")); XCTAssertTrue(script.contains("--connect-timeout 1")); XCTAssertTrue(script.contains("--max-time 3"))
    }
    func testMissingEndpointFallsBackAndSaysSo() async throws {
        let fake = BackendMacAppHandoffFakeOpener()
        let result = try await BackendMacAppHandoffShimInvocation.run(arguments: ["https://example.com/"], sessionID: nil, ask: { _, _ in throw BackendMacAppHandoffTestError(message: "offline") }, opener: { await fake.open($0) }), calls = await fake.result()
        BackendMacAppHandoffEqual(result.status, 0); BackendMacAppHandoffEqual(calls.arguments, [["https://example.com/"]]); XCTAssertTrue(result.stdout.contains("default browser"))
    }
    func testSystemReplyFallsBackWithItsOwnSentence() async throws {
        let fake = BackendMacAppHandoffFakeOpener()
        let result = try await BackendMacAppHandoffShimInvocation.run(arguments: ["https://example.com/"], sessionID: nil, ask: { _, _ in "system\nNo Terminal Deck session here — opened in your default browser.\n" }, opener: { await fake.open($0) }), calls = await fake.result()
        BackendMacAppHandoffEqual(result.status, 0); BackendMacAppHandoffEqual(calls.arguments, [["https://example.com/"]]); XCTAssertTrue(result.stdout.contains("No Terminal Deck session here"))
    }
    func testRealOpenerIsOneAbsoluteLiteralNeverPATHLookup() {
        let script = BackendMacAppHandoffOpenShimScript.make(realOpener: "/usr/bin/open", configPath: "/tmp/x.conf")
        let assignments = script.components(separatedBy: "\n").filter { $0.hasPrefix("REAL_OPENER=") }
        BackendMacAppHandoffEqual(assignments, ["REAL_OPENER='/usr/bin/open'"]); XCTAssertFalse(script.contains("command -v")); XCTAssertFalse(script.contains("`")); XCTAssertFalse(script.contains("$(which"))
    }
    func testOwnFirstPATHDoesNotChangeResolvedOpener() async throws {
        let files = BackendMacAppHandoffFakeFiles(), shim = BackendMacAppHandoffOpenShim(files: files)
        let made = try await shim.write(dataRoot: "/fixture", configPath: "/fixture/hook.conf"), state = await files.snapshot()
        let path = try XCTUnwrap(made?.browser), script = String(decoding: try XCTUnwrap(state.data[path]), as: UTF8.self)
        XCTAssertTrue(script.contains("REAL_OPENER='/usr/bin/open'")); BackendMacAppHandoffEqual(BackendMacAppHandoffOpenShim.prepend(path: "/fixture/shim:/usr/bin", shim: "/fixture/shim"), "/fixture/shim:/usr/bin")
    }
    func testShimIsWrittenThenRemovedAtShutdown() async throws {
        let files = BackendMacAppHandoffFakeFiles(), shim = BackendMacAppHandoffOpenShim(files: files)
        let installed = try await shim.write(dataRoot: "/fixture", configPath: "/fixture/endpoint.conf"), before = await files.snapshot()
        BackendMacAppHandoffEqual(installed?.browser, "/fixture/shim/open"); BackendMacAppHandoffEqual(before.modes["/fixture/shim/open"], 0o755)
        try await shim.remove(dataRoot: "/fixture"); let after = await files.snapshot(), current = await shim.current()
        XCTAssertNil(after.data["/fixture/shim/open"]); XCTAssertNil(current)
    }
    func testPATHPrependsExactlyOnceAndNilLeavesItAlone() { BackendMacAppHandoffEqual(BackendMacAppHandoffOpenShim.prepend(path: "/usr/bin:/bin", shim: "/data/shim"), "/data/shim:/usr/bin:/bin"); BackendMacAppHandoffEqual(BackendMacAppHandoffOpenShim.prepend(path: "/data/shim:/usr/bin", shim: "/data/shim"), "/data/shim:/usr/bin"); BackendMacAppHandoffEqual(BackendMacAppHandoffOpenShim.prepend(path: "/usr/bin", shim: nil), "/usr/bin") }
}
