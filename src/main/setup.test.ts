import { describe, expect, it } from 'vitest'
import { composeSetup, SETUP_TOOL_IDS, type SetupInput } from './setup'
import { HOOK_PROVIDERS } from './hooks'
import type { HookProviderStatus } from './hooks'
import type { ProbeResult } from './tool-probe'
import type { Prerequisites } from './prerequisites'

/**
 * `composeSetup` is where the panel's three rules live — what order the tools
 * come in, when a probe is shown, and what never crosses the bridge — so it is
 * pure and tested here rather than inferred from a screenshot.
 */

const probe: ProbeResult = {
  command: 'which codex',
  output: 'codex not found',
  exitCode: 1,
  found: false,
  line: 'codex not found',
}

const prerequisites: Prerequisites = {
  canRunSessions: true,
  needsLogin: false,
  tools: [
    { id: 'claude', label: 'Claude Code', state: 'ready', purpose: 'Run Claude Code sessions', required: false },
    { id: 'codex', label: 'Codex CLI', state: 'missing', purpose: 'Run OpenAI Codex sessions', required: false },
    { id: 'gemini', label: 'Gemini CLI', state: 'ready', purpose: 'Run Gemini CLI sessions', required: false },
    { id: 'git', label: 'Git', state: 'ready', purpose: 'Branch and change tracking', required: false },
  ],
}

function hookStatus(id: 'claude' | 'codex' | 'gemini', over: Partial<HookProviderStatus> = {}): HookProviderStatus {
  return {
    id,
    label: HOOK_PROVIDERS[id].label,
    file: `/home/${id}/settings.json`,
    fileExists: true,
    state: 'none',
    installedEvents: [],
    staleEvents: [],
    missingEvents: [...HOOK_PROVIDERS[id].events],
    foreignHooks: 0,
    foreignOwners: [],
    backupPath: null,
    message: 'No hooks from this app in this file yet.',
    ...over,
  }
}

function build(over: Partial<SetupInput> = {}) {
  return composeSetup({
    prerequisites,
    copilot: { state: 'missing', route: null, probe: { ...probe, command: 'which copilot', line: 'copilot not found' } },
    probes: { codex: probe },
    hooks: [hookStatus('claude'), hookStatus('codex'), hookStatus('gemini')],
    endpoint: { socketPath: '/tmp/terminaldeck-test/hook.sock' },
    now: 1,
    ...over,
  })
}

describe('the tool list', () => {
  it('answers for every supported tool, in one order', () => {
    expect(build().tools.map((tool) => tool.id)).toEqual([...SETUP_TOOL_IDS])
  })

  it('shows the literal probe only for a tool it could not find', () => {
    const tools = new Map(build().tools.map((tool) => [tool.id, tool]))
    expect(tools.get('codex')?.probe?.line).toBe('codex not found')
    expect(tools.get('claude')?.probe).toBeNull()
  })

  /**
   * A binary that is there and will not start prints what it said, not what a
   * lookup found.
   *
   * The lookup *succeeds* in that case — `which codex` resolves the npm
   * launcher perfectly well — so printing `/opt/homebrew/bin/codex` under a row
   * headed "Not found" reads as a contradiction rather than as evidence. The
   * failed launch is the thing worth quoting, and it is the only place in this
   * app that quotes it: the account row and the remedy line are both plain
   * sentences, because the machine's own words were the entire error message
   * the user was given and he could not read them.
   */
  it('prefers what a failed launch said over what the lookup found', () => {
    const snapshot = build({
      prerequisites: {
        ...prerequisites,
        tools: prerequisites.tools.map((tool) =>
          tool.id === 'codex'
            ? {
                ...tool,
                remedy: 'Codex CLI is installed at /opt/homebrew/bin/codex but will not start.',
                evidence: 'Error: spawn /opt/homebrew/.../codex ENOENT',
              }
            : tool,
        ),
      },
    })
    const codex = snapshot.tools.find((tool) => tool.id === 'codex')
    expect(codex?.probe?.line).toContain('ENOENT')
    expect(codex?.probe?.command).toBe('codex --version')
  })

  /**
   * A note is not a remedy, and it survives the trip.
   *
   * The one note today says an agent is running from a copy other than the one
   * on the user's PATH. Dropping it here would leave a person to discover that
   * by watching `codex` fail in their own terminal and work in this app.
   */
  it('carries a caveat that is true even when the tool is fine', () => {
    const snapshot = build({
      prerequisites: {
        ...prerequisites,
        tools: prerequisites.tools.map((tool) =>
          tool.id === 'claude' ? { ...tool, note: 'Runs from /elsewhere/claude.' } : tool,
        ),
      },
    })
    expect(snapshot.tools.find((tool) => tool.id === 'claude')?.note).toBe(
      'Runs from /elsewhere/claude.',
    )
  })

  it('does not contradict itself when Copilot came in through gh', () => {
    // `which copilot` fails on a machine that has the gh extension, so the
    // probe would sit under the word "Installed" saying the opposite.
    const snapshot = build({
      copilot: {
        state: 'ready',
        route: 'gh-extension',
        probe: { ...probe, command: 'which copilot', line: 'copilot not found' },
      },
    })
    expect(snapshot.tools.find((tool) => tool.id === 'copilot')).toMatchObject({
      state: 'ready',
      probe: null,
    })
  })

  it('says plainly that Copilot is detected but not spawned here', () => {
    // `providers.ts` has no Copilot entry, so a session cannot run it.
    expect(build().tools.find((tool) => tool.id === 'copilot')?.note).toContain('Detected only')
  })

  it('still lists a tool the prerequisites answer never mentioned', () => {
    const snapshot = build({ prerequisites: { ...prerequisites, tools: [] } })
    expect(snapshot.tools.map((tool) => tool.id)).toEqual([...SETUP_TOOL_IDS])
    expect(snapshot.tools[0].state).toBe('unknown')
  })
})

