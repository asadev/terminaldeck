import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { buildCatalogue } from '../deck-control/catalogue'
import { COPILOT_FRAME_TIER, parseClientMessage, type ClientMessage } from './protocol'

/**
 * **No tool name ever appears in a frame a phone can construct.**
 *
 * This is the property that makes the enforcement in §3 airtight rather than
 * exhaustive, and it is the one most likely to be lost to a good idea.
 *
 * Every other design for this feature has to *enumerate and deny*: here are the
 * tools, here is which of them a `read` phone may name, here is the check. That
 * works until somebody adds a tool and forgets the list — which is precisely
 * OpenClaw's GHSA-943q-mwmv-hhvh (OC-02), where the gateway did not deny the
 * session-orchestration tools by default and anyone holding gateway auth could
 * call `sessions_spawn`.
 *
 * This design has nothing to enumerate. The phone sends **prose**. The tool
 * calls are made by a Claude CLI process on this machine, over loopback,
 * authenticated by a per-run bearer token the phone does not hold and cannot
 * read. So the set of frames a phone can construct contains no tool at all, and
 * the alter tier is not "denied" so much as unreachable.
 *
 * ## Why it is scanned as text as well as checked as data
 *
 * The same argument `wire-wording.test.ts` makes about platform nouns. The data
 * check below proves that today's corpus of frames carries no tool id; it cannot
 * prove that tomorrow's `copilot.tool` variant does not exist, because a variant
 * nobody wrote a fixture for is a variant this file never sees. The text check
 * reads `protocol.ts` itself and asserts the *declared shape* of every copilot
 * client frame against an allowlist of field names — so adding a field is a
 * failing test and a decision, rather than a diff nobody read.
 *
 * `COPILOT-REMOTE.md` §2 names the pressure this will come under, and it is
 * worth repeating here where somebody about to change it will be looking: the
 * first person who wants `copilot.tool` for a nice phone UI — *"tap to re-run
 * that"* — is asking to trade the whole property for one gesture.
 */

/** The fields a `copilot.*` **client** frame is allowed to declare, and no others. */
const ALLOWED_FIELDS: Readonly<Record<string, readonly string[]>> = {
  'copilot.attach': [],
  'copilot.detach': [],
  'copilot.state': [],
  'copilot.sessions': [],
  /*
   * `limit` is a count and `before` is a row id from a log this device was
   * already shown. Neither names a tool, a session or a path — `before` is the
   * `id` of a row the desktop itself sent, so the worst a phone can do with it
   * is page to somewhere that does not exist.
   */
  'copilot.log': ['limit', 'before'],
  'copilot.pending': [],
  'copilot.start': [],
  /*
   * The one field that carries content, and it is a sentence.
   *
   * A phone saying *"stop the stuck session"* is a phone expressing an
   * intention. Whether that becomes `sessions.stop` is decided by an agent
   * reading its own tool list, and whether the call is allowed is decided by
   * `DeckControl.call` against that device's grant. Both of those happen on this
   * machine, behind a token the phone does not have.
   */
  'copilot.say': ['text'],
  'copilot.cancel': [],
  'copilot.stop': [],
}

