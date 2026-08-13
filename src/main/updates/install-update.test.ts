import { spawn as realSpawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises'
import * as realFsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_OPEN_BINARY,
  MAX_WAIT_MS,
  LOG_NAME,
  SCRIPT_NAME,
  SWAP_EXIT,
  backupPathFor,
  bundleParent,
  canInstallInPlace,
  compareVersions,
  installStagedUpdate,
  installedBundlePath,
  readShortVersion,
  shellQuote,
  swapScript,
  type InstallFs,
  type InstallOptions,
  type SpawnLike,
  type SpawnedHelper,
} from './install-update'

/**
 * These tests are about one promise: **a failed update never costs the user
 * their application.**
 *
 * That splits into two halves, and both are tested differently on purpose.
 *
 * The *decision* half — is this a bundle, can it be written, is the download
 * newer — is a pure function of injected `fs`, `spawn` and `quit`, so the whole
 * tree runs against fakes with no application anywhere near it. The assertion
 * that matters most in that half is negative: `quit` was **not** called. Every
 * refusal path checks it, because quitting and then discovering the app cannot
 * be replaced is the one outcome this module exists to prevent.
 *
 * The *swap* half is shell, and shell cannot be reasoned about from a mock —
 * word splitting, `mv` into an existing directory, and a rollback that has to
 * survive its own failures are exactly the things that look right in a
 * description and are wrong on a disk. So those tests generate the real script
 * and **run it**, against bundles made of ordinary directories in a temp dir:
 * a real `mv`, a real rollback, a real timeout, real paths with spaces and an
 * apostrophe in them. The only thing swapped out is the `open` binary, which
 * is a recording stub so a test cannot launch an application — every line that
 * moves a directory is the production one.
 *
 * No test reads, writes or looks at /Applications.
 */

/* ------------------------------------------------------------ fake plumbing -- */

/** A `quit` that remembers, so every refusal can assert it stayed at zero. */
function recordingQuit(): { quit: () => void; calls: () => number } {
  let calls = 0
  return {
    quit: () => {
      calls += 1
    },
    calls: () => calls,
  }
}

/** Run a script through a real `/bin/sh` and hand back what it printed. */
function shOutput(script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = realSpawn('/bin/sh', ['-c', script], { stdio: ['ignore', 'pipe', 'ignore'] })
    let out = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      out += chunk
    })
    child.on('error', reject)
    child.on('close', () => resolve(out))
  })
}

interface FakeFsOptions {
  /** Paths that exist and are directories. */
  directories?: string[]
  /** Paths that `access(W_OK)` rejects, and the code to reject with. */
  unwritable?: Record<string, string>
  /** File contents `readFile` returns. */
  files?: Record<string, string>
  /** Make `writeFile` throw, to exercise the helper-failed path. */
  writeFails?: Error
}

interface FakeFs extends InstallFs {
  readonly accessed: Array<{ path: string; mode: number }>
  readonly written: Array<{ path: string; data: string; mode: number }>
  readonly appended: string[]
}

function fakeFs(options: FakeFsOptions = {}): FakeFs {
  const directories = new Set(options.directories ?? [])
  const unwritable = options.unwritable ?? {}
  const files = options.files ?? {}
  const accessed: Array<{ path: string; mode: number }> = []
  const written: Array<{ path: string; data: string; mode: number }> = []
  const appended: string[] = []

  return {
    accessed,
    written,
    appended,
    async access(path, mode) {
      accessed.push({ path, mode })
      const code = unwritable[path]
      if (code !== undefined) {
        const error: NodeJS.ErrnoException = new Error(`${code}: ${path}`)
        error.code = code
        throw error
      }
    },
    async stat(path) {
      if (!directories.has(path)) {
        const error: NodeJS.ErrnoException = new Error(`ENOENT: ${path}`)
        error.code = 'ENOENT'
        throw error
      }
      return { isDirectory: () => true }
    },
    async mkdir() {
      return undefined
    },
    async writeFile(path, data, opts) {
      if (options.writeFails) throw options.writeFails
      written.push({ path, data, mode: opts.mode })
    },
    async appendFile(_path, data) {
      appended.push(data)
    },
    async readFile(path) {
      const content = files[path]
      if (content === undefined) {
        const error: NodeJS.ErrnoException = new Error(`ENOENT: ${path}`)
        error.code = 'ENOENT'
        throw error
      }
      return content
    },
  }
}

interface FakeSpawn {
  spawn: SpawnLike
  calls: Array<{ command: string; args: string[]; options: unknown }>
  unrefs: () => number
}

function fakeSpawn(throws?: Error): FakeSpawn {
  const calls: Array<{ command: string; args: string[]; options: unknown }> = []
  let unrefs = 0
  return {
    calls,
    unrefs: () => unrefs,
    spawn: (command, args, spawnOptions): SpawnedHelper => {
      if (throws) throw throws
      calls.push({ command, args, options: spawnOptions })
      return {
        pid: 4242,
        unref: () => {
          unrefs += 1
        },
      }
    },
  }
}

const EXE = '/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck'
const BUNDLE = '/Applications/Terminal Deck.app'
const STAGED = '/Users/someone/Library/Caches/terminaldeck-updater/pending/Terminal Deck.app'
const STAGING_DIR = '/Users/someone/Library/Caches/terminaldeck-updater/pending'

function plist(version: string): string {
  // The real shape, copied from the installed bundle's own Info.plist.
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<plist version="1.0">',
    '  <dict>',
    '    <key>CFBundleExecutable</key>',
    '    <string>Terminal Deck</string>',
    '    <key>CFBundleShortVersionString</key>',
    `    <string>${version}</string>`,
    '  </dict>',
    '</plist>',
  ].join('\n')
}

