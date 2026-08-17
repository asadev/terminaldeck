import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Caller } from '../deck-control/surface'
import { CopilotGrants } from './copilot-grants'
import type { CopilotSink } from './copilot-remote'
import { isHiddenSession, resetHiddenSessions } from './hidden-sessions'
import { CopilotRuns, runConfigName, type CopilotRunDeps, type CopilotRunSpawn } from './copilot-runs'
import { MAX_COPILOT_LOG_ROWS, MAX_COPILOT_MESSAGE_CHARS } from './protocol'

/**
 * The run manager, driven with no Electron, no pty and no socket.
 *
 * Every dependency is injected for exactly this reason — the properties worth
 * pinning here are a grace window, an unwind ordering and a token lifetime, and
 * none of them can be driven against a real Claude CLI in under ten minutes.
 *
 * The load-bearing tests are the two about the token: it exists in the caller
 * table for as long as the run does and no longer, and it re-reads the grant
 * rather than carrying a copy of it. Those are the two that would go red if
 * somebody made a revoked phone keep driving an agent.
 */

let dir: string

interface Harness {
  runs: CopilotRuns
  grants: CopilotGrants
  /** Tokens currently registered, and the caller each resolves to right now. */
  tokens: Map<string, { attended: boolean; caller(): Caller; signal?: AbortSignal }>
  spawned: CopilotRunSpawn[]
  stopped: string[]
  said: Array<{ id: string; text: string }>
  interrupted: string[]
  /** Sessions the harness considers alive. Take one out to kill it. */
  alive: Set<string>
  /** Push a chat update into whatever run is subscribed to a session. */
  emitChat(sessionId: string, text: string, reset?: boolean): void
  clock: { at: number }
}

function harness(over: Partial<CopilotRunDeps> = {}): Harness {
  const tokens = new Map<string, { attended: boolean; caller(): Caller; signal?: AbortSignal }>()
  const spawned: CopilotRunSpawn[] = []
  const stopped: string[] = []
  const said: Array<{ id: string; text: string }> = []
  const interrupted: string[] = []
  const alive = new Set<string>()
  const chatters = new Map<string, (update: { messages: Array<{ id: string; role: 'you' | 'agent'; text: string; at: number }>; reset: boolean }) => void>()
  const clock = { at: 1_000 }
  const grants = new CopilotGrants(dir)
  let next = 0

  const deps: CopilotRunDeps = {
    grants,
    callers: {
      set: (token, grant) => {
        tokens.set(token, grant)
      },
      delete: (token) => tokens.delete(token),
    },
    endpoint: () => ({ url: 'http://127.0.0.1:5599/mcp' }),
    copilotRoot: () => join(dir, 'copilot'),
    spawn: async (request) => {
      spawned.push(request)
      next += 1
      const id = `run-${next}`
      alive.add(id)
      return id
    },
    isAlive: (id) => alive.has(id),
    stop: (id) => {
      stopped.push(id)
      alive.delete(id)
    },
    say: (id, text) => said.push({ id, text }),
    interrupt: (id) => interrupted.push(id),
    desk: () => ({ status: 'running', profile: 'Personal', signedIn: true, available: true, reason: null }),
    cost: () => ({ tools: 11, turnTokens: 900 }),
    sessions: () => [],
    log: () => ({ rows: [], more: false }),
    pending: () => [],
    chat: (sessionId, onUpdate) => {
      chatters.set(sessionId, onUpdate)
      return () => chatters.delete(sessionId)
    },
    now: () => clock.at,
    ...over,
  }

  return {
    runs: new CopilotRuns(deps),
    grants,
    tokens,
    spawned,
    stopped,
    said,
    interrupted,
    alive,
    emitChat: (sessionId, text, reset = false) => {
      chatters.get(sessionId)?.({ messages: [{ id: 'm1', role: 'agent', text, at: 5 }], reset })
    },
    clock,
  }
}

