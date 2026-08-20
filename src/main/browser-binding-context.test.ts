import { mkdtempSync, rmSync } from 'node:fs'
import { request } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  attach,
  detach,
  hasAnnouncement,
  hookContext,
  resetForTests,
  takeAnnouncement,
} from './browser-binding'
import {
  SESSION_HEADER,
  TOKEN_HEADER,
  startHookServer,
  stopHookServer,
  type HookEndpoint,
} from './hook-server'

/**
 * When the agent learns about a browser window — over the real wire.
 *
 * Asad attached two windows to a session that was already running and then asked
 * it what it could see:
 *
 * > *"First of all, it should automatically right away get a context. Whenever I
 * > just connect, it should get a context… See, it doesn't know anything about
 * > it… If I tell it 'I open this in your browser and check B2, B1', it will not
 * > know. It doesn't know what is B1, what is B2."*
 *
 * Nothing in this process can push into a turn that is already running. The only
 * channel is the agent's own hook, which blocks on this HTTP response — so the
 * question is not *whether* to push but **which knock to answer**, and this file
 * pins the answer over a real socket rather than by calling a function:
 *
 *  - `SessionStart` / `UserPromptSubmit` — the standing description, as before.
 *  - `PostToolUse` — the *change*, once, so an attach made mid-turn arrives at
 *    the agent's very next tool call instead of waiting for the next prompt.
 *
 * And the constraint that shapes all of it: not one character of any of this is
 * written into the terminal. There is no pty in this file for the same reason
 * there is none in the feature.
 */

let live: HookEndpoint | null = null
const dirs: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-bind-ctx-'))
  dirs.push(dir)
  return dir
}

/** The wiring `index.ts` does, reproduced here so the test covers the join. */
async function serve(knows = true): Promise<HookEndpoint> {
  live = await startHookServer({
    dir: scratch(),
    contextFor: ({ event, sessionId }) =>
      event === 'PostToolUse'
        ? sessionId === null
          ? null
          : takeAnnouncement(sessionId)
        : hookContext(sessionId, '', { known: knows, opensInApp: true }),
  })
  return live
}

/** One hook call, exactly as the installed `curl` command makes it. */
function knock(
  endpoint: HookEndpoint,
  event: string,
  sessionId: string,
): Promise<{ status: number; context: string | null }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  headers[TOKEN_HEADER] = endpoint.token
  headers[SESSION_HEADER] = sessionId
  return new Promise((resolve, reject) => {
    const req = request(
      { socketPath: endpoint.socketPath, method: 'POST', path: `/hook/claude/${event}`, headers },
      (res) => {
        let text = ''
        res.setEncoding('utf8')
        res.on('data', (chunk: string) => {
          text += chunk
        })
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            context:
              text === ''
                ? null
                : ((JSON.parse(text) as { hookSpecificOutput?: { additionalContext?: string } })
                    .hookSpecificOutput?.additionalContext ?? null),
          }),
        )
      },
    )
    req.on('error', reject)
    req.write('{}')
    req.end()
  })
}

beforeEach(() => {
  resetForTests()
})

afterEach(async () => {
  await stopHookServer()
  live = null
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

describe('an attach made mid-turn arrives at the next tool call', () => {
  it('names B1 and B2 on the very next PostToolUse, with nothing typed anywhere', async () => {
    const endpoint = await serve()

    // The turn is already running: the agent has made a tool call and there was
    // nothing to say.
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)

    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe', url: 'https://stripe.com' })
    attach({ sessionId: 's1', browserTabId: 'b:2', title: 'Docs', url: 'https://docs.dev' })

    const answered = await knock(endpoint, 'PostToolUse', 's1')

    expect(answered.status).toBe(200)
    expect(answered.context).toContain('B1 — Stripe — https://stripe.com')
    expect(answered.context).toContain('B2 — Docs — https://docs.dev')
    expect(answered.context).toContain('"the browser" means B1.')
  })

  it('says it once — the standing answer carries it from then on', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })

    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(200)
    // Every tool call after it is the empty 204 again. A channel that repeated
    // itself after every Read would cost the same words on every step of every
    // turn, out of the context budget the top bar shows him.
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)

    // …and the fact is still there for the next prompt.
    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).context).toContain('B1 — Stripe')
  })

  it('tells it when a window is taken away, which is the more urgent half', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })
    await knock(endpoint, 'PostToolUse', 's1')

    detach('b:1')

    expect((await knock(endpoint, 'PostToolUse', 's1')).context).toBe(
      'No browser window is attached to this session now.',
    )
  })

  it('says nothing to a session that had nothing attached to it', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })

    // The other session in the window is mid-turn too, and its surroundings did
    // not change. Marking every session on every attach would put a paragraph
    // into turns that have nothing to do with it.
    expect((await knock(endpoint, 'PostToolUse', 's2')).status).toBe(204)
  })

  it('never answers a session this app did not start', async () => {
    const endpoint = await serve(false)

    // His own terminal `claude`, whose hook is the same globally installed one.
    // Nothing is attached to it, nothing can be, and it must hear nothing.
    expect((await knock(endpoint, 'SessionStart', 'outside')).status).toBe(204)
    expect((await knock(endpoint, 'PostToolUse', 'outside')).status).toBe(204)
  })
})

describe('what the agent is told is what is true', () => {
  it('names the machine a page is really served by, because the URL cannot', async () => {
    const endpoint = await serve()
    // The tunnel put this page on a loopback port of *this* machine. An agent
    // reading the address alone would conclude the opposite of the truth.
    attach({
      sessionId: 's1',
      browserTabId: 'b:1',
      title: 'Orders',
      url: 'http://localhost:3000/orders',
      hostMachineId: 'm-desktop',
      hostMachineName: 'DESKTOP-DDGMNCV',
    })

    const answered = await knock(endpoint, 'UserPromptSubmit', 's1')

    expect(answered.context).toContain(
      'B1 — Orders — http://localhost:3000/orders — served by DESKTOP-DDGMNCV',
    )
  })

  it('says nothing about a machine for a page on this computer', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Orders', url: 'http://localhost:3000/' })

    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).context).toContain(
      'B1 — Orders — http://localhost:3000/',
    )
    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).context).not.toContain('served by')
  })

  it('drains rather than accumulating, so nothing is said twice', () => {
    attach({ sessionId: 's1', browserTabId: 'b:1' })
    expect(hasAnnouncement('s1')).toBe(true)
    expect(takeAnnouncement('s1')).not.toBeNull()
    expect(hasAnnouncement('s1')).toBe(false)
    expect(takeAnnouncement('s1')).toBeNull()
  })

  it('does not announce a page merely navigating', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })
    await knock(endpoint, 'PostToolUse', 's1')

    // A window he is not looking at following a redirect must not interrupt a
    // turn. The standing answer carries the new address at the next prompt.
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe', url: 'https://stripe.com/x' })

    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)
    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).context).toContain('https://stripe.com/x')
  })
})
