import { mkdtempSync, rmSync } from 'node:fs'
import { request } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  attach,
  detach,
  hasAnnouncement,
  heldRowsFor,
  hookContext,
  recordRemoteHolds,
  remoteHoldsFor,
  resetForTests,
  takeAnnouncement,
} from './browser-binding'
import { noVerbsLine, resetNoVerbsForTests } from './session-verbs'
import type { HeldSession } from '../shared/held-window'
import {
  SESSION_HEADER,
  TOKEN_HEADER,
  startHookServer,
  stopHookServer,
  type HookEndpoint,
} from './hook-server'

/**
 * A browser window on **another computer**, told to the session it is attached
 * to — over the real socket the agent knocks on.
 *
 * ## The gap this closes
 *
 * Every part of driving a window across a link worked before tonight and none of
 * it could be *used*, because nothing ever told the agent the window was there.
 * A window attached in the Mac's app to a session running on the PC is a
 * `WebContentsView` and a `Map` entry in the Mac's process; the PC has a pty and
 * an empty binding map. `window.holds` carried the session ids, which is exactly
 * enough for `window-owner.ts` to *address* a verb and not one word of what the
 * agent would have to know to send one. Measured, an agent in that state does
 * not conclude that it has a browser window somewhere — it concludes it has
 * none, and offers to print a link.
 *
 * ## What is pinned here
 *
 *  - the rows going **out**, and the one translation in them: `hostMachineId`
 *    means "this computer" and has to be restated from the reader's side,
 *  - the rows coming **in**, and the two rules that keep the answer honest — a
 *    window here beats a claim from over there, and two claims are silence,
 *  - the announcement itself, at both doors, through a real unix socket rather
 *    than by calling the composer.
 *
 * The wire is pinned where the wire is: `remote/server.test.ts` for a device
 * sending these rows into a real endpoint, `remote/machines/guest.test.ts` for
 * the same frame read the other way through the real parser, and
 * `remote/machines/live.test.ts` for the whole chain over a real relay. This file
 * is the map and the sentence.
 */

let live: HookEndpoint | null = null
const dirs: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-bind-remote-'))
  dirs.push(dir)
  return dir
}

