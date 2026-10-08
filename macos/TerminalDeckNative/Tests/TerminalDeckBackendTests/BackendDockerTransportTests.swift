import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Docker HTTP transport, with no sockets or servers")
struct BackendDockerTransportTests {
    @Test func splitHeadersAndLengthBodyPreserveStatusAndBytes() async throws {
        let body = Data([0, 1, 127, 255])
        var reply = Data("HTTP/1.1 404 Missing\r\nContent-Length: 4\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        reply.append(body)
        let fixture = BackendDockerTransportFixture(fragments: reply.map { Data([$0]) })
        let transport = BackendDockerHTTPTransport(opener: { fixture })
        let result = try await transport.request(.init(path: "/version"))
        #expect(result.status == 404)
        #expect(result.headers["content-type"] == "application/octet-stream")
        #expect(result.body == body)
        #expect(fixture.closeCount == 1)
        let request = String(decoding: fixture.writes[0], as: UTF8.self)
        #expect(request.hasPrefix("GET /version HTTP/1.1\r\n"))
        #expect(request.contains("host: docker\r\n"))
        #expect(request.contains("connection: close\r\n"))
    }

    @Test func chunkedWithExtensionsAndTrailersAcrossEveryByte() async throws {
        let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;name=value\r\nWiki\r\n5\r\npedia\r\n0\r\nDocker-Test: passed\r\n\r\n"
        let fixture = BackendDockerTransportFixture(fragments: wire.utf8.map { Data([$0]) })
        let response = try await BackendDockerHTTPTransport(opener: { fixture }).request(.init(path: "/version"))
        #expect(String(decoding: response.body, as: UTF8.self) == "Wikipedia")
        #expect(fixture.closeCount == 1)
    }

    @Test func eofBodyAndInformationalResponseAreSupported() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.0 200 OK\r\n\r\neof body".utf8)], endAfterReply: true)
        let response = try await BackendDockerHTTPTransport(opener: { fixture }).request(.init(path: "/version"))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "eof body")
    }

    @Test func finiteRepliesStartReceivingOnlyAfterRequestWriteAcknowledgement() async throws {
        let body = Data((0..<192).map { UInt8($0) })
        var reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 192\r\n\r\n".utf8)
        reply.append(body)
        let fixture = BackendDockerPausedWriteFixture(reply: reply)
        var limits = BackendDockerTransportLimits(); limits.maximumReadBytes = 64
        let response = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).request(.init(path: "/version"))
        #expect(response.status == 200 && response.body == body)
        #expect(fixture.resumesBeforeAcknowledgement == 0)
        #expect(fixture.writeCount == 1 && fixture.closeCount == 1)
    }

    @Test(arguments: [200, 403, 404, 500])
    func completeFramedReplySurvivesPeerCloseAfterReceivedBytes(status: Int) async throws {
        let body = Data(repeating: 65, count: 192)
        var reply = Data("HTTP/1.1 \(status) Reply\r\nContent-Length: 192\r\n\r\n".utf8)
        reply.append(body)
        let fixture = BackendDockerPausedWriteFixture(reply: reply, closeAfterReply: true)
        var limits = BackendDockerTransportLimits(); limits.maximumReadBytes = 64
        let response = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).request(.init(path: "/version"))
        #expect(response.status == status && response.body == body)
        #expect(fixture.closeCount == 1)
    }

    @Test func truncatedFramedReplyStillFailsAfterPeerClose() async throws {
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 192\r\n\r\nshort-secret-body".utf8)
        let fixture = BackendDockerPausedWriteFixture(reply: reply, closeAfterReply: true)
        do {
            _ = try await BackendDockerHTTPTransport(opener: { fixture }).request(.init(path: "/version"))
            Issue.record("A truncated reply became successful")
        } catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
            #expect(!error.message.contains("short-secret-body") && error.details == .missing)
        }
    }

    @Test func ambiguousFramingAndEarlyEofFailWithSafeErrors() async throws {
        let cases = [
            ("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\nsecret", false),
            ("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nxx", false),
            ("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", true),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nx", true),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n", false),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n", false),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r", true),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nBad: \u{01}\r\n\r\n", false),
            ("HTTP/1.1 200 OK\r\nContent-Length: 0\r", true),
        ]
        for (wire, eof) in cases {
            let fixture = BackendDockerTransportFixture(fragments: [Data(wire.utf8)], endAfterReply: eof)
            do {
                _ = try await BackendDockerHTTPTransport(opener: { fixture }).request(.init(path: "/version"))
                Issue.record("Malformed HTTP succeeded")
            } catch let error as NativeRPCError {
                #expect(error.code == "docker-protocol")
                #expect(!error.message.contains("secret"))
                #expect(fixture.closeCount == 1)
            }
        }
    }

    @Test func bodyAndHeaderBoundsCloseTheConnection() async throws {
        var bodyLimits = BackendDockerTransportLimits(); bodyLimits.maximumBodyBytes = 3
        let body = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234".utf8)])
        do {
            _ = try await BackendDockerHTTPTransport(opener: { body }, limits: bodyLimits).request(.init(path: "/version"))
            Issue.record("Oversized body succeeded")
        } catch let error as NativeRPCError { #expect(error.code == "docker-stream-overflow"); #expect(body.closeCount == 1) }
        var headLimits = BackendDockerTransportLimits(); headLimits.maximumHeaderBytes = 128
        let head = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nX-Test: \(String(repeating: "x", count: 256))\r\nContent-Length: 0\r\n\r\n".utf8)])
        do {
            _ = try await BackendDockerHTTPTransport(opener: { head }, limits: headLimits).request(.init(path: "/version"))
            Issue.record("Oversized headers succeeded")
        } catch let error as NativeRPCError { #expect(error.code == "docker-protocol"); #expect(head.closeCount == 1) }
    }

    @Test func requestValidationNeverOpensAConnection() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [])
        let calls = BackendDockerTransportFixtureCounter()
        let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture })
        for request in [BackendDockerRequest(path: "/version\r\nDELETE /containers/x"), .init(path: "/version", headers: ["X-Test": "bad\r\nInjected: yes"]), .init(path: "/version", headers: ["Transfer-Encoding": "chunked"]), .init(path: "https://elsewhere/version")] {
            do { _ = try await transport.request(request); Issue.record("Invalid request succeeded") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect(calls.value == 0)
        #expect(fixture.writes.isEmpty)
    }

    @Test func dependencyErrorsNeverExposeSshTextOrDetails() async throws {
        let transport = BackendDockerHTTPTransport(opener: {
            throw NativeRPCError(code: "docker-permission", message: "ssh stderr secret-password", details: .string("secret-key"))
        })
        do { _ = try await transport.request(.init(path: "/version")); Issue.record("A failed opener succeeded") }
        catch let error as NativeRPCError {
            #expect(error.code == "docker-permission")
            #expect(!error.message.contains("secret"))
            #expect(error.details == .missing)
        }
    }

    @Test func sshUsesOnlyFixedDialStdioCommandAndExistingDuplex() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)])
        let command = BackendDockerTransportFixtureCommand()
        let transport = BackendDockerSSHTransport(openDialStdio: { value in command.record(value); return fixture })
        let result = try await transport.request(.init(path: "/version"))
        #expect(result.status == 200)
        #expect(command.values == ["docker system dial-stdio"])
    }

    @Test func trustedCaddyHostUsesTheExistingPrivateByteOpener() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)])
        let calls = BackendDockerTransportFixtureCounter()
        let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture }, host: "localhost:2019")
        #expect(calls.value == 0)
        let response = try await transport.request(.init(path: "/config/"))
        #expect(response.status == 200)
        #expect(response.body == Data("{}".utf8))
        #expect(calls.value == 1)
        let wire = String(decoding: fixture.writes[0], as: UTF8.self)
        #expect(wire.hasPrefix("GET /config/ HTTP/1.1\r\n"))
        #expect(wire.contains("host: localhost:2019\r\n"))
        #expect(!wire.contains("host: docker\r\n"))
        #expect(fixture.closeCount == 1)
    }

    @Test func privateHostWhitelistCannotBeOverriddenByRequestHeaders() async throws {
        for host in ["docker", "localhost:2019", "127.0.0.1:2019", "[::1]:2019"] {
            let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)])
            let transport = BackendDockerHTTPTransport(opener: { fixture }, host: host)
            _ = try await transport.request(.init(path: "/config/"))
            #expect(String(decoding: fixture.writes[0], as: UTF8.self).contains("host: \(host)\r\n"))
        }
        let fixture = BackendDockerTransportFixture(fragments: [])
        let calls = BackendDockerTransportFixtureCounter()
        for host in ["", "example.com:2019", "203.0.113.10:2019", "localhost:80", "localhost:2019\r\nX-Injected: yes", "user@localhost:2019"] {
            let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture }, host: host)
            do { _ = try await transport.request(.init(path: "/config/")); Issue.record("An invalid private host opened a connection") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture }, host: "localhost:2019")
        do { _ = try await transport.request(.init(path: "/config/", headers: ["Host": "example.com"])); Issue.record("A request overrode its trusted host") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(calls.value == 0)
        #expect(fixture.writes.isEmpty)
    }

    @Test func missingLocalSocketIsClassifiedBeforeNetworkOpeningWithoutPathDetails() async throws {
        let path = "/private/tmp/dke-missing-" + UUID().uuidString + ".sock"
        var limits = BackendDockerTransportLimits(); limits.openTimeoutMilliseconds = 500
        let transport = BackendDockerLocalTransport(socketPath: path, limits: limits)
        do { _ = try await transport.request(.init(path: "/version")); Issue.record("A missing socket returned success") }
        catch let error as NativeRPCError {
            #expect(error.code == "docker-not-found")
            #expect(!error.message.contains(path))
            #expect(error.details == .missing)
        }
    }

    @Test func regularFileAndNonDirectorySocketParentsAreRefusedWithoutChangingContents() async throws {
        let manager = FileManager.default
        let name = "dke-" + UUID().uuidString.prefix(8).lowercased()
        let roots = [manager.temporaryDirectory.path, "/tmp", "/private/tmp"]
        let root = try #require(roots.first { candidate in
            let folder = candidate.hasSuffix("/") ? candidate + name : candidate + "/" + name
            var isDirectory: ObjCBool = false
            return (folder + "/f/http.sock").utf8.count < 104 &&
                manager.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
        })
        let folder = root.hasSuffix("/") ? root + name : root + "/" + name
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(atPath: folder) }
        let path = folder + "/f"
        #expect((path + "/http.sock").utf8.count < 104)
        let file = URL(fileURLWithPath: path)
        let original = Data("This is an ordinary file, not a Docker endpoint.".utf8)
        let transport = BackendDockerLocalTransport(socketPath: path)
        // Construction is inert, including before the candidate exists.
        try original.write(to: file, options: .withoutOverwriting)
        let requests = [transport, BackendDockerLocalTransport(socketPath: path + "/http.sock")]
        for candidate in requests {
            do { _ = try await candidate.request(.init(path: "/version")); Issue.record("A non-socket endpoint returned success") }
            catch let error as NativeRPCError {
                #expect(error.code == "docker-not-found")
                #expect(!error.message.contains(path))
                #expect(error.details == .missing)
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func hijackKeepsPostHeaderBytesAndWritesRawInput() async throws {
        var response = Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8)
        response.append(Data([0, 255, 13, 10]))
        let fixture = BackendDockerTransportFixture(fragments: [response])
        let duplex = try await BackendDockerHTTPTransport(opener: { fixture }).hijack(.init(method: "POST", path: "/exec/one/start", body: Data("{}".utf8)))
        #expect(duplex.status == 101)
        var iterator = duplex.incoming.makeAsyncIterator()
        #expect(try await iterator.next() == Data([0, 255, 13, 10]))
        try await duplex.write(Data([3]))
        #expect(fixture.writes.last == Data([3]))
        let request = String(decoding: fixture.writes[0], as: UTF8.self)
        #expect(request.contains("connection: Upgrade\r\n"))
        #expect(request.contains("upgrade: tcp\r\n"))
        duplex.close(); duplex.close()
        #expect(fixture.closeCount == 1)
    }

    @Test func rejectedHijackRetainsHttpStatusAndBodyAndRefusesInput() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\n\r\ndenied".utf8)])
        let duplex = try await BackendDockerHTTPTransport(opener: { fixture }).hijack(.init(method: "POST", path: "/exec/one/start"))
        #expect(duplex.status == 403)
        var body = Data()
        for try await bytes in duplex.incoming { body.append(bytes) }
        #expect(String(decoding: body, as: UTF8.self) == "denied")
        do { try await duplex.write(Data([3])); Issue.record("A rejected upgrade accepted input") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(fixture.writes.count == 1)
    }

    @Test func terminalUpgradeRequiresValidRawFraming() async throws {
        for wire in ["HTTP/1.1 101 Switching Protocols\r\n\r\n", "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"] {
            let fixture = BackendDockerTransportFixture(fragments: [Data(wire.utf8)])
            do {
                _ = try await BackendDockerHTTPTransport(opener: { fixture }).hijack(.init(method: "POST", path: "/exec/one/start"))
                Issue.record("An invalid terminal upgrade succeeded")
            } catch let error as NativeRPCError { #expect(error.code == "docker-protocol"); #expect(fixture.closeCount == 1) }
        }
        let legacy = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\nraw".utf8)])
        let duplex = try await BackendDockerHTTPTransport(opener: { legacy }).hijack(.init(method: "POST", path: "/exec/one/start"))
        var iterator = duplex.incoming.makeAsyncIterator()
        #expect(try await iterator.next() == Data("raw".utf8))
        try await duplex.write(Data([3])); duplex.close()
        #expect(legacy.writes.last == Data([3]))
    }

    @Test func slowConsumerFailsOnBoundedQueueInsteadOfDroppingBytes() async throws {
        var limits = BackendDockerTransportLimits(); limits.maximumReadBytes = 8; limits.maximumStreamChunks = 1
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
        let stream = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).stream(.init(path: "/events"))
        fixture.send(Data(repeating: 7, count: 24))
        #expect(await fixture.waitForClose())
        do { for try await _ in stream.data {} ; Issue.record("A slow consumer silently lost bytes") }
        catch let error as NativeRPCError { #expect(error.code == "docker-stream-overflow") }
        #expect(fixture.closeCount == 1)
    }

    @Test func explicitStreamCancellationClosesOnceAndFinishesPendingRead() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
        let stream = try await BackendDockerHTTPTransport(opener: { fixture }).stream(.init(path: "/events"))
        stream.cancel(); stream.cancel()
        do { for try await _ in stream.data {} ; Issue.record("A cancelled stream succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(fixture.closeCount == 1)
    }

    @Test func requestTimeoutReleasesSilentConnection() async throws {
        var limits = BackendDockerTransportLimits(); limits.requestTimeoutMilliseconds = 30
        let fixture = BackendDockerTransportFixture(fragments: [])
        do {
            _ = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).request(.init(path: "/version"))
            Issue.record("A silent peer did not time out")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(fixture.closeCount == 1) }
    }

    @Test func requestDeadlineFinishesEvenWhenWriterIgnoresClose() async throws {
        let release = BackendServersSSHOnce<Void>()
        var limits = BackendDockerTransportLimits(); limits.requestTimeoutMilliseconds = 30
        let fixture = BackendDockerTransportFixture(fragments: [], blockWrites: release)
        defer { release.finish(.success(())) }
        do {
            _ = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).request(.init(path: "/version"))
            Issue.record("A blocked writer ignored the request deadline")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(fixture.closeCount == 1) }
    }

    @Test func cancelledBlockedWriterFinishesWithoutItsAcknowledgement() async throws {
        let release = BackendServersSSHOnce<Void>()
        let fixture = BackendDockerTransportFixture(fragments: [], blockWrites: release)
        defer { release.finish(.success(())) }
        let task = Task { try await BackendDockerHTTPTransport(opener: { fixture }).request(.init(path: "/version")) }
        defer { task.cancel() }
        try await waitForFixture(fixture.writeStarted); task.cancel()
        do { _ = try await task.value; Issue.record("A blocked writer ignored cancellation") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled"); #expect(fixture.closeCount == 1) }
    }

    @Test func terminalInputHasItsOwnWriteDeadline() async throws {
        let release = BackendServersSSHOnce<Void>()
        var limits = BackendDockerTransportLimits(); limits.writeTimeoutMilliseconds = 30
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8)], blockWrites: release, blockOnlyAfterReply: true)
        defer { release.finish(.success(())) }
        let duplex = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).hijack(.init(method: "POST", path: "/exec/one/start"))
        do { try await duplex.write(Data([3])); Issue.record("A blocked terminal input ignored its write deadline") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(fixture.closeCount == 1) }
        do { for try await _ in duplex.incoming {}; Issue.record("A failed terminal writer left incoming open") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
    }

    @Test func lateWriteAcknowledgementCannotUndoPeerFailure() async throws {
        let release = BackendServersSSHOnce<Void>()
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8)], blockWrites: release, blockOnlyAfterReply: true)
        defer { release.finish(.success(())) }
        let duplex = try await BackendDockerHTTPTransport(opener: { fixture }).hijack(.init(method: "POST", path: "/exec/one/start"))
        let input = Task { try await duplex.write(Data([3])) }
        defer { input.cancel(); duplex.close() }
        try await waitForFixture(fixture.rawWriteStarted)
        fixture.failPeerConnection()
        // The provider acknowledges after the connection has failed, as can
        // happen when send-completion and connection-state callbacks race.
        release.finish(.success(()))
        do { try await input.value; Issue.record("A late send acknowledgement erased a connection failure") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        do { for try await _ in duplex.incoming {}; Issue.record("A failed peer left terminal input open") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(fixture.closeCount == 1)
    }

    @Test func timedOutOpenerClosesChannelWhenItArrivesLate() async throws {
        let release = BackendServersSSHOnce<Void>()
        let fixture = BackendDockerTransportFixture(fragments: [])
        var limits = BackendDockerTransportLimits(); limits.openTimeoutMilliseconds = 30
        let transport = BackendDockerHTTPTransport(opener: { try await release.value(); return fixture }, limits: limits)
        do { _ = try await transport.request(.init(path: "/version")); Issue.record("A blocked opener did not time out") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        release.finish(.success(()))
        #expect(await fixture.waitForClose())
        #expect(fixture.writes.isEmpty)
    }

    @Test func cancellationBeforeOpenerReturnsStillClosesLateChannel() async throws {
        let started = BackendServersSSHOnce<Void>(), release = BackendServersSSHOnce<Void>()
        let fixture = BackendDockerTransportFixture(fragments: [])
        let transport = BackendDockerHTTPTransport(opener: { started.finish(.success(())); try await release.value(); return fixture })
        let task = Task { try await transport.request(.init(path: "/version")) }
        defer { task.cancel(); release.finish(.success(())) }
        try await waitForFixture(started); task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled opener succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        release.finish(.success(()))
        #expect(await fixture.waitForClose())
        #expect(fixture.writes.isEmpty)
    }

    @Test func alreadyCancelledRequestDoesNotInvokeOpener() async throws {
        let started = BackendServersSSHOnce<Void>(), release = BackendServersSSHOnce<Void>()
        let fixture = BackendDockerTransportFixture(fragments: [])
        let calls = BackendDockerTransportFixtureCounter()
        let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture })
        let task = Task {
            started.finish(.success(())); try await release.value()
            return try await transport.request(.init(path: "/version"))
        }
        defer { task.cancel(); release.finish(.success(())) }
        try await waitForFixture(started); task.cancel(); release.finish(.success(()))
        do { _ = try await task.value; Issue.record("An already-cancelled request succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(calls.value == 0)
        #expect(fixture.writes.isEmpty)
    }

    @Test func perRequestTimeoutOverridesConfiguredDeadlineForSlowStop() async throws {
        var limits = BackendDockerTransportLimits(); limits.requestTimeoutMilliseconds = 1
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)], delayFirstWriteMilliseconds: 30)
        let transport = BackendDockerHTTPTransport(opener: { fixture }, limits: limits)
        let result = try await transport.request(.init(method: "POST", path: "/v1.47/containers/one/stop?t=120", timeoutMilliseconds: 135_000))
        #expect(result.status == 204)
        #expect(fixture.closeCount == 1)
        // An override can shorten the configured deadline too; otherwise this
        // delayed response would succeed within the one-second default.
        limits.requestTimeoutMilliseconds = 1_000
        let slow = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)], delayFirstWriteMilliseconds: 100)
        do {
            _ = try await BackendDockerHTTPTransport(opener: { slow }, limits: limits).request(.init(path: "/version", timeoutMilliseconds: 20))
            Issue.record("A short request override did not control its deadline")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(slow.closeCount == 1) }
    }

    @Test func invalidTimeoutOverridesNeverOpenRequestOrStream() async throws {
        let fixture = BackendDockerTransportFixture(fragments: [])
        let calls = BackendDockerTransportFixtureCounter()
        let transport = BackendDockerHTTPTransport(opener: { calls.add(); return fixture })
        for timeout in [-1, 0, 660_001] {
            let request = BackendDockerRequest(path: "/version", timeoutMilliseconds: timeout)
            do { _ = try await transport.request(request); Issue.record("An invalid request timeout succeeded") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
            do { _ = try await transport.stream(request); Issue.record("An invalid stream timeout succeeded") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect(calls.value == 0)
    }

    @Test func longResponseDeadlineDoesNotExtendInitialWriteDeadline() async throws {
        var limits = BackendDockerTransportLimits(); limits.writeTimeoutMilliseconds = 20
        let fixture = BackendDockerTransportFixture(fragments: [Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)], delayFirstWriteMilliseconds: 100)
        do {
            _ = try await BackendDockerHTTPTransport(opener: { fixture }, limits: limits).request(.init(method: "POST", path: "/v1.47/containers/one/stop?t=600", timeoutMilliseconds: 615_000))
            Issue.record("A long response deadline extended a blocked writer")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(fixture.closeCount == 1) }
    }

    private func waitForFixture<Value: Sendable>(_ gate: BackendServersSSHOnce<Value>) async throws -> Value {
        // A regression before the expected callback should fail the test, not
        // leave the suite waiting forever on an unobserved operation task.
        let watchdog = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            gate.finish(.failure(NativeRPCError(code: "test-timeout", message: "The Docker fixture did not reach its expected callback.")))
        }
        defer { watchdog.cancel() }
        return try await gate.value()
    }
}