/** A world where everything is fine, so each test can spoil exactly one thing. */
function healthyOptions(overrides: Partial<InstallOptions> = {}): {
  options: InstallOptions
  quit: () => number
  spawned: FakeSpawn
  fs: FakeFs
} {
  const fs = fakeFs({
    directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
    files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
  })
  const spawned = fakeSpawn()
  const quit = recordingQuit()
  return {
    quit: quit.calls,
    spawned,
    fs,
    options: {
      environment: { platform: 'darwin', exePath: EXE },
      stagingDir: STAGING_DIR,
      stagedBundlePath: STAGED,
      currentVersion: '0.1.0',
      fs,
      spawn: spawned.spawn,
      quit: quit.quit,
      pid: 999,
      now: () => 1_700_000_000_000,
      ...overrides,
    },
  }
}

/* ------------------------------------------------------------------- paths -- */

describe('installedBundlePath', () => {
  it('walks up from the executable to the bundle', () => {
    expect(installedBundlePath(EXE)).toBe(BUNDLE)
  })

  it('keeps spaces in the path intact', () => {
    expect(installedBundlePath('/Users/a b/My Apps/Terminal Deck.app/Contents/MacOS/Terminal Deck')).toBe(
      '/Users/a b/My Apps/Terminal Deck.app',
    )
  })

  it('refuses a path that is not inside Contents/MacOS', () => {
    // A dev build: `node_modules/electron/dist/Electron.app/Contents/MacOS/Electron`
    // is a bundle, but `out/main/index.js` is not.
    expect(installedBundlePath('/Users/a/project/out/main/index.js')).toBeNull()
    expect(installedBundlePath('/Applications/Terminal Deck.app/Contents/Resources/app')).toBeNull()
    expect(installedBundlePath('/Applications/Terminal Deck.app/Contents/MacOS/')).toBeNull()
  })

  it('refuses a directory that is not an .app', () => {
    expect(installedBundlePath('/Applications/Terminal Deck/Contents/MacOS/Terminal Deck')).toBeNull()
    expect(installedBundlePath('/Applications/.app/Contents/MacOS/x')).toBeNull()
  })

  it('refuses a bundle nested inside another bundle', () => {
    // Helpers live at Contents/Frameworks/<name>.app/Contents/MacOS/<name>, and
    // that path has exactly the same three-levels-up shape as the real one. If
    // it resolved, the swap would rename the helper aside, move the whole new
    // application into Contents/Frameworks under the helper's name, and then
    // rm -rf the real helper — corrupting the installed app instead of updating
    // it. The outer bundle is the only one an update ever replaces, and this
    // module would rather resolve nothing than resolve the wrong one.
    expect(
      installedBundlePath(
        '/Applications/Terminal Deck.app/Contents/Frameworks/Terminal Deck Helper.app/Contents/MacOS/Terminal Deck Helper',
      ),
    ).toBeNull()
    // Same shape, one level of nesting, no Frameworks involved.
    expect(
      installedBundlePath('/Applications/Outer.app/Inner.app/Contents/MacOS/Inner'),
    ).toBeNull()
  })

  it('refuses a relative path', () => {
    expect(installedBundlePath('Terminal Deck.app/Contents/MacOS/Terminal Deck')).toBeNull()
  })

  it('never returns a path that is not the app it was given', () => {
    // The property that matters: whatever comes back is a prefix of the input.
    for (const exe of [EXE, '/a/B.app/Contents/MacOS/B', '/x.app/Contents/MacOS/x']) {
      const bundle = installedBundlePath(exe)
      expect(bundle).not.toBeNull()
      expect(exe.startsWith(`${bundle as string}/Contents/MacOS/`)).toBe(true)
      expect((bundle as string).endsWith('.app')).toBe(true)
    }
  })
})

describe('bundleParent', () => {
  it('is the directory the rename happens in', () => {
    expect(bundleParent(BUNDLE)).toBe('/Applications')
    expect(bundleParent('/Users/a b/Apps/Terminal Deck.app')).toBe('/Users/a b/Apps')
  })

  it('does not collapse a bundle at the root of a volume to an empty path', () => {
    expect(bundleParent('/Terminal Deck.app')).toBe('/')
  })
})

describe('backupPathFor', () => {
  it('stays beside the bundle, so the rename is within one volume', () => {
    expect(backupPathFor(BUNDLE, 17)).toBe('/Applications/Terminal Deck.app.old-17')
    expect(bundleParent(backupPathFor(BUNDLE, 17))).toBe(bundleParent(BUNDLE))
  })
})

/* ----------------------------------------------------------------- version -- */

describe('readShortVersion', () => {
  it('reads the real plist shape', () => {
    expect(readShortVersion(plist('0.1.0'))).toBe('0.1.0')
  })

  it('is null when the key is absent or empty', () => {
    expect(readShortVersion('<plist><dict></dict></plist>')).toBeNull()
    expect(
      readShortVersion('<key>CFBundleShortVersionString</key>\n<string></string>'),
    ).toBeNull()
  })

  it('is null for a binary plist rather than inventing a version', () => {
    expect(readShortVersion('bplist00\u0000\u0000garbage')).toBeNull()
  })
})

describe('compareVersions', () => {
  it('orders releases numerically, not lexically', () => {
    expect(compareVersions('0.2.0', '0.1.0')).toBe(1)
    expect(compareVersions('0.10.0', '0.9.0')).toBe(1)
    expect(compareVersions('1.0.0', '1.0.0')).toBe(0)
    expect(compareVersions('0.1.0', '0.1.1')).toBe(-1)
  })

  it('treats a missing segment as zero', () => {
    expect(compareVersions('1.2', '1.2.0')).toBe(0)
    expect(compareVersions('1.2', '1.2.1')).toBe(-1)
  })

  it('sorts a prerelease below its release', () => {
    expect(compareVersions('0.2.0-beta.1', '0.2.0')).toBe(-1)
    expect(compareVersions('0.2.0-beta.1', '0.2.0-beta.2')).toBe(-1)
    expect(compareVersions('0.2.0-beta.2', '0.2.0-beta.10')).toBe(-1)
    expect(compareVersions('0.2.0-alpha', '0.2.0-beta')).toBe(-1)
    expect(compareVersions('0.2.0-beta', '0.1.9')).toBe(1)
  })

  it('ignores a leading v and build metadata', () => {
    expect(compareVersions('v1.2.3', '1.2.3')).toBe(0)
    expect(compareVersions('1.2.3+build.9', '1.2.3')).toBe(0)
  })
})

