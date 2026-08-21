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
import { noteNoVerbs, noVerbsLine, resetNoVerbsForTests } from './session-verbs'
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
          : takeAnnouncement(sessionId, '', sessionId === null ? null : noVerbsLine(sessionId))
        : hookContext(sessionId, '', {
            known: knows,
            opensInApp: true,
            // The third thing `index.ts` hands in, read out of the same module
            // rather than faked, so this covers the join and not a stand-in.
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

beforeEach(() => {
  resetForTests()
  resetNoVerbsForTests()
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

  it('reaches an idle session on his next prompt, before the model sees it', async () => {
    const endpoint = await serve()

    // The case he actually filmed: nothing is running, he attaches two windows,
    // then types. A CLI at an empty prompt has no turn to inject into and will
    // not knock until it is spoken to, so *this* is what "whenever I just
    // connect, it should get a context" can mean without typing into his
    // terminal — the facts ride in on the prompt itself, ahead of the model.
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe', url: 'https://stripe.com' })
    attach({ sessionId: 's1', browserTabId: 'b:2', title: 'Docs', url: 'https://docs.dev' })

    const prompt = await knock(endpoint, 'UserPromptSubmit', 's1')
    expect(prompt.status).toBe(200)
    expect(prompt.context).toContain('B1 — Stripe — https://stripe.com')
    expect(prompt.context).toContain('B2 — Docs — https://docs.dev')
    expect(prompt.context).toContain('"the browser" means B1.')
  })

  it('does not then say the same list again at the first tool call of that turn', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })

    // The prompt above already carried the whole list, so the mid-turn door has
    // nothing left to announce. Before this it said it twice inside one turn.
    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).status).toBe(200)
    expect((await knock(endpoint, 'PostToolUse', 's1')).status).toBe(204)
  })

  it('still tells a mid-turn agent that its last window went away', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe' })
    await knock(endpoint, 'UserPromptSubmit', 's1')

    detach('b:1')

    // The standing answer says nothing about windows when there are none, so it
    // cannot be the thing that tells an agent still holding `B1` that `B1` is
    // gone. The empty case is deliberately left for the mid-turn door.
    expect((await knock(endpoint, 'UserPromptSubmit', 's1')).context).not.toContain('B1')
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

/**
 * The sentence a session gets when it holds a window it cannot touch.
 *
 * Asad, on a session that had been told about its windows and had no verbs for
 * them: *"Now, if I currently ask the session which is outside, it just don't
 * know anything."* What that agent did next is the part worth pinning — it
 * reasoned entirely from outside the app and proposed to install Playwright and
 * read a CDP port. Being told about `B1` and given no way to look at it does not
 * read as "you cannot look"; it reads as "you have not found the way yet".
 *
 * So the two facts travel together or the first one is a trap.
 */
describe('a session that cannot drive is told so, beside the windows it holds', () => {
  it('says why at the top of the turn, in one sentence it can act on', async () => {
    const endpoint = await serve()
    noteNoVerbs('s1', 'provider')
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'v1', title: 'Docs' })

    const said = (await knock(endpoint, 'UserPromptSubmit', 's1')).context ?? ''

    // Both halves in the same answer: the window it owns, and the fact that
    // owning it is not the same as being able to look at it.
    expect(said).toContain('B1')
    expect(said).toContain('Claude session')
    expect(said).toContain('no other way in')
  })

  it('says it again mid-turn, which is when the agent is about to try', async () => {
    const endpoint = await serve()
    noteNoVerbs('s1', 'endpoint')
    // The shim has just landed a page in a window. This is the gap between "it
    // is open in B1" and the agent's first attempt to read it.
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'v1' })

    const said = (await knock(endpoint, 'PostToolUse', 's1')).context ?? ''

    expect(said).toContain('B1')
    expect(said).toContain('control endpoint is not running')
  })

  it('says nothing at all to a session that can drive', async () => {
    const endpoint = await serve()
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'v1' })

    const said = (await knock(endpoint, 'UserPromptSubmit', 's1')).context ?? ''

    expect(said).toContain('B1')
    // Not a word of it. This line rides in every turn it appears in, out of the
    // same context budget the top bar shows him, so the ordinary case pays
    // nothing.
    expect(said).not.toContain('cannot read or act on')
  })

  it('tells a session that merely started too early to be started again', async () => {
    const endpoint = await serve()
    // The desktop's control server binds a few hundred milliseconds after the
    // window, and a restored tab can be launched inside that gap. The flag is
    // read once at exec, so this session will never have the verbs — and the one
    // thing that fixes it is a thing only he can do.
    noteNoVerbs('s1', 'early')
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'v1' })

    const said = (await knock(endpoint, 'UserPromptSubmit', 's1')).context ?? ''

    expect(said).toContain('started again')
    // And not the dead-end sentence the other four get: this door is open, it
    // was simply shut when this session walked through.
    expect(said).not.toContain('no other way in')
  })

  /**
   * The two sentences it composed used to contradict each other.
   *
   * `hookContext` writes them in a fixed order, and the line before the refusal
   * is *"`open <url>` goes to B1 unless you detach it"* on every launch where
   * this run put the shim on the PATH — which is macOS and most of Linux. The
   * refusal opened *"You cannot open, read or act on them from here"*. So a
   * Codex or Gemini session with a window attached read, in one answer, on every
   * turn: this is how you open a page into `B1`, and you cannot open them.
   *
   * The withheld thing was never `open` — the shim is a script on a PATH and has
   * nothing to do with `--mcp-config`. It is reading and acting on the page. So
   * both halves are pinned together here, because the defect was only ever
   * visible in the composition.
   */
  it('does not deny the one route the line above it just promised', async () => {
    const endpoint = await serve()
    // Codex: no per-run MCP override, so no verbs — and the shim is on its PATH
    // like everybody else's.
    noteNoVerbs('s1', 'provider')
    attach({ sessionId: 's1', browserTabId: 'browser:1', viewId: 'v1' })

    const said = (await knock(endpoint, 'UserPromptSubmit', 's1')).context ?? ''

    expect(said).toContain('`open <url>` goes to B1')
    expect(said).toContain('cannot read or act on what is in them')
    expect(said).not.toContain('cannot open')
  })

  it('says nothing to a session with no windows to be misled about', async () => {
    const endpoint = await serve()
    noteNoVerbs('s1', 'wsl')

    const said = (await knock(endpoint, 'UserPromptSubmit', 's1')).context ?? ''

    // There is nothing here to reach for, so the sentence would be words paid
    // for on every turn to describe an absence.
    expect(said).not.toContain('cannot read or act on')
  })
})