/// In-memory counterpart of the existing server duplex. Tests perform no I/O.
private final class BackendDockerTransportFixture: BackendServersDuplex, @unchecked Sendable {
    private let lock = NSLock()
    private let output = BackendServersSSHEvents<Data>()
    private let ending = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let closing = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let closed = BackendServersSSHOnce<Bool>()
    private let fragments: [Data]
    private let endAfterReply: Bool
    private let blockWrites: BackendServersSSHOnce<Void>?
    private let blockOnlyAfterReply: Bool
    private let delayFirstWriteMilliseconds: Int
    let writeStarted = BackendServersSSHOnce<Void>()
    let rawWriteStarted = BackendServersSSHOnce<Void>()
    private var sentReply = false
    private var storedWrites: [Data] = []
    private var closes = 0
    init(fragments: [Data], endAfterReply: Bool = false, blockWrites: BackendServersSSHOnce<Void>? = nil, blockOnlyAfterReply: Bool = false, delayFirstWriteMilliseconds: Int = 0) {
        self.fragments = fragments; self.endAfterReply = endAfterReply; self.blockWrites = blockWrites; self.blockOnlyAfterReply = blockOnlyAfterReply
        self.delayFirstWriteMilliseconds = delayFirstWriteMilliseconds
    }
    var writes: [Data] { lock.withLock { storedWrites } }
    var closeCount: Int { lock.withLock { closes } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { output.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func write(_ bytes: Data) async throws {
        let first = lock.withLock { storedWrites.append(bytes); if sentReply { return false }; sentReply = true; return true }
        writeStarted.finish(.success(()))
        if !first { rawWriteStarted.finish(.success(())) }
        if first, delayFirstWriteMilliseconds > 0 { try await Task.sleep(for: .milliseconds(delayFirstWriteMilliseconds)) }
        if let blockWrites, !blockOnlyAfterReply || !first { try await blockWrites.value() }
        if first { for bytes in fragments { output.send(bytes) }; if endAfterReply { ending.send(true) } }
    }
    func send(_ bytes: Data) { output.send(bytes) }
    func failPeerConnection() { closing.send(true) }
    func end() async throws { ending.send(true) }
    func close() { let first = lock.withLock { if closes > 0 { return false }; closes = 1; return true }; if first { closing.send(true); closed.finish(.success(true)) } }
    func pause() {}
    func resume() {}
    func waitForClose() async -> Bool {
        let timer = Task { do { try await Task.sleep(for: .seconds(2)) } catch { return }; closed.finish(.success(false)) }
        defer { timer.cancel() }
        return (try? await closed.value()) ?? false
    }
}
private final class BackendDockerTransportFixtureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var stored = 0
    var value: Int { lock.withLock { stored } }
    func add() { lock.withLock { stored += 1 } }
}
private final class BackendDockerTransportFixtureCommand: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func record(_ command: String) { lock.withLock { stored.append(command) } }
}

