import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  CUSTOM_AGENTS_FILE,
  CustomAgentStore,
  MAX_CUSTOM_AGENTS,
  registerCustomAgentsIpc,
} from './custom-agents'
import { customProviderSpec } from './providers'
import { customEntry, isCustomProviderId } from '../shared/custom-agents'
import { AGENT_ENTRIES } from '../shared/agent-catalog'

/**
 * The agents somebody added, and the one rule that makes them honest.
 *
 * The catalogue's rule has no exceptions — never declare an agent that has not
 * been launched — and a form that took any string would drive straight through
 * it, putting a row in the New-session picker that dies on selection. That is
 * the recorded bug this whole area was opened to fix: pressing Add on a Codex
 * account opened a blank terminal that printed a Node `ENOENT` stack trace, five
 * times in one session.
 *
 * So the interesting assertions here are not "the file round-trips". They are:
 * a command this machine cannot run never reaches the file; a command it can run
 * is recorded with the path it resolved to; and the entry the rest of the app
 * then reads withdraws every feature nobody has measured, rather than claiming
 * them and failing later.
 */

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-agents-'))
}

/** A lookup that finds exactly the commands named, and nothing else. */
const finds = (...commands: string[]) => {
  return async (command: string): Promise<string | null> =>
    commands.includes(command) ? `/usr/local/bin/${command}` : null
}

const draft = (over: Partial<Record<string, string>> = {}): Record<string, string> => ({
  label: 'Grok',
  description: 'Grok from the command line.',
  command: 'grok',
  args: '',
  resumeArgs: '',
  ...over,
})

describe('adding an agent', () => {
  it('refuses a command this machine cannot run, and says which command', async () => {
    const dir = tempDir()
    const store = new CustomAgentStore(dir, { lookup: finds() })

    const outcome = await store.add(draft())

    expect(outcome.ok).toBe(false)
    if (!outcome.ok) {
      // Under `command`, because that is the field the person has to change.
      expect(outcome.problems.command).toContain('grok')
      expect(outcome.problems.label).toBeUndefined()
    }
    expect(store.list()).toEqual([])
    // Nothing written at all: a refused agent must not leave a file behind that
    // a later launch reads back as a real one.
    expect(() => readFileSync(join(dir, CUSTOM_AGENTS_FILE), 'utf8')).toThrow()
  })

  it('records where the command resolved, as the evidence for the entry', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })

    const outcome = await store.add(draft())

    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return
    expect(outcome.agent.resolvedPath).toBe('/usr/local/bin/grok')
    expect(isCustomProviderId(outcome.agent.id)).toBe(true)
    // Derived from the name, so the id in `state.json` is one a person can
    // recognise — see `customAgentId`.
    expect(outcome.agent.id).toBe('custom:grok')
  })

  it('splits arguments the way the form previewed them', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })

    const outcome = await store.add(
      draft({ args: '--model fast --system-prompt "answer in French"' }),
    )

    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return
    // The quoted pair is one argument. Splitting on whitespace would send two,
    // and the preview under the field would have been a lie.
    expect(outcome.agent.args).toEqual([
      '--model',
      'fast',
      '--system-prompt',
      'answer in French',
    ])
  })

  it('will not take a name a shipped agent already has', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })

    const outcome = await store.add(draft({ label: 'Claude Code' }))

    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.problems.label).toContain('Claude Code')
    // The builtin labels come from the catalogue rather than being typed here,
    // so an agent renamed there cannot leave this check pointing at nothing.
    expect(AGENT_ENTRIES.map((entry) => entry.label)).toContain('Claude Code')
  })

  it('will not take a name another added agent already has', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok', 'amp') })

    expect((await store.add(draft())).ok).toBe(true)
    const second = await store.add(draft({ command: 'amp' }))

    expect(second.ok).toBe(false)
    if (!second.ok) expect(second.problems.label).toBeDefined()
  })

  it('refuses a command line where a command belongs', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok --yes') })

    // The lookup would happily "find" it; the validation never gets that far,
    // which is the point — a shell metacharacter is refused before anything
    // this machine can run is consulted.
    const outcome = await store.add(draft({ command: 'grok --yes' }))

    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.problems.command).toContain('Just the program')
  })

  it('stops at the cap rather than growing a file the app reads at every start', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: async () => '/usr/local/bin/x' })

    for (let index = 0; index < MAX_CUSTOM_AGENTS; index += 1) {
      const outcome = await store.add(draft({ label: `Agent ${index}`, command: `agent${index}` }))
      expect(outcome.ok).toBe(true)
    }
    const overflow = await store.add(draft({ label: 'One too many', command: 'extra' }))

    expect(overflow.ok).toBe(false)
    expect(store.list()).toHaveLength(MAX_CUSTOM_AGENTS)
  })
})