/* ---------------------------------------------------------------- quoting -- */

describe('shellQuote', () => {
  it('survives spaces', () => {
    expect(shellQuote('/Applications/Terminal Deck.app')).toBe("'/Applications/Terminal Deck.app'")
  })

  it('survives an apostrophe', () => {
    expect(shellQuote("/Users/me/it's here/App.app")).toBe("'/Users/me/it'\\''s here/App.app'")
  })

  it('neutralises everything sh would otherwise expand', async () => {
    // Asserted by asking `sh` itself rather than by reasoning about the string.
    // Quoting rules are the shell's, so the shell is the only authority worth
    // testing against — and `printf '%s'` prints exactly one argument, so a
    // value that split into two fails visibly instead of quietly.
    for (const nasty of [
      '$HOME',
      '`whoami`',
      '$(whoami)',
      'a;rm -rf /',
      'a b\tc',
      'a*b?c',
      'a\nb',
      'a\\b',
      "it's",
      "''",
      '/Volumes/Terminal Deck 0.1.0/Terminal Deck.app',
    ]) {
      expect(await shOutput(`printf '%s' ${shellQuote(nasty)}`)).toBe(nasty)
    }
  })
})

/* ------------------------------------------------------------- capability -- */

describe('canInstallInPlace', () => {
  it('accepts a writable bundle and reports both paths it checked', async () => {
    const fs = fakeFs({ directories: [`${BUNDLE}/Contents/MacOS`] })
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: EXE },
      fs,
    })
    expect(verdict).toEqual({ ok: true, bundlePath: BUNDLE, parentPath: '/Applications' })
    // Both, not one: an app that is writable inside a locked folder passes a
    // single check and fails a moment after the app has quit.
    expect(fs.accessed.map((a) => a.path)).toEqual([BUNDLE, '/Applications'])
    // W_OK, not F_OK — "it is there" is not "it can be replaced".
    expect(fs.accessed.every((a) => a.mode === 2)).toBe(true)
  })

  it('refuses a non-darwin platform', async () => {
    const verdict = await canInstallInPlace({
      environment: { platform: 'win32', exePath: 'C:\\Program Files\\Terminal Deck\\td.exe' },
      fs: fakeFs(),
    })
    expect(verdict).toMatchObject({ ok: false, block: 'unsupported-platform' })
  })

  it('refuses a path that is not an .app', async () => {
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: '/Users/a/project/node_modules/.bin/electron' },
      fs: fakeFs(),
    })
    expect(verdict).toMatchObject({ ok: false, block: 'not-a-bundle' })
  })

  it('refuses when the bundle has no Contents/MacOS on disk', async () => {
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: EXE },
      fs: fakeFs({ directories: [] }),
    })
    expect(verdict).toMatchObject({ ok: false, block: 'bundle-incomplete' })
  })

  it('refuses a bundle owned by another account, and names it', async () => {
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: EXE },
      fs: fakeFs({
        directories: [`${BUNDLE}/Contents/MacOS`],
        unwritable: { [BUNDLE]: 'EACCES' },
      }),
    })
    expect(verdict.ok).toBe(false)
    if (verdict.ok) return
    expect(verdict.block).toBe('not-writable')
    expect(verdict.message).toContain(BUNDLE)
  })

  it('refuses a writable bundle inside a locked folder', async () => {
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: EXE },
      fs: fakeFs({
        directories: [`${BUNDLE}/Contents/MacOS`],
        unwritable: { '/Applications': 'EACCES' },
      }),
    })
    expect(verdict).toMatchObject({ ok: false, block: 'not-writable' })
  })

  it('tells a user running from the disk image what to do about it', async () => {
    const dmgExe = '/Volumes/Terminal Deck 0.1.0/Terminal Deck.app/Contents/MacOS/Terminal Deck'
    const dmgBundle = '/Volumes/Terminal Deck 0.1.0/Terminal Deck.app'
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: dmgExe },
      fs: fakeFs({
        directories: [`${dmgBundle}/Contents/MacOS`],
        unwritable: { [dmgBundle]: 'EROFS' },
      }),
    })
    expect(verdict.ok).toBe(false)
    if (verdict.ok) return
    expect(verdict.block).toBe('not-writable')
    expect(verdict.message).toContain('read-only volume')
    expect(verdict.message).toContain('Applications folder')
  })
})

/* --------------------------------------------------- refusing before quitting -- */