/** A sink that records what one connection was sent. */
function recorder(): { sink: CopilotSink; chats: Array<{ run: string; texts: string[]; reset: boolean }>; states: number } & {
  states: number
} {
  const chats: Array<{ run: string; texts: string[]; reset: boolean }> = []
  const box = { states: 0 }
  const sink: CopilotSink = {
    state: () => {
      box.states += 1
    },
    chat: (run, messages, reset) => chats.push({ run, texts: messages.map((m) => m.text), reset }),
    tool: () => {},
    sessions: () => {},
    pending: () => {},
  }
  return Object.assign(box, { sink, chats })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-copilot-runs-'))
  // The register is process-wide, like the copilot singleton it sits beside, so
  // a run left hidden by one test would make the next one's assertions about a
  // *different* session pass for the wrong reason.
  resetHiddenSessions()
})

afterEach(() => {
  resetHiddenSessions()
  rmSync(dir, { recursive: true, force: true })
})

/* ---------------------------------------------------------------- the token */

describe('the token is the caller, and it lives exactly as long as the run', () => {
  it('registers one token per run, re-reading the grant rather than copying it', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })

    await h.runs.start('phone-1')
    expect(h.tokens.size).toBe(1)

    const [entry] = [...h.tokens.values()]
    // Attended: there is demonstrably a person, they sent a message seconds ago,
    // and they are holding a device that can display a prompt. See §4.3 — the
    // flag is currently unobservable for a phone and must still say what is true.
    expect(entry.attended).toBe(true)
    expect(entry.caller()).toEqual({ kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: false } })

    // The property the whole design rests on: the untick lands on the *next*
    // tool call, with no restart, no reconnect and no message from the phone.
    h.grants.set('phone-1', { read: true })
    expect(entry.caller().tiers.act).toBe(false)
  })

  it('never registers a token carrying alter, whatever the store is told', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true, alter: true })

    await h.runs.start('phone-1')
    const [entry] = [...h.tokens.values()]
    expect(entry.caller().tiers.alter).toBe(false)
  })

  /**
   * Revocation, in the order §3 sets out.
   *
   * The store is written first by `server.ts`; by the time `revoked` is called
   * the grant is already gone. What this pins is the rest: the token leaves the
   * table, the signal fires so a tool call in flight aborts with `caller-gone`,
   * the process stops, and the config file holding the token is removed.
   */
  it('drops the token, aborts in-flight calls and stops the run when act is revoked', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    const [entry] = [...h.tokens.values()]
    const signal = entry.signal
    expect(signal?.aborted).toBe(false)
    const config = join(dir, 'copilot', runConfigName('phone-1'))
    expect(existsSync(config)).toBe(true)

    h.grants.set('phone-1', { read: true })
    h.runs.revoked('phone-1')

    expect(h.tokens.size).toBe(0)
    expect(signal?.aborted).toBe(true)
    expect(h.stopped).toEqual(['run-1'])
    expect(existsSync(config)).toBe(false)
  })

  /**
   * Losing `read` while keeping `act` does not stop the run.
   *
   * A phone that may still drive the copilot but no longer watch it is a strange
   * thing to have granted and the panel does not offer it — but the store can
   * hold it, and the answer must be the one written down rather than an inferred
   * ladder. `server.ts` drops the *subscription*; the run is `act`'s.
   */
  it('keeps the run when only read was taken away', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    h.grants.set('phone-1', { act: true })
    h.runs.revoked('phone-1')

    expect(h.tokens.size).toBe(1)
    expect(h.stopped).toEqual([])
  })

  it('writes the token into a config file only this account can read, and nowhere else', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    const config = join(dir, 'copilot', runConfigName('phone-1'))
    const parsed = JSON.parse(readFileSync(config, 'utf8')) as {
      mcpServers: Record<string, { url: string; headers: Record<string, string> }>
    }
    const [token] = [...h.tokens.keys()]
    expect(parsed.mcpServers['deck-control'].url).toBe('http://127.0.0.1:5599/mcp')
    expect(parsed.mcpServers['deck-control'].headers.Authorization).toBe(`Bearer ${token}`)
    // The spawn is told the path, never the token. A bearer credential on a
    // command line is a credential in everybody's process list.
    expect(h.spawned[0].mcpConfig).toBe(config)
    expect(JSON.stringify(h.spawned[0])).not.toContain(token)
  })

  it('leaves no token behind when the spawn fails', async () => {
    const h = harness({
      spawn: async () => {
        throw new Error('claude is not installed')
      },
    })
    h.grants.set('phone-1', { read: true, act: true })

    const outcome = await h.runs.start('phone-1')
    expect(outcome.ok).toBe(false)
    expect(h.tokens.size).toBe(0)
    expect(existsSync(join(dir, 'copilot', runConfigName('phone-1')))).toBe(false)
    // The reason is not quoted. It came from a spawn on this machine and the
    // sentence is drawn on somebody's phone.
    if (!outcome.ok) expect(outcome.message).not.toContain('claude is not installed')
  })
})

