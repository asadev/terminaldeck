import Darwin
import Foundation
import Testing

@Suite("DKT private HTTP fixture")
struct DKTHTTPServerTests {
    @Test func contentLengthQueryAndVersionPrefixArePreserved() throws {
        let server = DKTUnixHTTPServer { request in .init(body: request.body) }
        try server.start()
        defer { server.stop() }
        let bytes = Data("body 🙂".utf8)
        let reply = try DKTUnixHTTPClient.request(socketPath: server.socketPath, method: "GET",
                                                 target: "/v1.47/echo?name=hello%20world", headers: ["X-DKT": "fixture"], body: bytes)
        #expect(reply.statusCode == 200 && reply.body == bytes)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET" && request.target == "/v1.47/echo?name=hello%20world")
        #expect(request.enginePath == "/echo" && request.query["name"] == "hello world")
        #expect(request.headers["x-dkt"] == "fixture" && request.body == bytes)
    }

    @Test func chunkedUploadsExtensionsAndTrailersDecodeWithoutChangingBody() throws {
        let server = DKTUnixHTTPServer { request in .init(body: request.body) }
        try server.start()
        defer { server.stop() }
        let wire = Data("POST /config/ HTTP/1.1\r\nHost: dkt-fixture\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n4;fixture=yes\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Fixture: complete\r\n\r\n".utf8)
        let reply = try DKTUnixHTTPClient.rawExchange(socketPath: server.socketPath, request: wire, method: "POST")
        #expect(reply.statusCode == 200 && reply.body == Data("Wikipedia".utf8))
        #expect(String(decoding: reply.wireData.prefix(25), as: UTF8.self).hasPrefix("HTTP/1.1 100 Continue"))
        #expect(server.requests.first?.body == Data("Wikipedia".utf8))
    }

    @Test func ambiguousAndMalformedFramingNeverCallsHandler() throws {
        let server = DKTUnixHTTPServer { _ in .init(statusCode: 503) }
        try server.start()
        defer { server.stop() }
        let heads = [
            "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n",
            "Content-Length: 1\r\nContent-Length: 1\r\n",
            "Content-Length: -1\r\n",
            "Transfer-Encoding: gzip, chunked\r\n",
            " Bad-Header: value\r\n",
        ]
        for head in heads {
            let wire = Data(("POST /config/ HTTP/1.1\r\nHost: dkt-fixture\r\n" + head + "\r\n").utf8)
            let reply = try DKTUnixHTTPClient.rawExchange(socketPath: server.socketPath, request: wire)
            #expect(reply.statusCode == 400)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func oversizedDeclaredBodyIsRejectedBeforeUpload() throws {
        let server = DKTUnixHTTPServer { _ in .init() }
        try server.start()
        defer { server.stop() }
        let wire = Data("POST /load HTTP/1.1\r\nHost: dkt-fixture\r\nContent-Length: 1048577\r\n\r\n".utf8)
        let reply = try DKTUnixHTTPClient.rawExchange(socketPath: server.socketPath, request: wire)
        #expect(reply.statusCode == 413 && server.requests.isEmpty)
    }

    @Test func chunkedResponsesPreserveBinaryFrameSegmentsAndUTF8() throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let route = "/v1.47/containers/\(DKTDockerFake.containerID)/logs?follow=false"
        let expected = fake.respond(to: .init(method: "GET", target: route))
        let reply = try DKTUnixHTTPClient.request(socketPath: fake.socketPath, target: route)
        #expect(reply.statusCode == 200 && reply.headers["transfer-encoding"] == "chunked")
        #expect(reply.chunks == expected.streamChunks)
        #expect(reply.body == expected.streamChunks.reduce(into: Data()) { $0.append($1) })
        var offset = 0
        var stdout = Data()
        var stderr = Data()
        while offset < reply.body.count {
            let header = Data(reply.body.dropFirst(offset).prefix(8))
            #expect(header.count == 8)
            guard header.count == 8 else { break }
            let count = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
            let part = Data(reply.body.dropFirst(offset + 8).prefix(count))
            #expect(part.count == count)
            if header[0] == 1 { stdout.append(part) }
            else if header[0] == 2 { stderr.append(part) }
            offset += 8 + count
        }
        #expect(String(data: stdout, encoding: .utf8) == "ready 🙂 token=\(DKTDockerFake.secret)\n")
        #expect(String(data: stderr, encoding: .utf8) == "synthetic warning\n")
    }

