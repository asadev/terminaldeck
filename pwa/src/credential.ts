/**
 * What this browser client does when a machine asks it for a GitHub login — and
 * the one thing it deliberately does not do.
 *
 * # This client does not hold a GitHub token, and it must not
 *
 * The iOS and Android clients answer a `credential.request` with a token out of
 * the Keychain or the Android Keystore. This one refuses, every time, and the
 * refusal is the honest implementation rather than an unfinished one.
 *
 * The whole premise of the credential proxy is in one line of
 * `CREDENTIAL-PROXY.md`: *"You never hold their GitHub."* The token belongs to
 * the person joining a folder; the machine they are working on must never be
 * able to get it.
 *
 * **This page is served by that machine.** `src/main/index.ts` hands the remote
 * server `webRoot: <app>/pwa/dist` and it serves these files over the tailnet;
 * the QR code somebody scans is `https://<machine>.<tailnet>.ts.net/#t=…`. So
 * the HTML and the JavaScript running in this tab come from the same computer
 * that would be asking for the token, on that computer's own origin.
 *
 * Nothing a browser offers survives that:
 *
 * - `localStorage` and IndexedDB are plaintext to any script on the origin, and
 *   the origin serves the script.
 * - A non-extractable `CryptoKey` in IndexedDB protects the *key material* from
 *   being read, and not the plaintext: any script on the origin can call
 *   `crypto.subtle.decrypt` with the handle. It has to be able to — this client
 *   answers reads silently, with nobody looking at the screen, so the page must
 *   be able to decrypt unattended.
 * - There is no OS keychain a web page can reach. That is the whole difference
 *   between this client and the other two.
 *
 * A token here would therefore be a token the machine owner can take at will,
 * silently, by changing one line of the page they are serving — with no prompt,
 * no approval and nothing on screen. That is not a weaker version of the
 * feature. It is the exact thing the feature exists to prevent, wearing the
 * feature's clothes, and shipping it would make the promise on the other two
 * clients unbelievable.
 *
 * So: no token store here, no Approve button, and no settings row that hints one
 * is coming. What is shipped instead is the half that is honest and is not
 * optional.
 *
 * # What is shipped, and why every piece of it earns its place
 *
 * **`credential` is advertised in `hello.capabilities`.** It sounds wrong for a
 * client that always refuses, and it is the difference between two sentences in
 * somebody's terminal. Without it `post.reachable(deviceId)` is false on the
 * desktop and a push fails immediately with *"Your device isn't reachable — open
 * the app to approve this push"*, about a browser tab that is open, connected,
 * and showing a live terminal. That sentence is a lie, and it is the one failure
 * mode `CREDENTIAL-PROXY.md` singles out as the way people stop trusting a
 * feature.
 *
 * **Every request is acknowledged, immediately, before anything else.** Same
 * reason it is on the other two clients: the acknowledgement is what tells the
 * desktop the difference between a device that is asleep and a device that is
 * thinking. This one is never thinking, so the answer follows in the same
 * breath — but the ack still goes first, because "acknowledge on every path" is
 * a rule that is either true or is one more thing that has to be right.
 *
 * **The refusal is `no-account`, not `denied`.** `denied` makes the desktop
 * print "That push was refused on your device", which says a person decided
 * something. Nobody decided anything. `no-account` is the truthful code: there
 * is no GitHub account connected on this device. Its desktop sentence — "No
 * GitHub account is connected in the app on your device. Connect one there, then
 * try again" — is imperfect here, because *there* is a browser and the answer is
 * not to connect one in it. Both halves of that gap are worth stating plainly:
 * the code is the closest true one of the two available, and the sentence that
 * actually explains the situation is written **on this page**, by
 * `credentialNotice` below, where it can say the thing the desktop has no way to
 * know.
 *
 * **The question is shown.** A refusal nobody sees is indistinguishable from a
 * broken feature. The notice names the repository, the machine and the account
 * situation — the same three facts the approval prompt names on the phones — and
 * then says what to do instead: use the app on a phone or another computer, or
 * take the route `CREDENTIAL-PROXY.md` keeps on purpose for people who will not
 * install anything, a fine-grained personal access token scoped to the single
 * repository, with an expiry.
 */

import type { ClientMessage, CredentialOperation, ServerMessage } from './protocol-client'

/** The frame this module answers, narrowed out of `ServerMessage`. */
export type CredentialRequest = Extract<ServerMessage, { t: 'credential.request' }>

/**
 * One question, as this page needs to draw it.
 *
 * `origin` rather than `host` for what the wire calls `host`, because on this
 * side "host" already means *the machine this browser is paired with*, and the
 * two would be on the same screen.
 */
export interface CredentialNotice {
  id: string
  /** The git host — `github.com`, or an enterprise one. */
  origin: string
  /** `owner/name`, or null when the desktop could not name it. Shown as null. */
  repo: string | null
  operation: CredentialOperation
  /** Whether the desktop wanted a person interrupted. True for a first push. */
  prompt: boolean
  /** Epoch ms, so a stale notice can be aged out rather than sitting there. */
  at: number
}

/**
 * How this client answers, in order.
 *
 * Two frames, always, and always these two. Returned as an array rather than
 * sent from in here so that the policy is a pure function of the request — which
 * is what makes "the acknowledgement always goes first" a thing a test can hold
 * this file to rather than a thing a reviewer has to notice.
 */
export function answerCredential(request: CredentialRequest): ClientMessage[] {
  return [
    { t: 'credential.ack', id: request.id },
    // Not `denied`. Nobody refused anything — there is no account here to refuse
    // with, and there cannot be. See the header.
    { t: 'credential.deny', id: request.id, reason: 'no-account' },
  ]
}

/** The question, in the shape the notice on screen is drawn from. */
export function credentialNotice(request: CredentialRequest, at: number): CredentialNotice {
  return {
    id: request.id,
    origin: request.host,
    repo: request.repo,
    operation: request.operation,
    prompt: request.prompt,
    at,
  }
}

/**
 * The headline, in the words of whatever git is doing.
 *
 * Read off `operation` rather than assumed, the same way the phones' prompts do:
 * the two fields are separate precisely so a client can say what is happening
 * rather than what it expected to happen.
 */
export function credentialHeadline(notice: CredentialNotice, machine: string): string {
  const verb = notice.operation === 'write' ? 'push to' : 'sign in to'
  const what = notice.repo === null ? `a repository on ${notice.origin}` : notice.repo
  return `${machine} asked this browser for a GitHub login to ${verb} ${what}.`
}

/**
 * The sentence the desktop cannot write, because it does not know what kind of
 * client is on the other end of the socket.
 *
 * It says the true thing and no more: not that the browser is insecure, not that
 * anything went wrong, but that this page comes from the machine that is asking
 * — which is a fact about the deployment and is the entire reason there is no
 * token here. Then it names both ways forward, because a refusal with no route
 * out is a dead end.
 */
export const CREDENTIAL_EXPLANATION =
  'This page is served by that machine, so a token kept here would be a token it ' +
  'could read. Answer from the app on a phone or another computer, or push with a ' +
  'fine-grained token scoped to that one repository.'
