/**
 * One SSH connection from the phone to one server — the thing this app did not
 * have, and the reason the phone could only ever reach a machine that was
 * already running a host.
 *
 * ## What was chosen, and why
 *
 * Asad's requirement is that the phone manage a server *exactly* the way the Mac
 * does: *"Say no MacBook or Windows exists at all — a user only has a server and
 * a phone."* The Mac does it with `ssh2`, a Node library, which iOS cannot load;
 * so the honest choices were three, and two of them were wrong:
 *
 *  1. **Route SSH through a desktop or a relay.** Rejected outright: it is the
 *     one thing the requirement forbids. A phone that needs a Mac in the middle
 *     has not managed the server, it has borrowed a Mac. (A relay could carry
 *     raw TCP without ever seeing plaintext — SSH is end to end — but it would
 *     still need an SSH client at this end, so it solves reachability, not this.)
 *  2. **Write an SSH client here.** This repo has hand-rolled Noise IK in three
 *     languages, so it is not out of reach — but SSH is a transport, a key
 *     exchange, six ciphers, a user-auth layer and a channel multiplexer, and a
 *     bug in any of them is a security bug on somebody's production server.
 *  3. **`apple/swift-nio-ssh`.** Apache-2.0, from Apple, the only maintained
 *     pure-Swift SSH implementation with a client role. Chosen.
 *
 * ## What that choice costs, stated rather than discovered
 *
 * **NIOSSH does not do RSA** — not as a user key, not as a host key. Two
 * consequences, and both are handled rather than left to fail as "refused":
 *
 *  - an RSA private key is refused by name in `SSHKeys.swift`, with the two
 *    things that work instead;
 *  - a server offering *only* an `ssh-rsa` host key cannot be connected to at
 *    all. Every OpenSSH since 7.0 generates an Ed25519 host key by default and
 *    offers it first, so this is rare — but it is real, and
 *    {@link SSHProblem.nothingInCommon} says so in those words rather than
 *    blaming the network.
 *
 * ## The identity check is not optional here either
 *
 * `connection.ts` makes `hostVerifier` a required option so that a second code
 * path cannot forget it. The equivalent here is that {@link open} takes the
 * expected fingerprint as a *parameter* — there is no initialiser that skips it,
 * and `nil` means "first sight, tell me what you saw", not "trust anything".
 * `ServerStore` is what remembers the answer, and a changed key stops the
 * connection before a single byte of a password is offered.
 *
 * ## Nothing is kept open
 *
 * The desktop's rule, which is his: **events, not polling.** A session is opened
 * for a piece of work and closed when it ends. There is no keepalive, no
 * reconnect loop and no timer per server — facts are stamped with when they were
 * measured and the screen shows the age instead.
 */

import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// How a sign-in is offered. Exactly the two the desktop's form asks for.
enum SSHAuthMethod {
    case password(String)
    /// The text of an unencrypted private key, as pasted.
    case key(String)
}

/// What one command on the server came to.
struct SSHRun: Equatable {
    /// The command's exit status, or -1 when it ended without giving one.
    let code: Int
    let stdout: String
    let stderr: String
    /// True when output was cut off at the ceiling. Reported, never silent.
    let truncated: Bool
}

/// The server's identity, in the form every other SSH tool prints.
struct SSHHostKey: Equatable, Codable {
    /// The key's own algorithm name, as the server announced it.
    let algorithm: String
    /// `SHA256:` and unpadded base64 — byte-identical to `ssh-keyscan | ssh-keygen -lf -`.
    let fingerprint: String
}

/**
 * What went wrong, as something a person can act on.
 *
 * A port of the argument in `connection.ts`: the sentences live where the
 * failure is recognised, once, rather than as ten `catch` blocks each inventing
 * their own wording. Note what is deliberately *not* claimed — which half of a
 * sign-in was wrong. A server does not tell a client whether the username or the
 * credential was the problem, so neither does this.
 */
