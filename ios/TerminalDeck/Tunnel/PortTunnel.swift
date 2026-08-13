/**
 * The phone's half of "see your Mac's localhost on your phone".
 *
 * A port on the Mac is made to exist on the phone, **at the same number**, by
 * listening on the phone's own loopback and copying every byte across the sealed
 * channel that is already open. A `WKWebView` is then pointed at
 * `http://127.0.0.1:<port>/` and, as far as it is concerned, that is simply
 * where the site is.
 *
 * ## Why a byte pipe and not an HTTP client
 *
 * The obvious version fetches the page and hands it to the web view. It fails
 * immediately and for good: the page's own `fetch` calls, its stylesheets, its
 * images and — the one that matters — its **hot-reload WebSocket** all go
 * wherever the page's origin says, which is a port on `localhost`. Unless
 * something is really listening there, the site is a screenshot.
 *
 * So this listens for real, and forwards bytes without reading them. The
 * WebSocket upgrade is bytes. Chunked transfer is bytes. Server-sent events are
 * bytes. Nothing here has to know what any of them are, which is why nothing
 * here can get them wrong.
 *
 * ## Why the port number has to match
 *
 * A dev server puts absolute URLs in its own output — a redirect to
 * `http://localhost:3000/login`, a websocket at `ws://localhost:3000/_next/hmr`,
 * a cookie scoped to a port. Serve the same site on a different port on the
 * phone and every one of those escapes the tunnel and fails, in ways that look
 * like the framework being broken. Matching the number is not a nicety; it is
 * the reason this works at all. When the number is unavailable, this says so
 * rather than quietly choosing another and half-working.
 *
 * ## Flow control
 *
 * `NWConnection` is pull-based: bytes arrive only when `receive` is called. That
 * is the backpressure — the next read is not armed until the far end has
 * acknowledged enough of what was already sent. Nothing needs to be buffered
 * here for it to work, which is the whole reason the window is expressed this
 * way round.
 */

import Foundation
import Network
import Observation

/// What a tunnel needs from the connection it rides. `DeckModel` implements it.
@MainActor
protocol TunnelWire: AnyObject {
    /// False when the socket is down. Never queues — a byte held back and
    /// delivered after a reconnect arrives in the middle of someone's HTTP
    /// response, which is worse than the connection having dropped.
    @discardableResult
    func send(_ message: ClientMessage) -> Bool
}

@MainActor
@Observable
final class PortTunnel: Identifiable {

    /// Where a tunnel is in its short life. Every case a screen can be in, and
    /// each one carries the sentence that screen should be showing.
    enum Phase: Equatable {
        /// `tunnel.open` is on the wire; the Mac has not answered yet.
        case opening
        /// Serving. The URL is what the web view should load.
        case live(URL)
        /// It never started, or it ended. `detail` is for the person, not the log.
        case ended(String)
    }

    private(set) var phase: Phase = .opening
    /// Browser connections currently open through this tunnel. Shown so that a
    /// page that is quietly still talking — a hot-reload socket — is visible.
    private(set) var streams = 0

    let id = UUID().uuidString
    let port: Int

    private weak var wire: TunnelWire?
    private var listener: NWListener?
    /// The second family, on the same port. Best effort — see `bind`.
    private var alternate: NWListener?
    private var connections: [String: Stream] = [:]
    private var finished = false

    init(port: Int, wire: TunnelWire) {
        self.port = port
        self.wire = wire
    }

    /// Ask the Mac for the port. Nothing is bound until it says yes: a listener
    /// standing open for a tunnel that was refused would accept a browser
    /// connection it can do nothing with.
    func start() {
        guard wire?.send(.tunnelOpen(id: id, port: port)) == true else {
            end("The connection to the Mac is not up.", tellMac: false)
            return
        }
    }

    /// The user closed the view, or the app is going away.
    func stop() {
        end("Closed.", tellMac: true)
    }

