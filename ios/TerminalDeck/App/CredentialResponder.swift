/**
 * The half of the credential proxy that lives on the phone: what happens when a
 * machine asks this device for a GitHub login.
 *
 * The desktop half is built and shipping — `src/main/remote/credentials.ts` —
 * and until this existed nothing answered it. Git on a machine somebody has been
 * granted a folder on runs with no credentials of its own, asks over the sealed
 * channel, and waits. This is what waits at the other end.
 *
 * ## The policy, which is four lines and is the whole feature
 *
 *  - **Reads are silent.** fetch, pull, clone. Asking buys nothing: they are
 *    reversible, they happen constantly, and a person tapping Approve forty
 *    times a day stops reading what they are approving.
 *  - **Writes are asked about, once per repository.** A push is the irreversible
 *    one and the one where somebody should get to see whose name goes on the
 *    commit.
 *  - **Whether to ask is the desktop's answer, not this one's.** It arrives as
 *    `prompt` on the frame. The desktop is the side that knows which
 *    repositories this device has already approved *on that machine*, so it is
 *    the side that decides — and a phone that second-guessed it would be a
 *    second source of truth with no way to reconcile the two.
 *  - **No account is not a refusal.** It is a different thing to be told and has
 *    a different fix, so it gets its own code and the desktop writes a sentence
 *    that points at this phone rather than at the person who pushed.
 *
 * ## Every request is acknowledged first, including the ones about to be refused
 *
 * The desktop gives a device four seconds to say it is there and only then
 * starts the sixty seconds a person gets to decide. That split is the difference
 * between "your device isn't reachable — open the app to approve this push",
 * arriving in seconds, and a thirty-second stall on a `git push` with nothing on
 * screen, which is how people stop trusting a feature. So the acknowledgement
 * goes out before anything else is worked out, on every path.
 *
 * ## What this object never does
 *
 * It never logs a token, never puts one in an error, and never holds one between
 * requests: the bytes are read out of the Keychain at the moment a reply is
 * built and go into that reply and nowhere else. It also keeps no record of what
 * has been approved — that memory belongs to the desktop, in its own process,
 * for as long as its app is running. See `GitHubAccount` for why.
 */

import Foundation
import Observation

/**
 * One question, as a phone needs to render it.
 *
 * `origin` rather than `host` for what the wire calls `host`, because on this
 * side of the connection "host" already means *the machine this phone is paired
 * with* — and the two are on the same screen at the same time. This one is
 * `github.com`; the machine is `machineName`.
 */
struct CredentialRequest: Equatable, Identifiable {
    /// The desktop's id for this question. Every reply carries it back.
    let id: String
    /// Which paired machine asked. Replies are routed by it, and getting it
    /// wrong would answer one machine's question on another's socket.
    let machineId: String
    /// What the user calls that machine. The third line of the prompt, and the
    /// one the design brief says the whole feature rests on: *which machine
    /// asked*.
    let machineName: String
    /// The git host — `github.com`, or an enterprise one.
    let origin: String
    /// `owner/name`, or nil when the desktop could not derive one. Nil is shown
    /// as nil; see `CredentialPromptView`.
    let repo: String?
    let operation: CredentialOperation
    /// Whether a person is being asked. The desktop's answer, carried through.
    let prompt: Bool
}

/**
 * The three ways this phone answers, as one narrow type.
 *
 * A type rather than a general "send this message" door on `HostLink`, because
 * the rule everywhere else in this app is that a view never builds a wire
 * message — and the prompt is a view. Three cases, all of which carry an id the
 * desktop minted, is the entire vocabulary this feature needs pointing that way.
 */
enum CredentialAnswer: Equatable {
    case ack(id: String)
    case login(id: String, username: String, password: String, remember: Bool)
    case refuse(id: String, reason: CredentialDenial)

    var message: ClientMessage {
        switch self {
        case let .ack(id):
            return .credentialAck(id: id)
        case let .login(id, username, password, remember):
            return .credentialAnswer(id: id, username: username, password: password, remember: remember)
        case let .refuse(id, reason):
            return .credentialDeny(id: id, reason: reason)
        }
    }
}

@MainActor
@Observable
final class CredentialResponder {

    /**
     * How long a question stays on screen.
     *
     * The desktop's own `DECIDE_TIMEOUT_MS`. Kept in step deliberately: past it
     * the desktop has already told the person at the keyboard that nobody
     * answered, so the buttons here answer nothing. A prompt that outlives the
     * request it belongs to is a dead control, and the design brief's first rule
     * is that anything that looks pressable does something.
     *
     * It is measured from arrival on this side, which is a fraction *earlier*
     * than the desktop's — it arms its clock when the acknowledgement gets back
     * — and that is the right direction to be wrong in.
     */
    static let decideTimeout: TimeInterval = 60

    /**
     * How many unanswered questions this phone will hold.
     *
     * Unreachable through a desktop that behaves: it refuses more than four in
     * flight per device and sixteen in total, so a person would need several
     * machines all pushing at once to come near this. It exists so that a
     * machine which has stopped behaving cannot make this phone accumulate state
     * without limit, and the refusal is immediate rather than silent.
     */
    static let maxPending = 16

    /// The question on screen, or nil. The prompt is presented off this.
    private(set) var asking: CredentialRequest?

