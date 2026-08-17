/**
 * Whether the copilot can publish a conversation under somebody else's project,
 * asked of the readers themselves.
 *
 * ## The channel
 *
 * `transcriptDirs(cwd)` used to answer with `projects/<encode(cwd)>` inside
 * **every** confined home under `<userData>/remote/device-home/`. The copilot
 * had a home there, deliberately: the placement was what let the transcript
 * viewer, chat mode, the cost pane and the alert watcher see its conversation
 * with no change to any of them.
 *
 * The copilot could write inside its own home. So creating
 *
 *     <copilotHome>/.claude/projects/<encode(/somebody/else/api)>/x.jsonl
 *
 * was an ordinary, permitted file write — and those four readers would then
 * render it as a conversation belonging to `/somebody/else/api`. Not a
 * permission bypass. Fabricated input to four readers, and those readers are the
 * person's independent check on what their assistant tells them.
 *
 * ## Why this still matters after the copilot stopped being jailed
 *
 * `confine/records.ts` explains the change: the copilot is an ordinary session
 * now, with the person's own account, and its conversation is written into that
 * profile's store like every other session's. **Nothing creates a copilot home
 * any more.**
 *
 * Two things follow, and only the second is obvious.
 *
 *  1. The privileged channel is gone at the source. A store that answers for
 *     every project, holding files an agent may write, is what made this a
 *     copilot-shaped hole rather than a machine-shaped one — and the copilot no
 *     longer has such a store.
 *  2. **Every install upgraded from a build that jailed it still has one**, on
 *     disk, in that root, with real conversations in it — and with anything a
 *     jailed copilot ever wrote there. Removing the scope because the home is no
 *     longer created would put all of it back in front of every project. So the
 *     scope stays installed at boot, and this file is what says so.
 *
 * ## Why the proof has the shape it has
 *
 * It is *not* a boundary test with a denial at the end of it, and writing one
 * would be dishonest — for a stronger reason than before. The copilot can write
 * that file. So can any other agent session on this machine, into the very same
 * store, because they share the person's `~/.claude`; that is the honest limit
 * and it is stated rather than papered over. What this file proves is the thing
 * that *is* still specific to the copilot: a store of its own that four readers
 * scan answers for one folder and no other.
 *
 * The rest of the file asks the readers, and it asks all three questions that
 * matter: the forged one is gone, the copilot's real one is still there, and a
 * paired phone's transcript for the same project is untouched.
 *
 * The last of those is the one worth being careful about. A phone that starts a
 * session on the desktop writes into its own device home, and the desktop
 * reading that home is the entire reason `transcriptDirs` answers with a list.
 * Narrowing device homes as well would need a per-device folder list that
 * `remote/folder-grants.ts` deliberately does not always have — "absence is not
 * denial" — so they are left exactly as they were, and a test says so.
 */

import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { deviceHomesRoot } from './confine'
import { recordsFencePaths, recordsFenceProfile } from './confine/records'
import { SANDBOX_EXEC } from './confine/seatbelt'
import { copilotPaths, type CopilotPaths } from './copilot-home'
import { createHostCore } from './host-core'
import { installPaths, resetPaths } from './platform/paths'
import { COPILOT_HOME_KEY, copilotHomeScope } from './copilot-session'
import {
  configDirs,
  encodeProjectPath,
  homeScopes,
  installHomeScopes,
  listTranscripts,
  newestConversation,
  resetHomeScopes,
  TranscriptWatcher,
  transcriptDirs,
} from './transcript'

const onMac = process.platform === 'darwin'

/** The project the copilot is trying to put words into. It has no idea. */
const VICTIM = '/fake/somebody-elses-api'

/**
 * One line of a transcript, in the shape the real CLI writes.
 *
 * Enough for `parseEventLine` to take it seriously — a `usage` block on an
 * `assistant` message — because a forgery that the readers *ignored as
 * malformed* would prove nothing about whether they were looking.
 */
