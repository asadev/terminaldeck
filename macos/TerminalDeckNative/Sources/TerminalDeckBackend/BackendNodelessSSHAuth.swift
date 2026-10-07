import Foundation
import CryptoKit

/// N18 — the native supplier for `BackendRemoteServeSSHTransport`, replacing
/// ssh2 in `src/main/remote/ssh-verify.ts`. A minimal SSH-2 client that dials
/// 127.0.0.1 only, completes key exchange (curve25519-sha256 / ecdh-sha2-nistp256,
/// AES-GCM), authenticates with the one supplied password (keyboard-interactive
/// answered with the same string) or in-memory private key, then disconnects.
/// It opens no channel: no shell, exec, PTY, forwarding or agent; no keepalive;
/// the loopback host key is accepted without comparison (its exchange-hash
/// signature is still checked). Secrets are never logged or written.
public struct BackendNodelessSSHAuthTransport: BackendRemoteServeSSHTransport {
    public static let clientVersion = "SSH-2.0-TerminalDeck_LoginCheck"
    public init() {}

    public func authenticateLoopback(port: Int, username: String, secret: String, method: String,
                                     keyboardInteractive: Bool, timeoutMilliseconds: Int) async throws {
        let socket = BackendNodelessSSHSocket(deadline: Date().addingTimeInterval(Double(max(1, timeoutMilliseconds)) / 1000))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { socket.close() }
                    do {
                        var session = BackendNodelessSSHSession(socket: socket)
                        try session.run(port: port, username: username, secret: secret, method: method, keyboardInteractive: keyboardInteractive)
                        continuation.resume()
                    } catch {
                        // Only the verifier's classification shapes leave here: a
                        // crypto library error must not read as an unreadable key.
                        if socket.isCancelled || error is CancellationError { continuation.resume(throwing: CancellationError()) }
                        else if let signal = error as? BackendRemoteServeSSHSignal { continuation.resume(throwing: signal) }
                        else { continuation.resume(throwing: BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH handshake failed.")) }
                    }
                }
            }
        } onCancel: {
            socket.cancel()
        }
    }
}

/// One synchronous login check on a dedicated dispatch thread.
struct BackendNodelessSSHSession {
    static let kex = ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256"]
    static let ciphers = ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"]
    static let macs = ["hmac-sha2-256", "hmac-sha2-512"]
    static let refused = BackendRemoteServeSSHSignal(level: "client-authentication", message: "All configured authentication methods failed")

    let socket: BackendNodelessSSHSocket
    private var packets = BackendNodelessSSHPackets()
    private var sessionID: [UInt8] = []
    private var authenticating = false
    init(socket: BackendNodelessSSHSocket) { self.socket = socket }

    private static func unexpected(_ what: String) -> BackendRemoteServeSSHSignal {
        .init(level: "protocol", message: "The SSH server answered \(what) unexpectedly.")
    }

    mutating func run(port: Int, username: String, secret: String, method: String, keyboardInteractive: Bool) throws {
        // ssh2 rejects an unreadable key before any socket exists: same order.
        let key: BackendNodelessSSHPrivateKey? = method == "key" ? try BackendNodelessSSHPrivateKey.parse(secret) : nil
        guard method == "key" || method == "password" else {
            throw BackendRemoteServeSSHSignal(level: "protocol", message: "Unsupported sign-in method.")
        }
        try socket.connectLoopback(port: port)
        try socket.write(Array((BackendNodelessSSHAuthTransport.clientVersion + "\r\n").utf8))
        var serverVersion = ""
        for _ in 0..<64 {
            let line = try socket.readLine()
            if line.hasPrefix("SSH-") { serverVersion = line; break }
        }
        guard serverVersion.hasPrefix("SSH-2.0-") || serverVersion.hasPrefix("SSH-1.99-") else {
            throw BackendRemoteServeSSHSignal(level: "protocol", message: "Protocol mismatch: nothing answered as an SSH-2 server.")
        }
        try exchangeKeys(serverVersion: serverVersion)
        var service = BackendNodelessSSHWriter(); service.byte(5); service.string("ssh-userauth")
        try send(service.bytes)
        guard try next().first == 6 else { throw Self.unexpected("the sign-in service request") }
        authenticating = true
        if method == "password" { try password(username: username, secret: secret, keyboardInteractive: keyboardInteractive) }
        else if let key { try publicKey(username: username, key: key) }
        authenticating = false
        // Authenticated: nothing is opened or run. Leave politely, then close.
        var bye = BackendNodelessSSHWriter(); bye.byte(1); bye.uint32(11); bye.string(""); bye.string("")
        try? send(bye.bytes)
    }