describe('installStagedUpdate refuses before quitting', () => {
  it('does not quit when the app is not writable', async () => {
    const { options, quit, spawned } = healthyOptions()
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
      unwritable: { [BUNDLE]: 'EACCES' },
    })
    const result = await installStagedUpdate({ ...options, fs })

    expect(result).toMatchObject({ started: false, block: 'not-writable' })
    // The assertion this module exists for.
    expect(quit()).toBe(0)
    expect(spawned.calls).toHaveLength(0)
    // ...and it still left evidence.
    expect(fs.appended.join('')).toContain('not-writable')
  })

  it('does not quit when the app is on a read-only mount', async () => {
    const { options, quit } = healthyOptions()
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
      unwritable: { '/Applications': 'EROFS' },
    })
    expect(await installStagedUpdate({ ...options, fs })).toMatchObject({
      started: false,
      block: 'not-writable',
    })
    expect(quit()).toBe(0)
  })

  it('does not quit when the running path is not an .app', async () => {
    const { options, quit } = healthyOptions({
      environment: { platform: 'darwin', exePath: '/Users/a/project/out/main/index.js' },
    })
    expect(await installStagedUpdate(options)).toMatchObject({
      started: false,
      block: 'not-a-bundle',
    })
    expect(quit()).toBe(0)
  })

  it('does not quit when the staged download is not a bundle', async () => {
    const { options, quit } = healthyOptions()
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
    })
    expect(await installStagedUpdate({ ...options, fs })).toMatchObject({
      started: false,
      block: 'staged-invalid',
    })
    expect(quit()).toBe(0)
  })

  it('does not quit when the staged bundle is the installed one', async () => {
    const { options, quit } = healthyOptions({ stagedBundlePath: BUNDLE })
    expect(await installStagedUpdate(options)).toMatchObject({
      started: false,
      block: 'staged-invalid',
    })
    expect(quit()).toBe(0)
  })

  it('does not quit when the helper cannot be written', async () => {
    const { options, quit } = healthyOptions()
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
      writeFails: new Error('ENOSPC: no space left on device'),
    })
    const result = await installStagedUpdate({ ...options, fs })
    expect(result).toMatchObject({ started: false, block: 'helper-failed' })
    expect(quit()).toBe(0)
  })

  it('does not quit when the helper cannot be spawned', async () => {
    const { options, quit } = healthyOptions()
    const failing = fakeSpawn(new Error('EAGAIN'))
    expect(await installStagedUpdate({ ...options, spawn: failing.spawn })).toMatchObject({
      started: false,
      block: 'helper-failed',
    })
    expect(quit()).toBe(0)
  })

  it('does not quit when the spawn reports no pid', async () => {
    // `spawn` reports a failure to launch on the `error` event rather than by
    // throwing, and hands back an object with an undefined pid. Treating that
    // as a running helper is the one way to quit the app with nothing left to
    // bring it back — the user watches their app close and nothing happens.
    const { options, quit } = healthyOptions()
    let unrefs = 0
    const pidless: SpawnLike = () => ({
      pid: undefined,
      unref: () => {
        unrefs += 1
      },
    })
    expect(await installStagedUpdate({ ...options, spawn: pidless })).toMatchObject({
      started: false,
      block: 'helper-failed',
    })
    expect(quit()).toBe(0)
    expect(unrefs).toBe(1)
  })

  it('does not quit when the pid or the timeout is unusable', async () => {
    // A pid that is not a pid makes the helper's `kill -0` fail, which it reads
    // as "the app has exited" — and it would swap the bundle out from under a
    // process still running from it. A zero poll interval makes the bounded
    // wait unbounded. Both are refusals with the app still up, not surprises.
    for (const broken of [
      { pid: Number.NaN },
      { pid: 0 },
      { pid: -12 },
      { pollSeconds: 0 },
      { pollSeconds: Number.NaN },
      { waitTimeoutMs: 0 },
    ]) {
      const { options, quit, spawned } = healthyOptions(broken)
      expect(await installStagedUpdate(options)).toMatchObject({
        started: false,
        block: 'helper-failed',
      })
      expect(quit()).toBe(0)
      expect(spawned.calls).toHaveLength(0)
    }
  })
})

/* ------------------------------------------------------------ version guard -- */

describe('the version guard', () => {
  it('refuses an older build', async () => {
    const { options, quit } = healthyOptions({ currentVersion: '0.3.0' })
    const result = await installStagedUpdate(options)
    expect(result).toMatchObject({ started: false, block: 'not-newer' })
    if (result.started) return
    expect(result.message).toContain('0.2.0')
    expect(result.message).toContain('0.3.0')
    expect(quit()).toBe(0)
  })

  it('refuses the same build', async () => {
    const { options, quit } = healthyOptions({ currentVersion: '0.2.0' })
    expect(await installStagedUpdate(options)).toMatchObject({ started: false, block: 'not-newer' })
    expect(quit()).toBe(0)
  })

  it('refuses a build whose version cannot be read', async () => {
    const { options, quit } = healthyOptions()
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: 'bplist00\u0000binary' },
    })
    expect(await installStagedUpdate({ ...options, fs })).toMatchObject({
      started: false,
      block: 'staged-version-unreadable',
    })
    expect(quit()).toBe(0)
  })

  it('installs a newer build', async () => {
    const { options, quit } = healthyOptions()
    expect(await installStagedUpdate(options)).toMatchObject({ started: true })
    expect(quit()).toBe(1)
  })

  it('installs the same build when told to reinstall', async () => {
    const { options, quit } = healthyOptions({ currentVersion: '0.2.0', reinstall: true })
    expect(await installStagedUpdate(options)).toMatchObject({ started: true })
    expect(quit()).toBe(1)
  })

  it('still refuses an unwritable app when told to reinstall', async () => {
    // reinstall overrides the version, never the safety checks.
    const { options, quit } = healthyOptions({ reinstall: true })
    const fs = fakeFs({
      directories: [`${BUNDLE}/Contents/MacOS`, `${STAGED}/Contents/MacOS`],
      files: { [`${STAGED}/Contents/Info.plist`]: plist('0.2.0') },
      unwritable: { [BUNDLE]: 'EACCES' },
    })
    expect(await installStagedUpdate({ ...options, fs })).toMatchObject({
      started: false,
      block: 'not-writable',
    })
    expect(quit()).toBe(0)
  })
})

/* ------------------------------------------------------------- the handoff -- */