    /**
     * A frame from the Mac. True when it belonged to this tunnel.
     *
     * Returning a Bool rather than filtering upstream keeps the routing in one
     * place: `DeckModel` has no idea which channel ids are whose, and giving it
     * one would be a second copy of this map to keep in step.
     */
    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .tunnelOpened(id, _) where id == self.id:
            begin()
            return true
        case let .tunnelClosed(id, detail) where id == self.id:
            // The Mac decided, so it is not told again.
            end(detail, tellMac: false)
            return true
        case let .netData(ch, data):
            guard let stream = connections[ch] else { return false }
            stream.write(data)
            return true
        case let .netAck(ch, bytes):
            guard let stream = connections[ch] else { return false }
            stream.acknowledge(bytes)
            return true
        case let .netClose(ch):
            guard connections[ch] != nil else { return false }
            drop(ch, tell: false)
            return true
        default:
            return false
        }
    }

    /// The connection to the Mac went down. Every stream through it is dead, and
    /// saying so beats a browser spinner that never resolves.
    func connectionLost(_ detail: String) {
        // Nothing is sent: the wire that would carry it is the thing that broke.
        end(detail, tellMac: false)
    }

    // MARK: - Listening

    private func begin() {
        guard !finished, case .opening = phase else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await self.bind() else { return }
            guard !self.finished else { return }
            self.phase = .live(url)
        }
    }

    /**
     * Listen on the phone's loopback, at the port the Mac serves on.
     *
     * Both address families are attempted, and that is not belt-and-braces: a
     * dev server that redirects to `http://localhost:<port>` is resolved by the
     * web view to `::1` before `127.0.0.1`, so a phone listening on IPv4 alone
     * drops exactly the links a framework writes for itself. IPv4 is the one the
     * loaded URL names, so it is the one that has to succeed — except in the
     * Simulator, where it cannot.
     *
     * Nil when it could not listen; the tunnel has already been ended and the
     * Mac told, because a tunnel held open for a port this phone cannot serve is
     * a socket on somebody's machine with nothing on the other end of it.
     */
    private func bind() async -> URL? {
        guard port > 0, port <= 65_535, let number = NWEndpoint.Port(rawValue: UInt16(port)) else {
            end("\(port) is not a port this phone can listen on.", tellMac: true)
            return nil
        }

        // Asked before binding, and this is the check that actually works.
        //
        // Two weaker versions were tried. Taking whichever `NWListener(using:)`
        // did not throw is wrong because that initialiser does not bind, it
        // configures — the conflict arrives later as a `.failed` state. Waiting
        // for `.ready` is better and still not enough: BSD lets a socket bound
        // to the *specific* address `127.0.0.1` sit underneath one already bound
        // to the IPv6 wildcard with v4-mapping on, so the bind succeeds, the
        // kernel then splits new connections between the two by specificity,
        // and half the page comes from one server and half from the other.
        // Measured, not reasoned about: against a dual-stack listener on the
        // same port this bound cleanly and then span up thirteen streams
        // relaying to itself.
        //
        // Asking whether the address already *answers* is the direct question
        // and has no such gap.
        async let takenFour = answers(host: .ipv4(.loopback), port: number)
        async let takenSix = answers(host: .ipv6(.loopback), port: number)
        let (busyFour, busySix) = await (takenFour, takenSix)

        async let first = busyFour ? nil : ready(host: .ipv4(.loopback), port: number)
        async let second = busySix ? nil : ready(host: .ipv6(.loopback), port: number)
        let (four, six) = await (first, second)

        if finished {
            four?.cancel()
            six?.cancel()
            return nil
        }

        if let four {
            listener = four
            alternate = six
            watch(four)
            return URL(string: "http://127.0.0.1:\(port)/")!
        }

        #if targetEnvironment(simulator)
        // The Simulator has no network stack of its own: `127.0.0.1` inside it
        // *is* the Mac's loopback, so the dev server being tunnelled is already
        // holding the address this would bind. `::1` is a separate socket and
        // the collision does not arise there, so development keeps working —
        // measured, not assumed, and the reason the URL below is an IPv6
        // literal. On a real phone this branch does not exist, because there a
        // collision means what it says: something else has the port.
        if let six {
            listener = six
            watch(six)
            return URL(string: "http://[::1]:\(port)/")!
        }
        #else
        six?.cancel()
        #endif

        end(
            "Port \(port) is already in use on this phone, so the page cannot be served at the address the "
                + "Mac's server writes into its own links. Close whatever is using it and tap again.",
            tellMac: true)
        return nil
    }

    /**
     * Is something already answering on this address?
     *
     * A connect, not a bind — see `bind` for why the bind cannot be trusted on
     * its own. Loopback either answers immediately or refuses immediately, so
     * the timeout is short; it exists only so that an address in a state neither
     * of those covers cannot hold the tap open.
     *
     * Treated as busy when the answer does not arrive. Refusing a port that
     * might have been free costs one honest sentence and a second tap; taking a
     * port that was not free costs a page assembled from two different servers.
     */
    private func answers(host: NWEndpoint.Host, port: NWEndpoint.Port) async -> Bool {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            let answer = { (live: Bool) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: live)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    answer(true)
                case .failed, .cancelled:
                    answer(false)
                case .waiting:
                    // `.waiting`, not `.failed`, is what a **refused** connection
                    // looks like in Network.framework: it holds the connection
                    // open and retries, on the assumption that the far end will
                    // turn up. On loopback nothing is going to turn up, and
                    // reading this as "no answer yet" made the timeout below
                    // fire and call every free port busy — which refused the
                    // happy path outright.
                    answer(false)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(true) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return reachable
    }

    /// A listener that has actually bound, or nil. Never throws and never hangs:
    /// a state machine that settles neither way is a spinner forever.
    private func ready(host: NWEndpoint.Host, port: NWEndpoint.Port) async -> NWListener? {
        let parameters = NWParameters.tcp
        // The bind address, and the only one. Without this the listener takes
        // every interface the phone has, which on a café's wifi is a stranger's
        // route to a server on somebody's Mac.
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        // Deliberately *not* `allowLocalEndpointReuse`. That would let this bind
        // succeed alongside another listener on the same port, and the kernel
        // would then hand new connections to one of the two — so half the page
        // would come through the tunnel and half from whatever else was there.
        // A refusal that says "this port is taken" is worth more than a bind
        // that works four times out of five.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            // Hot-reload notices are forty bytes. Nagle would sit on each one
            // waiting for company.
            tcp.noDelay = true
        }

        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }

        let settled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            let answer = { (bound: Bool) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: bound)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: answer(true)
                case .failed, .cancelled: answer(false)
                default: break
                }
            }
            listener.start(queue: .main)
        }

        guard settled else {
            listener.cancel()
            return nil
        }
        return listener
    }

    /// Watch a bound listener for a later failure. Set after `ready` has used
    /// the handler for its own purpose, so the two do not fight over it.
    private func watch(_ listener: NWListener) {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, case let .failed(error) = state else { return }
                self.end("The phone stopped listening on port \(self.port): \(error.localizedDescription)",
                         tellMac: true)
            }
        }
    }

    // MARK: - Streams

    private func accept(_ connection: NWConnection) {
        guard !finished, case .live = phase else {
            connection.cancel()
            return
        }
        let ch = UUID().uuidString
        guard wire?.send(.netOpen(ch: ch, tunnel: id)) == true else {
            connection.cancel()
            return
        }

        let stream = Stream(ch: ch, connection: connection)
        stream.onOutbound = { [weak self] data in
            self?.wire?.send(.netData(ch: ch, data: data))
        }
        stream.onAck = { [weak self] bytes in
            self?.wire?.send(.netAck(ch: ch, bytes: bytes))
        }
        stream.onEnded = { [weak self] in
            self?.drop(ch, tell: true)
        }
        connections[ch] = stream
        streams = connections.count
        stream.start()
    }

    private func drop(_ ch: String, tell: Bool) {
        guard let stream = connections.removeValue(forKey: ch) else { return }
        streams = connections.count
        stream.cancel()
        if tell { wire?.send(.netClose(ch: ch)) }
    }

    /**
     * Take the tunnel down, once.
     *
     * `tellMac` is false only when the Mac already knows — it closed the tunnel
     * itself, or the connection carrying the message is the thing that broke.
     * Every other path has to send: a tunnel this phone abandoned quietly would
     * leave a socket open on somebody's machine and a row in their device list
     * for a page nobody is looking at.
     */
    private func end(_ detail: String, tellMac: Bool) {
        guard !finished else { return }
        finished = true
        if tellMac { wire?.send(.tunnelClose(id: id)) }
        for ch in connections.keys { connections[ch]?.cancel() }
        connections = [:]
        streams = 0
        listener?.cancel()
        alternate?.cancel()
        listener = nil
        alternate = nil
        phase = .ended(detail)
    }
}