function line(id: string, cwd: string): string {
  return `${JSON.stringify({
    type: 'assistant',
    uuid: `${id}-u`,
    requestId: `req_${id}`,
    timestamp: new Date().toISOString(),
    cwd,
    sessionId: id,
    isSidechain: false,
    message: {
      id,
      model: 'claude-opus-5',
      role: 'assistant',
      usage: { input_tokens: 1, output_tokens: 1_000_000, cache_read_input_tokens: 0 },
    },
  })}\n`
}

/* -------------------------------------------------- the write, in the sandbox -- */

interface Ran {
  code: number
  stdout: string
  stderr: string
}

let root = ''
let userData = ''
let homes = ''
let copilotDeviceHome = ''
let paths: CopilotPaths
let profile = ''

function sh(line: string): Promise<Ran> {
  return new Promise((resolve) => {
    execFile(
      SANDBOX_EXEC,
      ['-p', profile, '/bin/sh', '-c', line],
      { cwd: paths.root, timeout: 20_000, encoding: 'utf8' },
      (error, stdout, stderr) => {
        const code =
          error && typeof (error as { code?: unknown }).code === 'number'
            ? (error as { code: number }).code
            : error
              ? 1
              : 0
        resolve({ code, stdout, stderr })
      },
    )
  })
}

