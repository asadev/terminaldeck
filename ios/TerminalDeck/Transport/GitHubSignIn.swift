/**
 * Getting a GitHub token onto this phone, the two ways a person can.
 *
 * Both end in the same place — a login and a secret in the Keychain — and
 * neither of them puts anything on anybody else's machine. That is the point of
 * the whole exercise: the token is obtained here, kept here, and spent one
 * request at a time over a channel that is already sealed.
 *
 * ## Sign in
 *
 * The **device flow**, which is the only OAuth shape that works from an app with
 * no server behind it: no redirect URI to register, no client secret to ship, no
 * loopback listener. GitHub hands back a short code, the browser takes it, and
 * this polls until somebody has typed it. `github-auth.ts` on the desktop does
 * exactly this and the two agree on the client id on purpose — one registration
 * for one product.
 *
 * ### It is the product's own GitHub App, the same one the desktop signs into
 *
 * Until this build the id below was the **GitHub CLI's** OAuth client, borrowed
 * because this project had no registration of its own, and the screen carried a
 * line apologising that GitHub would name the sign-in "GitHub CLI". Two things
 * were wrong with that and only one of them was cosmetic: an OAuth app's `repo`
 * scope is a single all-or-nothing grant over **every** private repository the
 * account can reach, write included, with no way to choose. `src/main/github-app.ts`
 * has the whole argument.
 *
 * The desktop registered a GitHub App on 2026-08-16 and moved to it, and this is
 * the phone catching up to the same registration: same client id, same endpoints,
 * and **no `scope` parameter** — an App's permissions come from its registration
 * and the repositories it can touch are chosen by the person at install time, so
 * there is nothing for a scope string to say and sending one asks GitHub to
 * reconcile two permission models in one request.
 *
 * The consequence worth knowing about: a user-to-server token only reaches
 * repositories the App is **installed** on. Signing in is therefore half of it,
 * and `GitHubAccountView` links to the install page for the other half.
 *
 * ## Paste a token
 *
 * The fallback the design keeps on purpose, and it is a good one: a **fine
 * grained personal access token**, scoped to a single repository, with an
 * expiry. Somebody who does not want an OAuth grant on their account gets a
 * blast radius of one repository they already chose to share. It is validated by
 * being used — the login on the account comes from GitHub's answer to
 * `GET /user`, never from something a person typed — because the login is what
 * the approval prompt names, and a prompt that can name the wrong account is
 * worse than no prompt.
 *
 * ## Nothing here logs anything
 *
 * No `print`, no error carrying a response body, and no token in any string that
 * leaves this file. The failures a person can act on are enumerated as sentences
 * written here; everything else becomes one general sentence rather than a
 * transcript that might contain a secret.
 */

import Foundation

/// A minimal HTTP seam, so the whole flow can be exercised without a network.
/// `URLSession` is the only implementation the app uses.
typealias GitHubFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/**
 * The three addresses this app talks to, and the one seam that moves them.
 *
 * ## Why there is a seam at all
 *
 * The approval prompt cannot be exercised end to end without an account, and an
 * account cannot be had without a token GitHub will accept. Which leaves a UI
 * test with three options: hold a real person's GitHub token in the repository,
 * write a back door that puts a token in the Keychain from a launch argument, or
 * point the three requests at a stand-in the way `host-standin.ts` already
 * stands in for a desktop. The first is out of the question, the second is a
 * code path in the shipping app whose whole job is to fake being signed in, and
 * the third is what this is.
 *
 * ## Why it cannot be turned on in a shipped build
 *
 * `#if DEBUG`, so it is not compiled into the Release configuration that
 * `scripts/ios/release.sh` archives — there is no environment variable, no
 * plist key and no setting that reaches it, because the code is not there. In
 * Debug it is read once from the process environment, which only whoever
 * launched the app can set: `xcodebuild` through `launchEnvironment`, or
 * `simctl launch` through `SIMCTL_CHILD_…`. Nothing on the wire and nothing on
 * screen can move it.
 */
enum GitHubEndpoints {
    static var deviceCode: URL { resolve("https://github.com/login/device/code", path: "/login/device/code") }
    static var accessToken: URL {
        resolve("https://github.com/login/oauth/access_token", path: "/login/oauth/access_token")
    }
    static var user: URL { resolve("https://api.github.com/user", path: "/user") }

