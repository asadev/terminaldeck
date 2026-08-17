/**
 * Turning "get the flaky auth test fixed" into something worth spending money on.
 *
 * `COPILOT-CAPABILITIES.md` §2.2, and it is second on the list for a reason
 * that is about people rather than software: the named failure mode of parallel
 * agent work is that **ambiguity multiplies**. An under-specified ask goes out
 * to three sessions, each goes slightly wrong in a slightly different
 * direction, and you find out at review time across all three at once. The
 * copilot is the one agent that is *allowed to be slow*, because the sessions
 * it starts are the ones that cost money.
 *
 * So a copilot-started session can carry a **brief**: a written spec, saved to
 * a file, shown to the person, and handed to the session as its first
 * instruction.
 *
 * ## The brief is a file, and the session is told to read it
 *
 * This is lifted whole from the prompt discipline `COPILOT-CAPABILITIES.md`
 * §2.2 says to copy verbatim: *state the repo, the base branch and the expected
 * proof up front; write the worker prompt to a file rather than passing it
 * through a shell.* Every word of that is load-bearing here:
 *
 *  - **A file survives.** A brief typed into a composer is gone the moment the
 *    session is closed, and the first attempt at a task is the one most likely
 *    to fail. A spec on disk is re-runnable — start a second session, point it
 *    at the same file — which a chat message scrolled off the top is not.
 *  - **A file is reviewable before it is expensive.** The person can open it,
 *    disagree with it and edit it, and the session that reads it reads the
 *    edited version.
 *  - **A file has no quoting.** What gets typed into the pty is one short
 *    sentence naming a path. A multi-paragraph brief typed directly would have
 *    to survive a terminal that treats newline as *submit* and escape as a
 *    command — so it would arrive as six separate half-messages, or as a
 *    bracketed-paste sequence this app would have to get exactly right on three
 *    agent CLIs. One line pointing at a file is the version that cannot be
 *    subtly wrong.
 *
 * ## Typing into a session that has not drawn its prompt yet
 *
 * An agent CLI takes seconds to start, and a line written into its pty before
 * it is listening is a line that vanishes — or worse, half-vanishes. So the
 * delivery waits for the composer to be *seen* to be ready, using
 * `agent-controls.ts`'s `readComposer`, which is this codebase's accumulated
 * knowledge of what an agent CLI's screen looks like in each of its states.
 *
 * And when the wait runs out, **it says so instead of pretending**. The result
 * carries `delivered: false` and the reason, and the spec path is still
 * returned — so the copilot's honest answer is "the session is running, here is
 * the brief, it did not take it, send it yourself", which is a sentence a
 * person can act on. Silently returning a started session whose brief went
 * nowhere is the failure this whole module would otherwise introduce: an agent
 * running with no instructions, billing, in a folder somebody cares about.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { readComposer, refuseToType } from '../agent-controls'
import type { DeckSurface } from './surface'

/* ------------------------------------------------------------------ limits -- */

/**
 * Longest brief that will be written.
 *
 * Eight kilobytes is the same ceiling `routines/format.ts` puts on a routine
 * prompt, and for the same reason: this is an instruction, not a document. A
 * brief that does not fit is a brief that is describing the work instead of
 * scoping it.
 */
export const MAX_BRIEF_CHARS = 8_000

/** Shortest brief worth calling one. Below this, it is a chat message. */
export const MIN_BRIEF_CHARS = 40

/**
 * How long to wait for the new session's prompt before giving up on delivery.
 *
 * Twenty seconds, and the number is bounded from both directions by things
 * outside this file. Below it: the Claude CLI on this machine draws its first
 * composer in a little over two seconds warm and around six cold, measured by
 * starting one through this very tool and polling the screen — so twenty is
 * three times the slow case. Above it: this wait happens *inside* a tool call,
 * and an MCP client has a timeout of its own; a delivery that outlasted the
 * client would come back to the model as a failed call for a session that had
 * in fact started, which is the worst of both answers.
 */
export const DELIVERY_TIMEOUT_MS = 20_000

/** How often the screen is looked at while waiting. */
export const DELIVERY_POLL_MS = 400

/* ------------------------------------------------------------------ writing -- */

/** `<copilot>/specs` — where briefs are kept. */
export function specsDir(copilotRoot: string): string {
  return join(copilotRoot, 'specs')
}

