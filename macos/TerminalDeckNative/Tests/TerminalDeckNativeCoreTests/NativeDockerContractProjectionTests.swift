import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Docker contract presentation projections")
struct NativeDockerContractProjectionTests {
    private var containerReply: CodingAIJSON {
        .parse(#"{"id":"container-1","name":"web","image":"example/web:1","state":"running","status":"Up 3 minutes","labels":{"com.docker.compose.project":"site","com.docker.compose.service":"web"},"ports":[{"privatePort":80,"publicPort":8080,"type":"tcp","ip":"0.0.0.0"}]}"#)
    }

    private var usageReply: CodingAIJSON {
        .object(["cpuPercent": .number(250.5), "memoryBytes": .number(1_024), "memoryLimitBytes": .number(4_096)])
    }

    private func replacing(_ reply: CodingAIJSON, _ key: String, with value: CodingAIJSON?) -> CodingAIJSON {
        var fields = reply.object ?? [:]
        fields[key] = value
        return .object(fields)
    }

    private func wrapped(_ section: NativeDockerSection, _ rows: [CodingAIJSON]) -> CodingAIJSON {
        .object([section.rawValue: .array(rows)])
    }

    private func fact(_ item: NativeDockerItem, _ label: String) -> String? {
        item.facts.first { $0.label == label }?.value
    }

    private func rendered(_ item: NativeDockerItem) -> String {
        ([item.id, item.name, item.subtitle, item.state] + item.facts.flatMap { [$0.label, $0.value] }).joined(separator: "\n")
    }

    private func expectMalformed<T>(_ body: () throws -> T) {
        do {
            _ = try body()
            Issue.record("Expected the malformed Docker reply to be refused")
        } catch let error as NativeRPCError {
            #expect(error.code == "malformed")
            #expect(error.details == .missing)
            #expect(!error.message.isEmpty)
        } catch {
            Issue.record("Expected a NativeRPCError with the malformed code")
        }
    }

    @Test func listWrappersAreRequiredAndEmptyListsAreReal() throws {
        for section in NativeDockerSection.allCases {
            #expect(try NativeDockerContractProjection.items(section: section, reply: wrapped(section, [])).isEmpty)
            for badReply in [CodingAIJSON.null, .object([:]), .array([]), .object([section.rawValue: .object([:])]),
                             .object(["ok": .bool(false), "error": .string("Not available")])] {
                expectMalformed { try NativeDockerContractProjection.items(section: section, reply: badReply) }
            }
        }
        expectMalformed {
            try NativeDockerContractProjection.items(section: .containers, reply: wrapped(.images, []))
        }
    }

    @Test func malformedRowsAreNotSilentlySkipped() {
        let badRows: [CodingAIJSON] = [
            .null, .array([]), replacing(containerReply, "id", with: nil),
            replacing(containerReply, "id", with: .string("")),
            replacing(containerReply, "name", with: .string(" \n")),
            replacing(containerReply, "name", with: .number(1)),
            replacing(containerReply, "ports", with: .bool(false)),
            replacing(containerReply, "labels", with: .array([])),
        ]
        for row in badRows {
            expectMalformed {
                try NativeDockerContractProjection.items(section: .containers, reply: wrapped(.containers, [containerReply, row]))
            }
        }
        expectMalformed {
            try NativeDockerContractProjection.items(section: .containers, reply: wrapped(.containers, [containerReply, containerReply]))
        }
    }

    @Test func containerDetailsDisplayOnlySafeFieldsAndMaskEveryEnvironmentValue() throws {
        var fields = try #require(containerReply.object)
        fields["environment"] = .array([
            .object(["name": .string("PASSWORD"), "value": .string("password-secret")]),
            .object(["name": .string("PORT"), "value": .string("8080")]),
            .object(["name": .string("TOKEN"), "value": .object(["unexpected": .string("token-secret")])]),
        ])
        fields["mounts"] = .parse(#"[{"type":"bind","name":"mount-name-secret","source":"/Users/example/.ssh/key-secret","destination":"/data","readOnly":true}]"#)
        fields["labels"] = .parse(#"{"com.docker.compose.project":"site","com.docker.compose.service":"web","password":"label-secret","unrelated":"other-label-secret"}"#)
        fields["command"] = .string("command-secret")
        fields["inspect"] = .object(["Config": .object(["Env": .array([.string("RAW=inspect-secret")])])])
        let item = try NativeDockerContractProjection.container(.object(fields))
        #expect(item.id == "container-1" && item.name == "web" && item.running == true)
        #expect(item.subtitle == "example/web:1 · site")
        #expect(fact(item, "Ports") == "0.0.0.0:8080 → 80/tcp")
        #expect(fact(item, "Mount destinations") == "/data (read-only)")
        #expect(fact(item, "Environment") == "PASSWORD=••••••\nPORT=••••••\nTOKEN=••••••")
        for unsafe in ["password-secret", "token-secret", "mount-name-secret", "key-secret", "label-secret", "other-label-secret", "command-secret", "inspect-secret", "PORT=8080"] {
            #expect(!rendered(item).contains(unsafe))
        }
        #expect(Set(item.facts.map(\.id)).count == item.facts.count)
    }

    @Test func environmentCannotSmuggleAValueThroughItsName() {
        for name in ["TOKEN=hidden-secret", "TOKEN\nhidden-secret", ""] {
            let row = replacing(containerReply, "environment", with: .array([.object(["name": .string(name), "value": .string("hidden-secret")])]))
            expectMalformed { try NativeDockerContractProjection.container(row) }
        }
    }

    @Test func portsAndKnownContainerStatesProjectWithoutInventingStatus() throws {
        let ipv6 = replacing(containerReply, "ports", with: .parse(#"[{"privatePort":53,"publicPort":5353,"type":"udp","ip":"::1"},{"privatePort":80,"type":"tcp"}]"#))
        #expect(fact(try NativeDockerContractProjection.container(ipv6), "Ports") == "[::1]:5353 → 53/udp\n80/tcp")
        #expect(try NativeDockerContractProjection.container(containerReply).running == true)
        for state in ["created", "exited", "dead", "paused", "restarting"] {
            #expect(try NativeDockerContractProjection.container(replacing(containerReply, "state", with: .string(state))).running == false)
        }
        #expect(try NativeDockerContractProjection.container(replacing(containerReply, "state", with: .string("unrecognized"))).running == nil)
        for port in [0.0, -1, 65_536, 80.5] {
            let row = replacing(containerReply, "ports", with: .array([.object(["privatePort": .number(port), "type": .string("tcp")])]))
            expectMalformed { try NativeDockerContractProjection.container(row) }
        }
    }

    @Test func noneImageTagsUseTheCanonicalRealTagOrFullIdentifier() throws {
        let rawID = "sha256:0123456789abcdef0123456789abcdef"
        let reply = CodingAIJSON.object(["id": .string(rawID), "tags": .array([.string("<none>:<none>"), .string("<none>:legacy"), .string("example/web:1")]),
                                         "size": .number(1_024)])
        let taggedItems = try NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [reply]))
        let tagged = try #require(taggedItems.first)
        #expect(tagged.name == "example/web:1")
        #expect(fact(tagged, "Confirmation name") == "example/web:1")
        #expect(fact(tagged, "Tags") == "example/web:1")
        let onlyNone = replacing(reply, "tags", with: .array([.string("<none>:<none>")]))
        let untaggedItems = try NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [onlyNone]))
        let untagged = try #require(untaggedItems.first)
        #expect(untagged.name == "0123456789ab" && untagged.id == rawID)
        #expect(fact(untagged, "Confirmation name") == rawID)
        #expect(fact(untagged, "Tags") == "None")
    }

    @Test func imagesKeepTheExactConfirmationName() throws {
        let rawID = "sha256:0123456789abcdef0123456789abcdef"
        let tagged = CodingAIJSON.object(["id": .string(rawID), "tags": .array([.string("example/web:1"), .string("example/web:latest")]),
                                          "size": .number(1_024), "labels": .object(["secret": .string("label-secret")])])
        let untagged = replacing(tagged, "tags", with: .array([]))
        let images = try NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [tagged]))
        let first = try #require(images.first)
        #expect(first.name == "example/web:1")
        #expect(fact(first, "Confirmation name") == "example/web:1")
        #expect(fact(first, "Tags") == "example/web:1\nexample/web:latest")
        let second = try #require(NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [untagged])).first)
        #expect(second.name == "0123456789ab" && second.id == rawID)
        #expect(fact(second, "Confirmation name") == rawID)
        #expect(!rendered(first).contains("label-secret"))
        expectMalformed { try NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [replacing(tagged, "id", with: nil)])) }
        expectMalformed { try NativeDockerContractProjection.items(section: .images, reply: wrapped(.images, [replacing(tagged, "tags", with: .array([.null]))])) }
    }

    @Test func volumesAndNetworksKeepNamedIdentifiersAndSafeFacts() throws {
        let volume = CodingAIJSON.parse(#"{"name":"database-data","driver":"local","scope":"local","mountpoint":"mount-secret","labels":{"token":"label-secret"}}"#)
        let network = CodingAIJSON.parse(#"{"id":"network-1","name":"private","driver":"bridge","scope":"local","internal":true,"labels":{"token":"label-secret"},"options":{"secret":"option-secret"}}"#)
        let volumes = try NativeDockerContractProjection.items(section: .volumes, reply: wrapped(.volumes, [volume]))
        let networks = try NativeDockerContractProjection.items(section: .networks, reply: wrapped(.networks, [network]))
        let stored = try #require(volumes.first)
        let connected = try #require(networks.first)
        #expect(stored.id == "database-data" && stored.name == "database-data")
        #expect(fact(stored, "Driver") == "local" && fact(stored, "Scope") == "local")
        #expect(connected.id == "network-1" && connected.name == "private")
        #expect(fact(connected, "Internal") == "Yes")
        #expect(!rendered(stored).contains("secret") && !rendered(connected).contains("secret"))
        expectMalformed { try NativeDockerContractProjection.items(section: .volumes, reply: wrapped(.volumes, [replacing(volume, "name", with: nil)])) }
        expectMalformed { try NativeDockerContractProjection.items(section: .networks, reply: wrapped(.networks, [replacing(network, "internal", with: .number(1))])) }
    }

    @Test func projectsExposeServicesAndVerifiedCounts() throws {
        var runningFields = try #require(containerReply.object)
        runningFields["environment"] = .parse(#"[{"name":"TOKEN","value":"member-env-secret"}]"#)
        runningFields["mounts"] = .parse(#"[{"source":"/private/member-mount-secret","destination":"/data","readOnly":false}]"#)
        runningFields["labels"] = .parse(#"{"com.docker.compose.project":"site","com.docker.compose.service":"web","token":"member-label-secret"}"#)
        runningFields["command"] = .string("member-command-secret")
        let running = CodingAIJSON.object(runningFields)
        let stopped = replacing(replacing(replacing(containerReply, "id", with: .string("container-2")), "name", with: .string("database")), "state", with: .string("exited"))
        let reply = CodingAIJSON.object(["name": .string("site"), "containers": .array([running, stopped]),
                                        "services": .array([.string("web"), .string("database")]), "running": .number(1), "total": .number(2)])
        let item = try NativeDockerContractProjection.project(reply)
        #expect(item.id == "site" && item.state == "Partly running" && item.subtitle == "1 of 2 running")
        #expect(fact(item, "Services") == "web, database")
        #expect(fact(item, "Running") == "1 of 2 running" && fact(item, "Total containers") == "2")
        #expect(item.members.map(\.id) == ["container-1", "container-2"])
        #expect(item.members.map(\.name) == ["web", "database"])
        #expect(item.members == [try NativeDockerContractProjection.container(running), try NativeDockerContractProjection.container(stopped)])
        let member = try #require(item.members.first)
        #expect(fact(member, "Image") == "example/web:1")
        #expect(fact(member, "Environment") == "TOKEN=••••••")
        #expect(fact(member, "Mount destinations") == "/data")
        for member in item.members {
            #expect(member.members.isEmpty)
            #expect(!rendered(member).contains("member-env-secret"))
            #expect(!rendered(member).contains("member-mount-secret"))
            #expect(!rendered(member).contains("member-label-secret"))
            #expect(!rendered(member).contains("member-command-secret"))
        }
        #expect(try NativeDockerContractProjection.items(section: .projects, reply: wrapped(.projects, [reply])) == [item])
        for (key, value) in [("running", CodingAIJSON.number(3)), ("total", .number(3)), ("running", .number(0)),
                             ("services", .array([.number(1)])), ("name", .string(""))] {
            expectMalformed { try NativeDockerContractProjection.project(replacing(reply, key, with: value)) }
        }
    }

    @Test func usageAllowsMultiCoreCPUZeroBytesAndRepresentableUInt64Bounds() throws {
        let usage = try NativeDockerContractProjection.usage(usageReply)
        #expect(usage.cpuPercent == 250.5 && usage.memoryBytes == 1_024 && usage.memoryLimitBytes == 4_096)
        let zero = try NativeDockerContractProjection.usage(.object(["cpuPercent": .number(0), "memoryBytes": .number(0), "memoryLimitBytes": .number(0)]))
        #expect(zero.cpuPercent == 0 && zero.memoryBytes == 0 && zero.memoryLimitBytes == 0)
        let belowUpperBound = Double(UInt64.max).nextDown
        let large = try NativeDockerContractProjection.usage(replacing(usageReply, "memoryBytes", with: .number(belowUpperBound)))
        #expect(large.memoryBytes == UInt64(exactly: belowUpperBound))
        #expect(large.memoryBytes == UInt64.max - 2_047)
    }

    @Test func usageRefusesMissingCoercedNonfiniteAndOutOfRangeReadings() {
        let invalidCPU: [CodingAIJSON] = [.null, .bool(true), .string("1"), .number(-1), .number(.infinity), .number(.nan)]
        for value in invalidCPU {
            expectMalformed { try NativeDockerContractProjection.usage(replacing(usageReply, "cpuPercent", with: value)) }
        }
        let invalidBytes: [CodingAIJSON] = [.null, .bool(false), .string("1024"), .number(-1), .number(1.5),
                                            .number(Double(UInt64.max)), .number(Double.greatestFiniteMagnitude), .number(.infinity), .number(.nan)]
        for key in ["memoryBytes", "memoryLimitBytes"] {
            for value in invalidBytes {
                expectMalformed { try NativeDockerContractProjection.usage(replacing(usageReply, key, with: value)) }
            }
        }
        for key in ["cpuPercent", "memoryBytes", "memoryLimitBytes"] {
            expectMalformed { try NativeDockerContractProjection.usage(replacing(usageReply, key, with: nil)) }
        }
        expectMalformed { try NativeDockerContractProjection.usage(.null) }
    }
}
