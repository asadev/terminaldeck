/**
 * The pipe under the protocol: how a line of JSON gets to a Mac.
 *
 * There are two ways, and the protocol layer must not know which one it is
 * riding — that is the whole reason this seam exists rather than two copies of
 * the state machine in `LiveTransport`:
 *
 *   - `RelayCarrier` — a WebSocket to a rendezvous relay, binary frames, with a
 *     Noise IK handshake run before a single protocol byte moves. The relay is
 *     treated as hostile; it carries ciphertext and a routing header.
 *   - `DirectCarrier` — a WebSocket straight to the desktop's own listener on a
 *     tailnet, text frames, no sealed channel. The tunnel is the privacy there
 *     and there is no third party in the middle to seal against.
 *
 * ## `ready` is not `connected`
 *
 * A carrier says `ready` when the *protocol* may flow, which for the relay is
 * after the handshake has authenticated the far end — not when TCP connected,
 * not when the WebSocket upgraded. The relay accepts a guest socket for a host
 * that is not online and only then closes it, deliberately, so that the endpoint
 * cannot be used to ask which machines are up. A carrier that reported the
 * upgrade as success would put "Connected" on screen for a Mac that is asleep.
 */

import Foundation

enum CarrierEvent {
    /// The far end is authenticated and protocol messages may be sent.
    case ready
    /// One protocol message, already unsealed if it arrived sealed.
    case text(String)
    /// The pipe is gone. Nothing more will arrive on it and `send` will refuse.
    case closed(CarrierClose)
}

/**
 * Why a pipe ended.
 *
 * `code` is the WebSocket close code when there was one and `-1` when the socket
 * died without one — which is the common case on a phone and is not the same
 * thing as a clean close, so it is not flattened into 1000.
 */
struct CarrierClose: Equatable {
    let code: Int
    /// Set when this side decided. Nil when the peer or the network did, in
    /// which case the close code is all there is to go on.
    let detail: String?
    /// True while the far end had not authenticated. A close here means
    /// something quite different from one during a live session, and the
    /// sentence the user reads depends on it.
    let beforeReady: Bool
}

@MainActor
protocol Carrier: AnyObject {
    var onEvent: ((CarrierEvent) -> Void)? { get set }
    func open()
    func close()
    /// False when the pipe is not ready. Never queues — see `Transport.send`.
    @discardableResult
    func send(_ text: String) -> Bool
}

/* -------------------------------------------------------------------------- */
/* The socket underneath both                                                  */
/* -------------------------------------------------------------------------- */

/**
 * `URLSessionWebSocketTask`, with its callbacks brought onto the main actor and
 * its lifetime made explicit.
 *
 * Two things here are less obvious than they look. The session is created per
 * connection and invalidated on close, because a `URLSession` retains its
 * delegate until it is invalidated and a carrier that only cancelled its task
 * would leak one per reconnect — on a phone that reconnects every time it
 * changes cell, that is the whole afternoon. And the receive loop re-arms itself
 * only while the generation it started in is current, so a callback from a
 * socket that has already been replaced cannot deliver a frame into its
 * successor's state machine.
 */
