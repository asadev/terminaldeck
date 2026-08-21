/**
 * Which sessions were launched without this app's browser verbs, and the one
 * sentence each of them gets to explain itself.
 *
 * ## Why this exists at all
 *
 * `deck-control/session-tools.ts` hands an ordinary session the six browser
 * verbs on its own command line, and there are several launches it cannot hand
 * them to — an agent whose CLI has no per-run MCP override, a session inside a
 * WSL distribution, a session a paired device asked for, a run with no control
 * endpoint. That list is fine. What is not fine is what such a session *does*.
 *
 * Asad, on watching one, 2026-08-21:
 *
 * > *"Now, if I currently ask the session which is outside, it just don't know
 * > anything."*
 *
 * and, of the round that was supposed to fix it:
 *
 * > *"other sessions still cant see inside the browser window they opened they
 * > can just open."*
 *
 * The failure has a shape. `browser-binding.ts` already tells every session, at
 * the top of every turn, which windows are attached to it — `B1`, its title, its
 * URL. A session that has been told it owns `B1` and has no verb for it does not
 * conclude that it cannot look; it concludes that it has not found the way yet,
 * and goes looking for one. The measured version of that is an agent proposing
 * to install Playwright and attach to a CDP port, which is a turn spent, a
 * wrong answer, and — if it had succeeded — a browser holding his logins driven
 * by something outside every tier, budget and log in this app.
 *
 * So a session that cannot drive is told so in the same breath it is told the
 * window exists. One sentence, in the same channel, from the same map.
 *
 * ## Why it is a module of its own with no imports
 *
 * Three places need it and no two of them can import each other's world. It is
 * written by `host-core.ts`, which is the one place a session starts and the
 * only place that knows *why* a launch was not given the flags. It is read by
 * `index.ts` and by `src/headless/host.ts`, which compose the hook answer for
 * the desktop and for a shell with no window. And it must not drag
 * `deck-control/` into the headless bundle, which cannot have it —
 * `deck-control/index.ts` reaches Electron through `browserDrive`, and
 * `src/headless/host.ts` says so where it declines to build a copilot.
 *
 * So this is what `browser-binding.ts` is: a map and some sentences, testable
 * without a window, an app object or a spawned process.
 */

/**
 * Why a session was launched without the browser verbs.
 *
 * A closed set rather than a free string, for the reason `RefusalReason` is one
 * in `deck-control/surface.ts`: these become sentences an agent reads, and a
 * caller composing its own would be a second place that has to know how this
 * app talks about itself.
 *
 * There is deliberately no member for the one caller that composes its own tool
 * surface. That is the copilot, and it composes *these verbs into it* — see
 * `browser-tools.ts` — so a sentence saying it cannot drive would be the only
 * false one in the set.
 */
export type NoVerbsReason =
  /** Not a Claude CLI, which is the only one with a per-run MCP override. */
  | 'provider'
  /** Inside a WSL distribution: the endpoint and the file are the Windows side's. */
  | 'wsl'
  /** A session a paired device asked for. See the gate in `host-core.ts`. */
  | 'device'
  /** This build has no `deck-control` endpoint at all — the headless host. */
  | 'endpoint'
  /**
   * The endpoint was not up **yet** when this session started.
   *
   * Held apart from `endpoint` because the two want different sentences and only
   * one of them is a dead end. The desktop's control server binds a few hundred
   * milliseconds after the window is built, and a session started inside that
   * window — a restored tab, above all — is launched with no `--mcp-config`.
   * There is no way to add one afterwards: the flag is read once, at exec.
   *
   * So the honest thing is not to say "there is no endpoint", which stops being
   * true a second later and leaves him with a session that quietly cannot see.
   * It is to say that this session missed it and a new one will not.
   */
  | 'early'

/**
 * The clause each reason contributes. Kept short on purpose: this rides in a
 * hook answer, which is paid for out of the session's context on every turn it
 * appears in — `hookContext`'s own header makes that argument at length.
 */
const BECAUSE: Readonly<Record<NoVerbsReason, string>> = Object.freeze({
  provider: 'this app can only add its browser verbs to a Claude session',
  wsl: 'the verbs are on the Windows side and this session runs inside WSL',
  device: 'a session a paired device started is not given them',
  endpoint: 'this app’s control endpoint is not running here',
  early: 'this session started before this app’s control endpoint did, and the flag that carries them is ' +
    'read once at launch',
})

/**
 * And what to do about it — which is not the same sentence in every case.
 *
 * Four of these are dead ends and say so, because an agent told merely that
 * something did not work will try again in another way; the measured version is
 * an agent reaching for a CDP port. `early` is the one that is *not* a dead end:
 * a session started a moment later has the verbs, so the useful thing is to say
 * that rather than to close a door that is open. Telling him is the point — a
 * session that quietly cannot see is exactly the thing he has been left to
 * discover twice.
 */
const THEN: Readonly<Record<NoVerbsReason, string>> = Object.freeze({
  provider: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  wsl: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  device: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  endpoint: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  early:
    'Tell the person this session has to be started again before it can act on its own windows, and do ' +
    'not look for another way in.',
})

/** sessionId → why it has no verbs. Absent means it has them, or is not ours. */
const withheld = new Map<string, NoVerbsReason>()

/**
 * Write down that this session was launched without them.
 *
 * Called with the session id rather than at the moment the decision is made,
 * because the decision is made before the pty exists — the same ordering
 * `sessionTools.started` is subject to and for the same reason.
 */
export function noteNoVerbs(sessionId: string, reason: NoVerbsReason): void {
  if (sessionId === '') return
  withheld.set(sessionId, reason)
}

/**
 * This session has them after all, or is gone.
 *
 * Called on both edges. Ids are minted once and never reused, so an entry left
 * behind could never mean anything again — the argument `forgetBoundary` makes
 * next to it in `host-core.ts`'s exit callback, where this is called from.
 */
export function forgetNoVerbs(sessionId: string): void {
  withheld.delete(sessionId)
}

/**
 * The sentence, or null when there is nothing true to say.
 *
 * Null covers two different states on purpose — a session that holds the verbs
 * and a session this app never started — because the answer for both is the
 * same: say nothing. The only case that earns words is the one where this
 * process positively knows the agent is about to look for a way in that does
 * not exist.
 */
export function noVerbsLine(sessionId: string): string | null {
  const reason = withheld.get(sessionId)
  if (reason === undefined) return null
  return `You cannot open, read or act on them from here — ${BECAUSE[reason]}. ${THEN[reason]}`
}

/** Test seam. Nothing in the app calls this; every real drop is a session ending. */
export function resetNoVerbsForTests(): void {
  withheld.clear()
}