    private mutating func send(_ payload: [UInt8]) throws { try socket.write(try packets.seal(payload)) }

    /// Next meaningful message; transport chatter is skipped, DISCONNECT ends it.
    private mutating func next() throws -> [UInt8] {
        while true {
            let payload = try packets.receive(from: socket)
            guard let type = payload.first else { throw Self.unexpected("with an empty message") }
            switch type {
            case 2, 3, 4, 7, 53: continue // ignore, unimplemented, debug, ext-info, banner
            case 1:
                var reader = BackendNodelessSSHReader(payload); _ = try reader.byte()
                let reason = (try? reader.uint32()) ?? 0
                if authenticating && reason == 14 { throw Self.refused }
                throw BackendRemoteServeSSHSignal(level: "protocol", code: "DISCONNECT_\(reason)", message: "The SSH server closed the connection (reason \(reason)).")
            default: return payload
            }
        }
    }

    private static func choose(_ ours: [String], _ theirs: [String], _ what: String) throws -> String {
        guard let pick = ours.first(where: { theirs.contains($0) }) else {
            throw BackendRemoteServeSSHSignal(level: "protocol", message: "No matching \(what) algorithm with the SSH server.")
        }
        return pick
    }

    private mutating func exchangeKeys(serverVersion: String) throws {
        var hello = BackendNodelessSSHWriter()
        hello.byte(20); hello.raw((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        hello.nameList(Self.kex); hello.nameList(BackendNodelessSSHHostKey.algorithms)
        hello.nameList(Self.ciphers); hello.nameList(Self.ciphers)
        hello.nameList(Self.macs); hello.nameList(Self.macs)
        hello.nameList(["none"]); hello.nameList(["none"])
        hello.nameList([]); hello.nameList([])
        hello.bool(false); hello.uint32(0)
        let clientInit = hello.bytes
        try send(clientInit)
        let serverInit = try next()
        guard serverInit.first == 20 else { throw Self.unexpected("the key exchange") }
        var offer = BackendNodelessSSHReader(serverInit)
        _ = try offer.byte(); _ = try offer.raw(16)
        let theirKex = try offer.nameList(), theirHostKeys = try offer.nameList()
        let theirCipherOut = try offer.nameList(), theirCipherIn = try offer.nameList()
        _ = try offer.nameList(); _ = try offer.nameList()
        let theirCompressionOut = try offer.nameList(), theirCompressionIn = try offer.nameList()
        _ = try offer.nameList(); _ = try offer.nameList()
        let guessFollows = try offer.bool()
        let kex = try Self.choose(Self.kex, theirKex, "key exchange")
        let hostKey = try Self.choose(BackendNodelessSSHHostKey.algorithms, theirHostKeys, "host key")
        let cipherOut = try Self.choose(Self.ciphers, theirCipherOut, "cipher")
        let cipherIn = try Self.choose(Self.ciphers, theirCipherIn, "cipher")
        _ = try Self.choose(["none"], theirCompressionOut, "compression"); _ = try Self.choose(["none"], theirCompressionIn, "compression")
        if guessFollows, theirKex.first != kex || theirHostKeys.first != hostKey { _ = try packets.receive(from: socket) }

        let curve = kex.hasPrefix("curve25519")
        let x25519 = Curve25519.KeyAgreement.PrivateKey(), p256 = P256.KeyAgreement.PrivateKey()
        let ours = curve ? Array(x25519.publicKey.rawRepresentation) : Array(p256.publicKey.x963Representation)
        var start = BackendNodelessSSHWriter(); start.byte(30); start.string(ours)
        try send(start.bytes)
        let reply = try next()
        guard reply.first == 31 else { throw Self.unexpected("the key exchange reply") }
        var fields = BackendNodelessSSHReader(reply)
        _ = try fields.byte()
        let hostBlob = try fields.string(), theirs = try fields.string(), signature = try fields.string()
        let shared: [UInt8]
        do {
            if curve {
                let secret = try x25519.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs))
                shared = secret.withUnsafeBytes { Array($0) }
            } else {
                let secret = try p256.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: theirs))
                shared = secret.withUnsafeBytes { Array($0) }
            }
        } catch { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH server sent an invalid exchange value.") }
        guard shared.contains(where: { $0 != 0 }) else { throw BackendRemoteServeSSHSignal(level: "protocol", message: "The SSH key exchange produced no secret.") }
        var secretInteger = BackendNodelessSSHWriter(); secretInteger.mpint(shared)
        var exchange = BackendNodelessSSHWriter()
        exchange.string(BackendNodelessSSHAuthTransport.clientVersion); exchange.string(serverVersion)
        exchange.string(clientInit); exchange.string(serverInit); exchange.string(hostBlob)
        exchange.string(ours); exchange.string(theirs); exchange.raw(secretInteger.bytes)
        let hash = Array(SHA256.hash(data: Data(exchange.bytes)))
        try BackendNodelessSSHHostKey.verify(blob: hostBlob, signature: signature, hash: hash, algorithm: hostKey)
        sessionID = hash

        func derive(_ letter: UInt8, _ count: Int) -> [UInt8] {
            var out = Array(SHA256.hash(data: Data(secretInteger.bytes + hash + [letter] + hash)))
            while out.count < count { out += Array(SHA256.hash(data: Data(secretInteger.bytes + hash + out))) }
            return Array(out.prefix(count))
        }
        func keyBytes(_ cipher: String) -> Int { cipher.hasPrefix("aes256") ? 32 : 16 }
        try send([21])
        packets.outgoing = .init(key: derive(0x43, keyBytes(cipherOut)), iv: derive(0x41, 12))
        guard try next() == [21] else { throw Self.unexpected("the new keys") }
        packets.incoming = .init(key: derive(0x44, keyBytes(cipherIn)), iv: derive(0x42, 12))
    }

    private mutating func password(username: String, secret: String, keyboardInteractive: Bool) throws {
        var request = BackendNodelessSSHWriter()
        request.byte(50); request.string(username); request.string("ssh-connection"); request.string("password")
        request.bool(false); request.string(secret)
        try send(request.bytes)
        let answer = try next()
        var methods: [String] = []
        switch answer.first {
        case 52: return
        case 51:
            var reader = BackendNodelessSSHReader(answer); _ = try reader.byte(); methods = try reader.nameList()
        case 60: break // a password-change demand is not a usable login
        default: throw Self.unexpected("the password sign-in")
        }
        // Some sshd setups take the password only through keyboard-interactive;
        // the same string answers every prompt (servers/connection.ts mirror).
        guard keyboardInteractive, methods.contains("keyboard-interactive") else { throw Self.refused }
        var interactive = BackendNodelessSSHWriter()
        interactive.byte(50); interactive.string(username); interactive.string("ssh-connection")
        interactive.string("keyboard-interactive"); interactive.string(""); interactive.string("")
        try send(interactive.bytes)
        for _ in 0..<16 {
            let reply = try next()
            switch reply.first {
            case 52: return
            case 51: throw Self.refused
            case 60:
                var reader = BackendNodelessSSHReader(reply); _ = try reader.byte()
                _ = try reader.string(); _ = try reader.string(); _ = try reader.string()
                let count = Int(try reader.uint32())
                guard count <= 32 else { throw Self.unexpected("with too many prompts") }
                for _ in 0..<count { _ = try reader.string(); _ = try reader.bool() }
                var response = BackendNodelessSSHWriter(); response.byte(61); response.uint32(UInt32(count))
                for _ in 0..<count { response.string(secret) }
                try send(response.bytes)
            default: throw Self.unexpected("the keyboard-interactive sign-in")
            }
        }
        throw Self.refused
    }

    private mutating func publicKey(username: String, key: BackendNodelessSSHPrivateKey) throws {
        let blob = key.publicBlob
        for algorithm in key.algorithms {
            var signed = BackendNodelessSSHWriter()
            signed.string(sessionID); signed.byte(50); signed.string(username); signed.string("ssh-connection")
            signed.string("publickey"); signed.bool(true); signed.string(algorithm); signed.string(blob)
            let signature = try key.sign(signed.bytes, algorithm: algorithm)
            var request = BackendNodelessSSHWriter()
            request.byte(50); request.string(username); request.string("ssh-connection"); request.string("publickey")
            request.bool(true); request.string(algorithm); request.string(blob); request.string(signature)
            try send(request.bytes)
            let answer = try next()
            if answer.first == 52 { return }
            guard answer.first == 51 else { throw Self.unexpected("the key sign-in") }
            var reader = BackendNodelessSSHReader(answer); _ = try reader.byte()
            guard try reader.nameList().contains("publickey") else { break }
        }
        throw Self.refused
    }
}
