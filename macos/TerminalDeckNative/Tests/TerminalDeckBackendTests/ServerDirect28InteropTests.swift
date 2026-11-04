import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckPeer

/// A real native client and Node host, in separate processes. No app, session host or saved data is opened.
@Suite("Server direct link between the native client and Node", .serialized)
struct ServerDirect28InteropTests {
    enum Failure: Error { case missingProbe, badSignal, stopped, timedOut, refusedSend }

    actor Client {
        enum Phase { case ready, open, firstPong, relayDropped, secondPong }
        let binding = Data((1...32).map(UInt8.init))
        var child: Process?
        var input: FileHandle?
        var output: FileHandle?
        var reader: Task<Void, Never>?
        var feed: AsyncStream<Data>.Continuation?
        var pending = Data()
        var link: PeerLink?
        var ready = false, opened = false, hostMoved = false, relayDropped = false
        var pongs: Set<String> = []
        var relayAppTypes: Set<String> = []
        var failed = false
        var stopping = false

        func start(probe: String, runner: String?) throws {
            let process = Process(), stdin = Pipe(), stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: runner ?? "/usr/bin/env")
            process.arguments = runner == nil ? ["node", probe] : [probe]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let stream = AsyncStream<Data>.makeStream()
            feed = stream.continuation
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; stream.continuation.finish() }
                else { stream.continuation.yield(data) }
            }
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            child = process
            reader = Task { [weak self] in
                for await data in stream.stream { await self?.received(data) }
            }
            try process.run()
        }

        static func text(_ fields: [NativeRPCValue.Field]) -> String {
            String(decoding: (try? NativeRPCValue.object(fields).encodedJSON()) ?? Data(), as: UTF8.self)
        }

        func control(_ text: String) throws {
            guard let input, child?.isRunning == true else { throw Failure.stopped }
            try input.write(contentsOf: Data((text + "\n").utf8))
        }

        func ping(_ rid: String) throws {
            let text = Self.text([.init("t", .string("ping")), .init("rid", .string(rid))])
            guard link?.send(Data(text.utf8), lane: .control) == true else { throw Failure.refusedSend }
        }

        func wait(_ phase: Phase) async throws {
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                if failed { throw Failure.badSignal }
                if child?.isRunning != true { throw Failure.stopped }
                let done: Bool
                switch phase {
                case .ready: done = ready
                case .open: done = opened && hostMoved
                case .firstPong: done = pongs.contains("before-drop")
                case .relayDropped: done = relayDropped
                case .secondPong: done = pongs.contains("after-drop")
                }
                if done { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure.timedOut
        }

        private func received(_ data: Data) async {
            pending.append(data)
            guard pending.count <= 128 * 1024 else { failed = true; return }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let value = try? NativeRPCValue.parseJSON(Data(line)) else { failed = true; return }
                await relay(value)
            }
        }

        private func relay(_ value: NativeRPCValue) async {
            switch value["t"].string {
            case "probe.ready": ready = true
            case "probe.relayDropped":
                relayDropped = value["kept"].bool == true && value["up"].bool == true
                if !relayDropped { failed = true }
            case "probe.closed": if !stopping { failed = true }
            case "welcome":
                let caps = value["capabilities"].elements?.compactMap(\.string) ?? []
                if !caps.contains("link.dc2") || !caps.contains("link.only") { failed = true }
            case "link.moved": hostMoved = true
            case "link.peer":
                switch value["op"].string {
                case "offer": await offer(value)
                case "cand":
                    if let candidate = value["c"].string {
                        link?.add(candidate: candidate, mid: value["mid"].string, index: Int32(value["idx"].number ?? 0))
                    }
                case "end": failed = true
                default: failed = true
                }
            case "probe.finished": break
            default: relayAppTypes.insert(value["t"].string ?? "unknown")
            }
        }

        private func offer(_ value: NativeRPCValue) async {
            guard link == nil, let sdp = value["sdp"].string, let fp = value["fp"].string, let bind = value["bind"].string,
                  sdp.utf8.count <= 32_000, PeerLink.fingerprint(in: sdp) == fp,
                  PeerBinding.check(bind, binding: binding, role: "host", fingerprint: fp) else { failed = true; return }
            let servers = (value["ice"].elements ?? []).map {
                PeerICEServer(urls: $0["urls"].elements?.compactMap(\.string) ?? [],
                              username: $0["username"].string, credential: $0["credential"].string)
            }
            let events = PeerLink.Events(
                candidate: { [weak self] sdp, mid, index in
                    let text = Client.text([.init("t", .string("link.peer")), .init("op", .string("cand")),
                                            .init("c", .string(sdp)), .init("mid", .string(mid ?? "0")),
                                            .init("idx", .number(Double(index)))])
                    Task { await self?.candidate(text) }
                },
                open: { [weak self] _ in Task { await self?.didOpen() } },
                closed: { [weak self] _ in Task { await self?.didClose() } },
                message: { [weak self] data, lane in Task { await self?.message(data, lane) } })
            do {
                let made = try PeerLink(role: .answerer, servers: servers, events: events)
                link = made
                let answer = try await made.answer(offer: sdp)
                guard let fingerprint = PeerLink.fingerprint(in: answer) else { failed = true; return }
                try control(Self.text([.init("t", .string("link.peer")), .init("op", .string("answer")),
                                       .init("sdp", .string(answer)), .init("fp", .string(fingerprint)),
                                       .init("bind", .string(PeerBinding.make(binding: binding, role: "client", fingerprint: fingerprint)))]))
            } catch { failed = true }
        }

        private func candidate(_ text: String) {
            guard !stopping else { return }
            if opened { _ = link?.send(Data(text.utf8), lane: .control) }
            guard !relayDropped else { return }
            do { try control(text) } catch { failed = true }
        }

        private func didOpen() {
            opened = true
            do { try control(#"{"t":"link.moved"}"#) } catch { failed = true }
        }

        private func didClose() { if !stopping { failed = true } }

        private func message(_ data: Data, _ lane: PeerLane) {
            guard lane == .control, let value = try? NativeRPCValue.parseJSON(data) else { failed = true; return }
            if value["t"].string == "link.peer" {
                if value["op"].string == "cand", let candidate = value["c"].string {
                    link?.add(candidate: candidate, mid: value["mid"].string, index: Int32(value["idx"].number ?? 0))
                } else if value["op"].string == "end" { failed = true }
                return
            }
            guard value["t"].string == "pong", let rid = value["rid"].string else { failed = true; return }
            pongs.insert(rid)
        }

        func facts() -> (pongs: Set<String>, relayAppTypes: Set<String>, failed: Bool) { (pongs, relayAppTypes, failed) }

        func stop() {
            stopping = true
            try? control(#"{"t":"probe.stop"}"#)
            link?.close(); link = nil
            try? input?.close(); input = nil
            output?.readabilityHandler = nil
            try? output?.close(); output = nil
            feed?.finish(); feed = nil
            reader?.cancel(); reader = nil
            if child?.isRunning == true { child?.terminate() }
            child = nil
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SERVER_DIRECT_28_PROBE"] != nil))
    func nativeClientTalksToNodeAndKeepsItsLinkWhenTheRelayDrops() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let probe = environment["SERVER_DIRECT_28_PROBE"], FileManager.default.fileExists(atPath: probe) else {
            throw Failure.missingProbe
        }
        let client = Client()
        do {
            try await client.start(probe: probe, runner: environment["SERVER_DIRECT_28_PROBE_RUNNER"])
            try await client.wait(.ready)
            try await client.control(#"{"t":"hello","capabilities":["link.dc2","link.only"]}"#)
            try await client.wait(.open)
            try await client.ping("before-drop")
            try await client.wait(.firstPong)
            try await client.control(#"{"t":"probe.dropRelay"}"#)
            try await client.wait(.relayDropped)
            try await client.ping("after-drop")
            try await client.wait(.secondPong)
            let facts = await client.facts()
            #expect(facts.pongs == Set(["before-drop", "after-drop"]))
            #expect(facts.relayAppTypes.isEmpty)
            #expect(!facts.failed)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }
}