/** Every copilot client frame a phone can build, as it goes onto the wire. */
const FRAMES: ClientMessage[] = [
  { t: 'copilot.attach' },
  { t: 'copilot.detach' },
  { t: 'copilot.state' },
  { t: 'copilot.sessions' },
  { t: 'copilot.pending' },
  { t: 'copilot.log' },
  { t: 'copilot.log', limit: 50 },
  { t: 'copilot.log', limit: 50, before: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5' },
  { t: 'copilot.start' },
  { t: 'copilot.say', text: 'which of my sessions is stuck?' },
  { t: 'copilot.cancel' },
  { t: 'copilot.stop' },
]

/** Both spellings of every tool: the dotted id a person reads, the wire name a client calls. */
function toolNames(): string[] {
  return buildCatalogue().flatMap((spec) => [spec.id, spec.wire])
}

/** Every string anywhere inside a value, keys included. */
function stringsIn(value: unknown, out: string[] = []): string[] {
  if (typeof value === 'string') out.push(value)
  else if (Array.isArray(value)) for (const item of value) stringsIn(item, out)
  else if (typeof value === 'object' && value !== null) {
    for (const [key, item] of Object.entries(value)) {
      out.push(key)
      stringsIn(item, out)
    }
  }
  return out
}

describe('a phone cannot name a tool', () => {
  it('carries no tool id, in any field, of any copilot frame it can send', () => {
    const tools = new Set(toolNames())
    // A guard on the guard: an empty catalogue would make every assertion below
    // vacuous, and this file would report airtightness while checking nothing.
    expect(tools.size).toBeGreaterThan(10)

    for (const frame of FRAMES) {
      for (const text of stringsIn(frame)) {
        expect(tools.has(text), `${frame.t} carries the tool name ${text}`).toBe(false)
      }
    }
  })

  /**
   * The same check, after the parser — because the parser is what a real frame
   * goes through, and a parser that passed an unknown field along would defeat
   * the check above without changing a type.
   */
  it('drops anything a hand-built frame smuggles in beside the allowed fields', () => {
    const smuggled = parseClientMessage(
      JSON.stringify({ t: 'copilot.say', text: 'hello', tool: 'settings.write', args: { key: 'a' } }),
    )
    expect(smuggled.ok).toBe(true)
    if (!smuggled.ok) return
    expect(Object.keys(smuggled.message).sort()).toEqual(['t', 'text'])
  })

  /**
   * The text half. Reads the union in `protocol.ts` and holds each copilot
   * client arm to its allowlist.
   *
   * A regex over a type declaration is a blunt instrument and it is the right
   * one here: what is being defended is not a type relationship, it is the
   * *absence* of a field nobody has written yet. There is no type-level way to
   * assert that.
   */
  it('declares no field on a copilot client frame beyond the allowlist', () => {
    const source = readFileSync(join(__dirname, 'protocol.ts'), 'utf8')
    const client = clientUnion(source)
    const seen = new Set<string>()

    for (const match of client.matchAll(/\{\s*t:\s*'(copilot\.[a-z]+)'\s*;?([^}]*)\}/g)) {
      const verb = match[1]
      seen.add(verb)
      const declared = [...match[2].matchAll(/([a-zA-Z_][a-zA-Z0-9_]*)\??\s*:/g)].map((f) => f[1])
      const allowed = ALLOWED_FIELDS[verb]
      expect(allowed, `${verb} is a client frame nobody decided the fields of`).toBeDefined()
      expect(
        declared.sort(),
        `${verb} declares a field that is not on the allowlist — see the header before widening it`,
      ).toEqual([...(allowed ?? [])].sort())
    }

    // Every verb in the allowlist was actually found. A regex that matched
    // nothing is a test that passes loudly and checks nothing, which is the
    // failure mode `wire-wording.test.ts` guards against by the same means.
    expect([...seen].sort()).toEqual(Object.keys(ALLOWED_FIELDS).sort())
  })

  /**
   * `copilot.tool` is a **server** frame and must never become a client one.
   *
   * It is how a refusal becomes visible — a call the phone's grant did not cover
   * arrives with `outcome: 'refused'` — and that direction is the safe one:
   * naming a tool the desktop already ran is a report, naming one to run is a
   * request. The tier table is what decides which frames exist inbound, so the
   * assertion is against that.
   */
  it('has no inbound verb for a tool, a run, or an approval', () => {
    for (const verb of ['copilot.tool', 'copilot.run', 'copilot.approve', 'copilot.allow']) {
      expect(COPILOT_FRAME_TIER[verb], `${verb} must not be a client verb`).toBeUndefined()
      expect(parseClientMessage(JSON.stringify({ t: verb })).ok).toBe(false)
    }
  })

  /**
   * The tier table and the client union say the same thing.
   *
   * Two lists that can disagree is how a verb ships with no tier and falls
   * through to whatever the handler assumed. `server.ts` lists the ten verbs one
   * by one for the same reason, so that adding one without deciding its tier
   * stops the build.
   */
  it('gives every copilot client frame exactly one tier', () => {
    expect(Object.keys(COPILOT_FRAME_TIER).sort()).toEqual(Object.keys(ALLOWED_FIELDS).sort())
    for (const frame of FRAMES) expect(COPILOT_FRAME_TIER[frame.t]).toBeDefined()
  })
})

/**
 * The `ClientMessage` union's text, from `export type ClientMessage` to the
 * declaration after it.
 *
 * Sliced rather than parsed, and bounded at the *next* top-level `export`, so
 * that the `ServerMessage` union below it — which does carry `copilot.tool` —
 * cannot leak into the scan and make this test fail for the one frame that is
 * supposed to exist.
 */
function clientUnion(source: string): string {
  const start = source.indexOf('export type ClientMessage =')
  expect(start, 'ClientMessage is no longer declared where this test looks').toBeGreaterThan(0)
  const after = source.indexOf('\nexport ', start + 1)
  expect(after, 'ClientMessage runs to the end of the file').toBeGreaterThan(start)
  return source.slice(start, after)
}