/** The wiring `index.ts` does, reproduced so the test covers the join. */
async function serve(): Promise<HookEndpoint> {
  live = await startHookServer({
    dir: scratch(),
    contextFor: ({ event, sessionId }) =>
      event === 'PostToolUse'
        ? sessionId === null
          ? null
          : takeAnnouncement(sessionId, '', noVerbsLine(sessionId))
        : hookContext(sessionId, '', {
            known: true,
            opensInApp: true,
            cannotDrive: sessionId === null ? null : noVerbsLine(sessionId),
          }),
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

/** One session's worth of what a peer says it is holding. */
function holds(session: string, ...windows: { n: number; title?: string; url?: string; host?: string }[]): HeldSession[] {
  return [
    {
      session,
      windows: windows.map((window) => ({
        n: window.n,
        title: window.title ?? '',
        url: window.url ?? '',
        host: window.host ?? '',
      })),
    },
  ]
}

const MAC = { id: 'machine-mac', name: "Asad's Mac" }
const PC = { id: 'machine-pc', name: 'Office PC' }

beforeEach(() => {
  resetForTests()
  resetNoVerbsForTests()
})

afterEach(async () => {
  await stopHookServer()
  live = null
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

describe('the rows this machine sends about windows it holds', () => {
  it('carries the slot number, the title and the URL, not just the id', () => {
    attach({
      sessionId: 'pty-on-the-pc',
      machineId: PC.id,
      browserTabId: 'browser:1:1',
      title: 'Stripe',
      url: 'https://stripe.com',
    })

    expect(heldRowsFor(PC.id, "Asad's Mac")).toEqual([
      {
        session: 'pty-on-the-pc',
        windows: [{ n: 1, title: 'Stripe', url: 'https://stripe.com', host: "Asad's Mac" }],
      },
    ])
  })

  it('restates where the page is served from the *reader’s* side', () => {
    /*
     * The one line in `heldRowsFor` that could be wrong in a way nobody would
     * notice for a week. `BoundWindow.hostMachineId` is empty for *this*
     * computer; sent unchanged it would arrive somewhere else, where empty means
     * a different computer, and a page served by the Mac would be described to
     * the PC as a page served by the PC.
     */
    attach({
      sessionId: 's-here',
      machineId: PC.id,
      browserTabId: 'browser:1:1',
      url: 'http://localhost:5173',
      // Served by the very machine being told: through the reach tunnel, that
      // `localhost` is the PC's own dev server.
      hostMachineId: PC.id,
      hostMachineName: 'Office PC',
    })
    attach({
      sessionId: 's-third',
      machineId: PC.id,
      browserTabId: 'browser:1:2',
      url: 'http://localhost:3000',
      hostMachineId: 'machine-server',
      hostMachineName: 'terminaldeck-server',
    })

    const rows = heldRowsFor(PC.id, "Asad's Mac")
    const served = Object.fromEntries(rows.map((row) => [row.session, row.windows[0].host]))
    // Served on the machine being told → empty, which is what that reader
    // already prints as "this computer".
    expect(served['s-here']).toBe('')
    // Served on a third machine → its name, which means the same to both ends.
    expect(served['s-third']).toBe('terminaldeck-server')
  })

  it('says nothing about a session on a different machine, or one with no window', () => {
    attach({ sessionId: 'local', browserTabId: 'browser:1:1', title: 'Local' })
    attach({ sessionId: 'theirs', machineId: MAC.id, browserTabId: 'browser:1:2', title: 'Theirs' })

    expect(heldRowsFor(PC.id, 'Here')).toEqual([])
    expect(heldRowsFor('', 'Here')).toEqual([])
    expect(heldRowsFor(MAC.id, 'Here').map((row) => row.session)).toEqual(['theirs'])
  })
})

describe('what a peer says it is holding for a session here', () => {
  it('is a replacement, so a detach arrives as an absence', () => {
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    expect(remoteHoldsFor('s1')).toHaveLength(1)

    // The person detaches it over there. The frame is the whole set again, and
    // this session is simply no longer in it.
    recordRemoteHolds(MAC, [])
    expect(remoteHoldsFor('s1')).toEqual([])
  })

  it('keeps two computers apart rather than letting one overwrite the other', () => {
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    recordRemoteHolds(PC, holds('s1', { n: 1, title: 'Invoices' }))
    expect(remoteHoldsFor('s1')).toHaveLength(2)

    recordRemoteHolds(MAC, [])
    expect(remoteHoldsFor('s1').map((hold) => hold.at)).toEqual(['Office PC'])
  })

  it('ignores a claim with no windows in it, which is all an older build can send', () => {
    // `sessions` without `held` is what a desktop from before tonight sends. It
    // routes and says nothing, which is where this app was — and an empty entry
    // would print as a session that has windows nobody can name.
    recordRemoteHolds(MAC, [{ session: 's1', windows: [] }])
    expect(remoteHoldsFor('s1')).toEqual([])
    expect(hasAnnouncement('s1')).toBe(false)
  })

  it('describes a peer this machine has no name for, rather than printing its id', () => {
    recordRemoteHolds({ id: 'device-9f2a', name: '' }, holds('s1', { n: 1 }))
    expect(remoteHoldsFor('s1')[0].at).toBe('another computer')
  })

  it('knocks only when something actually changed', () => {
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    expect(hasAnnouncement('s1')).toBe(true)
    takeAnnouncement('s1')

    /*
     * A welcome re-sends the whole set — that is what makes the frame idempotent
     * — and a link on a flaky network welcomes often. If arriving were enough,
     * every reconnection would put the window list into the next tool call of
     * every agent on this machine, out of the budget he watches in the top bar.
     */
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    expect(hasAnnouncement('s1')).toBe(false)

    // The page moved, which is a change and is worth the words.
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Invoices' }))
    expect(hasAnnouncement('s1')).toBe(true)
  })

  it('does not knock for a session that reads its own list anyway', () => {
    // A window in this app is what that session is told about — see the
    // local-first rule below — so a peer attaching one changes nothing anybody
    // would read, and a turn's context is not spent saying so.
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Local' })
    takeAnnouncement('s1')

    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Elsewhere' }))
    expect(hasAnnouncement('s1')).toBe(false)
  })
})

describe('telling the agent, at both doors', () => {
  it('names the window and the computer it is on, at the top of a turn', async () => {
    const endpoint = await serve()
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe', url: 'https://stripe.com' }))

    const answered = await knock(endpoint, 'UserPromptSubmit', 's1')

    expect(answered.status).toBe(200)
    expect(answered.context).toContain('Browser windows attached to this session:')
    expect(answered.context).toContain("B1 — Stripe — https://stripe.com — on Asad's Mac")
    expect(answered.context).toContain('"the browser" means B1.')
  })

  it('lands mid-turn on the very next tool call, with nothing typed anywhere', async () => {
    const endpoint = await serve()

    // The turn is already running and there was nothing to say.
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)

    // He attaches a window on the other computer. Nothing here was asked.
    recordRemoteHolds(MAC, holds('s1', { n: 2, title: 'Docs', url: 'https://docs.dev' }))

    const answered = await knock(endpoint, 'PostToolUse', 's1')
    expect(answered.status).toBe(200)
    expect(answered.context).toContain('this just changed')
    expect(answered.context).toContain("B2 — Docs — https://docs.dev — on Asad's Mac")
    expect(answered.context).toContain('"the browser" means B2.')

    // And once. The standing answer carries it from there.
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)
  })

  it('says the page is served elsewhere when it is, and nothing when it is not', async () => {
    const endpoint = await serve()
    recordRemoteHolds(
      MAC,
      holds('s1', { n: 1, title: 'Deck', url: 'http://localhost:5173', host: 'terminaldeck-server' }),
    )

    const answered = await knock(endpoint, 'UserPromptSubmit', 's1')
    expect(answered.context).toContain(
      "B1 — Deck — http://localhost:5173 — on Asad's Mac — served by terminaldeck-server",
    )
  })

  it('tells the agent it has none again when the last one is detached over there', async () => {
    const endpoint = await serve()
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    await knock(endpoint, 'PostToolUse', 's1')

    recordRemoteHolds(MAC, [])
    const answered = await knock(endpoint, 'PostToolUse', 's1')
    expect(answered.context).toBe('No browser window is attached to this session now.')
  })

  it('prints a window in this app and never a peer’s claim beside it', async () => {
    /*
     * The local-first rule, and it is `routeWindowVerb`'s rather than this
     * file's: a verb from a session with a window in this app is served in this
     * app, so a peer's `B1` cannot be reached at all while a local `B1` exists.
     * Printing both would put two names in one list where every verb resolves to
     * one of them, which is the control that looks like it works and does not.
     */
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Here', url: 'https://here.dev' })
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Over there' }))

    const answered = await knock(endpoint, 'UserPromptSubmit', 's1')
    expect(answered.context).toContain('B1 — Here — https://here.dev')
    expect(answered.context).not.toContain('Over there')
    expect(answered.context).not.toContain("on Asad's Mac")
  })

  it('falls back to the peer’s window the moment the local one is detached', async () => {
    /*
     * The local-first rule is about which window is *reachable*, and it flips the
     * instant the local one goes. An agent still holding `B1` would otherwise be
     * told "no browser window is attached to this session now" about a page it can
     * still drive — the false sentence this whole round exists to stop.
     */
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Here' })
    recordRemoteHolds(MAC, holds('s1', { n: 3, title: 'Over there' }))
    await knock(endpoint, 'PostToolUse', 's1')

    detach('browser:1:1')
    const answered = await knock(endpoint, 'PostToolUse', 's1')
    expect(answered.context).toContain("B3 — Over there — on Asad's Mac")
    expect(answered.context).toContain('"the browser" means B3.')
  })

  it('says nothing at all when two computers both claim it', async () => {
    /*
     * `routeWindowVerb` refuses a session two computers have claimed — there is
     * no order that would be right — so naming `B1` twice would be printing two
     * names that both refuse. The sentence for that state is composed where the
     * decision is made, not here.
     */
    const endpoint = await serve()
    recordRemoteHolds(MAC, holds('s1', { n: 1, title: 'Stripe' }))
    recordRemoteHolds(PC, holds('s1', { n: 1, title: 'Invoices' }))

    const answered = await knock(endpoint, 'UserPromptSubmit', 's1')
    expect(answered.context).not.toContain('Browser windows attached to this session:')
    expect(answered.context).not.toContain('B1')

    // And when one of them lets go, the other is nameable again.
    recordRemoteHolds(PC, [])
    const after = await knock(endpoint, 'UserPromptSubmit', 's1')
    expect(after.context).toContain("B1 — Stripe — on Asad's Mac")
  })

  it('never lets a peer put context into a session this app did not start', async () => {
    /*
     * The hook is installed globally, so it fires for the `claude` Asad runs in
     * his own terminal outside this app. A window in *this* map is proof the app
     * started the session; a claim from a paired machine is not, and it is not
     * even an assertion about this computer. So a peer that guessed an id gets
     * the same empty 204 that terminal has always had.
     */
    live = await startHookServer({
      dir: scratch(),
      contextFor: ({ sessionId }) => hookContext(sessionId, '', { known: false }),
    })
    recordRemoteHolds(MAC, holds('not-ours', { n: 1, title: 'His bank' }))

    const answered = await knock(live, 'UserPromptSubmit', 'not-ours')
    expect(answered.status).toBe(204)
    expect(answered.context).toBe(null)
  })

  it('costs a session with no windows nothing it did not cost before', async () => {
    /*
     * The budget rule, stated as a test because it is the one that decays. This
     * answer rides every prompt of every session, and the great majority of
     * sessions have no browser window at all.
     */
    const endpoint = await serve()
    const before = (await knock(endpoint, 'UserPromptSubmit', 'quiet')).context

    // Another machine is connected and talking about somebody else's sessions.
    recordRemoteHolds(MAC, holds('loud', { n: 1, title: 'Stripe' }))

    expect((await knock(endpoint, 'UserPromptSubmit', 'quiet')).context).toBe(before)
    expect((await knock(endpoint, 'PostToolUse', 'quiet')).status).toBe(204)
  })
})
