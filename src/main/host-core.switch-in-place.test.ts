import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import type { SessionMeta } from '../shared/types'

/**
 * Switching a running Claude Code session's account in place, through the real
 * host core: a real pty, the real vault socket and shim, the real switch.
 *
 * The agent is a stand-in — a shell script named `claude` that, for every line
 * typed into it, asks `security` for its login exactly the way Claude Code
 * does (`find-generic-password -w -s "Claude Code-credentials-<hash of its
 * CLAUDE_CONFIG_DIR>"`) and prints the answer, beside its own PID. The real CLI
 * against the same machinery is `account-vault/switch-in-place.cli.test.ts`.
 *
 * Nothing real is reached: the data folder is scratch, the logins are made up,
 * the "real" `security` behind the shim is a script that answers "not found",
 * and `loginPath` is pinned to a folder holding only the stand-in, with the
 * agent table taken as written rather than probed — so neither the real
 * `claude` nor any other agent binary on this machine is ever run.
 */

const darwin = process.platform === 'darwin'
const root = mkdtempSync('/tmp/tdhc-')
const fakeBin = join(root, 'bin')

vi.mock('./providers', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./providers')>()
  return {
    ...actual,
    loginPath: async () => `${fakeBin}:/usr/bin:/bin`,
    detectProviders: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
    // The pure table, with no probing: the real one asks every agent's binary
    // for its version — including a fallback copy of Codex inside the owner's
    // own Codex folder — and nothing here may run that.
    resolvedProvidersFor: async (platform: Parameters<typeof actual.providersFor>[0], env: Parameters<typeof actual.providersFor>[1]) =>
      actual.providersFor(platform, env),
  }
})

const { installPaths, resetPaths, nodePaths } = await import('./platform/paths')
const { resetProfilesCache, createProfile } = await import('./profiles')
const { createHostCore } = await import('./host-core')
const { createSessionSwitch } = await import('./session-switch-run')
const { wireAccountVault } = await import('./account-vault/wire')
const { fakeCipher, claudeLogin } = await import('./account-vault/fake-cipher.fixture')

type Core = ReturnType<typeof createHostCore>
let core: Core
let handle: Awaited<ReturnType<typeof wireAccountVault>> = null
const SLOT = 'keychain:Claude Code-credentials'

beforeAll(async () => {
  if (!darwin) return
  mkdirSync(fakeBin, { recursive: true })
  writeFileSync(
    join(fakeBin, 'claude'),
    [
      '#!/bin/sh',
      'echo "PID=$$"',
      'while IFS= read -r line; do',
      '  svc="Claude Code-credentials"',
      '  if [ -n "$CLAUDE_CONFIG_DIR" ]; then',
      '    h=$(printf "%s" "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)',
      '    svc="$svc-$h"',
      '  fi',
      '  out=$(security find-generic-password -a me -w -s "$svc" 2>/dev/null)',
      '  token=$(printf "%s" "$out" | sed -n "s/.*accessToken\\":\\"\\([^\\"]*\\)\\".*/\\1/p")',
      '  echo "ANSWER[$token] PID=$$"',
      'done',
      '',
    ].join('\n'),
  )
  chmodSync(join(fakeBin, 'claude'), 0o755)
  const fakeSecurity = join(root, 'fake-security')
  writeFileSync(fakeSecurity, '#!/bin/sh\n[ "$1" = "-i" ] && cat >/dev/null\nexit 44\n')
  chmodSync(fakeSecurity, 0o755)

  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: root }, home: root, appRoot: root }))
  resetProfilesCache()
  handle = await wireAccountVault({
    userDataDir: root,
    cipher: fakeCipher(),
    platform: 'darwin',
    realSecurity: fakeSecurity,
    home: root,
    watch: () => () => undefined,
    inUse: () => false,
  })
  if (handle === null) throw new Error('the vault did not start')
  core = createHostCore({ storageDir: join(root, 'remote'), userData: root })
}, 30_000)