enum SSHProblem: Error, Equatable {
    case noSuchAddress
    case noAnswer
    case notAServer
    case signInRefused
    case identityChanged(seen: String, stored: String)
    case badKey(PrivateKeyProblem)
    case nothingInCommon
    case lost
    case timedOut
    case commandFailed(String)

    var headline: String {
        switch self {
        case .noSuchAddress: return "That address could not be found"
        case .noAnswer: return "That address did not answer"
        case .notAServer: return "That answered, but not as a server"
        case .signInRefused: return "That sign-in was refused"
        case .identityChanged: return "That server is not the one you added"
        case let .badKey(problem): return problem.headline
        case .nothingInCommon: return "This phone and that server share no way to talk"
        case .lost: return "The connection to that server ended"
        case .timedOut: return "That server stopped answering"
        case .commandFailed: return "That server refused the command"
        }
    }

    var advice: String {
        switch self {
        case .noSuchAddress:
            return "Check the address. A name has to resolve from this phone's network, so a name "
                + "that only exists on your office network will not be found from a mobile one."
        case .noAnswer:
            return "The server may be off, the port may be wrong, or something in between may be "
                + "blocking it. Check the port — SSH is usually 22, and a server set up to use "
                + "another number will not answer on 22 at all."
        case .notAServer:
            return "Something is listening on that port and it is not SSH. That usually means the "
                + "port belongs to something else — a website, a database — rather than to the "
                + "server's own sign-in."
        case .signInRefused:
            return "The server did not accept that account with that password or key. It will not "
                + "say which of the two it disliked, so check both. A key has to have been added "
                + "to that account on the server before it will be accepted."
        case let .identityChanged(seen, stored):
            return "It answered with \(seen). When you added it, it was \(stored). That is what a "
                + "rebuilt server looks like, and it is also what an impostor looks like — so "
                + "nothing was sent. Forget this server and add it again only if you know why it "
                + "changed."
        case let .badKey(problem):
            return problem.advice
        case .nothingInCommon:
            return "This phone signs in with Ed25519 and ECDSA. A server that offers only an older "
                + "RSA host key has nothing in common with it. Adding an Ed25519 host key on that "
                + "server — `ssh-keygen -A` on most of them — is what fixes it."
        case .lost:
            return "It closed the connection. Opening the server again reconnects."
        case .timedOut:
            return "It accepted the connection and then stopped answering. That is usually a server "
                + "under heavy load or a network that dropped in the middle."
        case let .commandFailed(detail):
            return detail
        }
    }
}

/* -------------------------------------------------------------------------- */

final class SSHSession {

    /**
     * One event loop for every server, for the whole life of the app.
     *
     * A group per connection would mean a thread per connection and a thread
     * leak per failure. One loop is plenty: everything this does is a round trip
     * to a server, and the work in this process is parsing a few kilobytes.
     */
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// How long the handshake gets. The desktop's number, deliberately.
    static let handshakeTimeout: TimeAmount = .seconds(20)
    /// How long any one ordinary command gets. The probe takes 293 ms on a real box.
    static let commandTimeout: TimeAmount = .seconds(30)
    /// The ceiling on one command's output, so `cat` of a log cannot become this app's heap.
    static let maxOutputBytes = 4 * 1024 * 1024

    private let channel: Channel
    private let handler: NIOSSHHandler
    /// What the server proved itself with. Shown, and remembered by the store.
    let hostKey: SSHHostKey

    private init(channel: Channel, handler: NIOSSHHandler, hostKey: SSHHostKey) {
        self.channel = channel
        self.handler = handler
        self.hostKey = hostKey
    }

    var isOpen: Bool { channel.isActive }