/* ------------------------------------------------------------ one per device */

describe('a run belongs to one device and to nothing else', () => {
  it('answers a second start with the run that already exists', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })

    await h.runs.start('phone-1')
    await h.runs.start('phone-1')

    expect(h.spawned.length).toBe(1)
    expect(h.tokens.size).toBe(1)
  })

  it('gives two devices two runs, two tokens and two conversations', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    h.grants.set('tablet', { read: true, act: true })

    await h.runs.start('phone-1')
    await h.runs.start('tablet')

    expect(h.spawned.length).toBe(2)
    expect(h.tokens.size).toBe(2)
    expect(h.runs.state('phone-1').run).not.toBe(h.runs.state('tablet').run)
  })

  /**
   * Rule 11 of the never-list: a device cannot reach another device's run.
   *
   * Anything else makes a grant to one device a grant to every device that comes
   * after it, which is a permission model with a shared password.
   */
  it('refuses to interrupt or stop a run this device does not own', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    expect(h.runs.cancel('tablet').ok).toBe(false)
    expect(h.runs.stop('tablet').ok).toBe(false)
    expect(h.interrupted).toEqual([])
    expect(h.stopped).toEqual([])

    expect(h.runs.cancel('phone-1').ok).toBe(true)
    expect(h.interrupted).toEqual(['run-1'])
  })

  /**
   * The pty is hidden, and this is the predicate that hides it.
   *
   * Handed to `SessionFanout` alongside the desk copilot's own id. A phone that
   * could `attach` to its run's pty would hold `alter` no matter what its grant
   * said, because every tier check in this design sits above that layer.
   */
  it('names its run sessions as hidden, and stops naming them when they end', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    expect(h.runs.isRunSession('run-1')).toBe(true)
    expect(h.runs.isRunSession('sess-ordinary')).toBe(false)

    h.runs.stop('phone-1')
    expect(h.runs.isRunSession('run-1')).toBe(false)
  })

  /**
   * The register the fanout actually reads, which is the one that matters.
   *
   * `isRunSession` is this object's answer; `isHiddenSession` is what
   * `host-core.ts` asks, and the two are wired to the same fact deliberately.
   * Asserting only the first would pass on a build where the run manager knew
   * its sessions were secret and nothing else did — which is the shipped state
   * §0.1 of the spec calls blocking, with a phone able to `attach` and type
   * into a Claude CLI holding `deck-control`.
   */
  it('puts the run in the register the session fanout consults', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    expect(isHiddenSession('run-1')).toBe(true)
    expect(isHiddenSession('sess-ordinary')).toBe(false)

    h.runs.stop('phone-1')
    expect(isHiddenSession('run-1')).toBe(false)
  })

  it('releases every run’s id when the app quits', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    h.grants.set('tablet', { read: true, act: true })
    await h.runs.start('phone-1')
    await h.runs.start('tablet')
    expect(isHiddenSession('run-1') && isHiddenSession('run-2')).toBe(true)

    h.runs.stopAll()
    expect(isHiddenSession('run-1')).toBe(false)
    expect(isHiddenSession('run-2')).toBe(false)
  })

  /**
   * A run that expired is not merely stopped, it is un-hidden.
   *
   * The register fails closed by design — nothing ages an id out of it — so the
   * only thing that can leak is the *opposite* mistake: an id left in it forever
   * would make a future ordinary session with a recycled id invisible to every
   * paired device, with nothing on screen to explain why.
   */
  it('releases the id when a run times out rather than being stopped', async () => {
    const h = harness({ graceMs: 60_000 })
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')
    expect(isHiddenSession('run-1')).toBe(true)

    h.clock.at += 61_000
    h.runs.state('phone-1')
    expect(isHiddenSession('run-1')).toBe(false)
  })
})

