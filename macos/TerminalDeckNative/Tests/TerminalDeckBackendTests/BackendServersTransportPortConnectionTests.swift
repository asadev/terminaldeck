import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Every connection.ts app rule with fake channels")
struct BackendServersTransportPortConnectionTests {
    @Test func quoteFingerprintAndMalformedAlgorithm() {
        for pair in [("simple", "'simple'"), ("a b", "'a b'"), ("$(rm -rf /)", "'$(rm -rf /)'"), ("it's", "'it'\\''s'"), ("`x`", "'`x`'")] { #expect(BackendServersConnections.quote(pair.0) == pair.1) }
        #expect(BackendServersConnections.fingerprintOf(BackendServersTransportPortDialer.key) == "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0")
        #expect(BackendServersConnections.algorithmOf(BackendServersTransportPortDialer.key) == "ssh-ed25519")
        #expect(BackendServersConnections.algorithmOf(Data([1, 2])) == "" && BackendServersConnections.algorithmOf(Data(repeating: 0, count: 8)) == "")
    }
    @Test func allSevenFailureSignalsBusyLoginAndFallback() {
        let table: [(String, BackendServersSSHSignal, String)] = [("a typo in the address", .init(code: "ENOTFOUND"), "no-such-address"), ("nothing there", .init(code: "ECONNREFUSED"), "no-answer"), ("no answer at all", .init(level: "client-timeout"), "no-answer"), ("the wrong sign-in", .init(level: "client-authentication"), "sign-in-refused"), ("something that is not a server", .init(level: "protocol"), "not-a-server"), ("a server that said nothing at all", .init(level: "protocol", message: "Connection lost before handshake"), "said-nothing"), ("nothing in common", .init(level: "handshake", message: "no matching cipher"), "nothing-in-common")]
        for item in table { let result = BackendServersProblem.problemFor(item.1); #expect(result.kind == item.2 && result.sentence.first?.isUppercase == true && result.sentence.hasSuffix(".")) }
        let busy = BackendServersProblem.problemFor(BackendServersSSHSignal(level: "protocol", message: "Connection lost before handshake"))
        #expect(busy.kind == "said-nothing" && busy.sentence.contains("try again"))
        #expect(!busy.sentence.hasPrefix("Something answered at that address, but it is not a server"))
        let refused = BackendServersProblem.problemFor(BackendServersSSHSignal(level: "client-authentication", message: "All configured authentication methods failed"))
        #expect(!refused.sentence.contains("password is wrong") && !refused.sentence.contains("username is wrong"))
        #expect(refused.sentence.contains("username") && refused.sentence.contains("password or key"))
        let original = BackendServersProblem("identity-changed", BackendServersConnections.identityChanged)
        #expect(BackendServersProblem.problemFor(original) == original)
        #expect(BackendServersProblem.problemFor(BackendServersSSHSignal(message: "who knows")).kind == "lost")
        #expect(BackendServersProblem.problemFor(nil).sentence.count > 20)
    }
    @Test func oneConnectionRefcountsAndNoIdleConnection() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        #expect(!(await app.pool.isOpen("one")))
        let one = try await app.pool.acquireLease("one"), two = try await app.pool.acquireLease("one")
        #expect(app.dialer.clients.count == 1)
        await app.pool.release(one); let oneOpen = await app.pool.isOpen("one"); #expect(app.client.closeCount == 0 && oneOpen)
        await app.pool.release(two); let oneStillOpen = await app.pool.isOpen("one"); #expect(app.client.closeCount == 1 && !oneStillOpen)
    }
    @Test func remoteDropEvictsAndOldSecondCloseDoesNotEvictReplacement() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let first = try await app.pool.acquireLease("one"), old = app.client
        old.drop(); _ = try await app.events.gate("dropped").value()
        #expect(!(await app.pool.isOpen("one")))
        let replacement = try await app.pool.acquireLease("one")
        #expect(app.dialer.clients.count == 2)
        old.drop(); await app.pool.release(first)
        #expect(await app.pool.isOpen("one")); await app.pool.release(replacement)
    }
    @Test func throwingBodyReleasesAndUnknownOrMissingLoginNeverDials() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        do { _ = try await app.pool.withConnection("one") { _ -> Bool in throw BackendServersProblem("lost", "the action failed") }; Issue.record("Missing rejection") } catch { #expect(error.localizedDescription == "the action failed") }
        #expect(!(await app.pool.isOpen("one")))
        do { try await app.pool.acquire("nothing"); Issue.record("Unknown dial") } catch let failure as BackendServersProblem { #expect(failure.kind == "unknown-server") }
        let empty = try BackendServersTransportPortFixture(credential: nil); defer { empty.cleanup() }
        do { try await empty.pool.acquire("one"); Issue.record("No-login dial") } catch let failure as BackendServersProblem { #expect(failure.kind == "no-sign-in") }
        #expect(empty.dialer.clients.isEmpty)
    }
    @Test func firstIdentityRecordedChangedIdentityRefusedWithoutReplacement() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let lease = try await app.pool.acquireLease("one")
        #expect(try app.store.get("one")?.hostKey?.algorithm == "ssh-ed25519")
        #expect(try app.store.get("one")?.hostKey?.fingerprint == "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0")
        await app.pool.release(lease)
        _ = try app.store.forgetHostKey("one"); _ = try app.store.rememberHostKey("one", algorithm: "ssh-ed25519", fingerprint: "SHA256:somethingelseentirely")
        do { try await app.pool.acquire("one"); Issue.record("Changed identity accepted") } catch let failure as BackendServersProblem {
            #expect(failure.kind == "identity-changed" && failure.expected == "SHA256:somethingelseentirely" && failure.offered == "SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0")
        }
        #expect(try app.store.get("one")?.hostKey?.fingerprint == "SHA256:somethingelseentirely")
    }
    @Test func partsStdinProbeAndEmptyCommands() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let lease = try await app.pool.acquireLease("one")
        _ = try await app.pool.run("one", argv: ["systemctl", "restart", "my site.service"])
        #expect(app.client.commands.last?.0 == "'systemctl' 'restart' 'my site.service'")
        _ = try await app.pool.runScript("one", script: "echo hello")
        #expect(app.client.commands.last?.0 == "sh -s" && app.client.commands.last?.1 == Data("echo hello".utf8))
        app.client.answer = .init(code: 0, stdout: "os=Alpine Linux v3.24\ninit=openrc\n#end ok\n")
        let facts = try await BackendServersProbe.gather("one", connections: app.pool, measuredAt: { 1000 })
        #expect(facts.os.value == "Alpine Linux v3.24" && facts.`init`.value == .openrc && facts.serverId == "one")
        do { _ = try await app.pool.run("one", argv: []); Issue.record("Empty run") } catch { #expect(error is BackendServersProblem) }
        do { _ = try await app.pool.follow("one", argv: []); Issue.record("Empty follow") } catch { #expect(error is BackendServersProblem) }
        await app.pool.release(lease)
    }
    @Test func commandPtyAndFollowKeepSplitUnicodeWhole() async throws {
        let whole = "file\t2026-08-21T09:00:00.000Z\t/home/ada/Café/a→b/x.jsonl\n", bytes = Data(whole.utf8)
        let acute = try #require(bytes.range(of: Data("é".utf8))).lowerBound + 1, arrow = try #require(bytes.range(of: Data("→".utf8))).lowerBound + 2
        let chunks = [Data(bytes.prefix(acute)), Data(bytes[acute..<arrow]), Data(bytes.dropFirst(arrow))]
        let collector = BackendServersSSHBuffer(maximum: 4 * 1024 * 1024); for chunk in chunks { collector.takeOutput(chunk) }
        #expect(collector.outputText == whole && !collector.outputText.contains("\u{fffd}"))
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let shell = try await app.pool.shell("one", size: .init(cols: 80, rows: 24)), text = BackendServersTransportPortRecorder<String>()
        _ = shell.onData { text.add($0) }; for chunk in chunks { app.client.shellStream.bytes(chunk) }
        #expect(text.values.joined() == whole && !text.values.joined().contains("\u{fffd}"))
        let followed = try await app.pool.follow("one", argv: ["tail", "-n", "0", "-f", "x"]), seen = BackendServersTransportPortRecorder<Data>()
        _ = followed.onBytes { seen.add($0) }; for chunk in chunks { try app.client.followed.push(chunk) }
        #expect(seen.values.reduce(into: Data()) { $0.append($1) } == bytes)
        followed.close(); shell.close(); _ = try await app.events.gate("released").value()
    }
    @Test func followCloseAndRemoteEndReleaseOnceAndKeepComplaint() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let stream = try await app.pool.follow("one", argv: ["tail", "-n", "0", "-f", "/x.jsonl"])
        #expect(await app.pool.isOpen("one")); stream.close(); stream.close(); _ = try await app.events.gate("released").value()
        #expect(!(await app.pool.isOpen("one")))
        let fresh = try await app.pool.acquireLease("one"); stream.close(); #expect(await app.pool.isOpen("one")); await app.pool.release(fresh)
        let other = try BackendServersTransportPortFixture(); defer { other.cleanup() }
        let reading = try await other.pool.follow("one", argv: ["tail", "-n", "0", "-f", "/x.jsonl"]), ends = BackendServersTransportPortRecorder<BackendServersFollowEnd>()
        _ = reading.onEnd { ends.add($0) }; other.client.followed.finish(.init(code: 1, stderr: "tail: unrecognized option"))
        _ = try await other.events.gate("released").value()
        let otherOpen = await other.pool.isOpen("one")
        #expect(ends.values == [.init(code: 1, stderr: "tail: unrecognized option")] && !otherOpen)
    }
    @Test func followChannelErrorAndTerminalSizeResizeCloseAreEvents() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let followed = try await app.pool.follow("one", argv: ["tail", "-f", "/x"]), ends = BackendServersTransportPortRecorder<BackendServersFollowEnd>()
        _ = followed.onEnd { ends.add($0) }; app.client.followed.finish(.init(code: nil, stderr: "")); _ = try await app.events.gate("released").value()
        let appOpen = await app.pool.isOpen("one")
        #expect(ends.values.count == 1 && !appOpen)
        app.events.reset("released")
        let shell = try await app.pool.shell("one", size: .init(cols: 137, rows: 41)), client = app.dialer.clients.last!
        #expect(client.shellStream.size == .init(cols: 137, rows: 41))
        shell.resize(.init(cols: 80, rows: 24)); shell.resize(.init(cols: 137, rows: 41)); #expect(client.shellStream.size == .init(cols: 137, rows: 41))
        shell.close(); shell.close(); _ = try await app.events.gate("released").value()
        let page = try await app.pool.acquireLease("one"); shell.close(); #expect(await app.pool.isOpen("one")); await app.pool.release(page)
    }
    @Test func putHomeFolderCreationFreeNameAndSafeBasename() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let lease = try await app.pool.acquireLease("one"), desk = app.client.sftp
        let local = "/Users/apple/Pictures/Terminal Deck/shot.png", folder = BackendSharedBrand.name
        let first = try await app.pool.putFile("one", localPath: local, name: "shot.png", folder: folder)
        #expect(first == "/home/kiwi/\(folder)/shot.png")
        #expect(desk.puts.map { $0.0 } == [local] && desk.puts.map { $0.1 } == [first + ".part"])
        #expect(desk.renames.map { $0.0 } == [first + ".part"] && desk.renames.map { $0.1 } == [first])
        #expect(desk.made == ["/home/kiwi/\(folder)"])
        let second = try await app.pool.putFile("one", localPath: local, name: "shot.png", folder: folder)
        #expect(second == "/home/kiwi/\(folder)/shot (2).png" && desk.made.count == 1)
        let safe = try await app.pool.putFile("one", localPath: local, name: "../../etc/passwd", folder: folder)
        #expect(safe == "/home/kiwi/\(folder)/passwd")
        desk.home = "/var/root"
        #expect(try await app.pool.putFile("one", localPath: local, name: "shot.png", folder: folder) == "/var/root/\(folder)/shot.png")
        #expect(app.dialer.clients.count == 1 && app.client.closeCount == 0 && desk.closeCount == 4)
        await app.pool.release(lease)
    }
    @Test func putPermissionSubsystemAndChannelLifetimeFailures() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        app.client.sftp.refused["/home/kiwi/\(BackendSharedBrand.name)"] = 3
        do { _ = try await app.pool.putFile("one", localPath: "/local", name: "shot.png", folder: BackendSharedBrand.name); Issue.record("Permission became free name") } catch let error as BackendServersProblem { #expect(error.kind == "not-allowed") }
        #expect(app.client.sftp.puts.isEmpty && app.client.sftp.closeCount == 1 && app.client.closeCount == 1)
        app.dialer.next.absentSFTP = true
        do { _ = try await app.pool.putFile("one", localPath: "/local", name: "shot.png", folder: BackendSharedBrand.name); Issue.record("Absent SFTP succeeded") } catch let error as BackendServersProblem { #expect(error.kind == "not-a-server" && error.sentence.contains("folders")) }
    }
    @Test func chosenFolderPartialRenameOrderHomeAndAbsolutePaths() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let lease = try await app.pool.acquireLease("one"), desk = app.client.sftp
        #expect(try await app.pool.putFile("one", localPath: "/here/report.pdf", name: "report.pdf", folder: "/srv/incoming") == "/srv/incoming/report.pdf")
        #expect(desk.calls == ["stat /srv/incoming", "mkdir /srv/incoming", "stat /srv/incoming/report.pdf", "put /srv/incoming/report.pdf.part", "rename /srv/incoming/report.pdf.part /srv/incoming/report.pdf"])
        #expect(desk.closeCount == 1)
        desk.home = "/home/asad"; desk.calls = []
        #expect(try await app.pool.putFile("one", localPath: "/here/a.bin", name: "a.bin", folder: "") == "/home/asad/a.bin")
        #expect(desk.calls.first == "realpath .")
        desk.calls = []; _ = try await app.pool.putFile("one", localPath: "/here/a.bin", name: "a.bin", folder: "/srv")
        #expect(!desk.calls.contains("realpath ."))
        desk.present.formUnion(["/srv", "/srv/report.pdf"])
        #expect(try await app.pool.putFile("one", localPath: "/here/report.pdf", name: "report.pdf", folder: "/srv") == "/srv/report (2).pdf")
        await app.pool.release(lease)
    }
    @Test func failedPartialDeletesOnlyOwnPartialAndDoesNotRename() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        app.client.sftp.present.insert("/srv"); app.client.sftp.putFails = true
        do { _ = try await app.pool.putFile("one", localPath: "/here/a.bin", name: "a.bin", folder: "/srv"); Issue.record("False partial success") } catch { #expect(error is BackendServersProblem) }
        #expect(app.client.sftp.unlinked == ["/srv/a.bin.part"] && app.client.sftp.renames.isEmpty)
    }
    @Test func serverConnectionsNeverOwnARepeatingTimer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend")
        let pool = try String(contentsOf: root.appendingPathComponent("BackendServersConnection.swift"), encoding: .utf8), ssh = try String(contentsOf: root.appendingPathComponent("BackendServersSSH.swift"), encoding: .utf8)
        #expect(ssh.contains("ServerAliveInterval=0") && ssh.contains("TCPKeepAlive=no"))
        #expect(!pool.contains("Timer.scheduledTimer") && !pool.contains("setInterval") && !pool.contains("Task.sleep"))
    }
}
