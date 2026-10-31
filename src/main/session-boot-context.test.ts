import { mkdtempSync, rmSync } from 'node:fs'
import { request } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bootMapFor,
  INDEX_FILE,
  contextDir,
  resetForTests as resetContext,
  writeAppContext,
} from './app-context'
import {
  attach,
  hookContext,
  MID_TURN_EVENTS,
  resetForTests as resetBindings,
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
 * What a session is told at boot — over the real socket, in all three CLIs'
 * spellings.
 *
 * Asad, 2026-08-21, twice: *"when any session starts, even from the remote, even
 * from the office PC, local machine, or even if it is starting from the server …
 * we can give a proper context file or a map"*, and *"all the apps should have
 * full context, and they will inject in the beginning silently … and they should
 * be all aligned to each other."*
 *
 * "Aligned to each other" is the part a unit test can hold down, and it is the
 * part that was wrong: the three CLIs do not agree on what their events are
 * called, and two of the three have a door this app deliberately refuses to use.
 * So the same fact has to arrive through three different knocks, and this file
 * pins the whole matrix over a real endpoint rather than by calling a function.
 *
 * The other half of what he asked for is a negative and is pinned here too:
 * *"it will just back in the backend"*. Nothing below writes to a terminal,
 * because nothing in the feature does — the map is a hook response and there is
 * no pty in this file for the same reason there is none in the feature.
 */

let live: HookEndpoint | null = null
const dirs: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-boot-ctx-'))
  dirs.push(dir)
  return dir
}

/**
 * The wiring both hosts do, reproduced once.
 *
 * `src/main/index.ts` and `src/headless/host.ts` compose this same expression
 * from their own objects — the window from its pty manager, the headless host
 * from `core.ptys` — and the thing that must not differ between them is exactly
 * what this function is.
 */
async function serve(knows = true): Promise<{ endpoint: HookEndpoint; dir: string }> {
  const dir = scratch()
  writeAppContext({
    dir,
    version: '0.8.1',
    machineName: 'OFFICE-PC',
    opensInApp: true,
    platform: 'darwin',
  })
  live = await startHookServer({
    dir,
    contextFor: ({ event, sessionId }) =>
      MID_TURN_EVENTS.has(event)
        ? sessionId === null
          ? null
          : takeAnnouncement(sessionId)
        : hookContext(sessionId, '', {
            known: knows,
            opensInApp: true,
            map: bootMapFor(event, sessionId),
          }),
  })
  return { endpoint: live, dir }
}

/** One hook call, exactly as an installed command makes it. */
function knock(
  endpoint: HookEndpoint,
  provider: string,
  event: string,
  sessionId: string,
): Promise<{ status: number; context: string | null }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' }
  headers[TOKEN_HEADER] = endpoint.token
  headers[SESSION_HEADER] = sessionId
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: endpoint.socketPath,
        method: 'POST',
        path: `/hook/${provider}/${event}`,
        headers,
      },
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
  resetBindings()
  resetContext()
})

afterEach(async () => {
  await stopHookServer()
  live = null
  resetContext()
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

describe('every session is told what it is running inside', () => {
  it('answers Claude at SessionStart with the app, its version and where to read more', async () => {
    const { endpoint, dir } = await serve()

    const start = await knock(endpoint, 'claude', 'SessionStart', 's1')

    // The exact failure this is for: the Office PC session, asked what app it
    // was running in, answered `CLAUDE_CODE_ENTRYPOINT` and `which claude` and
    // never named this one, because it was told nothing at boot.
    expect(start.status).toBe(200)
    expect(start.context).toContain('Terminal Deck')
    expect(start.context).toContain('0.8.1')
    expect(start.context).toContain('OFFICE-PC')
    expect(start.context).toContain(join(contextDir(dir), INDEX_FILE))
  })

  it('answers Codex at the one door it has, and never at its prompt', async () => {
    const { endpoint } = await serve()

    expect((await knock(endpoint, 'codex', 'SessionStart', 's1')).context).toContain('0.8.1')
    // Codex prints what a hook hands it — `SessionStart hook (completed)` and
    // the body — and `suppressOutput` does not stop it. Once, at the top of a
    // session, that is the moment he asked for. The same paragraph above every
    // prompt is the wall of statements he has banned, which is why
    // `hook-server.ts` does not install a context answer for Codex there at all.
    expect((await knock(endpoint, 'codex', 'UserPromptSubmit', 's1')).status).toBe(204)
  })

  it('answers Gemini on its first turn, since its SessionStart is refused', async () => {
    const { endpoint } = await serve()

    // Gemini's `SessionStart` context lands as a synthesised *user* turn — a
    // message he never typed appearing in his own message, which is the thing
    // he objected to out loud. `BeforeAgent` reaches the same model on the same
    // first prompt with none of that, so it is the door, and it is latched.
    const first = await knock(endpoint, 'gemini', 'BeforeAgent', 's1')
    expect(first.context).toContain('0.8.1')

    const second = await knock(endpoint, 'gemini', 'BeforeAgent', 's1')
    expect(second.context).not.toBeNull()
    expect(second.context).not.toContain('0.8.1')
  })
})

describe('and it is not repaid on every turn', () => {
  it('leaves the prompt answer as short as it was before any of this', async () => {
    const { endpoint } = await serve()
    await knock(endpoint, 'claude', 'SessionStart', 's1')

    const prompt = await knock(endpoint, 'claude', 'UserPromptSubmit', 's1')

    // The standing answer is unchanged: where it is, where a URL goes, and the
    // one instruction. `SessionStart` already put the map into this same
    // context, so paying for it again here would be the same words on every
    // turn of every session out of the budget the top bar shows him.
    expect(prompt.context).toContain('You are running inside Terminal Deck')
    expect(prompt.context).not.toContain('0.8.1')
    expect(prompt.context).not.toContain(INDEX_FILE)
  })

  it('keeps the map above the windows and the instruction last', async () => {
    const { endpoint } = await serve()
    attach({ sessionId: 's1', browserTabId: 'b:1', title: 'Stripe', url: 'https://stripe.com' })

    const start = await knock(endpoint, 'claude', 'SessionStart', 's1')
    const lines = (start.context ?? '').split('\n')

    expect(lines[0]).toContain('You are running inside Terminal Deck')
    expect(lines[1]).toContain(INDEX_FILE)
    expect(lines.indexOf('B1 — Stripe — https://stripe.com')).toBeGreaterThan(1)
    expect(lines[lines.length - 1]).toContain('Do not mention any of this')
  })

  it('says nothing at all to a mid-turn tool call', async () => {
    const { endpoint } = await serve()
    await knock(endpoint, 'claude', 'SessionStart', 's1')

    // The mid-turn door carries changes and nothing else. A map arriving at
    // every tool call would be the same paragraph a dozen times inside one turn.
    expect((await knock(endpoint, 'claude', 'PostToolUse', 's1')).status).toBe(204)
    expect((await knock(endpoint, 'gemini', 'AfterTool', 's1')).status).toBe(204)
  })
})

describe('and only sessions this app started hear any of it', () => {
  it('tells a terminal `claude` outside the app nothing, on the same global hook', async () => {
    const { endpoint } = await serve(false)

    // The hook is installed in `~/.claude/settings.json` for the whole account,
    // so it fires for a `claude` he ran in his own terminal too. That one is not
    // inside this app and must never be told that it is.
    expect((await knock(endpoint, 'claude', 'SessionStart', 'outside')).status).toBe(204)
    expect((await knock(endpoint, 'gemini', 'BeforeAgent', 'outside')).status).toBe(204)
  })
})