/* ------------------------------------------------------------ grace window */

describe('a run survives a dropped socket for the grace window and no longer', () => {
  it('keeps the run alive while a watcher is attached', async () => {
    const h = harness({ graceMs: 60_000 })
    h.grants.set('phone-1', { read: true, act: true })
    const watcher = recorder()

    h.runs.watch('phone-1', watcher.sink)
    await h.runs.start('phone-1')

    h.clock.at += 10 * 60_000
    expect(h.runs.state('phone-1').run).toBe('run-1')
    expect(h.stopped).toEqual([])
  })

  it('stops the run once the window passes with nobody watching', async () => {
    const h = harness({ graceMs: 60_000 })
    h.grants.set('phone-1', { read: true, act: true })
    const watcher = recorder()

    const unwatch = h.runs.watch('phone-1', watcher.sink)
    await h.runs.start('phone-1')
    unwatch()

    h.clock.at += 59_000
    expect(h.runs.state('phone-1').run).toBe('run-1')

    h.clock.at += 2_000
    expect(h.runs.state('phone-1').run).toBeNull()
    expect(h.stopped).toEqual(['run-1'])
    expect(h.tokens.size).toBe(0)
  })

  /**
   * Two sockets from one phone are two places the same conversation appears, so
   * the first to close must not start a countdown the second is still inside.
   */
  it('only starts the countdown when the last watcher of a device leaves', async () => {
    const h = harness({ graceMs: 60_000 })
    h.grants.set('phone-1', { read: true, act: true })
    const first = recorder()
    const second = recorder()

    const dropFirst = h.runs.watch('phone-1', first.sink)
    h.runs.watch('phone-1', second.sink)
    await h.runs.start('phone-1')
    dropFirst()

    h.clock.at += 10 * 60_000
    expect(h.runs.state('phone-1').run).toBe('run-1')
  })

  /** A reconnect inside the window cancels the countdown and replays. */
  it('gives a reconnecting phone its run back, with a reset', async () => {
    const h = harness({ graceMs: 60_000 })
    h.grants.set('phone-1', { read: true, act: true })
    const first = recorder()

    const unwatch = h.runs.watch('phone-1', first.sink)
    await h.runs.start('phone-1')
    unwatch()

    h.clock.at += 30_000
    const again = recorder()
    h.runs.watch('phone-1', again.sink)
    expect(again.chats[0]).toEqual({ run: 'run-1', texts: [], reset: true })

    h.clock.at += 10 * 60_000
    expect(h.runs.state('phone-1').run).toBe('run-1')
  })

  /** A run whose process died on its own is not a run. */
  it('forgets a run whose pty exited, so the next start spawns a fresh one', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')

    h.alive.delete('run-1')
    expect(h.runs.state('phone-1').run).toBeNull()
    expect(h.tokens.size).toBe(0)

    await h.runs.start('phone-1')
    expect(h.spawned.length).toBe(2)
  })
})

/* ------------------------------------------------------------------- chat -- */

