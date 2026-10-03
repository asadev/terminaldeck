import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { tiersFor } from './access-keys'
import { keyRig, type KeyRig } from './key-door.fixture'
import { LOCAL_CALLER, type Caller, type SessionView } from './surface'

/**
 * A session an outside AI app starts says so — not "the copilot".
 *
 * The first live run with an access key started a Claude session through the
 * relay, and `sessions.list` reported it `startedByCopilot: true` while the
 * sidebar filed it under "Copilot sessions". Neither was true: ChatGPT, or
 * whichever app held the key, started it. So the start writes `origin: 'app'`
 * and the key's name onto the session, the list reads them back, and "a
 * session you started" — which is what lets a caller type into it without
 * asking — means the caller that started it, per key.
 */

let dir = ''
let rig: KeyRig

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-app-origin-'))
  rig = keyRig(dir)
})
afterEach(() => {
  rig.door.stop()
  rmSync(dir, { recursive: true, force: true })
})

function keyCaller(id: string, name: string): Caller {
  return { kind: 'key', keyId: id, keyName: name, tiers: tiersFor('work'), askFirst: true }
}

async function list(caller: Caller): Promise<SessionView[]> {
  const result = await rig.control.call('sessions.list', {}, { caller })
  return (result.value as { sessions: SessionView[] }).sessions
}

describe('a session an AI app starts', () => {
  it('is written down as that app’s, by its key’s name', async () => {
    const { id } = rig.key('work', { name: 'E2E test (Claude)' })
    const result = await rig.control.call('sessions.start', { cwd: '/work/site' }, { caller: keyCaller(id, 'E2E test (Claude)') })
    expect(result.ok).toBe(true)
    expect(rig.app.inputs[0]).toMatchObject({ origin: 'app', originApp: 'E2E test (Claude)' })
  })

  it('is listed as started by that app and not by the copilot — to the app and to the copilot', async () => {
    const { id } = rig.key('work', { name: 'E2E test (Claude)' })
    const app = keyCaller(id, 'E2E test (Claude)')
    await rig.control.call('sessions.start', { cwd: '/work/site' }, { caller: app })
    for (const caller of [app, LOCAL_CALLER]) {
      const started = (await list(caller)).find((session) => session.cwd === '/work/site')
      expect(started, caller.kind).toMatchObject({ startedByCopilot: false, startedByApp: 'E2E test (Claude)' })
    }
  })

  it('leaves the copilot’s own sessions as the copilot’s', async () => {
    await rig.control.call('sessions.start', { cwd: '/work/site' })
    expect(rig.app.inputs[0]).toMatchObject({ origin: 'copilot' })
    expect(rig.app.inputs[0].originApp).toBeUndefined()
    const started = (await list(LOCAL_CALLER)).find((session) => session.cwd === '/work/site')
    expect(started).toMatchObject({ startedByCopilot: true, startedByApp: null })
  })

  it('may be typed into by the app that started it, and only by asking for anyone else', async () => {
    // No window to ask, so the copilot's alter call below is refused at once
    // rather than waiting out the question.
    rig.door.stop()
    rig = keyRig(dir, { approver: false })
    const one = rig.key('work', { name: 'One' })
    const two = rig.key('work', { name: 'Two' })
    await rig.control.call('sessions.start', { cwd: '/work/site' }, { caller: keyCaller(one.id, 'One') })
    const sessionId = (await list(LOCAL_CALLER)).find((session) => session.cwd === '/work/site')?.id ?? ''

    const own = await rig.control.call('sessions.send', { sessionId, text: 'hello' }, { caller: keyCaller(one.id, 'One') })
    expect(own.row.tier).toBe('act')
    // Another app, and the copilot, are not the starter: that is a change to
    // somebody else's session, so it is `alter` — refused outright for a Work
    // key, and put to the person for the copilot.
    const other = await rig.control.call('sessions.send', { sessionId, text: 'hi' }, { caller: keyCaller(two.id, 'Two') })
    expect(other.row.tier).toBe('alter')
    expect(other.refusal).toBe('not-granted')
    const copilot = await rig.control.call('sessions.send', { sessionId, text: 'hi' })
    expect(copilot.row.tier).toBe('alter')
    expect(copilot.refusal).toBe('no-approver')
  })

  it('is not counted among the copilot’s sessions on the status line', async () => {
    const { id } = rig.key('work', { name: 'E2E' })
    await rig.control.call('sessions.start', { cwd: '/work/site' }, { caller: keyCaller(id, 'E2E') })
    expect(rig.control.copilotSessions()).toEqual([])
  })
})
