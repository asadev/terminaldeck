import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  CUSTOM_AGENTS_FILE,
  CustomAgentStore,
  MAX_CUSTOM_AGENTS,
  lookupCommand,
  registerCustomAgentsIpc,
} from './custom-agents'
import { customProviderSpec } from './providers'
import { wslExePath } from './wsl'
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

/* --------------------------------------- a command a Windows user would type -- */

/**
 * The half of this feature that did not exist on the platform it shipped to.
 *
 * `validateDraft` refused any command containing a backslash, on the reasoning
 * that a backslash is a shell character and "nothing in this repository runs on
 * Windows". Both halves were wrong: a signed Windows installer ships from every
 * tag, and a backslash is not a metacharacter to `cmd.exe`, it is the path
 * separator. The effect was that **every absolute path on Windows was refused**
 * — while the refusal for a name that is neither told the person to "give the
 * full path to it", which on that platform was advice that could not be
 * followed. A program not on PATH could not be added at all.
 *
 * It was found by CI rather than by a user: the fixture in
 * `host-core.agents.test.ts` adds an agent so that everything below it means
 * something, and on the Windows runner it could not add one.
 *
 * These run everywhere, because none of them touch the filesystem — the rule is
 * a string rule and it is the same rule on both platforms. What is pinned is the
 * pair: the ordinary Windows path is accepted, and every shape that was only
 * ever refused *incidentally* by the backslash is still refused on its own
 * merits.
 */
describe('a command a Windows user would actually type', () => {
  const WINDOWS_PATH = 'C:\\tools\\agent.exe'

  /** Like `finds`, but answering with the path itself — an absolute one is
   *  already where it resolved to, and `/usr/local/bin/C:\…` is not a place. */
  const findsPath = (...commands: string[]) => {
    return async (command: string): Promise<string | null> =>
      commands.includes(command) ? command : null
  }

  it('takes an absolute Windows path, which the backslash ban used to refuse', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: findsPath(WINDOWS_PATH) })

    const outcome = await store.add(draft({ command: WINDOWS_PATH }))

    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return
    expect(outcome.agent.command).toBe(WINDOWS_PATH)
  })

  it('takes a path as an argument, which most Windows arguments are', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: finds('grok') })

    const outcome = await store.add(draft({ args: '--config C:\\tools\\agent.json' }))

    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return
    expect(outcome.agent.args).toEqual(['--config', 'C:\\tools\\agent.json'])
  })

  it('still refuses a UNC path, which is a launch off somebody else’s file server', async () => {
    const store = new CustomAgentStore(tempDir(), {
      lookup: findsPath('\\\\server\\share\\agent.exe'),
    })

    const outcome = await store.add(draft({ command: '\\\\server\\share\\agent.exe' }))

    // Refused by the *shape* rule rather than by the character, which is what
    // was actually doing the work worth keeping: it is neither a bare name nor
    // a drive-letter path.
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.problems.command).toContain('neither a plain command name')
  })

  it('still refuses a relative path with a separator in it', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: async () => 'C:\\anything' })

    for (const command of ['tools\\agent.exe', '..\\agent.exe', 'tools/agent']) {
      const outcome = await store.add(draft({ command }))
      expect(outcome.ok, command).toBe(false)
      if (!outcome.ok) expect(outcome.problems.command, command).toBeDefined()
    }
  })

  it('still refuses what cmd.exe would read as an instruction', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: async () => 'C:\\anything' })

    // `cmd.exe /c <command> <args…>` is one command line, so each of these
    // would be two commands there. The backslash never belonged in this list;
    // these do, and they are still in it.
    for (const command of [
      'C:\\tools\\agent.exe&del',
      'C:\\tools\\agent.exe|more',
      'C:\\tools\\%USERNAME%.exe',
      'C:\\tools\\agent^.exe',
      'C:\\tools\\(agent).exe',
    ]) {
      const outcome = await store.add(draft({ command }))
      expect(outcome.ok, command).toBe(false)
      if (!outcome.ok) expect(outcome.problems.command, command).toContain('Just the program')
    }
  })

  it('goes through cmd.exe and through wsl.exe exactly as a shipped agent does', async () => {
    const store = new CustomAgentStore(tempDir(), { lookup: findsPath(WINDOWS_PATH) })
    const outcome = await store.add(draft({ command: WINDOWS_PATH, args: '--fast' }))
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    // The path survives into the argument list intact — no quoting scheme of
    // this app's own invention, because node-pty's `argsToCommandLine` already
    // implements the Windows argv rules and a second one here would be a second
    // thing to keep in step with it.
    const windows = customProviderSpec(outcome.agent, 'win32', { COMSPEC: 'cmd.exe' })
    expect(windows.spawn.command).toBe('cmd.exe')
    expect(windows.spawn.args).toEqual(['/c', WINDOWS_PATH, '--fast'])

    // And inside a distribution it is `wsl.exe`, from the same `launcher` the
    // catalogue agents go through — which is the whole reason that function was
    // lifted out of `providersFor` rather than copied.
    const distro = customProviderSpec(outcome.agent, 'win32', { COMSPEC: 'cmd.exe' }, {
      distro: 'Ubuntu',
      cwd: '/home/asad/proj',
    })
    // The launcher is `wsl.exe`, by whatever path this machine finds it at.
    // `wslExePath` returns the absolute `System32` path when the file is
    // really there and the bare name when it is not — so a literal `wsl.exe`
    // here asserted "this suite is running on a machine without WSL", which
    // is true on the Mac these tests were written on and false on the Windows
    // runner that gates the release. Asking the same function for the answer
    // states the rule instead of the platform.
    expect(distro.spawn.command).toBe(wslExePath({ COMSPEC: 'cmd.exe' }))
    expect(distro.spawn.args.join(' ')).toContain('Ubuntu')
    expect(distro.spawn.hostCwd).toBeDefined()
  })
})