describe('starting the helper', () => {
  it('spawns detached, ignores its stdio, unrefs it, and only then quits', async () => {
    const { options, quit, spawned } = healthyOptions()
    const result = await installStagedUpdate(options)

    expect(result.started).toBe(true)
    if (!result.started) return
    expect(spawned.calls).toHaveLength(1)
    const call = spawned.calls[0]
    // /bin/sh explicitly: a staging directory mounted noexec must not be able
    // to stop the swap.
    expect(call.command).toBe('/bin/sh')
    expect(call.args).toEqual([join(STAGING_DIR, SCRIPT_NAME)])
    expect(call.options).toEqual({ detached: true, stdio: 'ignore', cwd: '/' })
    // Drop any one of these three and the helper dies with the app it is
    // waiting for — after the app is already gone.
    expect(spawned.unrefs()).toBe(1)
    expect(quit()).toBe(1)
    expect(result.helperPid).toBe(4242)
    expect(result.backupPath).toBe(`${BUNDLE}.old-1700000000000`)
    expect(result.logPath).toBe(join(STAGING_DIR, LOG_NAME))
  })

  it('writes the helper into the staging directory, not the app', async () => {
    const { options, fs } = healthyOptions()
    await installStagedUpdate(options)
    expect(fs.written).toHaveLength(1)
    expect(fs.written[0].path.startsWith(STAGING_DIR)).toBe(true)
    // Only this account may run a script that moves its application around.
    expect(fs.written[0].mode).toBe(0o700)
    // And nothing was written inside the bundle being replaced.
    expect(fs.written.some((w) => w.path.startsWith(BUNDLE))).toBe(false)
  })

  it('bakes every path in as a quoted literal', async () => {
    const { options, fs } = healthyOptions()
    await installStagedUpdate(options)
    const script = fs.written[0].data
    expect(script).toContain(`INSTALL='${BUNDLE}'`)
    expect(script).toContain(`STAGED='${STAGED}'`)

    const code = script.split('\n').filter((line) => !line.trimStart().startsWith('#'))
    // Nothing may reach `mv` unquoted: "Terminal Deck.app" would arrive as two
    // arguments, and the failure would land in the middle of the swap — with
    // the app already moved aside — rather than before it.
    const moves = code.filter((line) => /\bmv\b/.test(line))
    expect(moves.length).toBeGreaterThan(0)
    for (const line of moves) expect(line).toMatch(/mv -f "\$[A-Z]+" "\$[A-Z]+"/)
    // Same for the one destructive command, and for every existence test that
    // decides whether a move is safe.
    for (const line of code.filter((line) => /\brm -rf\b/.test(line))) {
      expect(line).toMatch(/rm -rf "\$[A-Z]+"/)
    }
    for (const line of code.filter((line) => /^\s*if \[ /.test(line))) {
      expect(line).toMatch(/"\$[A-Z]+/)
    }
  })

  it('leaves the quarantine flag alone unless asked', async () => {
    // Clearing quarantine discards macOS's record that these bytes came off the
    // internet. It is a decision for the caller that verified the download, not
    // a default.
    const plain = healthyOptions()
    await installStagedUpdate(plain.options)
    expect(plain.fs.written[0].data).not.toContain('com.apple.quarantine')

    const asked = healthyOptions({ clearQuarantine: true })
    await installStagedUpdate(asked.options)
    expect(asked.fs.written[0].data).toContain('com.apple.quarantine')
  })
})

/* --------------------------------------------------------- the seams still fit -- */

describe('the injected seams match the real modules', () => {
  it('accepts node:fs/promises', () => {
    // A compile-time check that the narrowed surface has not drifted from the
    // module it stands in for. Nothing here touches the disk.
    const fits: InstallFs = realFsPromises
    expect(typeof fits.access).toBe('function')
  })

  it('accepts node:child_process spawn', () => {
    const fits: SpawnLike = realSpawn
    expect(typeof fits).toBe('function')
  })

  it('points at an `open` that exists on this machine', async () => {
    // Verified rather than assumed: the relaunch is the last thing the helper
    // does, and a wrong path there is an update that silently never comes back.
    await expect(stat(DEFAULT_OPEN_BINARY)).resolves.toBeDefined()
  })
})

/* =========================================================================== */
/* The script, run for real                                                    */
/* =========================================================================== */

const temporaries: string[] = []

afterEach(async () => {
  for (const dir of temporaries.splice(0)) {
    // A test may have made a directory read-only on purpose.
    await chmod(dir, 0o755).catch(() => undefined)
    await rm(dir, { recursive: true, force: true }).catch(() => undefined)
  }
})

async function temp(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'td-install-'))
  temporaries.push(dir)
  return dir
}

/**
 * A bundle made of ordinary directories.
 *
 * `marker` is written into `Contents/Resources/which` so a test can say *which*
 * of the two bundles ended up at the install path — "a directory exists there"
 * is exactly the assertion that would pass on a rollback that put the wrong one
 * back.
 */
async function fakeBundle(path: string, marker: string): Promise<string> {
  await mkdir(`${path}/Contents/MacOS`, { recursive: true })
  await mkdir(`${path}/Contents/Resources`, { recursive: true })
  await writeFile(`${path}/Contents/MacOS/Terminal Deck`, `#!/bin/sh\nexit 0\n`, { mode: 0o755 })
  // Every real .app has one, and the script checks for it before it destroys
  // the user's only copy of the old app, so the fixture has to have one too.
  await writeFile(`${path}/Contents/Info.plist`, plist('0.0.0'))
  await writeFile(`${path}/Contents/Resources/which`, marker)
  return path
}

async function markerAt(bundlePath: string): Promise<string | null> {
  return readFile(`${bundlePath}/Contents/Resources/which`, 'utf8').catch(() => null)
}

async function exists(path: string): Promise<boolean> {
  return stat(path).then(
    () => true,
    () => false,
  )
}

/** A stand-in for `/usr/bin/open` that records instead of launching anything. */
async function openStub(dir: string): Promise<{ bin: string; launched: () => Promise<string> }> {
  const bin = join(dir, 'open-stub.sh')
  const log = join(dir, 'launched.txt')
  await writeFile(bin, `#!/bin/sh\nprintf '%s\\n' "$*" >> ${shellQuote(log)}\n`, { mode: 0o755 })
  return { bin, launched: () => readFile(log, 'utf8').catch(() => '') }
}