    /**
     * Dial, check the identity, and sign in.
     *
     * `expect` is the fingerprint this app last saw for this server. `nil` is
     * first sight — the key is accepted and handed back for the caller to store
     * and show — and a mismatch fails before any credential is offered.
     */
    static func open(address: String,
                     port: Int,
                     username: String,
                     auth: SSHAuthMethod,
                     expect: String?) async throws -> SSHSession {
        // Read before anything is dialled: a key that cannot be used is a
        // sentence about the key, not a failed connection to a server.
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch auth {
        case let .password(password):
            offer = .password(.init(password: password))
        case let .key(text):
            do {
                offer = .privateKey(.init(privateKey: try SSHPrivateKeyReader.read(text)))
            } catch let problem as PrivateKeyProblem {
                throw SSHProblem.badKey(problem)
            }
        }

        let seen = HostKeySeen()
        let verifier = HostKeyVerifier(expect: expect, seen: seen)
        let authenticator = OneOffer(username: username, offer: offer)
        let signal = SignalHandler()

        // Built here rather than inside the initialiser so this object keeps a
        // reference to it: `createChannel` is on the handler, and fishing it back
        // out of the pipeline by type later is a lookup that can fail for no
        // reason a caller could act on.
        let ssh = NIOSSHHandler(
            role: .client(SSHClientConfiguration(userAuthDelegate: authenticator,
                                                 serverAuthDelegate: verifier)),
            allocator: ByteBufferAllocator(),
            inboundChildChannelInitializer: nil)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: handshakeTimeout)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([ssh, signal])
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: address, port: port).get()
        } catch {
            throw dialProblem(error)
        }

        do {
            try await signal.authenticated(within: handshakeTimeout, on: channel.eventLoop).get()
        } catch {
            channel.close(promise: nil)
            throw signInProblem(error, verifier: verifier)
        }

        guard let key = seen.key else {
            channel.close(promise: nil)
            throw SSHProblem.notAServer
        }
        return SSHSession(channel: channel, handler: ssh, hostKey: key)
    }

    /**
     * One script, one round trip — `sh -s` with the script on its standard
     * input, exactly as the desktop runs it.
     *
     * Not `sh -c '…'`: a script arriving as an argument has to survive the
     * server's own quoting, and these scripts are a hundred lines of `awk`.
     */
    func run(_ script: String, timeout: TimeAmount = SSHSession.commandTimeout) async throws -> SSHRun {
        try await exec(command: "sh -s", stdin: script, timeout: timeout, onChunk: nil)
    }

    /**
     * The same, with the output arriving as it happens.
     *
     * For the install, which takes minutes and whose whole complaint was silence
     * — `host.ts`: *"a person who looked away for a minute needs to come back to
     * what happened, not only to whatever is happening now."* The chunks are
     * handed over on the main actor so a view can simply append them.
     */
    func stream(command: String,
                stdin: String?,
                timeout: TimeAmount,
                onChunk: @escaping (String) -> Void) async throws -> SSHRun {
        try await exec(command: command, stdin: stdin, timeout: timeout) { text in
            // `DispatchQueue.main.async`, not `Task { @MainActor in }`. Tasks
            // are not ordered with respect to one another, so a spawn per chunk
            // is a licence to deliver the installer's output shuffled — which
            // would be an unreadable log, occasionally, on a fast server. A
            // serial queue keeps the order the bytes arrived in.
            DispatchQueue.main.async { onChunk(text) }
        }
    }

    func close() {
        channel.close(promise: nil)
    }

    /* ------------------------------------------------------------- inside -- */

    private func exec(command: String,
                      stdin: String?,
                      timeout: TimeAmount,
                      onChunk: ((String) -> Void)?) async throws -> SSHRun {
        guard channel.isActive else { throw SSHProblem.lost }
        // A child channel in NIOSSH shares its parent's event loop, so one
        // promise made here is fulfilled on the same loop every handler callback
        // below runs on. That is what makes the finish a plain read rather than
        // a lock around two threads.
        let loop = channel.eventLoop
        let ending = loop.makePromise(of: SSHRun.self)
        let collector = ExecCollector(ending: ending, onChunk: onChunk)
        let child: Channel
        do {
            child = try await withCheckedThrowingContinuation { resume in
                let promise = loop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { resume.resume(with: $0) }
                loop.execute {
                    self.handler.createChannel(promise, channelType: .session) { child, _ in
                        child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                            .flatMap { child.pipeline.addHandler(collector) }
                    }
                }
            }
        } catch {
            // A promise that is never completed traps in a debug build when it
            // is deallocated, so the one path that never reaches a handler has
            // to complete it by hand.
            ending.fail(error)
            throw channelProblem(error)
        }

        let deadline = loop.scheduleTask(deadline: .now() + timeout) {
            ending.fail(SSHProblem.timedOut)
            child.close(promise: nil)
        }
        defer { deadline.cancel() }

        do {
            try await child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        } catch {
            let refusal = SSHProblem.commandFailed(
                "It opened a session and refused to run anything in it. An account whose shell is "
                    + "set to `nologin`, or a `ForceCommand` in the server's SSH settings, does "
                    + "exactly this.")
            ending.fail(refusal)
            child.close(promise: nil)
            throw refusal
        }

        if let stdin, !stdin.isEmpty {
            var buffer = child.allocator.buffer(capacity: stdin.utf8.count)
            buffer.writeString(stdin)
            try? await child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
        }
        // EOF on the way in, or `sh -s` waits forever for a script that has
        // already arrived in full.
        child.close(mode: .output, promise: nil)

        return try await ending.futureResult.get()
    }

    /* --------------------------------------------------------- classifying -- */

    /**
     * A session this server would not open.
     *
     * `MaxSessions 0`, an account at its channel limit, or a connection that has
     * gone since the last command — three different sentences would be guessing,
     * and the one thing that is certainly true is that the server refused.
     */
    private func channelProblem(_ error: Error) -> SSHProblem {
        guard channel.isActive else { return .lost }
        if let ssh = error as? NIOSSHError, ssh.type == .channelSetupRejected {
            return .commandFailed(
                "It would not open a session channel. A server that limits how many an account may "
                    + "hold at once refuses exactly this way.")
        }
        return .lost
    }

    private static func dialProblem(_ error: Error) -> SSHProblem {
        // A name that does not resolve fails in the resolver, before any socket
        // is opened, and NIO reports that as its own error rather than as a
        // connect failure. The two are worth telling apart: one is a typo in the
        // address and the other is a port, a firewall or a machine that is off.
        if case SocketAddressError.unknown = error { return .noSuchAddress }
        if error is SocketAddressError { return .noSuchAddress }
        return .noAnswer
    }

    private static func signInProblem(_ error: Error, verifier: HostKeyVerifier) -> SSHProblem {
        if let refused = verifier.refusal { return refused }
        if let problem = error as? SSHProblem { return problem }
        if let ssh = error as? NIOSSHError {
            switch ssh.type {
            case .unsupportedVersion, .invalidPacketFormat, .protocolViolation:
                return .notAServer
            case .keyExchangeNegotiationFailure, .unknownPublicKey, .invalidHostKeyForKeyExchange:
                return .nothingInCommon
            default:
                return .signInRefused
            }
        }
        return .signInRefused
    }
}