describe('the hook blocks', () => {
  it('uses each provider’s own event names, in the order it fires them', () => {
    const blocks = new Map(build().hooks.map((block) => [block.id, block]))
    expect(blocks.get('claude')?.events).toEqual(HOOK_PROVIDERS.claude.events)
    // Gemini names its lifecycle Before/After where Claude names it Pre/Post,
    // and Codex has five events where Claude has ten.
    expect(blocks.get('gemini')?.events).toContain('AfterTool')
    expect(blocks.get('codex')?.events).toHaveLength(5)
  })

  it('keeps a provider’s extra requirement with it', () => {
    const codex = build().hooks.find((block) => block.id === 'codex')
    // `codex_hooks` was renamed to `hooks` in Codex 0.146 — the old key still
    // works and now prints a deprecation line into the terminal at every session
    // start, so this page must not keep asking for it. The trust step is the
    // other half: an installed Codex hook does not run until it is trusted once.
    expect(codex?.requirement).toContain('`hooks = true`')
    expect(codex?.requirement).not.toContain('codex_hooks')
    expect(codex?.requirement).toContain('Trust')
  })

  /**
   * Copilot is named once on this page, not twice.
   *
   * It used to get a hook block of its own whose whole content was "there is
   * nothing to install" — no events, no file, no buttons — directly under a tool
   * row already headed "GitHub Copilot". One page, one tool, two headings, and
   * the second one existed only to say it had nothing to say. That is the
   * *"what are these repeats?"* from the recording.
   *
   * The sentence survives, on the row it belongs to. Both halves are asserted,
   * because deleting the block and losing the fact would be the other bug.
   */
  it('gives Copilot a tool row and no hook block of its own', () => {
    const snapshot = build()
    expect(snapshot.hooks.find((block) => block.id === 'copilot')).toBeUndefined()
    const row = snapshot.tools.find((tool) => tool.id === 'copilot')
    expect(row?.note).toContain('no session-hook configuration')
  })

  it('passes through the counts the status reported, without recounting', () => {
    const snapshot = build({
      hooks: [
        hookStatus('claude', {
          state: 'stale',
          installedEvents: ['SessionStart'],
          staleEvents: ['Stop'],
          missingEvents: [],
        }),
      ],
    })
    expect(snapshot.hooks[0]).toMatchObject({
      state: 'stale',
      installedEvents: ['SessionStart'],
      staleEvents: ['Stop'],
    })
  })
})

describe('the endpoint', () => {
  it('reports the address and nothing else — the token stays in the main process', () => {
    expect(Object.keys(build().endpoint).sort()).toEqual(['address', 'running'])
    expect(build().endpoint).toEqual({
      running: true,
      address: '/tmp/terminaldeck-test/hook.sock',
    })
  })

  it('says it is not running rather than inventing an address', () => {
    expect(build({ endpoint: null }).endpoint).toEqual({ running: false, address: null })
  })
})