describe('the file', () => {
  it('survives a restart', async () => {
    const dir = tempDir()
    const first = new CustomAgentStore(dir, { lookup: finds('grok') })
    await first.add(draft())

    const second = new CustomAgentStore(dir, { lookup: finds() })

    expect(second.list().map((agent) => agent.label)).toEqual(['Grok'])
    // The lookup is deliberately not re-run on load. An agent uninstalled since
    // it was added must still be *listed* — it is re-checked where it matters,
    // at the session start and by the picker — because silently dropping a row
    // somebody added is a list that edits itself.
    expect(second.list()[0].command).toBe('grok')
  })

  it('drops one bad entry rather than the whole list', async () => {
    const dir = tempDir()
    const store = new CustomAgentStore(dir, { lookup: finds('grok') })
    await store.add(draft())

    // A hand-edited file with a shell metacharacter in one command. That is the
    // one place such a command could arrive without passing the form.
    const file = join(dir, CUSTOM_AGENTS_FILE)
    const state = JSON.parse(readFileSync(file, 'utf8')) as { agents: unknown[] }
    state.agents.push({
      id: 'custom:evil',
      label: 'Evil',
      description: '',
      command: 'rm -rf ~ & echo',
      args: [],
      resumeArgs: [],
      addedAt: 1,
      resolvedPath: '/bin/sh',
    })
    writeFileSync(file, JSON.stringify(state), 'utf8')

    const reopened = new CustomAgentStore(dir, { lookup: finds() })

    expect(reopened.list().map((agent) => agent.id)).toEqual(['custom:grok'])
  })

  it('reads an unreadable file as no agents rather than throwing at launch', () => {
    const dir = tempDir()
    writeFileSync(join(dir, CUSTOM_AGENTS_FILE), '{ not json', 'utf8')

    expect(() => new CustomAgentStore(dir)).not.toThrow()
    expect(new CustomAgentStore(dir).list()).toEqual([])
  })

  it('forgets one on request, and only that one', async () => {
    const dir = tempDir()
    const store = new CustomAgentStore(dir, { lookup: async () => '/usr/local/bin/x' })
    await store.add(draft())
    await store.add(draft({ label: 'Amp', command: 'amp' }))

    expect(store.remove('custom:grok')).toBe(true)
    expect(store.remove('custom:grok')).toBe(false)
    expect(store.list().map((agent) => agent.id)).toEqual(['custom:amp'])
    expect(new CustomAgentStore(dir).list().map((agent) => agent.id)).toEqual(['custom:amp'])
  })
})

describe('what the rest of the app reads', () => {
  it('withdraws every feature nobody has measured, rather than claiming it', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })
    const outcome = await store.add(draft())
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    const entry = customEntry(outcome.agent)

    // Each of these is read by a screen, and each null is what stops that screen
    // offering something this build cannot do for an agent it has never seen.
    expect(entry.statusArgs).toBeNull()
    expect(entry.statusFormat).toBeNull()
    expect(entry.signInArgs).toBeNull()
    expect(entry.configEnv).toBeNull()
    expect(entry.credentialFile).toBeNull()
    expect(entry.versionArgs).toBeNull()
    expect(entry.install).toBeNull()
    expect(entry.url).toBeNull()
    // `unmeasured`, never `none`: `none` would be a claim that this agent has no
    // login, and half the CLIs somebody would add do have one.
    expect(entry.logins).toBe('unmeasured')
    expect(entry.loginsNote).not.toBeNull()
    // Every entry has to say what was run and what answered. For an added agent
    // that is the lookup, and the path it produced.
    expect(entry.verified).toContain('/usr/local/bin/grok')
  })

  it('spawns through the same launcher the shipped agents do', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })
    const outcome = await store.add(draft({ args: '--fast', resumeArgs: '--continue' }))
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    const mac = customProviderSpec(outcome.agent, 'darwin', {})
    expect(mac.spawn).toEqual({ command: 'grok', args: ['--fast'], resumeArgs: ['--continue'] })

    // Windows cannot `CreateProcess` an npm `.cmd` shim, so the command goes
    // through the command processor exactly as it does for Claude Code. This is
    // the whole reason `customProviderSpec` calls the same function rather than
    // building a spawn of its own: the agent nobody here has tested must not get
    // the launch path nobody here has tested either.
    const windows = customProviderSpec(outcome.agent, 'win32', { COMSPEC: 'cmd.exe' })
    expect(windows.spawn.command).toBe('cmd.exe')
    expect(windows.spawn.args).toEqual(['/c', 'grok', '--fast'])
    expect(windows.spawn.resumeArgs).toEqual(['/c', 'grok', '--continue'])
  })

  it('offers no resume when no resume arguments were given', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })
    const outcome = await store.add(draft())
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    // Empty is the default and the safe answer: a resume flag that errors in a
    // folder with no history kills the tab with no explanation.
    expect(customEntry(outcome.agent).resumeArgs).toEqual([])
    expect(customProviderSpec(outcome.agent, 'darwin', {}).spawn.resumeArgs).toEqual([])
  })
})

describe('the ipc surface', () => {
  it('registers the three channels the preload calls, and no bulk write', async () => {
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })

    registerCustomAgentsIpc(
      {
        handle: (channel: string, handler: (event: unknown, ...args: unknown[]) => unknown) => {
          handlers.set(channel, handler)
        },
      } as unknown as Parameters<typeof registerCustomAgentsIpc>[0],
      store,
    )

    expect([...handlers.keys()].sort()).toEqual(['agents:add', 'agents:list', 'agents:remove'])

    const added = (await handlers.get('agents:add')?.(null, draft())) as { ok: boolean }
    expect(added.ok).toBe(true)
    expect(handlers.get('agents:list')?.(null)).toHaveLength(1)

    // A remove is only ever a custom id. Anything else is refused rather than
    // searched for, so a stray `'claude'` cannot become a no-op that looks like
    // it worked.
    expect(handlers.get('agents:remove')?.(null, 'claude')).toBe(false)
    expect(handlers.get('agents:remove')?.(null, 42)).toBe(false)
    expect(handlers.get('agents:remove')?.(null, 'custom:grok')).toBe(true)
  })
})