    #if DEBUG
    /// `ios/Harness/fake-github.mjs`, when a test launched the app pointing at
    /// one. Two hosts fold onto one base — `github.com` and `api.github.com`
    /// differ only in which paths they serve, and the stand-in serves all three.
    static let harnessVariable = "TD_GITHUB_BASE"

    private static var harness: URL? {
        guard let raw = ProcessInfo.processInfo.environment[harnessVariable],
              let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }
    #endif

    private static func resolve(_ real: String, path: String) -> URL {
        #if DEBUG
        if let harness { return harness.appendingPathComponent(path) }
        #endif
        // Force-unwrapped because these three are literals in this file and a
        // fallback for one that cannot be parsed would be a fallback for a typo
        // nobody would ever see.
        return URL(string: real)!
    }
}

/**
 * Terminal Deck's own GitHub App, the registration the desktop signs into.
 *
 * The same constant as `GITHUB_APP.clientId` in `src/main/github-app.ts`, which
 * documents the registration at length and records the live request it was
 * verified with on 2026-08-16. A client id is not a secret — it ships in every
 * copy of both apps and travels in the clear on the first leg of the device
 * flow, which is the whole reason the flow needs no client secret.
 *
 * A wrong id does not fail loudly. GitHub answers `404 {"error":"Not Found"}`,
 * which is indistinguishable from an outage and from an App with **Enable
 * Device Flow** unticked, so this is copied rather than remembered.
 */
private let clientID = "Iv23limkNV4N6mChRl60"

/// The App's URL slug, used for the one link that finishes the job: choosing
/// which repositories it may touch. `GITHUB_APP.slug` on the desktop.
private let appSlug = "terminal-deck"

/// Where a person chooses the repositories this app may reach. Signing in gets
/// a token; this is what gives it anything to reach. `appInstallUrl` on the
/// desktop builds the same address.
let gitHubInstallURL = URL(string: "https://github.com/apps/\(appSlug)/installations/new")!

@MainActor
@Observable
final class GitHubSignIn {

