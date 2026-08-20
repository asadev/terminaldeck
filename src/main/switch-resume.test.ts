import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createHostCore, type HostCore } from './host-core'

/**
 * The account switch keeps the conversation — proved at the spawn, not at the plan.
 *
 * ## Why this file exists rather than another case in `one-conversation.test.ts`
 *
 * Every piece of this was already tested and the feature was still broken, three
 * times over, in the way Asad reported twice:
 *
 *   > *"See, it is not going to keep it… It's not keeping the conversation
 *   > history… It should at least keep the conversation there, history there,
 *   > memory there when I switch between the accounts."*
 *
 * `one-conversation.test.ts` proved the guard refuses a resume while another
 * live session holds the folder. `session-switch.test.ts` proved the plan says
 * `resume: true`. Both were correct and they were about different subjects, so
 * nothing anywhere asked the only question that matters: *with the outgoing
 * session still alive, does the replacement actually get the flag?* It did not.
 * `performSwitch` starts the replacement before it stops the session it
 * replaces — deliberately, so a spawn that cannot start leaves a working agent
 * alone — and the guard, seeing a live session of the same provider in the same
 * folder, dropped `--continue` on every switch ever made. The plan, the log line
 * and the sheet all said the conversation followed.
 *
 * So this asserts through `startSession`, the one function that composes an
 * argument list, and reads `SessionMeta.resumed` — which is now set from that
 * argument list rather than from the request, for exactly the reason this test
 * exists.
 *
 * ## POSIX only, and the reason is the fixture rather than the feature
 *
 * The guard reads *live* sessions, so the first session has to still be running
 * when the second one spawns. That needs a command which stays up both with its
 * start arguments and with its resume arguments, and `/bin/cat` is one:
 * argument-less it reads stdin forever, and `cat -` does the same. Windows has
 * no equivalent reachable through the `cmd.exe /c <bin> <args>` wrapper a custom
 * agent is launched with, and a fixture that exits immediately would make both
 * cases below pass for the wrong reason — a dead session holds nothing.
 *
 * Nothing platform-specific is being skipped: what is proved here is the
 * composition of an argument list, and every branch of that decision is pinned
 * on both platforms in `one-conversation.test.ts`. This is the wiring between
 * them, which is what was missing.
 */

const windows = process.platform === 'win32'

let dir = ''
let core: HostCore

/**
 * A folder of its own for each case.
 *
 * Not tidiness: the guard is *about* a folder, and the sessions these cases
 * start stay alive until the file is done — so a shared directory would leave
 * the second case's replacement exempting one id while three other live
 * sessions from the first case still held the folder. That failed, correctly,
 * and it is precisely the fault the exemption must not have.
 */
function folder(): string {
  return mkdtempSync(join(dir, 'case-'))
}

beforeAll(async () => {
  if (windows) return
  dir = mkdtempSync(join(tmpdir(), 'td-switch-resume-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })

  const added = await core.agents.add({
    label: 'Held',
    description: '',
    command: '/bin/cat',
    // Both forms stay up: with no arguments `cat` reads stdin, and `cat -`
    // reads stdin. A resume list has to be non-empty or the guard is never
    // consulted at all — `argsForSpawn` returns the start arguments outright
    // for an agent that cannot continue anything.
    args: '',
    resumeArgs: '-',
  })
  expect(added.ok, 'the fixture agent has to be addable, or nothing below means anything').toBe(
    true,
  )
}, 30_000)

afterAll(async () => {
  if (windows) return
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  rmSync(dir, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
})

describe.skipIf(windows)('resuming while another session is alive in the folder', () => {
  it('refuses the flag to a second session, which is the rule', async () => {
    const cwd = folder()
    const held = await core.startSession({ cwd, cols: 80, rows: 24, provider: 'custom:held' })
    expect(core.ptys.list().some((s) => s.id === held.id && s.exitCode === null)).toBe(true)

    const second = await core.startSession({
      cwd,
      cols: 80,
      rows: 24,
      provider: 'custom:held',
      resume: true,
    })

    // Two tabs in one folder both resolving `--continue` is the measured fork
    // `one-conversation.ts` exists to prevent. Unchanged by anything here.
    expect(second.resumed).toBe(false)
  })

  it('hands it to a replacement that names the session it replaces', async () => {
    const cwd = folder()
    const outgoing = await core.startSession({
      cwd,
      cols: 80,
      rows: 24,
      provider: 'custom:held',
    })
    expect(core.ptys.list().some((s) => s.id === outgoing.id && s.exitCode === null)).toBe(true)

    const replacement = await core.startSession({
      cwd,
      cols: 80,
      rows: 24,
      provider: 'custom:held',
      resume: true,
      // The one thing an account switch says and nothing else does.
      replaces: outgoing.id,
    })

    expect(replacement.resumed).toBe(true)
  })

  it('still refuses when the id names a session that is not in this folder', async () => {
    // A replacement exempts *itself*, and one id only. An id from somewhere
    // else must not turn the guard off for the folder.
    const cwd = folder()
    const held = await core.startSession({ cwd, cols: 80, rows: 24, provider: 'custom:held' })
    expect(core.ptys.list().some((s) => s.id === held.id && s.exitCode === null)).toBe(true)

    const second = await core.startSession({
      cwd,
      cols: 80,
      rows: 24,
      provider: 'custom:held',
      resume: true,
      replaces: 'a-session-that-is-not-this-one',
    })

    expect(second.resumed).toBe(false)
  })
})