/* ---------------------------------------------------------------- the parts -- */

/// Where the host key lands, so `open` can hand it back after the handshake.
private final class HostKeySeen {
    private let lock = NSLock()
    private var stored: SSHHostKey?
    var key: SSHHostKey? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/**
 * The identity check, and the fingerprint every other tool prints.
 *
 * `SHA256:` followed by unpadded base64 of the SHA-256 of the key's own SSH wire
 * encoding — which is what `ssh-keyscan host | ssh-keygen -lf -` prints, and the
 * whole value of showing it is that a person can go and check it somewhere else.
 */
private final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate {
    private let expect: String?
    private let seen: HostKeySeen
    private let lock = NSLock()
    private var stored: SSHProblem?

    init(expect: String?, seen: HostKeySeen) {
        self.expect = expect
        self.seen = seen
    }

    /// Set when *this* is why the connection ended, so the sentence is the right one.
    var refusal: SSHProblem? {
        lock.lock(); defer { lock.unlock() }; return stored
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1)
        let algorithm = String(parts.first ?? "")
        guard parts.count == 2, let raw = Data(base64Encoded: String(parts[1])) else {
            lock.lock(); stored = .notAServer; lock.unlock()
            validationCompletePromise.fail(SSHProblem.notAServer)
            return
        }
        let fingerprint = "SHA256:" + SSHFingerprint.base64Unpadded(of: raw)
        let record = SSHHostKey(algorithm: algorithm, fingerprint: fingerprint)
        seen.key = record

        if let expect, expect != fingerprint {
            let problem = SSHProblem.identityChanged(seen: fingerprint, stored: expect)
            lock.lock(); stored = problem; lock.unlock()
            validationCompletePromise.fail(problem)
            return
        }
        validationCompletePromise.succeed(())
    }
}

