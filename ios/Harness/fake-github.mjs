/**
 * A stand-in for GitHub, so the credential proxy can be driven end to end.
 *
 * ## Why this exists
 *
 * The approval prompt is the whole explanation of the credential proxy, and it
 * only appears once this phone holds an account. An account needs a token GitHub
 * will accept, which leaves a UI test with three options: keep somebody's real
 * token in the repository, put a back door in the app that writes one into the
 * Keychain, or stand in for GitHub the way `host-standin.ts` already stands in
 * for a desktop. This is the third.
 *
 * It answers exactly the three requests `GitHubSignIn` makes and nothing else,
 * because it is not a GitHub emulator — it is the smallest thing that lets the
 * *phone's* half be exercised:
 *
 *     POST /login/device/code            a user code and a device code
 *     POST /login/oauth/access_token     a token, first time of asking
 *     GET  /user                         the login the prompt will name
 *
 * ## What it is careful about
 *
 * The login it returns is **not** the one anybody typed. That is the property
 * the sign-in code is built around — the name on the approval prompt comes from
 * GitHub's answer, never from a person's guess — and a stand-in that echoed the
 * request back would test the opposite of the thing that matters.
 *
 * A token it has not issued is refused with 401, so the "GitHub did not accept
 * that token" path is reachable from a test rather than only from a mistake.
 *
 *     node ios/Harness/fake-github.mjs [--port 8799] [--login someone]
 *
 * Then launch the app pointing at it. Nothing but a Debug build will look:
 *
 *     TEST_RUNNER_TD_GITHUB_BASE=http://127.0.0.1:8799 xcodebuild test …
 *
 * Plain HTTP on the loopback, which is the one address the app's ATS exception
 * already covers — see `Support/Info.plist`, and note that inside the Simulator
 * `127.0.0.1` is this Mac.
 */

import { createServer } from 'node:http'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
    const at = args.indexOf(`--${name}`)
    return at === -1 ? fallback : (args[at + 1] ?? fallback)
}

const PORT = Number(flag('port', '8799'))
/** The account name the prompt will show. Not derived from anything sent. */
const LOGIN = flag('login', 'harness-user')
/** The one token this stand-in issues through the device flow. */
const ISSUED = 'gho_harness_issued_token'
/**
 * Tokens this stand-in will also accept on `/user`, so the paste path works.
 *
 * A prefix rather than a list: a UI test types something it made up, and the
 * point of the paste path is that the *token* is opaque to this app. Anything
 * that does not look like one is refused, which is what makes the refusal path
 * reachable.
 */
const ACCEPTED_PREFIXES = ['gho_', 'ghp_', 'github_pat_']

const log = (line) => process.stdout.write(`[github] ${new Date().toISOString().slice(11, 19)} ${line}\n`)

const server = createServer((request, response) => {
    const path = (request.url ?? '/').split('?')[0]
    const json = (status, body) => {
        response.writeHead(status, { 'content-type': 'application/json' })
        response.end(JSON.stringify(body))
    }

    if (path === '/login/device/code') {
        log('device code requested')
        return json(200, {
            device_code: 'harness-device-code',
            user_code: 'HARN-3210',
            verification_uri: 'https://github.com/login/device',
            expires_in: 900,
            // The floor `GitHubSignIn` applies is five seconds, so asking for
            // less changes nothing — it is written honestly rather than as a
            // number this stand-in wishes were smaller.
            interval: 5,
        })
    }

    if (path === '/login/oauth/access_token') {
        log('token issued')
        return json(200, { access_token: ISSUED, token_type: 'bearer', scope: 'repo' })
    }

    if (path === '/user') {
        const auth = request.headers.authorization ?? ''
        const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
        const known = token === ISSUED || ACCEPTED_PREFIXES.some((prefix) => token.startsWith(prefix))
        if (!known) {
            // Never logs the token. The rule is the product's and there is no
            // reason for a harness to be the place it is broken.
            log(`refused a token of ${token.length} bytes`)
            return json(401, { message: 'Bad credentials' })
        }
        log(`identified as ${LOGIN}`)
        return json(200, { login: LOGIN, id: 1 })
    }

    response.writeHead(404)
    response.end()
})

server.listen(PORT, '127.0.0.1', () => log(`standing in for GitHub on 127.0.0.1:${PORT} as ${LOGIN}`))