beforeAll(() => {
  // Realpathed for the reason `plan.ts` measures: `/var` is a symlink to
  // `/private/var`, Seatbelt matches the resolved name, and an expectation
  // composed from the unresolved one asks about paths the profile never names.
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-forgery-')))
  userData = join(root, 'user-data')
  mkdirSync(userData, { recursive: true })

  paths = copilotPaths(userData)
  homes = deviceHomesRoot(join(userData, 'remote'))
  copilotDeviceHome = join(homes, COPILOT_HOME_KEY)

  mkdirSync(paths.memory, { recursive: true })
  mkdirSync(paths.log, { recursive: true })
  /*
   * A copilot home, as an install upgraded from a build that jailed the copilot
   * still has one: the home, its `tmp` (that session's `TMPDIR`), and the store
   * the CLI filled. Nothing creates this now — which is exactly why it has to be
   * built by hand here, and exactly the case the scope still exists for.
   */
  mkdirSync(join(copilotDeviceHome, 'tmp'), { recursive: true })
  mkdirSync(join(copilotDeviceHome, '.claude', 'projects'), { recursive: true })

  if (!onMac) return
  /*
   * The real profile the copilot is launched with — which is now the records
   * fence rather than a jail, and the substitution is the point of the first
   * block below: the write it makes was permitted under the old profile and is
   * permitted under this one, so the protection that closed this hole was never
   * the sandbox and does not depend on one.
   */
  profile = recordsFenceProfile(recordsFencePaths(userData))
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

afterEach(() => resetHomeScopes())

describe.skipIf(!onMac)('the write itself is permitted, and stays permitted', () => {
  it('runs at all — without this the next assertion means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('writes a transcript under another project name, from inside the real profile', async () => {
    /*
     * The forgery, attempted the way an agent would attempt it: `mkdir -p` a
     * directory named for the encoding of somebody else's project inside its
     * own store, and drop a syntactically real transcript in it.
     *
     * This **succeeds**, and it must. That directory tree is the copilot's own
     * home, which is where its own CLI writes its own conversation; a boundary
     * that refused it would be a copilot that cannot talk. The fix is not here.
     */
    const forged = join(
      copilotDeviceHome,
      '.claude',
      'projects',
      encodeProjectPath(VICTIM),
      'fabricated.jsonl',
    )
    const ran = await sh(
      `mkdir -p ${JSON.stringify(join(forged, '..'))} && ` +
        `printf %s ${JSON.stringify(line('fabricated', VICTIM))} > ${JSON.stringify(forged)}`,
    )

    expect(ran.stderr).toBe('')
    expect(ran.code).toBe(0)
    expect(existsSync(forged)).toBe(true)
  })

  it('and its own real conversation is written the same way, in the same store', async () => {
    // The control that keeps the assertions below honest: if the copilot's own
    // transcript were not there either, "the forged one is not found" would be
    // true of a store nobody reads at all.
    const real = join(
      copilotDeviceHome,
      '.claude',
      'projects',
      encodeProjectPath(paths.root),
      'real.jsonl',
    )
    const ran = await sh(
      `mkdir -p ${JSON.stringify(join(real, '..'))} && ` +
        `printf %s ${JSON.stringify(line('real', paths.root))} > ${JSON.stringify(real)}`,
    )
    expect(ran.code).toBe(0)
    expect(existsSync(real)).toBe(true)
  })
})

/* --------------------------------------------------------- and now the readers -- */

/**
 * The same fixture without a sandbox, so the reader assertions run everywhere.
 *
 * The section above proves the copilot can really produce these files. This one
 * produces them directly, which is the same bytes in the same places, and asks
 * the question every reader in the app asks.
 */
describe('what the readers find', () => {
  let store: string
  let phoneStore: string
  let profileConfig: string

  beforeAll(() => {
    profileConfig = join(root, 'profile-config')
    mkdirSync(join(profileConfig, 'projects'), { recursive: true })

    store = join(copilotDeviceHome, '.claude', 'projects')

    // The forgery: a conversation about somebody else's repository, in the
    // copilot's store.
    mkdirSync(join(store, encodeProjectPath(VICTIM)), { recursive: true })
    writeFileSync(join(store, encodeProjectPath(VICTIM), 'fabricated.jsonl'), line('fabricated', VICTIM))

    // The copilot's own conversation, in the same store, which must survive.
    mkdirSync(join(store, encodeProjectPath(paths.root)), { recursive: true })
    writeFileSync(join(store, encodeProjectPath(paths.root), 'real.jsonl'), line('real', paths.root))

    // A paired phone that has genuinely run a session in the victim project.
    // Nothing about this device changes, and that is the point of the last two
    // cases in this block.
    const phone = join(homes, 'a1b2c3d4e5f60718')
    mkdirSync(join(phone, 'tmp'), { recursive: true })
    phoneStore = join(phone, '.claude', 'projects')
    mkdirSync(join(phoneStore, encodeProjectPath(VICTIM)), { recursive: true })
    writeFileSync(join(phoneStore, encodeProjectPath(VICTIM), 'phone.jsonl'), line('phone', VICTIM))
  })

  /**
   * The stores this block asks about.
   *
   * A function rather than a `const`, because a `const` in a `describe` body is
   * evaluated at collection time — before either `beforeAll` has run — so it
   * would capture an undefined config directory and quietly fall back to this
   * developer's real `~/.claude`. That failed loudly once here and would have
   * failed silently in a test that only asserted on absence.
   */
  const scope = (): { configDir: string; deviceHomes: string } => ({
    configDir: profileConfig,
    deviceHomes: homes,
  })

  it('found the forgery before the scope existed — the hole was real', async () => {
    /*
     * The regression case, and it has to come first.
     *
     * `homeScopes: []` is the old behaviour exactly: every confined store
     * answers for every project. If this ever stops finding the file, the
     * assertions below stop meaning anything — they would be passing because
     * the fixture broke rather than because the fix works.
     */
    const dirs = transcriptDirs(VICTIM, { ...scope(), homeScopes: [] })
    expect(dirs).toContain(join(store, encodeProjectPath(VICTIM)))

    const found = (await Promise.all(dirs.map(listTranscripts))).flat()
    expect(found.map((file) => file.sessionId).sort()).toEqual(['fabricated', 'phone'])
  })

  it('does not offer it once the copilot store answers for its own folder only', async () => {
    installHomeScopes([copilotHomeScope(userData)])

    const dirs = transcriptDirs(VICTIM, scope())
    expect(dirs).not.toContain(join(store, encodeProjectPath(VICTIM)))

    const found = (await Promise.all(dirs.map(listTranscripts))).flat()
    expect(found.map((file) => file.sessionId)).not.toContain('fabricated')
  })

  it('still finds a real paired-device transcript for the same project', async () => {
    /*
     * The thing that must not break, stated as its own case rather than as a
     * clause of the one above.
     *
     * A phone starts a session on this desktop, the confined session writes its
     * conversation into that device's own home, and the desktop reading it is
     * the entire reason `transcriptDirs` answers with a list. If narrowing the
     * copilot's store had caught paired devices in the same net, chat mode and
     * the cost pane would go blank for every session started from a phone —
     * which is the exact regression `transcript.ts` was written to fix.
     */
    installHomeScopes([copilotHomeScope(userData)])

    const dirs = transcriptDirs(VICTIM, scope())
    expect(dirs).toContain(join(phoneStore, encodeProjectPath(VICTIM)))

    const found = (await Promise.all(dirs.map(listTranscripts))).flat()
    expect(found.map((file) => file.sessionId)).toEqual(['phone'])

    // And through the reader chat mode actually calls, not only the directory
    // listing underneath it.
    const newest = await newestConversation(join(phoneStore, encodeProjectPath(VICTIM)))
    expect(newest?.sessionId).toBe('phone')
  })

  it('still finds the copilot own conversation, which is why its home is in that root', async () => {
    installHomeScopes([copilotHomeScope(userData)])

    const dirs = transcriptDirs(paths.root, scope())
    expect(dirs).toContain(join(store, encodeProjectPath(paths.root)))

    const found = (await Promise.all(dirs.map(listTranscripts))).flat()
    expect(found.map((file) => file.sessionId)).toEqual(['real'])
  })

  it('leaves the list of stores alone — the narrowing is per project, not per store', () => {
    // `configDirs` answers "which stores exist", and `isTranscriptPath` is built
    // on it: the copilot's own transcript is loaded by path like any other, so
    // dropping its store from that list would refuse its own chat view. The
    // narrowing belongs one level up, where a project becomes a list of
    // directories.
    installHomeScopes([copilotHomeScope(userData)])
    expect(configDirs(scope())).toContain(join(copilotDeviceHome, '.claude'))
  })

  it('does not surface the forgery in the pane a person actually looks at', async () => {
    /*
     * The same question asked of `TranscriptWatcher`, because that is what the
     * cost pane and the alert watcher are built on and because it takes a
     * second path to the answer: it watches the stores as well as listing them,
     * and a watcher left subscribed to a store it no longer lists would enqueue
     * the forged file the moment it changed. `enqueueFromStore` matches on the
     * encoded directory name alone — which a fabricated directory carries by
     * construction — so the filtering has to happen when the subscription is
     * made.
     */
    installHomeScopes([copilotHomeScope(userData)])

    const watcher = new TranscriptWatcher({
      cwd: VICTIM,
      configDir: profileConfig,
      deviceHomes: homes,
      debounceMs: 20,
      onUpdate: () => undefined,
    })
    await watcher.start()
    const summary = watcher.summary()
    watcher.stop()

    expect(summary.sessions.map((session) => session.sessionId)).toEqual(['phone'])
  }, 10_000)
})

/**
 * And it is installed by the thing that boots, not by the thing that opens.
 *
 * This repository's most expensive class of bug, stated in `CLAUDE.md` and paid
 * for twice, is a feature wired to a button and never wired to boot. A scope
 * installed when somebody opens the copilot is a scope that is absent for every
 * transcript read before they do — which is all of them, on a machine where
 * nobody ever opens it and a copilot home from a previous run is still on disk.
 *
 * So it goes in `createHostCore`, beside `installDeviceHomes`, which both shells
 * call. This is the assertion that it really is there.
 */
describe('the scope is in force from assembly', () => {
  afterEach(() => {
    resetHomeScopes()
    resetPaths()
  })

  it('is installed by createHostCore, for the userData that shell was given', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-scope-boot-')))
    installPaths({
      userData: () => dir,
      home: () => dir,
      downloads: () => dir,
      temp: () => dir,
    } as never)

    createHostCore({ storageDir: join(dir, 'remote'), userData: dir })

    // Composed from `userData` rather than guessed from `storageDir`: the
    // headless build takes its state directory from a flag, so a `dirname` in
    // `host-core.ts` would be a security rule that silently stops applying the
    // moment somebody passes `--state-dir`.
    expect(homeScopes()).toEqual([
      { home: join(dir, 'remote', 'device-home', 'copilot'), folder: join(dir, 'copilot') },
    ])
    rmSync(dir, { recursive: true, force: true })
  })
})
