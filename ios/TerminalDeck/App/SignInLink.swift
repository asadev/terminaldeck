/**
 * Sign-in: the client half of `enroll`, driven across a socket somebody else is
 * holding.
 *
 * A port of `SignIn` in `pwa/src/signin.ts`. The pairing flow trades six typed
 * digits for a credential; this trades a login the machine already trusts. Over
 * a sealed channel the client sends `enroll` with a username and a
 * password-or-key, the host verifies it against its own sshd and answers
 * `enrolled` with a credential, and the client then says a normal `hello` with
 * that credential **on the same socket**. The end state is identical to pairing:
 * a stored credential for a machine, reconnected the same way.
 *
 * ## Why this is transport-agnostic
 *
 * It takes a `send` and is fed decoded frames, exactly as the pairing path hands
 * frames to whatever holds the socket. It does not open the socket, and it does
 * not know how the sealed channel to a first-contact host was established — that
 * is the rendezvous layer's problem, and a real one (a bare server has to be
 * reached at all before it can be signed into; the browser punts to an install
 * command, and iOS has no SSH client linked to install one itself). Keeping the
 * frame sequence here, pure and driven, is what lets it be tested against the
 * real `WireCodec` with no socket.
 */

import Foundation

/// The one-line install for a bare server, from `HEADLESS.md`. Shown for a
/// person to run on the machine when there is no host to sign into yet — the
/// same fallback the browser client shows, because neither a browser nor this
/// phone can install a host over SSH itself.
let installCommand = "curl -fsSL https://terminaldeck.dev/install.sh | sh"

struct SignInInput: Equatable {
    let username: String
    let secret: String
    let method: EnrollMethod
    let device: DeviceDescriptor
}

enum SignInOutcome: Equatable {
    /// `token` is the minted credential, `<id>.<secret>` — stored the way
    /// pairing stores its own. `welcome` fields ride along so the caller can
    /// record the host's facts.
    case ok(token: String, deviceId: String, deviceName: String)
    case failed(message: String)
}

/// The frame a sign-in opens with. Exposed so a caller holding the socket can
/// send it directly, and so a test can check its shape. Carries the same
/// claimed capabilities the follow-up `hello` will, so the desktop need not
/// renegotiate.
func enrollMessage(_ input: SignInInput) -> ClientMessage {
    .enroll(protocolVersion: Wire.protocolVersion,
            device: input.device,
            username: input.username,
            secret: input.secret,
            method: input.method,
            capabilities: WireCapability.claimed)
}

/**
 * Drives one sign-in. `start` sends `enroll`; every inbound frame goes to
 * `receive`; the outcome is delivered once through `onOutcome`. The sequence is
 * fixed — `enroll` → `enrolled` → `hello` → `welcome` — and a refusal is the
 * `error` frame at either step. Anything else before the welcome is ignored: a
 * sign-in in flight is not a session yet, and acting on a stray frame would be
 * acting on an unauthenticated socket.
 */
final class SignIn {
    private enum Stage { case idle, enrolling, sayingHello, done }
    private var stage: Stage = .idle
    private var device: DeviceDescriptor?
    private var token = ""
    private var deviceId = ""
    private var deviceName = ""

    private let send: (ClientMessage) -> Void
    private let onOutcome: (SignInOutcome) -> Void

    init(send: @escaping (ClientMessage) -> Void, onOutcome: @escaping (SignInOutcome) -> Void) {
        self.send = send
        self.onOutcome = onOutcome
    }

    func start(_ input: SignInInput) {
        guard stage == .idle else { return }
        stage = .enrolling
        device = input.device
        send(enrollMessage(input))
    }

    func receive(_ message: ServerMessage) {
        if stage == .done { return }

        // A refusal at any step ends it, in the host's own words. `enroll`'s
        // failure is a plain `error` — `unauthorized` for a bad login (collapsed
        // with a rate-limited one) or `unavailable` when it cannot offer sign-in.
        if case let .error(_, text) = message {
            finish(.failed(message: text))
            return
        }

        if stage == .enrolling, case let .enrolled(id, name, credential) = message {
            token = credential
            deviceId = id
            deviceName = name
            stage = .sayingHello
            // The credential becomes an ordinary hello, on the same socket. The
            // host does not special-case it — the device row is already approved
            // and bound to this connection's key.
            let device = self.device ?? DeviceDescriptor(name: name, platform: "ios")
            send(.hello(protocolVersion: Wire.protocolVersion, token: credential,
                        device: device, capabilities: WireCapability.claimed))
            return
        }

        if stage == .sayingHello, case .welcome = message {
            finish(.ok(token: token, deviceId: deviceId, deviceName: deviceName))
            return
        }
        // Every other frame before the welcome is dropped.
    }

    private func finish(_ outcome: SignInOutcome) {
        stage = .done
        onOutcome(outcome)
    }
}