export interface SpecInput {
  /** A few words. Becomes the filename and the heading. */
  title: string
  /** The brief itself, as the copilot wrote it. */
  brief: string
  cwd: string
  provider: string | null
  /** The action-log row that produced this. Links the spec back to the turn. */
  callId: string
  at: number
}

export interface WrittenSpec {
  path: string
  slug: string
}

/**
 * A title reduced to something safe to concatenate into a path.
 *
 * The same aggressive narrowing `routines/format.ts` uses on routine ids and
 * for the same reason: this string is a filename, so everything that is not a
 * lowercase letter, a digit or a hyphen is a separator, a Windows device name
 * or a `..` waiting to happen. The date prefix added below means two briefs
 * with the same title do not collide within a minute of each other, and a
 * counter is not worth the extra state for a case that means somebody asked for
 * the same thing twice.
 */
export function slugifyTitle(title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48)
    .replace(/-+$/g, '')
  return slug === '' ? 'brief' : slug
}

/** `20260817-0942`, local time, so a person can find today's briefs by eye. */
export function stampOf(at: number): string {
  const date = new Date(at)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return (
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}`
  )
}

/**
 * Write the brief, and answer with where it went.
 *
 * Front matter first, because the three facts §2.2 insists on — the repo, the
 * agent, and the turn that produced it — have to be in the file itself. A brief
 * whose repo is only knowable from the folder it happens to be sitting in is a
 * brief that cannot be re-run somewhere else, and re-running it is most of why
 * it is a file.
 */
export function writeSpec(dir: string, input: SpecInput): WrittenSpec {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const slug = `${stampOf(input.at)}-${slugifyTitle(input.title)}`
  const path = join(dir, `${slug}.md`)
  const body = [
    `# ${input.title.trim()}`,
    '',
    `repo: ${input.cwd}`,
    `agent: ${input.provider ?? 'the default'}`,
    `written: ${new Date(input.at).toISOString()}`,
    `from-turn: ${input.callId}`,
    '',
    '---',
    '',
    input.brief.trim(),
    '',
  ].join('\n')
  writeFileSync(path, body, { encoding: 'utf8', mode: 0o600 })
  return { path, slug }
}

/**
 * The one line that is actually typed into the new session.
 *
 * Deliberately blunt about two things. *Read it before you start* — because an
 * agent that begins working from the sentence rather than from the file has
 * ignored the brief entirely, which is the failure this replaces. And *this is
 * the whole of what you were asked* — because the alternative reading, that the
 * line is a preamble to instructions still to come, produces a session that
 * sits waiting for a second message that nobody is going to send.
 */
export function deliveryLine(specPath: string): string {
  return (
    `Read ${specPath} and do exactly what it says. That file is your whole brief — ` +
    'nothing else has been said to you, and nobody is going to add to it. ' +
    'Read it before you start.'
  )
}

/* ---------------------------------------------------------------- delivery -- */

export interface DeliveryResult {
  delivered: boolean
  /** Why not, when it was not. Null on success. */
  reason: string | null
  /** How long the wait took, in ms. */
  waitedMs: number
}

export interface DeliveryClock {
  now(): number
  sleep(ms: number): Promise<void>
}

export const realClock: DeliveryClock = {
  now: () => Date.now(),
  sleep: (ms) =>
    new Promise((resolve) => {
      setTimeout(resolve, ms)
    }),
}

/**
 * Wait for the session's prompt, then type the line.
 *
 * Three ways this ends, and all three are reported rather than thrown:
 *
 *  - The composer is seen ready, the line goes in, `delivered: true`.
 *  - The deadline passes with the composer never ready — a CLI that failed to
 *    start, a login screen, a provider that draws nothing recognisable. The
 *    last thing `refuseToType` had to say about the screen becomes the reason,
 *    because that function is the accumulated knowledge of *why* typing would
 *    have been wrong, and it is a better sentence than "timed out".
 *  - The session exits while waiting.
 */