/**
 * One browser connection, and the two halves of copying it.
 *
 * Split out of `PortTunnel` because the bookkeeping is per-socket and the
 * lifetime is not: a page reloads a dozen times through one tunnel, and a
 * WebSocket outlives every one of those reloads.
 */
@MainActor
private final class Stream {

    var onOutbound: ((Data) -> Void)?
    var onAck: ((Int) -> Void)?
    var onEnded: (() -> Void)?

    private let ch: String
    private let connection: NWConnection
    /// Bytes sent to the Mac that it has not said it has written yet. The next
    /// read is armed only when this is under the window.
    private var unacked = 0
    private var reading = false
    private var done = false

    init(ch: String, connection: NWConnection) {
        self.ch = ch
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.pull()
                case .failed, .cancelled:
                    self?.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Bytes from the Mac, on their way to the browser.
    func write(_ data: Data) {
        guard !done, !data.isEmpty else { return }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, !self.done else { return }
                    if error != nil {
                        self.finish()
                        return
                    }
                    // Acknowledged once the socket has taken it, so the Mac's
                    // window is measuring this phone's appetite rather than
                    // measuring nothing.
                    self.onAck?(data.count)
                }
            })
    }

    func acknowledge(_ bytes: Int) {
        unacked = max(0, unacked - bytes)
        // The read that was not armed while the window was full is armed now.
        if !reading && unacked < Wire.netWindowBytes { pull() }
    }

    func cancel() {
        guard !done else { return }
        done = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func pull() {
        guard !done, !reading, unacked < Wire.netWindowBytes else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: Wire.maxNetChunkBytes) {
            [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return }
                self.reading = false
                if let data, !data.isEmpty {
                    self.unacked += data.count
                    self.onOutbound?(data)
                }
                if complete || error != nil {
                    // The browser closed its half. There is no half-open state
                    // worth keeping here: the response it was waiting for has
                    // nowhere to go.
                    self.finish()
                    return
                }
                self.pull()
            }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEnded?()
    }
}