    enum Phase: Equatable {
        case idle
        /// Asking GitHub for a code. Sub-second; it exists so the button has a
        /// state rather than looking dead.
        case starting
        /**
         * A code is on screen and this is polling.
         *
         * `verificationURI` is opened in the browser rather than shown as text
         * to be typed, and the code is shown as text rather than pushed into the
         * URL, deliberately: GitHub's `verification_uri_complete` fills the field
         * in for you, which means a link that grants access if it is forwarded.
         */
        case waiting(userCode: String, verificationURI: URL)
        /// The code was entered; this is reading the account name back.
        case finishing
        /// Something went wrong, in a sentence somebody can act on.
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// True while either route is in flight, so both buttons can be disabled
    /// together — two sign-ins racing to write the same Keychain item is a
    /// state nobody needs to reason about.
    var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        case .starting, .waiting, .finishing: return true
        }
    }

    private let accounts: GitHubAccountStore
    private let fetch: GitHubFetch
    /// The clock, injected so the expiry and the poll spacing can be exercised
    /// without a test that waits fifteen minutes to prove one branch.
    private let clock: () -> Date
    /// Cancels the poll when the user backs out. **Not** when the sheet closes —
    /// see `cancel()`.
    private var poll: Task<Void, Never>?

    /// When the token endpoint was last asked. Read by `cameToTheFront`, which
    /// must not turn a return from Safari into a request GitHub rate-limits.
    private var lastPolled: Date?

    /// The interval GitHub asked for, once it has said. Its own property rather
    /// than a read of the in-flight `DeviceCode` because `cameToTheFront` is
    /// called from outside the flow and has no other way to see it.
    private var pollGap: TimeInterval = 5

    /// Resumed to cut a wait short. Nil unless a poll is sitting between two
    /// requests. See `waitBeforePolling`.
    private var waking: CheckedContinuation<Void, Never>?

    init(accounts: GitHubAccountStore,
         fetch: @escaping GitHubFetch = GitHubSignIn.urlSessionFetch,
         clock: @escaping () -> Date = Date.init) {
        self.accounts = accounts
        self.fetch = fetch
        self.clock = clock
    }

    static let urlSessionFetch: GitHubFetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubSignInError.sentence("GitHub answered with something that was not HTTP.")
        }
        return (data, http)
    }

    // MARK: - Sign in

    func start() {
        guard !isBusy else { return }
        phase = .starting
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let code = try await self.requestDeviceCode()
                guard !Task.isCancelled else { return }
                self.phase = .waiting(userCode: code.userCode, verificationURI: code.verificationURI)
                let token = try await self.awaitToken(code)
                guard !Task.isCancelled else { return }
                self.phase = .finishing
                try await self.adopt(token: token, source: .signIn)
            } catch is CancellationError {
                // The screen went away mid-flow. Not a failure to report to
                // somebody who is no longer looking at it.
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(GitHubSignInError.sentence(for: error))
            }
        }
    }

    /**
     * Stop polling and go back to the start.
     *
     * Called by the **Cancel** button, and by nothing else. It used to be called
     * from the sheet's `onDisappear` as well — a poll that outlives the screen
     * wakes the radio every five seconds, which is a real cost — and that is the
     * single most expensive line this file has had. The sequence he recorded:
     * finish the sign-in on github.com, come back, find the code still on
     * screen because the next poll is up to five seconds away, press **Done** to
     * get rid of it — and Done tore down the sheet, which cancelled the flow one
     * request short of the token. Reopening the screen then showed the sign-in
     * button again, which reads exactly like *"OK it's done, but on the
     * application it's not."*
     *
     * The flow now belongs to `DeckModel` and outlives the sheet. It ends by
     * itself: on the token, on a refusal, or when GitHub's code expires — a
     * bounded fifteen minutes, not forever.
     *
     * The continuation is resumed before the task is cancelled. A task suspended
     * in `withCheckedContinuation` is not woken by cancellation, so cancelling
     * without this leaves it parked for the lifetime of the app.
     */
    func cancel() {
        wake()
        poll?.cancel()
        poll = nil
        lastPolled = nil
        phase = .idle
    }

    /**
     * The app came back to the front — poll now, rather than sitting out the
     * rest of a five-second sleep.
     *
     * This is the moment the sign-in almost always completes: he has just been
     * on github.com typing the code, and the app was suspended the whole time.
     * Waiting out the remainder of the interval is up to five seconds of a
     * screen that still says "enter this code" *after* the code has been
     * entered, which is exactly long enough for somebody to conclude it did not
     * work and press Done.
     *
     * Guarded by the interval GitHub named. Asking again inside it is what
     * `slow_down` is for, and a person switching apps a few times in a row would
     * otherwise walk the flow straight into a rate limit.
     */
    func cameToTheFront() {
        guard case .waiting = phase else { return }
        if let lastPolled, clock().timeIntervalSince(lastPolled) < pollGap { return }
        wake()
    }

    /// Cut the current wait short, if there is one. Idempotent: the continuation
    /// is taken before it is resumed, so a second call finds nothing to do
    /// rather than resuming twice, which traps.
    private func wake() {
        let continuation = waking
        waking = nil
        continuation?.resume()
    }

    /**
     * Wait out the poll interval — or until somebody wakes us.
     *
     * A plain `Task.sleep` cannot be shortened, and shortening it is the whole
     * point: see `cameToTheFront`. So the sleep runs in a side task whose only
     * job is to resume the continuation this one is parked on, and either the
     * clock or the app coming forward gets there first.
     */
    private func waitBeforePolling(_ seconds: TimeInterval) async throws {
        // Whatever was parked here is released before a second one is stored. A
        // `CheckedContinuation` that is overwritten is never resumed, and the
        // task waiting on it is suspended for the lifetime of the process — a
        // leak that leaves no trace to find it by.
        wake()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.wake()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waking = continuation
        }
        timer.cancel()
        try Task.checkCancellation()
    }

    // MARK: - Paste a token

    func useToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        guard !token.isEmpty else {
            phase = .failed("Paste a token first.")
            return
        }
        guard token.count <= Wire.maxCredentialSecretLength else {
            // The desktop refuses a longer secret and answers a refused frame by
            // closing the socket, so this is caught at the one moment a person
            // can do something about it rather than on the first push.
            phase = .failed("That is longer than a GitHub token. Check what was pasted.")
            return
        }
        phase = .finishing
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.adopt(token: token, source: .token)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(GitHubSignInError.sentence(for: error))
            }
        }
    }

    // MARK: - The flow

    private struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let interval: TimeInterval
        let expiresAt: Date
    }

    private func requestDeviceCode() async throws -> DeviceCode {
        // No `scope`. See the header: a GitHub App's permissions live in its
        // registration, and sending a scope with an App client id is a request
        // GitHub answers with the same anonymous 404 a wrong id gets.
        let body = form(["client_id": clientID])
        let json = try await postJSON(GitHubEndpoints.deviceCode, body: body)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String,
              let url = URL(string: uri), url.scheme == "https" else {
            throw GitHubSignInError.sentence("GitHub did not hand back a sign-in code.")
        }
        // Both are advisory and both have sane floors: a zero interval would
        // become a request loop, and a zero expiry would give up before the
        // browser had opened.
        let interval = max((json["interval"] as? NSNumber)?.doubleValue ?? 5, 5)
        let lifetime = max((json["expires_in"] as? NSNumber)?.doubleValue ?? 900, 60)
        // Kept where `cameToTheFront` can read it: that runs outside the flow
        // and has no other way to know how long GitHub asked to be left alone.
        pollGap = interval
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURI: url,
                          interval: interval, expiresAt: clock().addingTimeInterval(lifetime))
    }

    private func awaitToken(_ code: DeviceCode) async throws -> String {
        var wait = code.interval
        while clock() < code.expiresAt {
            try await waitBeforePolling(wait)
            try Task.checkCancellation()

            let body = form([
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            lastPolled = clock()
            let json = try await postJSON(GitHubEndpoints.accessToken, body: body)
            if let token = json["access_token"] as? String, !token.isEmpty { return token }

            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // GitHub's own instruction, and ignoring it gets the flow
                // rate-limited rather than merely slowed. Copied onto `pollGap`
                // as well, or `cameToTheFront` would keep cutting the longer
                // wait short with the old number and walk straight back into it.
                wait += 5
                pollGap = wait
            case "expired_token":
                throw GitHubSignInError.sentence("That code expired. Start again.")
            case "access_denied":
                throw GitHubSignInError.sentence("That sign-in was cancelled on GitHub.")
            default:
                throw GitHubSignInError.sentence("GitHub refused the sign-in.")
            }
        }
        throw GitHubSignInError.sentence("That code expired. Start again.")
    }

    /**
     * Read the account name off GitHub and write both halves away.
     *
     * The login comes from GitHub rather than from anything a person typed,
     * because it is what the approval prompt names — and the prompt is the
     * entire explanation of this feature. A name this app guessed at would make
     * it a decoration.
     */
    private func adopt(token: String, source: GitHubAccount.Source) async throws {
        var request = URLRequest(url: GitHubEndpoints.user)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await fetch(request)
        guard response.statusCode != 401 else {
            throw GitHubSignInError.sentence("GitHub did not accept that token.")
        }
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.isEmpty else {
            throw GitHubSignInError.sentence("GitHub would not say which account that is.")
        }
        accounts.connect(login: login, token: token, source: source)
        phase = .idle
    }

    // MARK: - HTTP

    private func postJSON(_ url: URL, body: Data) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Without this GitHub answers the device endpoints in
        // `application/x-www-form-urlencoded`, which parses to nothing here and
        // looks exactly like a refusal.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await fetch(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubSignInError.sentence(response.statusCode == 404
                ? "GitHub did not recognise this app's sign-in."
                : "GitHub answered with something this app could not read.")
        }
        return json
    }

    private func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let body = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(body)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}

/**
 * A failure, as a sentence and never as a transcript.
 *
 * Everything a person reads about this flow is written in this file. An error
 * from `URLSession` is turned into one general line rather than surfaced,
 * because the strings in this module's requests include a bearer token and a
 * description that helpfully quoted a request would be the one place a secret
 * escaped.
 */
enum GitHubSignInError: Error {
    case sentence(String)

    static func sentence(for error: Error) -> String {
        if case let GitHubSignInError.sentence(text) = error { return text }
        return "That did not reach GitHub. Check the connection and try again."
    }
}
