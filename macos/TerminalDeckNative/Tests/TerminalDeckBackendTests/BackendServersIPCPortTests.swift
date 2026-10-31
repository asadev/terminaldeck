import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Servers IPC TypeScript cases through native facade")
struct BackendServersIPCPortTests {
    private func opened(_ app: BackendServersIPCPortFixture, cols: Double = 100, rows: Double = 40) async throws -> String { let reply = try await app.call("servers:shell:open", .string("s1"), .number(cols), .number(rows)); #expect(reply["ok"].bool == true); return try #require(reply["shellId"].string) }
    @Test func listDoesNotConnect() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let list = try await a.call("servers:list")
        #expect(list.elements?.count == 1); #expect(list.elements?.first?["id"].string == "s1" && list.elements?.first?["name"].string == "demo" && list.elements?.first?["address"].string == "example.test" && list.elements?.first?["username"].string == "root")
        #expect(a.dialer.count == 0 && a.client.commands == [] && a.client.scripts == []); await a.stop()
    }
    @Test func listCarriesNestedIdentityAndCredentialKind() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try a.store.setCredentialKind("s1", credential: .key); _ = try a.store.rememberHostKey("s1", algorithm: "ssh-ed25519", fingerprint: "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0")
        let list = try await a.call("servers:list"), row = try #require(list.elements?.first)
        #expect(row["credential"].string == "key" && row["hostKey"]["algorithm"].string == "ssh-ed25519" && row["hostKey"]["fingerprint"].string == "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0"); #expect(!row.has("fingerprint") && !row.has("privateKey") && !row.has("password")); await a.stop()
    }
    @Test func oneLookBuildsWholeViewAndCachesIt() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let answer = try await a.call("servers:look", .string("s1"))
        #expect(answer["ok"].bool == true && answer["view"]["cards"].elements?.count == 1); #expect(answer["view"]["offered"]["service:mine.service"].elements == [.string("logs"), .string("restart"), .string("stop")]); #expect(await a.room.cached("s1") != nil); await a.stop()
    }
    @Test func lookRefusalIsSentenceEnvelope() async throws {
        let a = try BackendServersIPCPortFixture(failure: NativeRPCError(code: "fixture", message: "That address did not answer in time.")); defer { a.cleanup() }
        #expect(try await a.call("servers:look", .string("s1")) == BackendServersWire.failure("That address did not answer in time.")); await a.stop()
    }
    @Test func previewDoesNotRunAction() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); let before = a.client.commands.count
        let answer = try await a.call("servers:preview", .string("s1"), .string("service:mine.service"), .string("restart")); #expect(answer["preview"]["sentence"].string?.contains("offline for about five seconds") == true && answer["preview"]["klass"].string == "reversible"); #expect(a.client.commands.count == before); await a.stop()
    }
    @Test func unknownActionRefusesBeforeLookup() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; #expect(try await a.call("servers:act", .string("s1"), .string("service:mine.service"), .string("rm -rf /")) == BackendServersWire.failure("That isn’t something this app can do.")); #expect(a.dialer.count == 0 && a.client.commands == []); await a.stop()
    }
    @Test func realActionRunsThenInvalidatesAndNextLookWorks() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1"))
        let answer = try await a.call("servers:act", .string("s1"), .string("service:mine.service"), .string("restart")); #expect(answer["outcome"]["done"].string == "Restarted mine."); #expect(a.client.commands.contains("'systemctl' 'restart' 'mine.service'")); #expect(await a.room.cached("s1") == nil)
        #expect(try await a.call("servers:look", .string("s1"))["ok"].bool == true); await a.stop()
    }
    @Test func logsReplyAndClampAreExact() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let answer = try await a.call("servers:logs", .string("s1"), .string("service:mine.service"), .number(999_999))
        #expect(answer["lines"].elements == [.string("line one"), .string("line two")]); #expect(a.client.commands.first { $0.contains("journalctl") }?.contains("'2000'") == true); await a.stop()
    }
    @Test func shellArmingTypesVisibleLineAndReportsNoRefusal() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; let id = try await opened(a), line = try #require(a.client.shellHandle.writes.first { $0.hasPrefix("export PATH=") })
        #expect(line.contains("/tmp/td-drive-abc123/bin") && line.contains("#")); #expect(await a.shells.whyNotDrive(id) == nil); await a.stop()
    }
    @Test func openedBrowserPortIsMeasured() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; _ = try await opened(a); #expect(a.client.scripts.contains { $0.contains("command -v ss") }); #expect(a.client.forwards.first?.activation != nil); await a.stop()
    }
    @Test func disabledServerCostsNoRemoteRoundTrips() async throws {
        let a = try BackendServersIPCPortFixture(enabled: false); defer { a.cleanup() }; let id = try await opened(a)
        #expect(a.client.shellHandle.writes == [] && a.client.commands == [] && a.client.scripts == [] && a.client.forwards.isEmpty); #expect(await a.shells.whyNotDrive(id)?.contains("turned off") == true); await a.stop()
    }
    @Test func unsupportedMCPFlagStillOpensTerminal() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true, help: "Usage: claude\n"); defer { a.cleanup() }; let id = try await opened(a)
        #expect(a.client.shellHandle.writes == []); #expect(await a.shells.whyNotDrive(id)?.contains("--mcp-config") == true); await a.stop()
    }
    @Test func driveSwitchReturnsActualStoredState() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; #expect(try await a.call("servers:drive-windows", .string("made-up"), .bool(true)) == .object([.init("drivesWindows", .bool(false))])); await a.stop()
    }
    @Test func switchingOffRevokesAlreadyOpenTerminal() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; let id = try await opened(a); #expect(await a.shells.whyNotDrive(id) == nil)
        #expect(try await a.call("servers:drive-windows", .string("s1"), .bool(false)) == .object([.init("drivesWindows", .bool(false))])); #expect(await a.shells.whyNotDrive(id)?.contains("turned off") == true); await a.stop()
    }
    @Test func unknownShellHasNoDriveRefusal() async throws { let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; #expect(await a.shells.whyNotDrive("a shell nobody opened") == nil); await a.stop() }
    @Test func hooksUseSecondMeasuredForwardAndItsOwnAddress() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; _ = try await opened(a)
        #expect(a.client.scripts.filter { $0.contains("command -v ss") }.count == 2); let written = try #require(a.client.scripts.first { $0.contains("bin/claude") })
        for bit in ["bin/open", "bin/td-hook", "settings.json", "context/INDEX.md", "http://127.0.0.1:40405/open"] { #expect(written.contains(bit)) }; await a.stop()
    }
    @Test func shellGetsExactRemoteDocumentMap() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true); defer { a.cleanup() }; let id = try await opened(a)
        #expect(await a.shells.belongingOf(id) == .object([.init("map", .string("read /tmp/td-drive-abc123/context/INDEX.md")), .init("opensInApp", .bool(true))])); #expect(await a.shells.belongingOf("a shell nobody opened") == nil); await a.stop()
    }
    @Test func legacyRowWithoutDriveKeyArmsEverythingAndPerCallGrantSeesOffSwitch() async throws {
        let a = try BackendServersIPCPortFixture(legacy: true); defer { a.cleanup() }; let id = try await opened(a)
        #expect(await a.shells.whyNotDrive(id) == nil); #expect(a.client.shellHandle.writes.contains { $0.hasPrefix("export PATH=") }); #expect(a.client.scripts.first { $0.contains("bin/claude") }?.contains("bin/open") == true)
        #expect(await a.shells.belongingOf(id) == .object([.init("map", .string("read /tmp/td-drive-abc123/context/INDEX.md")), .init("opensInApp", .bool(true))])); #expect(await a.audit.grantsAllowed() == [true])
        _ = try a.store.setDrivesWindows("s1", allowed: false); #expect(await a.audit.grantsAllowed() == [false]); await a.stop()
    }
    @Test func noCurlKeepsBrowserVerbsButClaimsNoBelonging() async throws {
        let a = try BackendServersIPCPortFixture(enabled: true, curl: ""); defer { a.cleanup() }; let id = try await opened(a)
        #expect(await a.shells.whyNotDrive(id) == nil); #expect(await a.shells.belongingOf(id) == nil); #expect(a.client.scripts.filter { $0.contains("command -v ss") }.count == 1); #expect(a.client.scripts.first { $0.contains("bin/claude") }?.contains("bin/open") == false); await a.stop()
    }
    @Test func pageCloseReleasesPageAndKeepsTerminalWritable() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); let id = try await opened(a)
        _ = try await a.call("servers:close", .string("s1")); #expect(a.client.shellHandle.closeCount == 0); #expect(try await a.call("servers:shell:write", .string(id), .string("ls\n")) == .object([.init("written", .bool(true))])); #expect(await a.pool.isOpen("s1")); await a.stop()
    }
    @Test func otherSurfaceCloseKeepsFirstSurfaceTerminal() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); let other = NativeRPCContext(caller: .nativeApp, ownerID: "other-window")
        _ = try await a.ipc.invoke("servers:look", arguments: [.string("s1")], context: other); let id = try await opened(a)
        _ = try await a.ipc.invoke("servers:close", arguments: [.string("s1")], context: other); #expect(a.client.shellHandle.closeCount == 0); #expect(try await a.call("servers:shell:write", .string(id), .string("echo hi\n"))["written"].bool == true); await a.stop()
    }
    @Test func terminalHolderCloseClosesExactlyOnce() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); _ = try await a.call("servers:look", .string("s1")); let id = try await opened(a)
        _ = try await a.call("servers:close", .string("s1")); _ = try await a.call("servers:close", .string("s1")); #expect(a.client.shellHandle.closeCount == 0)
        #expect(try await a.call("servers:shell:close", .string(id)) == .object([.init("closed", .bool(true))])); #expect(a.client.shellHandle.closeCount == 1)
        #expect(try await a.call("servers:shell:write", .string(id), .string("ls\n")) == .object([.init("written", .bool(false))])); #expect(try await a.call("servers:shell:close", .string(id)) == .object([.init("closed", .bool(false))])); #expect(a.client.shellHandle.closeCount == 1); await a.stop()
    }
    @Test func appStopClosesAbandonedTerminal() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); _ = try await opened(a); _ = try await a.call("servers:close", .string("s1")); #expect(a.client.shellHandle.closeCount == 0); await a.stop(); #expect(a.client.shellHandle.closeCount == 1)
    }
    @Test func forgettingServerClosesItsTerminal() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); let id = try await opened(a)
        #expect(try await a.call("servers:forget", .string("s1")) == .object([.init("forgotten", .bool(true))])); #expect(a.client.shellHandle.closeCount == 1); #expect(await a.shells.serverOfShell(id) == nil); await a.stop()
    }
    @Test func shellServerRegistryNeverInfersBrowserBindingFromId() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let id = try await opened(a)
        #expect(await a.shells.serverOfShell(id) == "s1"); #expect(await a.shells.serverOfShell("nothing this app opened") == nil); #expect(id.contains(" ")); #expect(await a.shells.serverOfShell(UUID().uuidString) == nil)
        _ = try await a.call("servers:shell:close", .string(id)); #expect(await a.shells.serverOfShell(id) == nil); await a.stop()
    }
    @Test func unavailableTerminalReturnsHonestSentence() async throws {
        let a = try BackendServersIPCPortFixture(shellUnavailable: true); defer { a.cleanup() }; let r = try await a.call("servers:shell:open", .string("s1"), .number(100), .number(40)); #expect(r["ok"].bool == false && r["sentence"].string == "This copy of the app can’t open a terminal on a server."); await a.stop()
    }
    @Test func shellAndResizeKeepColumnsBeforeRows() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let id = try await opened(a, cols: 132, rows: 43); #expect(a.client.shellHandle.sizes == [.init(cols: 132, rows: 43)]); #expect(a.client.shellHandle.writes == [])
        _ = try await a.call("servers:shell:resize", .string(id), .number(100), .number(25)); #expect(a.client.shellHandle.sizes == [.init(cols: 132, rows: 43), .init(cols: 100, rows: 25)]); await a.stop()
    }
    @Test func remoteOutputUsesTaggedOutputAndClosedChannels() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let id = try await opened(a, cols: 80, rows: 24); a.client.shellHandle.emit("hello\r\n")
        let output = await a.audit.nextOutput(); #expect(output?.0 == "servers:shell:output" && output?.1 == .object([.init("shellId", .string(id)), .init("data", .string("hello\r\n"))]))
        _ = try await a.call("servers:shell:close", .string(id)); #expect(await a.audit.nextOutput()?.0 == "servers:shell:closed"); await a.stop()
    }
    private var draft: NativeRPCValue { .object([.init("address", .string("example.test")), .init("username", .string("root")), .init("method", .string("password")), .init("password", .string("hunter2")), .init("remember", .bool(true))]) }
    @Test func savedSigninNeverCrossesReplyAndStoreLearnsItsKind() async throws {
        let a = try BackendServersIPCPortFixture(secure: true); defer { a.cleanup() }; let r = try await a.call("servers:add", draft)
        #expect(r["ok"].bool == true && r["id"].string == "new-1" && r["savedSignIn"].bool == true && r["note"].string == "Saved."); #expect(!String(decoding: try r.encodedJSON(), as: UTF8.self).contains("hunter2")); #expect(try a.credentials.read("new-1") == .password("hunter2")); #expect(try a.store.get("new-1")?.credential == .password); await a.stop()
    }
    @Test func dontSaveWritesNothingButRetainsSessionSignin() async throws {
        let a = try BackendServersIPCPortFixture(secure: true); defer { a.cleanup() }; let r = try await a.call("servers:add", draft.setting("remember", .bool(false)))
        #expect(r["savedSignIn"].bool == false && r["note"].string?.contains("only until you close the app") == true); #expect(!FileManager.default.fileExists(atPath: a.credentials.file.path)); let heldSecret = try a.credentials.read("new-1"); #expect(a.credentials.isHeldForSessionOnly("new-1") && heldSecret == .password("hunter2")); await a.stop()
    }
    @Test func unavailableSecureStoreStillAddsAndRetainsSessionSignin() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let r = try await a.call("servers:add", draft)
        #expect(r["ok"].bool == true && r["savedSignIn"].bool == false && r["note"].string?.localizedCaseInsensitiveContains("no secure store") == true); let heldSecret = try a.credentials.read("new-1"); #expect(a.credentials.isHeldForSessionOnly("new-1") && heldSecret == .password("hunter2")); await a.stop()
    }
    @Test func lockedKeyAsksForPassphraseBeforeDial() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let locked = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAAAA\n-----END OPENSSH PRIVATE KEY-----"
        let r = try await a.call("servers:add", .object([.init("address", .string("example.test")), .init("username", .string("root")), .init("method", .string("key")), .init("key", .string(locked))])); #expect(r["ok"].bool == false && ["needs-passphrase", "key-unreadable"].contains(r["kind"].string ?? "")); #expect(a.dialer.count == 0); await a.stop()
    }
    @Test func failedFirstDialRollsBackServerAndSignin() async throws {
        let a = try BackendServersIPCPortFixture(secure: true); defer { a.cleanup() }; a.client.dialFailure = .init("sign-in-refused", "That sign-in was refused.")
        let r = try await a.call("servers:add", draft); #expect(r == .object([.init("ok", .bool(false)), .init("kind", .string("sign-in-refused")), .init("sentence", .string("That sign-in was refused."))])); #expect(try a.store.get("new-1") == nil && a.credentials.read("new-1") == nil); await a.stop()
    }
    @Test func changedIdentityCarriesBothFingerprints() async throws {
        let a = try BackendServersIPCPortFixture(failure: BackendServersProblem("identity-changed", "This server answered with a different identity.", expected: "SHA256:aaa", offered: "SHA256:bbb")); defer { a.cleanup() }
        let r = try await a.call("servers:look", .string("s1")); #expect(r["ok"].bool == false && r["sentence"].string == "This server answered with a different identity." && r["detail"].string == "" && r["kind"].string == "identity-changed"); #expect(r["identity"] == .object([.init("expected", .string("SHA256:aaa")), .init("offered", .string("SHA256:bbb"))])); await a.stop()
    }
    @Test func forgetOnlyDeletesLocalRecordsAndSendsNoCommands() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); let before = a.client.commands.count, scripts = a.client.scripts.count
        #expect(try await a.call("servers:forget", .string("s1")) == .object([.init("forgotten", .bool(true))])); #expect(try a.store.get("s1") == nil && a.credentials.read("s1") == nil); #expect(a.client.commands.count == before && a.client.scripts.count == scripts); #expect(!(await a.pool.isOpen("s1"))); await a.stop()
    }
    @Test func grantReportRevokePerServer() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let r = try await a.call("servers:grant", .string("s1"), .number(60_000)); #expect(r["grant"]["serverId"].string == "s1"); #expect(try await a.call("servers:grant-state", .string("s1"))["serverId"].string == "s1"); #expect(try await a.call("servers:revoke", .string("s1")) == .object([.init("revoked", .bool(true))])); #expect(try await a.call("servers:grant-state", .string("s1")) == .null); await a.stop()
    }
    @Test func unknownServerGrantRefuses() async throws { let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; #expect(try await a.call("servers:grant", .string("made-up"), .number(60_000))["ok"].bool == false); await a.stop() }
    @Test func stopDropsEveryGrant() async throws { let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; _ = try await a.call("servers:grant", .string("s1"), .number(60_000)); await a.stop(); #expect(await a.room.grants.state("s1") == nil) }
    @Test func IPCUpdateWritesExactWayBackToLocalComputer() async throws {
        let a = try BackendServersIPCPortFixture(fileJournal: true); defer { a.cleanup() }; _ = try await a.call("servers:look", .string("s1")); #expect(try await a.call("servers:act", .string("s1"), .string("service:mine.service"), .string("update"))["ok"].bool == true)
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: a.root.appendingPathComponent("server-waybacks.json"))), row = try #require(raw["rows"].fields?.first?.value)
        #expect(row["kind"].string == "repo-commit" && row["commit"].string == String(repeating: "d", count: 40)); #expect(!a.client.commands.contains { $0.contains("server-waybacks.json") }); await a.stop()
    }
    private func uploadFile(_ a: BackendServersIPCPortFixture) throws -> URL { let file = a.root.appendingPathComponent("td-upload-fixture.png"); try Data("x".utf8).write(to: file); return file }
    @Test func uploadRepliesWithRemotePlacedPath() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let file = try uploadFile(a), r = try await a.call("servers:upload", .string("s1"), .string(file.path))
        #expect(r == .object([.init("ok", .bool(true)), .init("path", .string("/home/custom/Terminal Deck/td-upload-fixture.png"))])); #expect(a.client.sftp.renames.last?.1 == r["path"].string); await a.stop()
    }
    @Test func uploadSuggestionIsFilesOwnBasename() async throws {
        let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let file = try uploadFile(a); _ = try await a.call("servers:upload", .string("s1"), .string(file.path))
        #expect(a.client.sftp.puts == ["/home/custom/Terminal Deck/td-upload-fixture.png.part"]); #expect(!a.client.sftp.puts.contains { $0.contains(a.root.path) }); await a.stop()
    }
    @Test func unavailableUploaderRefuses() async throws { let a = try BackendServersIPCPortFixture(uploadUnavailable: true); defer { a.cleanup() }; let file = try uploadFile(a); #expect(try await a.call("servers:upload", .string("s1"), .string(file.path))["ok"].bool == false); await a.stop() }
    @Test func missingUploadFileNeverDials() async throws { let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; #expect(try await a.call("servers:upload", .string("s1"), .string(a.root.appendingPathComponent("td-not-a-file.png").path))["ok"].bool == false); #expect(a.dialer.count == 0 && a.client.sftp.puts.isEmpty); await a.stop() }
    @Test func uploadRefusalKeepsServersOwnSentence() async throws {
        let a = try BackendServersIPCPortFixture(uploadFailure: .init("not-allowed", "This sign-in is not allowed to write there.")); defer { a.cleanup() }; let file = try uploadFile(a)
        #expect(try await a.call("servers:upload", .string("s1"), .string(file.path)) == .object([.init("ok", .bool(false)), .init("message", .string("This sign-in is not allowed to write there."))])); await a.stop()
    }
    @Test func uploadRequiresServerAndFile() async throws { let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; #expect(try await a.call("servers:upload", .number(7), .string("/fixture.png"))["ok"].bool == false); #expect(try await a.call("servers:upload", .string("s1"), .string(""))["ok"].bool == false); await a.stop() }
    @Test func shellAccountUsesOneCachedProbe() async throws {
        let raw = BackendServersIPCPortClient.facts.replacingOccurrences(of: "#agents ok\n", with: "#agents ok\nclaude\t/usr/bin/claude\t2.0.0\tyes\tme@example.test\n"), a = try BackendServersIPCPortFixture(raw: raw); defer { a.cleanup() }; let id = try await opened(a)
        let wanted: NativeRPCValue = .object([.init("known", .string("yes")), .init("agents", .number(1)), .init("logins", .array([.object([.init("agentId", .string("claude")), .init("account", .string("me@example.test"))])]))])
        #expect(try await a.call("servers:shell:account", .string(id)) == wanted); _ = try await a.call("servers:shell:account", .string(id)); #expect(a.client.probes == 1); await a.stop()
    }
    @Test func shellAccountNamesEveryLoginIncludingKeyWithoutAddress() async throws {
        let raw = BackendServersIPCPortClient.facts.replacingOccurrences(of: "#agents ok\n", with: "#agents ok\nclaude\t/usr/bin/claude\t2.0.0\tno\t\ncodex\t/usr/bin/codex\t0.149.0\tyes\ta@example.test\ngemini\t/usr/bin/gemini\t0.56.0\tyes\t\n"), a = try BackendServersIPCPortFixture(raw: raw); defer { a.cleanup() }; let id = try await opened(a)
        #expect(try await a.call("servers:shell:account", .string(id)) == .object([.init("known", .string("yes")), .init("agents", .number(3)), .init("logins", .array([.object([.init("agentId", .string("codex")), .init("account", .string("a@example.test"))]), .object([.init("agentId", .string("gemini")), .init("account", .null)])]))])); await a.stop()
    }
    @Test func shellAccountNoLoginIsExplicitAnswer() async throws { let a = try BackendServersIPCPortFixture(); defer { a.cleanup() }; let id = try await opened(a); #expect(try await a.call("servers:shell:account", .string(id)) == .object([.init("known", .string("yes")), .init("agents", .number(0)), .init("logins", .array([]))])); await a.stop() }
    @Test func shellAccountNoAnswerDoesNotFailBar() async throws { let a = try BackendServersIPCPortFixture(failure: BackendServersProblem("no-answer", "That address did not answer.")); defer { a.cleanup() }; let id = try await opened(a); #expect(try await a.call("servers:shell:account", .string(id)) == .object([.init("known", .string("cannot")), .init("why", .string("This server did not answer."))])); await a.stop() }
    @Test func zeroHostChannelsContradictOnlineLocalRowAndRedialOnce() async throws {
        let a = try BackendServersIPCPortFixture(channels: 0, standing: ("office-pc", true)); defer { a.cleanup() }; let r = try await a.call("servers:host:look", .string("s1")); #expect(r["offer"]["linkedAs"].string == "office-pc" && r["offer"]["linkedButNotConnected"].bool == true); #expect(await a.audit.nextRedial() == "KZ2J9AWGK8BWGQUEZDYKW5RS22"); #expect(await a.audit.redialled() == ["KZ2J9AWGK8BWGQUEZDYKW5RS22"]); await a.stop()
    }
    @Test func offlineLocalRowRedialsEvenWithTwoOtherHostChannels() async throws {
        let a = try BackendServersIPCPortFixture(channels: 2, standing: ("office-pc", false)); defer { a.cleanup() }; let r = try await a.call("servers:host:look", .string("s1")); #expect(r["offer"]["linkedButNotConnected"].bool == true); #expect(await a.audit.nextRedial() == "KZ2J9AWGK8BWGQUEZDYKW5RS22"); #expect(await a.audit.redialled() == ["KZ2J9AWGK8BWGQUEZDYKW5RS22"]); await a.stop()
    }
    @Test func workingHostLinkIsLeftAlone() async throws { let a = try BackendServersIPCPortFixture(channels: 1, standing: ("office-pc", true)); defer { a.cleanup() }; let r = try await a.call("servers:host:look", .string("s1")); #expect(r["offer"]["linkedAs"].string == "office-pc" && r["offer"]["linkedButNotConnected"].bool == false); #expect(await a.audit.redialled() == []); await a.stop() }
    @Test func neverLinkedHostHasNoConnectionClaim() async throws { let a = try BackendServersIPCPortFixture(channels: 0); defer { a.cleanup() }; let r = try await a.call("servers:host:look", .string("s1")); #expect(r["offer"]["linkedAs"] == .null && r["offer"]["linkedButNotConnected"].bool == false); #expect(await a.audit.redialled() == []); await a.stop() }
}