/**
 * One offer, once.
 *
 * The person chose password or key on the form; offering the other one after a
 * refusal would mean this app trying credentials the person did not choose to
 * send. A second call means the first was rejected, and `nil` ends it — which
 * arrives here as {@link SSHProblem.signInRefused}.
 */
private final class OneOffer: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let offer: NIOSSHUserAuthenticationOffer.Offer
    private var spent = false

    init(username: String, offer: NIOSSHUserAuthenticationOffer.Offer) {
        self.username = username
        self.offer = offer
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !spent else {
            nextChallengePromise.succeed(nil)
            return
        }
        spent = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
    }
}

/**
 * Waiting for the handshake to finish, without a poll.
 *
 * `UserAuthSuccessEvent` is the one signal that says the connection is usable.
 * The race is against the channel closing, which is what a refused sign-in looks
 * like from this side — the server disconnects rather than saying which half was
 * wrong.
 */
private final class SignalHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var done = false
    private var lastError: Error?

    func authenticated(within timeout: TimeAmount, on loop: EventLoop) -> EventLoopFuture<Void> {
        let promise = loop.makePromise(of: Void.self)
        loop.execute {
            if self.done {
                promise.succeed(())
            } else if let error = self.lastError {
                promise.fail(error)
            } else {
                self.promise = promise
            }
        }
        loop.scheduleTask(deadline: .now() + timeout) {
            promise.fail(SSHProblem.timedOut)
        }
        return promise.futureResult
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            done = true
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lastError = error
        promise?.fail(error)
        promise = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(lastError ?? SSHProblem.signInRefused)
        promise = nil
        context.fireChannelInactive()
    }
}

/**
 * Everything one command said, and the status it ended with.
 *
 * stdout and stderr are kept apart because they mean different things — the
 * probe's answer is on stdout and a server's complaint is on stderr — and the
 * desktop's ceiling is kept, for the reason `connection.ts` gives: `cat` of a
 * log file is one keystroke away from any command this app runs.
 */
private final class ExecCollector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var out = [UInt8]()
    private var err = [UInt8]()
    private var status: Int?
    private var truncated = false
    private let ending: EventLoopPromise<SSHRun>
    private let onChunk: ((String) -> Void)?

    init(ending: EventLoopPromise<SSHRun>, onChunk: ((String) -> Void)?) {
        self.ending = ending
        self.onChunk = onChunk
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let piece = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = piece.data else { return }
        let bytes = Array(buffer.readableBytesView)
        if piece.type == .stdErr {
            if err.count < SSHSession.maxOutputBytes { err.append(contentsOf: bytes) }
        } else if out.count < SSHSession.maxOutputBytes {
            out.append(contentsOf: bytes)
        } else {
            truncated = true
        }
        onChunk?(String(decoding: bytes, as: UTF8.self))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            status = exit.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Completing a promise twice is a no-op in NIO, so the deadline having
        // already given up on this run does not turn into a second answer.
        ending.succeed(SSHRun(code: status ?? -1,
                              stdout: String(decoding: out, as: UTF8.self),
                              stderr: String(decoding: err, as: UTF8.self),
                              truncated: truncated))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ending.fail(error)
        context.close(promise: nil)
    }
}

/* -------------------------------------------------------------------------- */

/// `SHA256:`-style base64: no padding, which is how every SSH tool prints it.
enum SSHFingerprint {
    static func base64Unpadded(of data: Data) -> String {
        var text = Data(SHA256.hash(data: data)).base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }
}