    @Test func socketIsPrivateAndCollidingStartPreservesTheFirstServer() throws {
        let first = DKTUnixHTTPServer { _ in .init(body: Data("first".utf8)) }
        try first.start()
        defer { first.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: first.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let parent = URL(fileURLWithPath: first.socketPath).deletingLastPathComponent().path
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent)
        #expect((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let second = DKTUnixHTTPServer(socketPath: first.socketPath) { _ in .init(statusCode: 503) }
        #expect(throws: DKTHTTPServerError.self) { try second.start() }
        second.stop()
        let reply = try DKTUnixHTTPClient.request(socketPath: first.socketPath, target: "/")
        #expect(reply.body == Data("first".utf8))
    }

    @Test func stopDoesNotUnlinkAReplacementFile() throws {
        let server = DKTUnixHTTPServer { _ in .init() }
        try server.start()
        let path = server.socketPath
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: path)
            _ = Darwin.rmdir(parent)
        }
        #expect(Darwin.unlink(path) == 0)
        let replacement = Data("preserve replacement".utf8)
        try replacement.write(to: URL(fileURLWithPath: path))
        server.stop()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == replacement)
    }

    @Test func screenClosureClosesHeldStreamAndStopClosesAllPeers() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let connection = try DKTUnixHTTPClient.open(socketPath: fake.socketPath)
        defer { connection.close() }
        try connection.write(Data("GET /v1.47/events HTTP/1.1\r\nHost: dkt-fixture\r\n\r\n".utf8))
        #expect(!(try connection.readSome()).isEmpty)
        #expect(fake.activeConnectionCount == 1)
        connection.close()
        #expect(try await dktHTTPWaitUntil { fake.activeConnectionCount == 0 })
        let second = try DKTUnixHTTPClient.open(socketPath: fake.socketPath)
        defer { second.close() }
        try second.write(Data("GET /v1.47/events HTTP/1.1\r\nHost: dkt-fixture\r\n\r\n".utf8))
        #expect(!(try second.readSome()).isEmpty)
        fake.stop()
        #expect(fake.activeConnectionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fake.socketPath))
        // Buffered events may arrive before EOF, but closure must follow within the read deadline.
        var eof = false
        for _ in 0..<16 {
            if try second.readSome().isEmpty { eof = true; break }
        }
        #expect(eof)
    }

    @Test func onlyTestNamedResourcesAreRemovedAndCompleteInventoryIsRestored() throws {
        let fake = DKTDockerFake()
        let before = fake.snapshotInventory()
        let resources = fake.seedTestResources()
        #expect(fake.snapshotInventory() != before)
        let removals = [
            "/containers/\(resources.containerID)?force=true",
            "/images/\(resources.imageID)",
            "/volumes/\(resources.volumeName)",
            "/networks/\(resources.networkID)",
        ]
        for target in removals {
            let reply = fake.respond(to: .init(method: "DELETE", target: "/v1.47" + target))
            #expect(reply.statusCode >= 200 && reply.statusCode < 300)
        }
        #expect(fake.snapshotInventory() == before)
        #expect(fake.respond(to: .init(method: "GET", target: "/containers/\(DKTDockerFake.containerID)/json")).statusCode == 200)
    }

    @Test func unknownOperationsAndConfiguredEngineErrorsStayExplicit() {
        let fake = DKTDockerFake()
        #expect(fake.respond(to: .init(method: "POST", target: "/v1.47/compose/deploy")).statusCode == 404)
        fake.setResponse(method: "GET", target: "/containers/json", response: .json(["message": DKTDockerFake.secret], statusCode: 403))
        let reply = fake.respond(to: .init(method: "GET", target: "/v1.47/containers/json?all=true"))
        #expect(reply.statusCode == 403)
        #expect(String(decoding: reply.body, as: UTF8.self).contains(DKTDockerFake.secret))
        // Production contract tests, rather than the Engine fake, must strip this unsafe error body.
    }

    @Test func appCandidateUsesHealthyPrivateNetworkingAndCleanupPreservesBaseline() throws {
        let fake = DKTDockerFake()
        fake.seedImage(id: "sha256:td-test-app-image", tags: ["td-test-app:latest"], labels: ["ae.terminaldeck.managed": "true"])
        fake.seedNetwork(id: "td-test-app-network", name: "td-test-app-network", labels: ["ae.terminaldeck.managed": "true"])
        let baseline = fake.snapshotInventory()
        let body = DKTHTTPResponse.json([
            "Image": "td-test-app:latest", "ExposedPorts": ["8080/tcp": [:] as [String: String]],
            "Labels": ["ae.terminaldeck.managed": "true"], "Env": ["TOKEN=" + DKTDockerFake.secret],
            "NetworkingConfig": ["EndpointsConfig": ["td-test-app-network": [:] as [String: String]]],
        ] as [String: Any]).body
        let created = fake.respond(to: .init(method: "POST", target: "/v1.47/containers/create?name=td-test-app", body: body))
        #expect(created.statusCode == 201)
        let result = try #require(try JSONSerialization.jsonObject(with: created.body) as? [String: Any])
        let id = try #require(result["Id"] as? String)
        #expect(fake.respond(to: .init(method: "POST", target: "/v1.47/containers/\(id)/start")).statusCode == 204)
        let inspected = fake.respond(to: .init(method: "GET", target: "/v1.47/containers/\(id)/json"))
        let inspect = try #require(try JSONSerialization.jsonObject(with: inspected.body) as? [String: Any])
        let state = try #require(inspect["State"] as? [String: Any])
        #expect((state["Health"] as? [String: String])?["Status"] == "healthy")
        let networking = try #require(inspect["NetworkSettings"] as? [String: Any])
        let networks = try #require(networking["Networks"] as? [String: Any])
        let network = try #require(networks["td-test-app-network"] as? [String: Any])
        let privateIP = try #require(network["IPAddress"] as? String)
        #expect(privateIP.hasPrefix("172.18.0."))
        #expect(network["NetworkID"] as? String == "td-test-app-network")
        #expect(network["Aliases"] is [String])
        let bindings = try #require(networking["Ports"] as? [String: Any])
        #expect(bindings["8080/tcp"] is NSNull)
        #expect(fake.respond(to: .init(method: "DELETE", target: "/v1.47/containers/\(id)?force=true")).statusCode == 204)
        #expect(fake.snapshotInventory() == baseline)
    }

    @Test func execUpgradeUsesRawBytesAndCapturesInputUntilCancelled() async throws {
        let fake = DKTDockerFake()
        try fake.start()
        defer { fake.stop() }
        let created = try DKTUnixHTTPClient.request(socketPath: fake.socketPath, method: "POST",
            target: "/v1.47/containers/\(DKTDockerFake.containerID)/exec", body: DKTHTTPResponse.json(["Tty": true]).body)
        let value = try #require(try JSONSerialization.jsonObject(with: created.body) as? [String: String])
        let id = try #require(value["Id"])
        let connection = try DKTUnixHTTPClient.open(socketPath: fake.socketPath)
        defer { connection.close() }
        let body = Data(#"{"Detach":false,"Tty":true}"#.utf8)
        var request = Data("POST /v1.47/exec/\(id)/start HTTP/1.1\r\nHost: dkt-fixture\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        try connection.write(request)
        var received = Data()
        for _ in 0..<16 {
            received.append(try connection.readSome())
            if String(decoding: received, as: UTF8.self).contains("$ ") { break }
        }
        let text = String(decoding: received, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        #expect(text.contains("DKT shell ready\r\n$ "))
        #expect(!text.lowercased().contains("transfer-encoding"))
        let input = Data("echo fixture\n".utf8)
        try connection.write(input)
        #expect(try await dktHTTPWaitUntil { fake.hijackedBytes.reduce(into: Data()) { $0.append($1) } == input })
        connection.close()
        #expect(try await dktHTTPWaitUntil { fake.activeConnectionCount == 0 })
    }
}

private func dktHTTPWaitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if predicate() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}