@MainActor
final class WebSocketPipe: NSObject, @preconcurrency URLSessionWebSocketDelegate {

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    /// (close code or -1, a sentence when this side knows one)
    var onClose: ((Int, String?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    func open(url: URL, maximumMessage: Int) {
        closed = false
        let configuration = URLSessionConfiguration.ephemeral
        // A phone on a bad network should be told, not left spinning: this is
        // the wait before the socket is declared dead, not a limit on a session.
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessage
        self.task = task
        task.resume()
        receive(from: task)
    }

    func send(text: String, onFailure: @escaping (String) -> Void) {
        guard let task, !closed else { return onFailure("The connection is not open.") }
        task.send(.string(text)) { error in
            guard error != nil else { return }
            DispatchQueue.main.async { onFailure("The connection dropped while sending.") }
        }
    }

    func send(data: Data, onFailure: @escaping (String) -> Void) {
        guard let task, !closed else { return onFailure("The connection is not open.") }
        task.send(.data(data)) { error in
            guard error != nil else { return }
            DispatchQueue.main.async { onFailure("The connection dropped while sending.") }
        }
    }

    /// Idempotent, and safe to call from inside a callback: everything is
    /// dropped before the socket is cancelled, so the cancellation's own
    /// delegate call finds nothing to report.
    func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        guard !closed else { return }
        closed = true
        onOpen = nil
        onText = nil
        onData = nil
        onClose = nil
        task?.cancel(with: code, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive(from task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed, self.task === task else { return }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text): self.onText?(text)
                    case let .data(data): self.onData?(data)
                    @unknown default: break
                    }
                    self.receive(from: task)
                case .failure:
                    let code = task.closeCode.rawValue
                    self.finish(code: code == 0 ? -1 : code, detail: nil)
                }
            }
        }
    }

    private func finish(code: Int, detail: String?) {
        guard !closed else { return }
        let report = onClose
        close(code: .invalid)
        report?(code, detail)
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocolName: String?) {
        // The delegate queue is `.main`, which is what makes this safe to state
        // rather than dispatch — and dispatching would put the open behind a
        // frame that has already arrived.
        MainActor.assumeIsolated {
            guard !closed, task === webSocketTask else { return }
            onOpen?()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        MainActor.assumeIsolated {
            guard task === webSocketTask else { return }
            finish(code: closeCode.rawValue, detail: nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task sessionTask: URLSessionTask,
                                didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard task === sessionTask else { return }
            // The receive loop usually gets there first; this covers the case
            // where the connection never opened at all, which produces no
            // receive failure because nothing was ever received.
            finish(code: -1, detail: error.map { describe($0) })
        }
    }

    /**
     * A sentence, never `localizedDescription`.
     *
     * The common failures here have URLError codes with useful names and
     * useless descriptions, and the default one is worse than useless: pulling
     * the plug on the desktop put *"The operation couldn't be completed. Socket
     * is not connected"* in the app's connection banner, which is a POSIX errno
     * wearing a sentence's clothes. Anything unmapped says the true and boring
     * thing instead.
     */
    private func describe(_ error: Error) -> String {
        guard let url = error as? URLError else { return "The connection dropped." }
        switch url.code {
        case .notConnectedToInternet: return "This phone has no network."
        case .timedOut: return "The connection timed out."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Could not reach that address."
        case .networkConnectionLost: return "The network connection was lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "The server's TLS certificate was refused."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS refused a plaintext connection to that address."
        default: return "The connection dropped."
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Direct: a tailnet socket, no sealed channel                                 */
/* -------------------------------------------------------------------------- */

/**
 * The pipe the PWA uses, in Swift.
 *
 * Text frames of JSON, straight to `WS_PATH` on the desktop's own listener. No
 * handshake of ours: on a tailnet the two endpoints are already inside a private
 * network and TLS is terminated by Tailscale, so there is no third party to seal
 * against. That is a property of *that* path only, and it is why the pairing
 * screen says which kind of endpoint a code produced.
 */
@MainActor
final class DirectCarrier: Carrier {
    var onEvent: ((CarrierEvent) -> Void)?

    private let url: URL
    private let pipe = WebSocketPipe()
    private var ready = false

    init(url: URL) {
        self.url = url
    }

    func open() {
        pipe.onOpen = { [weak self] in
            guard let self else { return }
            ready = true
            onEvent?(.ready)
        }
        pipe.onText = { [weak self] text in
            self?.onEvent?(.text(text))
        }
        pipe.onData = { [weak self] _ in
            // The protocol is JSON text. A binary frame is something else
            // entirely — most likely not the desktop.
            self?.fail("The server sent something this client does not understand.")
        }
        pipe.onClose = { [weak self] code, detail in
            guard let self else { return }
            onEvent?(.closed(CarrierClose(code: code, detail: detail, beforeReady: !ready)))
        }
        pipe.open(url: url, maximumMessage: Wire.maxMessageBytes)
    }

    func close() {
        pipe.close()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard ready else { return false }
        pipe.send(text: text) { [weak self] detail in self?.fail(detail) }
        return true
    }

    private func fail(_ detail: String) {
        let wasReady = ready
        ready = false
        pipe.close()
        onEvent?(.closed(CarrierClose(code: -1, detail: detail, beforeReady: !wasReady)))
    }
}

/* -------------------------------------------------------------------------- */
/* Relay: sealed, through a machine we do not trust                            */
/* -------------------------------------------------------------------------- */

/**
 * A guest connection to a rendezvous relay, with the sealed channel inside it.
 *
 * Three things about this shape are worth stating because getting any of them
 * wrong produces a socket that connects and then goes quiet:
 *
 *  1. **Frames are binary and unwrapped.** The 17-byte envelope in
 *     `rendezvous.ts` is host-side only — a Mac holds one socket for many phones
 *     and needs to label them; a phone has one channel and is not told its own
 *     name. Sending an envelope from here would be relayed to the Mac as
 *     ciphertext that fails to open.
 *  2. **The first frame out is the handshake, and the first frame in is the
 *     reply.** Each is a Noise IK message behind one version byte, which is the
 *     framing in `src/shared/relay-wire.ts` and lives here as `RelayWire`:
 *     **81 bytes out, 49 bytes back**. Sending the bare 80 is what this client
 *     used to do, and the desktop answers a first payload of the wrong length by
 *     closing the channel and saying nothing — so the bug arrived on screen as
 *     "that Mac is not connected to the relay right now" and stayed there.
 *  3. **A close before the handshake is the usual case, not an error.** The
 *     relay accepts a guest for a host that is offline and then closes it,
 *     deliberately, so the endpoint cannot be used to enumerate which machines
 *     are up. So "the socket opened and immediately closed" means "that Mac is
 *     not there", and it must be said that way.
 */
@MainActor
final class RelayCarrier: Carrier {
    var onEvent: ((CarrierEvent) -> Void)?

    private let url: URL
    private let hostKey: Data
    private let deviceKeys: StaticKeyPair
    private let pipe = WebSocketPipe()

    private var pending: PendingHandshake?
    private var sealed: SealedTransport?

    init(url: URL, hostKey: Data, deviceKeys: StaticKeyPair) {
        self.url = url
        self.hostKey = hostKey
        self.deviceKeys = deviceKeys
    }

    func open() {
        pipe.onOpen = { [weak self] in self?.startHandshake() }
        pipe.onData = { [weak self] data in self?.receive(data) }
        pipe.onText = { [weak self] _ in
            // Everything on this socket is ciphertext. A text frame is a proxy,
            // a captive portal, or something that is not the relay.
            self?.fail("Something on the path answered with text instead of a sealed frame.")
        }
        pipe.onClose = { [weak self] code, detail in
            guard let self else { return }
            let beforeReady = sealed == nil
            onEvent?(.closed(CarrierClose(
                code: code,
                detail: detail ?? unstartedReason(),
                beforeReady: beforeReady)))
        }
        // The relay caps a payload at 96 KiB; the desktop caps a message at 64.
        pipe.open(url: url, maximumMessage: 96 * 1024)
    }

    func close() {
        sealed = nil
        pending = nil
        pipe.close()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let sealed else { return false }
        guard let frame = try? sealed.send(text: text) else {
            // The only way this throws is the counter cap, which is a
            // reconnect, never a reused nonce.
            fail("This connection has been open too long; reconnecting.")
            return false
        }
        pipe.send(data: frame) { [weak self] detail in self?.fail(detail) }
        return true
    }

    /**
     * Which of the two silences this was, when the socket died without saying.
     *
     * The relay accepts a guest for a host that is offline and then closes it —
     * deliberately, so the endpoint cannot be used to enumerate which machines
     * are up — so "opened, then closed" means the Mac is not there. But a relay
     * that is not running produces a close too, and telling a user their Mac is
     * offline when the truth is that the *relay* is unreachable sends them to
     * the wrong room. The two are told apart by whether this side ever got far
     * enough to put a handshake on the wire.
     *
     * Nil once the channel is sealed: a close after that is an ordinary
     * disconnection and `closeReason` has better words for it.
     */
    private func unstartedReason() -> String? {
        if sealed != nil { return nil }
        if pending != nil { return "That Mac is not connected to the relay right now." }
        return "Could not reach the relay at \(url.host ?? url.absoluteString)."
    }

    // MARK: - Handshake

    private func startHandshake() {
        do {
            let started = try SealedHandshake.start(deviceStatic: deviceKeys,
                                                    responderStaticPublic: hostKey)
            pending = started.pending
            // The version byte goes on here and nowhere else. `Sealed` produces
            // the Noise message; the wire carries it framed.
            pipe.send(data: RelayWire.withSealedVersion(started.message)) { [weak self] detail in
                self?.fail(detail)
            }
        } catch {
            // A malformed host key from a pairing code, essentially. Not
            // retryable, but the transport decides that; this only reports.
            fail("This device could not start a handshake with that Mac's key.")
        }
    }

    private func receive(_ data: Data) {
        if let sealed {
            let plaintext: Data
            do {
                plaintext = try sealed.receive(data)
            } catch {
                // Every failure is the same failure: a bad tag, a replay and a
                // reordering are not distinguished out loud.
                fail("A frame from the Mac failed authentication.")
                return
            }
            guard let text = String(data: plaintext, encoding: .utf8) else {
                // The seal held, so this really is the Mac — sending something
                // the protocol above does not define.
                fail("The Mac sent a frame that is not text.")
                return
            }
            onEvent?(.text(text))
            return
        }

        guard let pending else {
            fail("A frame arrived before this client had started a handshake.")
            return
        }

        // Unwrapped before the cryptography sees it, and a version this build
        // does not speak is told apart from a reply that failed its tag. Both
        // end the connection; only one of them is fixed by updating an app, and
        // a client that misparsed the framed reply as a Noise reply would report
        // the wrong one.
        let opened = RelayWire.readSealedHandshake(data, expected: RelayWire.handshakeReplyBytes)
        guard case let .ok(reply) = opened else {
            guard case let .refused(reason) = opened else { return }
            fail(reason.sentence)
            return
        }

        do {
            sealed = try SealedHandshake.finish(pending: pending, reply: reply)
            self.pending = nil
            onEvent?(.ready)
        } catch {
            // The relay cannot man-in-the-middle without landing here, which is
            // the property the whole design is for. It is also what a stale
            // pairing code looks like after the Mac has regenerated its key.
            fail("The Mac's reply failed authentication. Its key may have changed — pair again.")
        }
    }

    private func fail(_ detail: String) {
        let beforeReady = sealed == nil
        sealed = nil
        pending = nil
        pipe.close()
        onEvent?(.closed(CarrierClose(code: -1, detail: detail, beforeReady: beforeReady)))
    }
}