export async function deliverBrief(
  surface: Pick<DeckSurface, 'sessionScreen' | 'writeToSession' | 'listSessions'>,
  sessionId: string,
  line: string,
  options: { timeoutMs?: number; pollMs?: number; clock?: DeliveryClock } = {},
): Promise<DeliveryResult> {
  const clock = options.clock ?? realClock
  const timeoutMs = options.timeoutMs ?? DELIVERY_TIMEOUT_MS
  const pollMs = options.pollMs ?? DELIVERY_POLL_MS
  const startedAt = clock.now()
  let lastRefusal: string | null = null

  for (;;) {
    const alive = surface.listSessions().find((session) => session.id === sessionId)
    if (alive === undefined || alive.exitCode !== null) {
      return {
        delivered: false,
        reason: 'The session ended before it was ready to be typed into.',
        waitedMs: clock.now() - startedAt,
      }
    }

    const screen = await surface.sessionScreen(sessionId)
    if (screen !== null) {
      const refusal = refuseToType(readComposer(screen))
      if (refusal === null) {
        return {
          ...(await submit(surface, sessionId, line, clock, pollMs)),
          waitedMs: clock.now() - startedAt,
        }
      }
      lastRefusal = refusal
    }

    if (clock.now() - startedAt >= timeoutMs) {
      return {
        delivered: false,
        reason:
          lastRefusal ??
          'The session never drew a prompt this app could recognise, so nothing was typed.',
        waitedMs: clock.now() - startedAt,
      }
    }
    await clock.sleep(pollMs)
  }
}

/**
 * How long to wait for typed text to appear on the session's own command line.
 *
 * The same 2.5 seconds `agent-controls.ts` settled on for its `echo` timing,
 * against the same CLIs on the same machine.
 */
export const ECHO_TIMEOUT_MS = 2_500

/** Ctrl-U. Clears the composer, for the rollback below. */
const CLEAR_COMPOSER = '\x15'

/**
 * Write the line, watch it land, and only then press return.
 *
 * **The return is a separate write, and that is the whole of this function.**
 * The first version appended it — `write(`${line}\r`)` — which is one call, is
 * obviously correct, and does not work. Driven against a real session it
 * produced this, on screen, with the brief sitting unsent in the composer:
 *
 *     ❯ Read /…/specs/20260817-1034-fix-auth-test-and-test-script.md
 *       and do exactly what it says. That file is your whole brief …
 *
 * A 271-character burst arriving in one pty write is a **paste**, and the CLI
 * treats a newline inside a paste as a newline rather than as submit — which is
 * the correct behaviour for a person pasting a paragraph, and the wrong outcome
 * for this. The session was started, the brief was written, the copilot
 * reported it delivered, and the agent sat at a prompt holding an instruction
 * nobody had sent. Everything about that failure is silent.
 *
 * `agent-controls.ts` had already learned this and written the three-step
 * protocol down: refuse unless the composer is empty, write the text *without*
 * the return, wait until the screen reads it back, and only then send the byte
 * that commits. This is that protocol, applied to a brief instead of to a slash
 * command — and it is the second time in this repository that a single write
 * with a `\r` on the end has been wrong.
 *
 * The echo check is a **prefix** match rather than an equality one, and that is
 * not laziness. `readComposer` reads one line: it returns the first row of the
 * composer, and a brief is three rows once the terminal has wrapped it. Exact
 * equality would fail for every line longer than the window is wide, which is
 * every brief.
 *
 * ## The rollback
 *
 * If the echo never arrives, the keystrokes went somewhere this app cannot see,
 * so the line is cleared before giving up. That is safe precisely because the
 * caller established the composer was empty first — everything Ctrl-U removes
 * is this app's own typing.
 */
async function submit(
  surface: Pick<DeckSurface, 'sessionScreen' | 'writeToSession'>,
  sessionId: string,
  line: string,
  clock: DeliveryClock,
  pollMs: number,
): Promise<{ delivered: boolean; reason: string | null }> {
  surface.writeToSession(sessionId, line)

  const deadline = clock.now() + ECHO_TIMEOUT_MS
  for (;;) {
    const screen = await surface.sessionScreen(sessionId)
    if (screen !== null) {
      const state = readComposer(screen)
      if (state.kind === 'typing' && state.text.length > 0 && line.startsWith(state.text)) {
        surface.writeToSession(sessionId, '\r')
        return { delivered: true, reason: null }
      }
    }
    if (clock.now() >= deadline) {
      surface.writeToSession(sessionId, CLEAR_COMPOSER)
      return {
        delivered: false,
        reason:
          'The brief was typed but never appeared on the session command line, so the return was not sent and the line was cleared again. Nothing was delivered.',
      }
    }
    await clock.sleep(pollMs)
  }
}