/** A pid that is certainly gone: spawn something, wait for it to die, keep its pid. */
async function deadPid(): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = realSpawn('/bin/sh', ['-c', 'exit 0'], { stdio: 'ignore' })
    child.on('error', reject)
    child.on('close', () => resolve(child.pid ?? -1))
  })
}

function runScript(scriptPath: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = realSpawn('/bin/sh', [scriptPath], { stdio: 'ignore' })
    child.on('error', reject)
    child.on('close', (code) => resolve(code ?? -1))
  })
}

/** Everything a swap test needs, wired to a temp dir and a dead pid. */
async function swapWorld(options: { parentName?: string } = {}): Promise<{
  root: string
  installPath: string
  stagedPath: string
  backupPath: string
  logPath: string
  scriptPath: string
  openBin: string
  launched: () => Promise<string>
  pid: number
  log: () => Promise<string>
}> {
  const root = await temp()
  // A parent with a space in it by default, because the real one may have any
  // character the user's disk allows.
  const parent = join(root, options.parentName ?? 'App lications')
  const staging = join(root, 'pending')
  await mkdir(parent, { recursive: true })
  await mkdir(staging, { recursive: true })

  const installPath = join(parent, 'Terminal Deck.app')
  const stagedPath = join(staging, 'Terminal Deck.app')
  await fakeBundle(installPath, 'installed-0.1.0')
  await fakeBundle(stagedPath, 'staged-0.2.0')

  const { bin: openBin, launched } = await openStub(root)
  const logPath = join(staging, LOG_NAME)

  return {
    root,
    installPath,
    stagedPath,
    backupPath: backupPathFor(installPath, 1_700_000_000_000),
    logPath,
    scriptPath: join(staging, SCRIPT_NAME),
    openBin,
    launched,
    pid: await deadPid(),
    log: () => readFile(logPath, 'utf8').catch(() => ''),
  }
}