/* ------------------------------------------- resolving a path on Windows -- */

/**
 * `access(X_OK)` is not an executability check on Windows, so something else
 * has to be.
 *
 * libuv has no execute bit to consult there, so the mode is ignored and `X_OK`
 * behaves as `F_OK` — measured on Windows 11 with Node 26.7.0, where
 * `accessSync` on a plain `.txt` returns rather than throwing. Before this
 * mattered the point was moot, because no Windows path could reach the lookup at
 * all; now that one can, a person pointing the form at a readme would otherwise
 * get a picker row that dies on selection — the exact failure this module
 * exists to prevent.
 *
 * Both platforms run these: the file really is created, and the platform is
 * passed in rather than read, which is how every other Windows decision in this
 * tree is pinned from a Mac.
 */
describe('whether Windows would execute what was typed', () => {
  const file = (name: string): string => {
    const path = join(tempDir(), name)
    // 0700 so the POSIX half of `access(X_OK)` is satisfied on the Mac this is
    // usually run on; on Windows the mode is a no-op and the extension is the
    // whole question.
    writeFileSync(path, '', { mode: 0o700 })
    return path
  }

  it('takes a path whose extension PATHEXT names', async () => {
    for (const name of ['agent.exe', 'agent.CMD', 'agent.bat']) {
      const path = file(name)
      expect(await lookupCommand(path, 'win32', { PATHEXT: '.COM;.EXE;.BAT;.CMD' }), name).toBe(path)
    }
  })

  it('refuses a file Windows would never run, however readable it is', async () => {
    for (const name of ['notes.txt', 'agent', 'agent.json']) {
      const path = file(name)
      expect(await lookupCommand(path, 'win32', { PATHEXT: '.COM;.EXE;.BAT;.CMD' }), name).toBeNull()
    }
  })

  it('falls back to the four Windows itself falls back to, rather than to anything', async () => {
    // An environment with no PATHEXT is a stripped one — a service, a scheduled
    // task — not a permissive one.
    expect(await lookupCommand(file('agent.exe'), 'win32', {})).not.toBeNull()
    expect(await lookupCommand(file('agent.txt'), 'win32', {})).toBeNull()
  })

  it('reads PATHEXT however the environment spelled it', async () => {
    // Windows environment names are case-insensitive and `process.env` mirrors
    // that; a copied object does not. Same hazard `withPath` exists for.
    const path = file('agent.vbs')
    expect(await lookupCommand(path, 'win32', { PathExt: '.EXE;.VBS' })).toBe(path)
  })

  it('asks none of this on POSIX, where an extension means nothing', async () => {
    const runnable = file('agent')
    expect(await lookupCommand(runnable, 'darwin', {})).toBe(runnable)
  })

  /*
   * The other half of that sentence, and it can only be asked where the bit
   * exists. Windows has no execute bit for `access` to consult, so this file
   * would resolve there — which is not a softer version of this assertion, it
   * is the reason the Windows branch above had to be written at all.
   */
  it.skipIf(process.platform === 'win32')('refuses a file with no execute bit on POSIX', async () => {
    const plain = join(tempDir(), 'agent')
    writeFileSync(plain, '', { mode: 0o600 })
    expect(await lookupCommand(plain, 'darwin', {})).toBeNull()
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
