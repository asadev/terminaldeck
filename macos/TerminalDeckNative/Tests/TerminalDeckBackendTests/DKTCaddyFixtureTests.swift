import Foundation
import Testing

@Suite("DKT fake Caddy admin state and failure semantics")
struct DKTCaddyFixtureTests {
    private let serverPath = "/config/apps/http/servers/terminaldeck"
    private let routesPath = "/config/apps/http/servers/terminaldeck/routes"

    @Test("loopback admin emulation rejects Docker Host and accepts trusted localhost without wrong-host mutations")
    func strictAdminHost() throws {
        let caddy = try DKTFakeCaddy.protectedDemo(strictAdminHost: true)
        try caddy.start()
        defer { caddy.stop() }
        let before = try caddy.configSnapshot()
        let rejected = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: "PUT", target: routesPath + "/0",
                                                      headers: ["Host": "docker", "Content-Type": "application/json"],
                                                      body: Data(route("td-test-host", dial: "172.18.0.3:8080").utf8))
        #expect(rejected.statusCode == 403)
        #expect(try caddy.configSnapshot() == before)
        #expect(caddy.successfulWriteCount == 0)
        let accepted = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: "PUT", target: routesPath + "/0",
                                                      headers: ["Host": "localhost:2019", "Content-Type": "application/json"],
                                                      body: Data(route("td-test-host", dial: "172.18.0.3:8080").utf8))
        #expect(accepted.statusCode == 200)
        #expect(caddy.successfulWriteCount == 1)
        #expect(caddy.requests.map { $0.headers["host"] } == ["docker", "localhost:2019"])
    }

    @Test("load publishes config, nested GET exports actual active state")
    func loadAndRead() throws {
        let caddy = try DKTFakeCaddy()
        #expect(send(caddy, "POST", "/load", config()).statusCode == 200)
        let loaded = send(caddy, "GET", "/config/")
        #expect(try DKTCaddyJSON(data: loaded.body) == caddy.configuration)
        let listeners = send(caddy, "GET", serverPath + "/listen")
        #expect(try DKTCaddyJSON(data: listeners.body) == .array([.string(":443")]))
        #expect(loaded.headers["Etag"] != nil)
        #expect(caddy.successfulWriteCount == 1)
        #expect(caddy.requests.map(\.target) == ["/load", "/config/", serverPath + "/listen"])
    }

    @Test("invalid config rejects atomically and retains the working app route")
    func invalidLoadKeepsOldRoute() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let before = caddy.configuration
        let bad = #"{"apps":{"http":{"servers":{"terminaldeck":{"routes":"not-an-array"}}}}}"#
        #expect(send(caddy, "POST", "/load", bad).statusCode == 400)
        #expect(caddy.configuration == before)
        #expect(caddy.successfulWriteCount == 0)
        #expect(send(caddy, "PATCH", routesPath + "/0/handle/0/upstreams/0", #"{"dial":""}"#).statusCode == 400)
        #expect(caddy.configuration == before)
    }

    @Test("injected route failures retain config and expire deterministically")
    func injectedFailureRecovery() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let before = caddy.configuration
        caddy.failNext(method: "PATCH", path: routesPath + "/0", statusCode: 503, count: 2)
        for _ in 0..<2 {
            #expect(send(caddy, "PATCH", routesPath + "/0", route("candidate", dial: "candidate:8080")).statusCode == 503)
            #expect(caddy.configuration == before)
        }
        #expect(send(caddy, "PATCH", routesPath + "/0", route("candidate", dial: "candidate:8080")).statusCode == 200)
        #expect(try caddy.configuration.value(at: ["apps", "http", "servers", "terminaldeck", "routes", "0", "@id"]) == .string("candidate"))
        #expect(caddy.successfulWriteCount == 1)
    }

    @Test("POST appends, PUT inserts, PATCH replaces, DELETE removes the named route")
    func nestedArrayOperations() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        #expect(send(caddy, "POST", routesPath, route("second", dial: "second:8080")).statusCode == 200)
        #expect(send(caddy, "PUT", routesPath + "/0", route("first", dial: "first:8080")).statusCode == 200)
        #expect(send(caddy, "PATCH", routesPath + "/1", route("replacement", dial: "replacement:8080")).statusCode == 200)
        #expect(send(caddy, "DELETE", routesPath + "/0").statusCode == 200)
        let response = send(caddy, "GET", routesPath)
        let expected = try DKTCaddyJSON(data: Data(("[" + route("replacement", dial: "replacement:8080") + "," + route("second", dial: "second:8080") + "]").utf8))
        #expect(try DKTCaddyJSON(data: response.body) == expected)
    }

    @Test("PUT cannot overwrite an object, PATCH cannot create an object")
    func strictObjectOperations() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let before = caddy.configuration
        #expect(send(caddy, "PUT", serverPath + "/listen", #"[":8443"]"#).statusCode == 409)
        #expect(send(caddy, "PATCH", serverPath + "/missing", #"{"value":true}"#).statusCode == 404)
        #expect(send(caddy, "DELETE", serverPath + "/missing").statusCode == 404)
        #expect(caddy.configuration == before)
    }

    @Test("PUT creates missing intermediate objects without altering other config")
    func putCreatesAncestors() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(#"{"admin":{"listen":"127.0.0.1:2019"}}"#.utf8))
        #expect(send(caddy, "PUT", serverPath, #"{"listen":[":443"],"routes":[]}"#).statusCode == 200)
        #expect(try caddy.configuration.value(at: ["admin", "listen"]) == .string("127.0.0.1:2019"))
        #expect(try caddy.configuration.value(at: ["apps", "http", "servers", "terminaldeck", "routes"]) == .array([]))
    }

    @Test("bulk array expansion appends each route and rejects a nonarray payload")
    func arrayExpansion() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let additions = "[" + route("second", dial: "second:8080") + "," + route("third", dial: "third:8080") + "]"
        #expect(send(caddy, "POST", routesPath + "/...", additions).statusCode == 200)
        let before = caddy.configuration
        #expect(send(caddy, "POST", routesPath + "/...", route("invalid", dial: "invalid:8080")).statusCode == 400)
        #expect(caddy.configuration == before)
        guard case let .array(routes) = try caddy.configuration.value(at: ["apps", "http", "servers", "terminaldeck", "routes"]) else {
            Issue.record("active routes are not an array")
            return
        }
        #expect(routes.count == 3)
    }

    @Test("ID routes refer to live tree locations and duplicate IDs reject the write")
    func objectIDs() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        #expect(send(caddy, "PATCH", "/id/old/handle/0/upstreams/0/dial", #""candidate:8080""#).statusCode == 200)
        let response = send(caddy, "GET", "/id/old/handle/0/upstreams/0/dial")
        #expect(try DKTCaddyJSON(data: response.body) == .string("candidate:8080"))
        let before = caddy.configuration
        #expect(send(caddy, "POST", routesPath, route("old", dial: "duplicate:8080")).statusCode == 400)
        #expect(caddy.configuration == before)
        #expect(send(caddy, "GET", "/id/absent").statusCode == 404)
    }

    @Test("stale ETag rejects a config change and preserves both app routes")
    func conditionalWrite() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let tag = try #require(send(caddy, "GET", routesPath).headers["Etag"])
        #expect(send(caddy, "POST", routesPath, route("other", dial: "other:8080")).statusCode == 200)
        let before = caddy.configuration
        #expect(send(caddy, "PATCH", routesPath + "/0", route("candidate", dial: "candidate:8080"),
                     headers: ["If-Match": tag]).statusCode == 412)
        #expect(caddy.configuration == before)
        let fresh = try #require(send(caddy, "GET", routesPath).headers["Etag"])
        #expect(send(caddy, "PATCH", routesPath + "/0", route("candidate", dial: "candidate:8080"),
                     headers: ["If-Match": fresh]).statusCode == 200)
    }

    @Test("bad JSON and content types fail without echoing request bodies")
    func invalidPayloadsAndEndpoints() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        let before = caddy.configuration
        let dummySecret = "DKT_DUMMY_SECRET_NOT_A_REAL_CREDENTIAL"
        let malformed = send(caddy, "POST", "/load", "{\"secret\":\"\(dummySecret)")
        #expect(malformed.statusCode == 400)
        #expect(!String(decoding: malformed.body, as: UTF8.self).contains(dummySecret))
        let wrongType = caddy.respond(to: .init(method: "POST", target: "/load", headers: ["Content-Type": "text/caddyfile"], body: Data(config().utf8)))
        #expect(wrongType.statusCode == 400)
        #expect(send(caddy, "GET", "/debug/pprof/").statusCode == 404)
        #expect(send(caddy, "GET", "/config/apps/http/servers/terminaldeck/routes/01").statusCode == 400)
        #expect(caddy.configuration == before)
    }

    @Test("DELETE root unloads config without stopping the fixture")
    func unloadConfig() throws {
        let caddy = try DKTFakeCaddy(initialConfig: Data(config().utf8))
        #expect(send(caddy, "DELETE", "/config/").statusCode == 200)
        #expect(caddy.configuration == .null)
        #expect(send(caddy, "GET", "/config/").statusCode == 200)
        #expect(send(caddy, "POST", "/load", config()).statusCode == 200)
    }

    @Test("own td-test route is added and removed by ID while protected demo config stays equal")
    func protectsDemoSentinel() throws {
        let caddy = try DKTFakeCaddy.protectedDemo()
        let before = try caddy.configSnapshot()
        let sentinelBefore = send(caddy, "GET", "/id/" + DKTFakeCaddy.protectedDemoRouteID).body
        #expect(send(caddy, "POST", routesPath, route("td-test-owned", dial: "td-test-owned:8080")).statusCode == 200)
        #expect(send(caddy, "GET", "/id/" + DKTFakeCaddy.protectedDemoRouteID).body == sentinelBefore)
        #expect(send(caddy, "DELETE", "/id/td-test-owned").statusCode == 200)
        #expect(try caddy.configSnapshot() == before)
        #expect(caddy.requests.filter { $0.method != "GET" }.map(\.target) == [routesPath, "/id/td-test-owned"])
    }

    @Test("Caddy HTTP request bodies and state roundtrip over its temporary Unix socket")
    func unixSocketHTTPBoundary() throws {
        let caddy = try DKTFakeCaddy.protectedDemo()
        try caddy.start()
        defer { caddy.stop() }
        let before = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/config/")
        #expect(before.statusCode == 200)
        let routeBody = Data(route("td-test-unix", dial: "td-test-unix:8080").utf8)
        let append = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: "POST", target: routesPath,
                                                   headers: ["Content-Type": "application/json"], body: routeBody)
        #expect(append.statusCode == 200)
        let active = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/id/td-test-unix")
        #expect(try DKTCaddyJSON(data: active.body) == DKTCaddyJSON(data: routeBody))
        caddy.failNext(method: "PATCH", path: "/id/td-test-unix", statusCode: 400)
        let rejected = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: "PATCH", target: "/id/td-test-unix",
                                                     headers: ["Content-Type": "application/json"], body: Data(route("td-test-unix", dial: "replacement:8080").utf8))
        #expect(rejected.statusCode == 400)
        let retained = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/id/td-test-unix")
        #expect(retained.body == active.body)
        let remove = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, method: "DELETE", target: "/id/td-test-unix")
        #expect(remove.statusCode == 200)
        let after = try DKTUnixHTTPClient.request(socketPath: caddy.socketPath, target: "/config/")
        #expect(after.body == before.body)
        #expect(caddy.requests.first(where: { $0.method == "POST" })?.body == routeBody)
    }

    private func send(_ fixture: DKTFakeCaddy, _ method: String, _ path: String, _ body: String? = nil,
                      headers: [String: String] = [:]) -> DKTHTTPResponse {
        var combined = headers
        if body != nil { combined["Content-Type"] = "application/json" }
        return fixture.respond(to: .init(method: method, target: path, headers: combined,
                                         body: body.map { Data($0.utf8) } ?? Data()))
    }

    private func config() -> String {
        #"{"admin":{"listen":"127.0.0.1:2019"},"apps":{"http":{"servers":{"terminaldeck":{"listen":[":443"],"routes":["#
            + route("old", dial: "old:8080") + "]}}}}}"
    }

    private func route(_ id: String, dial: String) -> String {
        // Inputs are fixed dummy fixture strings, not user-controlled text.
        "{\"@id\":\"\(id)\",\"match\":[{\"host\":[\"demo.192.0.2.5.sslip.io\"]}],\"handle\":[{\"handler\":\"reverse_proxy\",\"upstreams\":[{\"dial\":\"\(dial)\"}]}]}"
    }
}