describe('the swap script, run against real directories', () => {
  it('replaces the bundle, removes the backup only after that, and relaunches', async () => {
    const w = await swapWorld()
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.ok)

    expect(await markerAt(w.installPath)).toBe('staged-0.2.0')
    expect(await exists(w.stagedPath)).toBe(false)
    expect(await exists(w.backupPath)).toBe(false)
    expect(await w.launched()).toContain(w.installPath)

    const log = await w.log()
    expect(log).toContain('the current app is safe at')
    expect(log).toContain('the new app is in place')
    expect(log).toContain('removed the backup')
  })

  it('survives an apostrophe in the path', async () => {
    const w = await swapWorld({ parentName: "it's here" })
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.ok)
    expect(await markerAt(w.installPath)).toBe('staged-0.2.0')
  })

  it('rolls back and leaves the original intact when the new bundle cannot be moved in', async () => {
    const w = await swapWorld()
    // The staged bundle disappears between the app quitting and the swap. Not
    // contrived: it sits in a cache directory, and macOS purges those.
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )
    await rm(`${w.stagedPath}/Contents/MacOS`, { recursive: true, force: true })

    const code = await runScript(w.scriptPath)

    // Caught before the backup was made — the strongest form of the rollback.
    expect(code).toBe(SWAP_EXIT.stagedInvalid)
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await exists(w.backupPath)).toBe(false)
    expect(await w.log()).toContain('nothing was moved')
  })

  it('puts the original back when the move fails after the backup was made', async () => {
    const w = await swapWorld()
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )
    // The log has to exist before the directory holding it is locked — in
    // production `installStagedUpdate` has already appended to it before the
    // helper ever runs.
    await writeFile(w.logPath, '')
    // Pass the script's own re-check, then make the rename itself fail: the
    // staging directory is locked, so the staged bundle cannot be renamed out
    // of it. This is the window the rollback exists for — the user has no app
    // at the install path at the moment it happens.
    await chmod(join(w.root, 'pending'), 0o555)
    try {
      const code = await runScript(w.scriptPath)

      expect(code).toBe(SWAP_EXIT.rolledBack)
      // The whole promise of this module, as one assertion.
      expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
      // The backup is gone because it was moved back, not because it was deleted.
      expect(await exists(w.backupPath)).toBe(false)
      // And the user's app was relaunched rather than left closed.
      expect(await w.launched()).toContain(w.installPath)

      const log = await w.log()
      expect(log).toContain('rolling back')
      expect(log).toContain('rolled back')
      expect(log).not.toContain('removed the backup')
    } finally {
      await chmod(join(w.root, 'pending'), 0o755)
    }
  })

  it('moves nothing at all when the app refuses to exit', async () => {
    const w = await swapWorld()
    const stubborn = realSpawn('/bin/sleep', ['30'], { stdio: 'ignore' })
    try {
      await writeFile(
        w.scriptPath,
        swapScript({
          pid: stubborn.pid ?? 1,
          bundlePath: w.installPath,
          stagedBundlePath: w.stagedPath,
          backupPath: w.backupPath,
          logPath: w.logPath,
          openBinary: w.openBin,
          pollSeconds: 0.05,
          // A bounded wait is the point: a helper that waits forever holds a
          // swap over the user's application indefinitely.
          maxPolls: 3,
          clearQuarantine: false,
        }),
      )

      expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.timeout)
      expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
      expect(await markerAt(w.stagedPath)).toBe('staged-0.2.0')
      expect(await exists(w.backupPath)).toBe(false)
      expect(await w.log()).toContain('still running')
      expect(await w.launched()).toBe('')
    } finally {
      stubborn.kill('SIGKILL')
    }
  })

  it('clears the install path and restores the backup when the moved bundle is unusable', async () => {
    const w = await swapWorld()
    // The nastier rollback: the move *succeeds*, and what lands is not usable.
    // Built with a relative symlink, which is how it happens for real — an
    // archive whose Contents/MacOS points outside the bundle resolves fine
    // where it was unpacked and dangles the moment it is moved somewhere else.
    // This is the only branch where the install path is occupied by rubbish at
    // the moment the user has no application, so it is the one worth building.
    await rm(`${w.stagedPath}/Contents/MacOS`, { recursive: true, force: true })
    await mkdir(join(w.root, 'pending', 'elsewhere'), { recursive: true })
    await symlink('../../elsewhere', `${w.stagedPath}/Contents/MacOS`)
    expect(await exists(`${w.stagedPath}/Contents/MacOS`)).toBe(true)

    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.rolledBack)
    // The user has their application back, and it is the original one.
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await exists(w.backupPath)).toBe(false)
    // The rubbish was moved aside, not deleted: it is what a bug report needs.
    expect(await exists(`${w.backupPath}.partial`)).toBe(true)
    expect(await w.launched()).toContain(w.installPath)
    expect(await w.log()).toContain('moved the unusable bundle')
  })

  it('rolls back even when what landed on the install path is a dangling symlink', async () => {
    // The regression this test exists for. If the staged path is itself a
    // symlink, the mv moves the *link*, the link dangles at its new home, and
    // `[ -e "$INSTALL" ]` answers "nothing there" — because -e follows links.
    // The clear-the-path branch was then skipped with the link still sitting on
    // the install path, and `mv backup install` failed with ENOTDIR. The user
    // was left with no application, their real one under a `.old-<millis>` name
    // they never chose, and exit 8. -L is what sees a dangling link.
    const w = await swapWorld()
    const staging = join(w.root, 'pending')
    await rm(w.stagedPath, { recursive: true, force: true })
    await fakeBundle(join(staging, 'unpacked', 'Terminal Deck.app'), 'staged-0.2.0')
    await symlink('unpacked/Terminal Deck.app', w.stagedPath)

    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.rolledBack)
    // The assertion the bug broke: the user still has their application.
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await exists(w.backupPath)).toBe(false)
    expect(await w.launched()).toContain(w.installPath)
    expect(await w.log()).not.toContain('CRITICAL')
  })

  it('will not delete the backup when the new bundle only looks complete', async () => {
    // `-d Contents/MacOS` follows symlinks, so a Contents/MacOS pointing at a
    // directory that still resolves after the move satisfied it, and the user's
    // only copy of the old app was removed on the strength of a link. The gate
    // in front of the one rm -rf has to be evidence of an application.
    const w = await swapWorld()
    const elsewhere = join(w.root, 'elsewhere')
    await mkdir(elsewhere, { recursive: true })
    await rm(`${w.stagedPath}/Contents/MacOS`, { recursive: true, force: true })
    await symlink(elsewhere, `${w.stagedPath}/Contents/MacOS`)

    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.rolledBack)
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await w.log()).not.toContain('removed the backup')
  })

  it('will not delete the backup for a bundle with no Info.plist', async () => {
    const w = await swapWorld()
    await rm(`${w.stagedPath}/Contents/Info.plist`, { force: true })

    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.rolledBack)
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await w.log()).not.toContain('removed the backup')
  })

  it('does not generate a loop whose bound `sh` cannot evaluate', async () => {
    // The fingerprint of the bug, watched for directly. `Math.ceil(ms / 0)` is
    // Infinity, and `MAX_POLLS='Infinity'` makes `[ "$polls" -ge "$MAX_POLLS" ]`
    // *fail* on every pass rather than evaluate false — `sh` prints "integer
    // expression expected" and returns 2, `if` reads that as false, and the
    // bounded wait this module promises becomes a loop spinning on `sleep 0`
    // over a live application, forever. So the test runs the real script
    // against a live pid and reads its stderr.
    const w = await swapWorld()
    const stubborn = realSpawn('/bin/sleep', ['30'], { stdio: 'ignore' })
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: stubborn.pid ?? 1,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0,
        maxPolls: Number.POSITIVE_INFINITY,
        clearQuarantine: false,
      }),
    )

    const helper = realSpawn('/bin/sh', [w.scriptPath], { stdio: ['ignore', 'ignore', 'pipe'] })
    let stderr = ''
    helper.stderr.setEncoding('utf8')
    helper.stderr.on('data', (chunk: string) => {
      stderr += chunk
    })
    try {
      await new Promise((resolve) => setTimeout(resolve, 750))
      expect(stderr).toBe('')
      // And it is still waiting rather than having decided the app was gone.
      expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
      expect(await exists(w.backupPath)).toBe(false)
    } finally {
      helper.kill('SIGKILL')
      stubborn.kill('SIGKILL')
    }
  })

  it('caps the wait at a wall-clock ceiling, not merely at a finite number', () => {
    // "Bounded" has to mean bounded in seconds. Ten million polls is a finite
    // integer and also a helper holding a swap over the user's app for a month.
    const plan = {
      pid: 999,
      bundlePath: '/Applications/Terminal Deck.app',
      stagedBundlePath: '/tmp/pending/Terminal Deck.app',
      backupPath: '/Applications/Terminal Deck.app.old-1',
      logPath: '/tmp/pending/log',
      openBinary: DEFAULT_OPEN_BINARY,
      clearQuarantine: false,
    }
    const boundOf = (script: string): { polls: number; seconds: number } => {
      const polls = Number(/^MAX_POLLS='(.+)'$/m.exec(script)?.[1])
      const seconds = Number(/^POLL='(.+)'$/m.exec(script)?.[1])
      return { polls, seconds }
    }

    for (const hostile of [
      { pollSeconds: 0.25, maxPolls: Number.POSITIVE_INFINITY },
      { pollSeconds: 0, maxPolls: Number.POSITIVE_INFINITY },
      { pollSeconds: Number.NaN, maxPolls: Number.NaN },
      { pollSeconds: -1, maxPolls: -1 },
      { pollSeconds: 0.25, maxPolls: 10_000_000 },
    ]) {
      const { polls, seconds } = boundOf(swapScript({ ...plan, ...hostile }))
      expect(Number.isInteger(polls)).toBe(true)
      expect(polls).toBeGreaterThanOrEqual(1)
      expect(seconds).toBeGreaterThan(0)
      expect(polls * seconds * 1000).toBeLessThanOrEqual(MAX_WAIT_MS)
    }

    // A sane request is passed through untouched.
    expect(boundOf(swapScript({ ...plan, pollSeconds: 0.25, maxPolls: 240 })).polls).toBe(240)
  })

  it('refuses to generate a script that waits on something that is not a pid', () => {
    // `kill -0 not-a-number` fails, and a failing wait reads as "the app has
    // exited" — which would swap the bundle out from under a running process.
    const plan = {
      bundlePath: '/Applications/Terminal Deck.app',
      stagedBundlePath: '/tmp/pending/Terminal Deck.app',
      backupPath: '/Applications/Terminal Deck.app.old-1',
      logPath: '/tmp/pending/log',
      openBinary: DEFAULT_OPEN_BINARY,
      pollSeconds: 0.25,
      maxPolls: 40,
      clearQuarantine: false,
    }
    expect(() => swapScript({ ...plan, pid: Number.NaN })).toThrow(RangeError)
    expect(() => swapScript({ ...plan, pid: 0 })).toThrow(RangeError)
    expect(() => swapScript({ ...plan, pid: -1 })).toThrow(RangeError)
    expect(() => swapScript({ ...plan, pid: 1.5 })).toThrow(RangeError)
  })

  it('is still valid sh with the quarantine step switched on', async () => {
    // That branch is generated, not written, so it is only ever exercised when
    // a caller opts in — which in production is the first time anyone runs it.
    // A syntax error there would abort the helper *after* the backup move.
    const w = await swapWorld()
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: true,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.ok)
    expect(await markerAt(w.installPath)).toBe('staged-0.2.0')
    expect(await exists(w.backupPath)).toBe(false)
    // A bundle that never had the attribute makes xattr exit non-zero, and that
    // must not be treated as a failed install.
    expect(await w.log()).toContain('done')
  })

  it('refuses to move the app aside onto something that already exists', async () => {
    const w = await swapWorld()
    // Nesting, not replacing, is what `mv dir existing-dir` does — the app
    // would end up one level down and the install path would be empty.
    await fakeBundle(w.backupPath, 'squatter')
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.backupFailed)
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
    expect(await markerAt(w.backupPath)).toBe('squatter')
  })

  it('refuses to install a bundle over itself', async () => {
    const w = await swapWorld()
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.installPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.stagedInvalid)
    expect(await markerAt(w.installPath)).toBe('installed-0.1.0')
  })

  it('will not rm -rf a backup path it did not name', async () => {
    const w = await swapWorld()
    // The one destructive command in the script, pointed somewhere else. The
    // case guard has to catch it even though every other step succeeds.
    const strayBackup = join(w.root, 'not-a-backup')
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: strayBackup,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )

    expect(await runScript(w.scriptPath)).toBe(SWAP_EXIT.ok)
    expect(await markerAt(w.installPath)).toBe('staged-0.2.0')
    // Left on disk, and said so, rather than removed.
    expect(await markerAt(strayBackup)).toBe('installed-0.1.0')
    expect(await w.log()).toContain('refusing to remove')
  })

  it('logs every step, so a failed swap leaves evidence', async () => {
    const w = await swapWorld()
    await writeFile(
      w.scriptPath,
      swapScript({
        pid: w.pid,
        bundlePath: w.installPath,
        stagedBundlePath: w.stagedPath,
        backupPath: w.backupPath,
        logPath: w.logPath,
        openBinary: w.openBin,
        pollSeconds: 0.05,
        maxPolls: 40,
        clearQuarantine: false,
      }),
    )
    await runScript(w.scriptPath)

    const lines = (await w.log()).trim().split('\n')
    expect(lines.length).toBeGreaterThanOrEqual(4)
    // Every line is timestamped, because "it failed" without a when is not
    // evidence.
    for (const line of lines) {
      expect(line).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z swap: /)
    }
  })
})