describe('the conversation is parsed messages, and only ever this device’s', () => {
  it('pushes a run’s messages to that device’s watchers and to no others', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    h.grants.set('tablet', { read: true, act: true })
    const mine = recorder()
    const theirs = recorder()
    h.runs.watch('phone-1', mine.sink)
    h.runs.watch('tablet', theirs.sink)

    await h.runs.start('phone-1')
    h.emitChat('run-1', 'session four is waiting on a prompt')

    expect(mine.chats.at(-1)).toEqual({
      run: 'run-1',
      texts: ['session four is waiting on a prompt'],
      reset: false,
    })
    expect(theirs.chats).toEqual([])
  })

  it('cuts an over-long bubble with a flag rather than chunking it', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    const watcher = recorder()
    h.runs.watch('phone-1', watcher.sink)
    await h.runs.start('phone-1')

    h.emitChat('run-1', 'x'.repeat(MAX_COPILOT_MESSAGE_CHARS + 500))
    const last = watcher.chats.at(-1)
    expect(last?.texts[0].length).toBe(MAX_COPILOT_MESSAGE_CHARS)
    // One bubble, not fifty. A chat bubble is read rather than scrolled.
    expect(last?.texts.length).toBe(1)
  })

  it('drops an update from a run that has already ended', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    const watcher = recorder()
    h.runs.watch('phone-1', watcher.sink)
    await h.runs.start('phone-1')
    const before = watcher.chats.length

    h.runs.stop('phone-1')
    h.emitChat('run-1', 'a late line from a dead run')

    expect(watcher.chats.length).toBe(before)
  })
})

/* -------------------------------------------------------- state and limits */

describe('the state frame and the caps', () => {
  it('reports the desk and this device’s own run as separate facts', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true })

    const idle = h.runs.state('phone-1')
    expect(idle.desk).toBe('running')
    expect(idle.run).toBeNull()
    expect(idle.grant).toEqual({ read: true, act: false })
    expect(idle.tools).toBe(11)

    h.grants.set('phone-1', { read: true, act: true })
    await h.runs.start('phone-1')
    expect(h.runs.state('phone-1').run).toBe('run-1')
    // Still running at the desk. A phone that drew its Start button off the
    // desk's status would offer to start something already running.
    expect(h.runs.state('phone-1').desk).toBe('running')
  })

  it('says why a run cannot start rather than offering a button that fails', () => {
    const h = harness({ endpoint: () => null })
    h.grants.set('phone-1', { read: true, act: true })

    const state = h.runs.state('phone-1')
    expect(state.available).toBe(false)
    expect(state.reason).not.toBeNull()
  })

  it('refuses to start when there is no tool surface to hand it', async () => {
    const h = harness({ endpoint: () => null })
    h.grants.set('phone-1', { read: true, act: true })

    const outcome = await h.runs.start('phone-1')
    expect(outcome.ok).toBe(false)
    expect(h.spawned).toEqual([])
  })

  it('clamps a log request that asks for more than a relay should carry', () => {
    const asked: number[] = []
    const h = harness({
      log: (options) => {
        asked.push(options.limit)
        return { rows: [], more: false }
      },
    })

    h.runs.log({ limit: 100_000 })
    h.runs.log({ limit: 0 })
    h.runs.log({ limit: Number.NaN })
    h.runs.log({})
    expect(asked).toEqual([MAX_COPILOT_LOG_ROWS, 1, MAX_COPILOT_LOG_ROWS, MAX_COPILOT_LOG_ROWS])
  })

  it('starts a run for a say that arrives without one, so one intention is one step', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })

    const outcome = await h.runs.say('phone-1', 'which session is stuck?')
    expect(outcome.ok).toBe(true)
    expect(h.spawned.length).toBe(1)
    expect(h.said).toEqual([{ id: 'run-1', text: 'which session is stuck?' }])
  })

  it('stops every run when the app quits', async () => {
    const h = harness()
    h.grants.set('phone-1', { read: true, act: true })
    h.grants.set('tablet', { read: true, act: true })
    await h.runs.start('phone-1')
    await h.runs.start('tablet')

    h.runs.stopAll()
    expect(h.stopped.sort()).toEqual(['run-1', 'run-2'])
    expect(h.tokens.size).toBe(0)
  })
})

/* ------------------------------------------------------------ the filename */

describe('a device id never becomes a path', () => {
  it('reduces anything to an alphabet this file controls', () => {
    expect(runConfigName('phone-1')).toBe('deck-control-device-phone-1.json')
    expect(runConfigName('../../etc/passwd')).not.toContain('/')
    expect(runConfigName('../../etc/passwd')).not.toContain('..')
    expect(runConfigName('')).toBe('deck-control-device-unnamed.json')
    expect(runConfigName('a'.repeat(500)).length).toBeLessThan(120)
  })
})
