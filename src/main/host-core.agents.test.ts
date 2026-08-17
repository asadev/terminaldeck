import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createHostCore, type HostCore } from './host-core'
import type { ProviderId } from '../shared/types'

/**
 * An added agent, started by the one function that starts sessions.
 *
 * The bug this pins is a silent one and it is the whole reason the wiring goes
 * through `host-core.ts` rather than through the Electron shell.
 * `startSession` chooses its agent with `available[requested] ? requested :
 * 'shell'`, and `detectProviders` answers about the agents in the catalogue —
 * so an id it has never had reads `undefined`, falls to the fallback, and a
 * person who added an agent and pressed Start gets a plain shell with nothing
 * said. `startSession`'s own comments call that failure out twice; this is the
 * third way it could have arrived.
 *
 * A real core, a real pty and a real command, because every part of the chain
 * that could be stubbed here is a part that has been wrong before: the launcher
 * that wraps a command for Windows, the lookup that decides whether a command
 * can run, and the fallback itself.
 *
 * `/bin/echo` on POSIX and `cmd.exe /c` on Windows, resolved as an *absolute
 * path* — which is the branch of `lookupCommand` that checks the executable bit
 * rather than shelling out to `which`, so this test never depends on what
 * happens to be installed on the machine running it.
 */

const windows = process.platform === 'win32'
const REAL_COMMAND = windows ? `${process.env.SystemRoot ?? 'C:\\Windows'}\\System32\\cmd.exe` : '/bin/echo'

let dir = ''
let core: HostCore

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-agents-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })

  const added = await core.agents.add({
    label: 'Echo',
    description: '',
    command: REAL_COMMAND,
    args: 'hello',
    resumeArgs: '',
  })
  expect(added.ok, 'the fixture agent has to be addable, or nothing below means anything').toBe(true)
}, 30_000)

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  rmSync(dir, { recursive: true, force: true })
})

describe('starting a session on an agent somebody added', () => {
  it('runs that agent, rather than quietly becoming a shell', async () => {
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })

    expect(meta.provider).toBe('custom:echo')
    // The tell for the bug: `shell` here means the session started, looked
    // fine, and was not the agent that was asked for.
    expect(meta.provider).not.toBe('shell')
  })

  it('falls back to a shell for an added agent that is no longer there', async () => {
    // Not a row in the store at all — the same state as an agent removed in
    // another window, or a session restored from a machine that had one.
    const meta = await core.startSession({
      cwd: dir,
      cols: 80,
      rows: 24,
      provider: 'custom:never-existed' as ProviderId,
    })

    expect(meta.provider).toBe('shell')
  })

  it('records no account against it, because none was isolated', async () => {
    // `supportsProfiles` is false for an agent whose config directory this app
    // cannot redirect, and an added agent is exactly that. Labelling the session
    // with an account name would be a claim about isolation nothing made happen.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })
    expect(meta.profileId).toBeUndefined()
    expect(meta.profileName).toBeUndefined()
  })
})

describe('whether a provider can continue a conversation', () => {
  it('answers for an added agent from its own record', () => {
    // Empty resume arguments is the default and the safe answer, so the picker
    // must not offer resume for it.
    expect(core.canContinue('custom:echo')).toBe(false)
  })

  it('still answers for the agents this build ships', () => {
    expect(core.canContinue('claude')).toBe(true)
    expect(core.canContinue('shell')).toBe(false)
  })

  it('answers false for a name nothing knows, instead of throwing', () => {
    /*
     * This is the crash, not a nicety. Both shells asked
     * `PROVIDERS[provider].resumeArgs` while planning a restore, which throws
     * outright on an id the table has never had — so one saved session naming an
     * added agent took the whole restore down with it, and every other tab in
     * the list with it.
     */
    expect(() => core.canContinue('custom:gone')).not.toThrow()
    expect(core.canContinue('custom:gone')).toBe(false)
    expect(core.canContinue('retired-agent' as ProviderId)).toBe(false)
  })
})