afterAll(async () => {
  if (!darwin) return
  core?.ptys.killAll()
  await core?.ptys.drain()
  await core?.credentials.stop()
  await handle?.dispose()
  resetPaths()
  resetProfilesCache()
  rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

async function until(check: () => boolean, ms = 8_000): Promise<void> {
  const end = Date.now() + ms
  while (!check() && Date.now() < end) await new Promise((resolve) => setTimeout(resolve, 50))
}

/** Type a line and wait for the agent's answer to it. */
async function ask(id: string): Promise<{ token: string; pid: string }> {
  const before = (core.ptys.scrollback(id).match(/ANSWER\[/g) ?? []).length
  core.ptys.write(id, 'x\r')
  await until(() => (core.ptys.scrollback(id).match(/ANSWER\[[^\]]*\] PID=\d+/g) ?? []).length > before)
  const all = [...core.ptys.scrollback(id).matchAll(/ANSWER\[([^\]]*)\] PID=(\d+)/g)]
  const last = all.at(-1)
  return { token: last?.[1] ?? '', pid: last?.[2] ?? '' }
}

describe.skipIf(!darwin)('switching a running Claude Code session in place', () => {
  it('hands the same process the other account’s login — same session, same PID, nothing restarted', async () => {
    if (handle === null) throw new Error('no vault')
    const home = createProfile('home@example.com')
    const work = createProfile('work@example.com')
    handle.runtime.vault.put(home.id, 'claude', SLOT, claudeLogin('HOME'), 'sign-in')
    handle.runtime.vault.put(work.id, 'claude', SLOT, claudeLogin('WORK'), 'sign-in')

    const cwd = mkdtempSync(join(root, 'proj-'))
    const meta = await core.startSession({ cwd, cols: 100, rows: 30, provider: 'claude', profileId: home.id })
    expect(meta.profileId).toBe(home.id)
    const pidBefore = core.ptys.pidOf(meta.id)

    expect(await ask(meta.id)).toMatchObject({ token: 'sk-ant-oat01-HOME' })

    const changed: SessionMeta[] = []
    const verbs = createSessionSwitch(core, { onAccountChanged: (row) => changed.push(row) })
    const { plan } = await verbs.subject(meta.id, work.id)
    expect(plan).toMatchObject({ refusal: null, mode: 'in-place', conversation: 'same' })

    const switched = await verbs.perform(meta.id, work.id)
    expect(switched.id).toBe(meta.id)
    expect(switched).toMatchObject({ profileId: work.id, profileName: 'work@example.com', homeProfileId: home.id })
    expect(changed.map((row) => row.id)).toEqual([meta.id])

    const after = await ask(meta.id)
    expect(after.token).toBe('sk-ant-oat01-WORK')
    expect(core.ptys.pidOf(meta.id)).toBe(pidBefore)
    expect(core.ptys.list().filter((row) => row.exitCode === null).map((row) => row.id)).toEqual([meta.id])

    // Remembered as it now is, in the folder its conversation is in.
    expect(core.ledger.get(meta.id)).toMatchObject({ profileId: work.id, homeProfileId: home.id })

    // And back: the same process again, on its own login.
    const back = await verbs.perform(meta.id, home.id)
    expect(back.id).toBe(meta.id)
    expect(back.homeProfileId).toBeUndefined()
    expect((await ask(meta.id)).token).toBe('sk-ant-oat01-HOME')
    expect(core.ptys.pidOf(meta.id)).toBe(pidBefore)
    expect(core.ledger.get(meta.id)?.homeProfileId).toBeUndefined()
  }, 30_000)

  it('a session whose process has ended loses its seat, and is switched by a restart instead', async () => {
    const home = createProfile('gone-home@example.com')
    const cwd = mkdtempSync(join(root, 'proj-'))
    const meta = await core.startSession({ cwd, cols: 100, rows: 30, provider: 'claude', profileId: home.id })
    const { sessionSeat } = await import('./account-vault/runtime')
    expect(sessionSeat(meta.id)).not.toBeNull()
    core.ptys.write(meta.id, '\u0004')
    await until(() => core.ptys.list().find((row) => row.id === meta.id)?.exitCode !== null)
    await until(() => sessionSeat(meta.id) === null)
    expect(sessionSeat(meta.id)).toBeNull()
  }, 30_000)
})
