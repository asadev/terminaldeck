import { readFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, resetPaths } from './platform/paths'
import { resetProfilesCache } from './profiles'
import { configureSessionAccounts, sessionAccount, type SessionAccountDeps } from './session-account'
import type { SessionMeta } from '../shared/types'

/**
 * The assembly seam, which is where the fifth account surface was actually
 * broken.
 *
 * `agent-controls.ts` was handed the `PtyManager` directly, and a pty can answer
 * two of the three questions that module asks: what is on the screen, and what
 * can be typed at it. The third — *which login is the agent in this session
 * running as* — nothing was asked, so every file it reads (`settings.json`,
 * `permissions.defaultMode`, the project's transcripts) came out of this app
 * process's own store for every session alike. On a machine with two logins the
 * model, effort, fast mode and permission mode on the bar described whichever
 * account this app had resolved, not the one in front of the person.
 *
 * The module-level fix is pinned in `agent-controls.test.ts` against a
 * `SessionAccess` built by hand. What is pinned here is that the *real* one
 * carries the answer — because a seam that exists and is not wired is exactly
 * the shape of the original defect, and both shells reach it through this one
 * object rather than each assembling their own.
 */

let dir: string
let core: HostCore

const SESSION: SessionMeta = {
  id: 'sess-core-account',
  title: 'zsh',
  cwd: '/Users/apple/Projects/demo',
  provider: 'shell',
  exitCode: null,
  createdAt: 1,
}

/** A `ps` reporting one `claude` under the pty, reading `dir`. */
function agentOn(store: string): SessionAccountDeps {
  return {
    pidOf: () => 4242,
    describeSession: () => SESSION,
    platform: 'darwin',
    exec: (_command, args) =>
      Promise.resolve(
        args[0] === '-Ao'
          ? ' 5000 4242 claude\n 4242    1 -zsh\n'
          : `  PID   TT  STAT      TIME COMMAND\n 5000 s001  S+     0:01 claude ` +
            `PATH=/usr/bin CLAUDE_CONFIG_DIR=${store} HOME=${homedir()}\n`,
      ),
  }
}

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'terminaldeck-core-account-'))
  mkdirSync(join(dir, 'remote'), { recursive: true })
  resetPaths()
  installPaths({
    userData: () => dir,
    home: () => dir,
    downloads: () => dir,
    appRoot: () => dir,
  })
  resetProfilesCache()
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })
})

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  configureSessionAccounts(null)
  resetPaths()
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

describe('the SessionAccess the core hands the controls', () => {
  it('answers with the store the session’s own agent is reading', async () => {
    configureSessionAccounts(agentOn('/tmp/work-store'))
    await sessionAccount(SESSION.id)
    expect(core.controlAccess.configDir?.(SESSION.id)).toBe('/tmp/work-store')
  })

  it('answers null for a session nothing has been established about', () => {
    // Which is every session on its first read, and every session in the
    // headless build — where nothing configures the ladder at all. Null is what
    // leaves `agent-controls.ts` on the fallback that shipped.
    configureSessionAccounts(null)
    expect(core.controlAccess.configDir?.('nobody')).toBeNull()
  })

  it('still writes and reads the screen through the pty, unchanged', async () => {
    // The other two rungs of the same seam. A session that is not running has
    // no screen, which is the answer `readControls` turns into "no longer
    // running" rather than into a set of confident readings.
    expect(await core.controlAccess.screen('nobody')).toBeNull()
    expect(() => core.controlAccess.write('nobody', 'x')).not.toThrow()
  })
})

describe('both shells reach the controls through that one object', () => {
  it('is what the window’s IPC is registered with, not the raw PtyManager', () => {
    const source = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(source).toContain('registerAgentControlsIpc(ipcMain, core.controlAccess)')
  })

  it('is what a window on a paired machine is served through too', () => {
    /*
     * `host-core.ts`'s own `controls` seam answers the remote protocol. Reading
     * it through the raw `ptys` would leave the phone naming a different
     * account's model than the desktop three feet from it — the same
     * disagreement, at a longer distance.
     */
    const source = readFileSync(join(__dirname, 'host-core.ts'), 'utf8')
    expect(source).toContain('readControls(controlAccess, id, row?.cwd, row?.provider)')
    expect(source).toContain('applyControl(controlAccess, {')
  })
})
