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
 * `deck-control/` into either of them merely to name a reason — a map and some
 * sentences have no business importing a dispatcher. (The headless bundle can
 * now hold `deck-control`: the two Electron edges were cut on 2026-08-22 and a
 * server runs its own tool endpoint. That makes this a layering rule rather than
 * a physical one, which is a weaker reason and still the right one.)
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
  /**
   * Inside a WSL distribution that could reach this app's tool endpoint neither
   * way.
   *
   * Narrower than it was twice over. It used to mean "inside WSL" flatly, on a
   * copy of the `open` shim's reasoning that did not apply — the shim cannot
   * cross because the hook endpoint on Windows is a named pipe, and the verbs do
   * not go through the pipe. On 2026-08-21 it narrowed to one measured question:
   * does `127.0.0.1` in that distribution reach the host's loopback? It does
   * under mirrored networking and does not under NAT.
   *
   * On 2026-08-22 it narrowed again, and this time the answer "no" stopped being
   * the end of it. A distribution that cannot reach loopback is handed a stdio
   * MCP server run through WSL's Windows interop instead of a URL — no port, no
   * firewall rule, no `.wslconfig` edit, no restart. `wsl-bridge.ts` is that
   * program and `wsl-reach.ts` measures both ways in one crossing. So this is
   * now the sentence for a distribution that answered **neither**, which in
   * practice means one with Windows interop switched off.
   */
  | 'wsl'
  /**
   * A session a paired device asked for, on a device that cannot hold a browser
   * window — a phone.
   *
   * Narrower than it was. Such a session's windows are never on this machine (a
   * device driving the browser here is refused and always will be), so they are
   * on the device, and since 2026-08-21 a verb can be sent there — but only to a
   * build that advertises `CAPABILITY.windows`, which a phone does not and a
   * paired desktop does. So this reason is now exactly the devices that have no
   * window to reach, and the sentence says that rather than the old blanket one.
   * See the gate in `host-core.ts`.
   */
  | 'device'
  /**
   * This build has no `deck-control` endpoint at all.
   *
   * It used to mean the headless host, flatly. A server now runs one of its own
   * over its own Chromium (`src/headless/host.ts`), so what is left is a build
   * that withholds it on purpose — the public demo box, whose container hands a
   * stranger a shell and must not hand them a browser on the same machine — and
   * a test harness that passes no seam.
   */
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
  wsl: 'this app’s endpoint is on the Windows side and this session could not reach it from inside WSL',
  device: 'the device that started this session cannot show a browser window',
  endpoint: 'this app’s control endpoint is not running here',
  early: 'this session started before this app’s control endpoint did, and the flag that carries them is ' +
    'read once at launch',
})

/**
 * And what to do about it — which is not the same sentence in every case.
 *
 * Three of these are dead ends and say so, because an agent told merely that
 * something did not work will try again in another way; the measured version is
 * an agent reaching for a CDP port. Two are not. `early` is a session that
 * started a moment before the endpoint did, so the useful thing is to say that
 * rather than to close a door that is open. `wsl` is a door that is *nearly*
 * always already open — the app now crosses the boundary itself, through WSL's
 * Windows interop, with nothing asked of anybody — so reaching this sentence at
 * all means the one remaining switch is off, and it names that switch rather
 * than only refusing.
 *
 * What it deliberately no longer names is `networkingMode=mirrored` and
 * `wsl --shutdown`. That sentence was true and was still a defect: it sent a
 * person out of the app to edit a file they have never opened and restart the
 * distribution their work is running in. `wsl-bridge.ts` is what replaced it.
 */
const THEN: Readonly<Record<NoVerbsReason, string>> = Object.freeze({
  provider: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  /*
   * The one dead end with a remedy the person can carry out themselves, so it
   * says the remedy rather than only closing the door — and it is a much rarer
   * dead end than it was, because the app no longer needs the distribution's
   * networking to be reconfigured at all. Getting here means both ways were
   * tried and both failed, and the switch that turns the second one off is
   * `[interop]`. It is a file inside their own distribution, needs no
   * administrator, and takes effect on the next shell rather than on a restart.
   * `wsl-reach.ts` and `wsl-bridge.ts` have the argument.
   */
  wsl:
    'Tell the person to start this session again; if it still cannot, this distribution has Windows ' +
    'interop switched off, and `enabled = true` under `[interop]` in its `/etc/wsl.conf` is what lets ' +
    'this app reach in. Until then say what you would have done on the page and let them do it; there ' +
    'is no other way in.',
  device: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  endpoint: 'Say what you would have done on the page and let the person do it; there is no other way in.',
  early:
    'Tell the person this session has to be started again before it can read a page in one of its own ' +
    'windows, and do not look for another way in.',
})

/**
 * Every reason, as clauses, for the document that has to describe the same set.
 *
 * `app-context.ts`'s `browser-windows.md` answers *"can this session act on the
 * page"* at length, for a session that will read it long after the one-line
 * answer above went past. Until this existed it answered it with a flat "a
 * session has no tool for any of that", which had been true when it was written
 * and was false the same day `deck-control/session-tools.ts` landed — one lane
 * each, 2026-08-21, neither knowing about the other.
 *
 * So the page renders **this** rather than a second list. A reason added to
 * {@link NoVerbsReason} shows up in the document by construction, and a page
 * that disagreed with the sentence a session is actually given is no longer a
 * thing anybody can write by forgetting.
 *
 * Order is the declaration order of {@link BECAUSE}, which is stable and is the
 * order the reasons are argued in above. Nothing reads the keys, so they stay
 * out of a document nobody can act on them in.
 */
export function noVerbsReasons(): readonly string[] {
  return Object.values(BECAUSE)
}

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
 *
 * ## It used to deny `open`, which the line directly above it had just promised
 *
 * `hookContext` composes these in a fixed order, and the line before this one is
 * *"`open <url>` goes to B1 unless you detach it"* whenever this run put the
 * shim on the session's PATH — which is every macOS and most Linux launches. So
 * a Codex or Gemini session with a window attached read two adjacent sentences,
 * one saying a URL it opens lands in `B1` and the next saying it cannot open
 * them. Both were composed from the same map, in the same answer, on every turn
 * of that session.
 *
 * The withheld thing was never `open`: the shim is a script on a PATH and has
 * nothing to do with `--mcp-config`. What is withheld is *reading and acting on
 * the page*, which is what the six verbs do and what an agent goes hunting for a
 * CDP port to get. So the sentence says that and leaves the one route that does
 * work standing — which is also the more useful refusal, because "put a page
 * there and describe what you would have done" is the fallback the clause after
 * it then asks for.
 */
export function noVerbsLine(sessionId: string): string | null {
  const reason = withheld.get(sessionId)
  if (reason === undefined) return null
  return `You cannot read or act on what is in them from here — ${BECAUSE[reason]}. ${THEN[reason]}`
}

/** Test seam. Nothing in the app calls this; every real drop is a session ending. */
export function resetNoVerbsForTests(): void {
  withheld.clear()
}