/// A duplex which acknowledges writes while its receiver remains paused.
/// The finite reply is released when the HTTP owner begins its first read.
private final class BackendDockerPausedWriteFixture: BackendServersDuplex, @unchecked Sendable {
    private let lock = NSLock()
    private let output = BackendServersSSHEvents<Data>()
    private let ending = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let closing = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let reply: Data
    private let closeAfterReply: Bool
    private var paused = false, acknowledged = false, delivered = false
    private var earlyResumes = 0, writes = 0, closes = 0
    init(reply: Data, closeAfterReply: Bool = false) { self.reply = reply; self.closeAfterReply = closeAfterReply }
    var resumesBeforeAcknowledgement: Int { lock.withLock { earlyResumes } }
    var writeCount: Int { lock.withLock { writes } }
    var closeCount: Int { lock.withLock { closes } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { output.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func write(_ bytes: Data) async throws {
        lock.withLock { writes += 1; acknowledged = true }
        deliverIfReady()
    }
    func end() async throws { ending.send(true) }
    func pause() { lock.withLock { paused = true } }
    func resume() {
        lock.withLock { if !acknowledged { earlyResumes += 1 }; paused = false }
        deliverIfReady()
    }
    private func deliverIfReady() {
        let send = lock.withLock { () -> Bool in
            guard acknowledged, !paused, !delivered, closes == 0 else { return false }
            delivered = true; return true
        }
        if send {
            output.send(reply)
            if closeAfterReply { close() } else { ending.send(true) }
        }
    }
    func close() {
        let first = lock.withLock { if closes > 0 { return false }; closes = 1; return true }
        if first { closing.send(true) }
    }
}