/* ------------------------------------------------- the real permission check -- */

describe('canInstallInPlace against a real directory', () => {
  it('refuses a bundle in a folder this account cannot write', async () => {
    if (process.getuid?.() === 0) return // root can write anything; the check is meaningless
    const root = await temp()
    const parent = join(root, 'Locked Apps')
    await mkdir(parent, { recursive: true })
    const bundle = await fakeBundle(join(parent, 'Terminal Deck.app'), 'installed')
    await chmod(parent, 0o555)

    try {
      const verdict = await canInstallInPlace({
        environment: { platform: 'darwin', exePath: `${bundle}/Contents/MacOS/Terminal Deck` },
        // The real fs, not a fake: this is the check that has to agree with the
        // kernel, and a fake cannot disagree with itself.
        fs: realFsPromises,
      })
      expect(verdict).toMatchObject({ ok: false, block: 'not-writable' })
    } finally {
      await chmod(parent, 0o755)
    }
  })

  it('accepts a bundle it can actually write', async () => {
    const root = await temp()
    const bundle = await fakeBundle(join(root, 'My Apps', 'Terminal Deck.app'), 'installed')
    const verdict = await canInstallInPlace({
      environment: { platform: 'darwin', exePath: `${bundle}/Contents/MacOS/Terminal Deck` },
      fs: realFsPromises,
    })
    expect(verdict).toEqual({ ok: true, bundlePath: bundle, parentPath: join(root, 'My Apps') })
  })
})