    /// Questions behind it, oldest first. A person pushing two repositories at
    /// once is a real thing; two prompts stacked on top of each other is not.
    private(set) var waiting: [CredentialRequest] = []

    private let accounts: GitHubAccountStore

    /**
     * How a reply reaches the machine that asked, by host id.
     *
     * Set by `DeckModel` immediately after construction, in the same shape
     * `HostLink`'s callbacks use — the two objects are mutually recursive, since
     * the model routes questions in and answers back out, and a closure handed
     * over afterwards is how that knot is tied without either holding the other
     * in its initialiser.
     *
     * Routing by **id** rather than by holding a link is deliberate: a machine
     * can be unpaired while its question is on screen, and answering through an
     * object that has been torn down would be answering nobody, quietly.
     */
    var route: ((String, CredentialAnswer) -> Void)?

    /// Bumped whenever what is on screen changes, so an expiry armed for one
    /// question can never take a later one off the screen.
    private var generation = 0

    init(accounts: GitHubAccountStore) {
        self.accounts = accounts
    }

    private func deliver(_ machineId: String, _ answer: CredentialAnswer) {
        route?(machineId, answer)
    }

    /// The account the prompt names. The non-secret half — nothing on screen
    /// ever holds the token.
    var account: GitHubAccount? { accounts.account }

    // MARK: - Inbound

    func receive(_ request: CredentialRequest) {
        // Before anything is decided, and before the Keychain is touched. See
        // the header: this is the frame the whole feature's failure mode rests
        // on, and every path owes it.
        deliver(request.machineId, .ack(id: request.id))

        guard accounts.account != nil else {
            deliver(request.machineId, .refuse(id: request.id, reason: .noAccount))
            return
        }

        guard request.prompt else {
            // A read, or a write against a repository already approved on that
            // machine. Nobody is interrupted, and the token is read here and
            // used once.
            answerNow(request, remember: false)
            return
        }

        guard asking != nil || !waiting.isEmpty else {
            present(request)
            return
        }
        guard waiting.count + 1 < Self.maxPending else {
            deliver(request.machineId, .refuse(id: request.id, reason: .denied))
            return
        }
        waiting.append(request)
    }

    /// A machine's socket went down. Anything it asked is unanswerable now — the
    /// reply has nowhere to go — so the question comes off the screen rather
    /// than staying up as two buttons that do nothing.
    func machineLost(_ machineId: String) {
        waiting.removeAll { $0.machineId == machineId }
        guard asking?.machineId == machineId else { return }
        asking = nil
        advance()
    }

    /// Every machine, on the way out of the app or the way into a fresh model.
    func reset() {
        generation &+= 1
        asking = nil
        waiting = []
    }

    // MARK: - The two buttons and the third

    /**
     * Yes.
     *
     * `remember` is the "Always for this repo" button, and it is a *scope*
     * rather than a stored secret: it tells that machine it may stop asking
     * about that repository from this device. Every push still comes back here
     * for the credential itself.
     *
     * It is dropped when the desktop could not name the repository. The desktop
     * refuses to record an approval it cannot key, so sending it would be this
     * phone claiming a consent that nothing acts on — and the prompt hides the
     * button in that case for the same reason.
     */
    func approve(remember: Bool) {
        guard let request = asking else { return }
        asking = nil
        answerNow(request, remember: remember && request.repo != nil)
        advance()
    }

    func deny() {
        guard let request = asking else { return }
        asking = nil
        deliver(request.machineId, .refuse(id: request.id, reason: .denied))
        advance()
    }

    // MARK: - Plumbing

    /**
     * Read the token and spend it on one request.
     *
     * The Keychain is read *here* rather than when the question arrived, which
     * matters for a prompted one: a person may take a minute to decide, and for
     * that minute the bytes are not in this process. It also means an account
     * disconnected while the prompt was up is answered honestly — the button
     * did not fail, there is simply no account any more.
     */
    private func answerNow(_ request: CredentialRequest, remember: Bool) {
        guard let account = accounts.account, let token = accounts.token() else {
            deliver(request.machineId, .refuse(id: request.id, reason: .noAccount))
            return
        }
        guard account.login.count <= Wire.maxCredentialUsernameLength,
              token.count <= Wire.maxCredentialSecretLength else {
            // Longer than the desktop's parser accepts, and a refused frame
            // closes the socket — so this costs one push rather than the
            // connection. Unreachable with anything GitHub issues today; kept
            // because "unreachable" is a claim about this week's token formats.
            deliver(request.machineId, .refuse(id: request.id, reason: .noAccount))
            return
        }
        deliver(request.machineId,
                .login(id: request.id, username: account.login, password: token, remember: remember))
    }

    private func present(_ request: CredentialRequest) {
        asking = request
        generation &+= 1
        let epoch = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.decideTimeout))
            guard let self, self.generation == epoch, self.asking?.id == request.id else { return }
            /*
             * Taken off the screen with no reply sent.
             *
             * The desktop settled this question a moment ago and has already
             * printed "nobody answered on your device" in the terminal that was
             * waiting; an answer arriving now is dropped over there. So the
             * honest local act is to stop showing a question that has no
             * answer, rather than to send a refusal for something nobody
             * refused.
             */
            self.asking = nil
            self.advance()
        }
    }

    private func advance() {
        guard !waiting.isEmpty else { return }
        present(waiting.removeFirst())
    }
}
