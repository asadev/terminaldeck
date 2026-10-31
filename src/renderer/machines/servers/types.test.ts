import { describe, expect, it } from 'vitest'
import {
  asAddResult,
  asFact,
  asFacts,
  asGitHubHostWire,
  asGrant,
  asHostControlWire,
  asLogLines,
  asOutcome,
  asPreview,
  asRefusal,
  asServers,
  asShellId,
  asShellOutput,
  asView,
  succeeded,
} from './types'

/**
 * What the window will and will not believe about a server.
 *
 * The three-state fact is the subject of most of this file, and the fixtures are
 * **measured** answers rather than invented ones — the three machines the probe
 * was run on before any of this was written: a rented box signed in to as its
 * owner, the same box signed in to as an ordinary account, and a container.
 * Three of the cells in that table are the third state doing its job, and each
 * of them would have been a lie under a model with only presence and absence.
 */

const AT = 1_700_000_000_000

function fact(known: string, over: Record<string, unknown> = {}): Record<string, unknown> {
  return { known, measuredAt: AT, how: 'asked', ...over }
}

describe('a fact has three states, and a fourth that is not a state', () => {
  it('reads all three', () => {
    expect(asFact(fact('yes', { value: 'Ubuntu' }), (raw) => (typeof raw === 'string' ? raw : null))).toEqual({
      known: 'yes',
      value: 'Ubuntu',
      measuredAt: AT,
      how: 'asked',
    })
    expect(asFact(fact('no'), () => null)).toEqual({ known: 'no', measuredAt: AT, how: 'asked' })
    expect(asFact({ known: 'cannot', measuredAt: AT, why: 'not allowed' }, () => null)).toEqual({
      known: 'cannot',
      measuredAt: AT,
      why: 'not allowed',
    })
  })

  /*
   * "We never asked" is expressed by the field being missing, not by a fourth
   * state and not by `no`. The difference reaches the screen: one draws "we have
   * not asked yet" and the other draws "there is none", and they send a person
   * to two different places.
   */
  it('turns something unreadable into absence rather than into a no', () => {
    expect(asFact(undefined, () => null)).toBeUndefined()
    expect(asFact({ known: 'maybe' }, () => null)).toBeUndefined()
    expect(asFact('nonsense', () => null)).toBeUndefined()
    // A `yes` whose value cannot be read is not a `yes` about nothing.
    expect(asFact(fact('yes', { value: 42 }), (raw) => (typeof raw === 'string' ? raw : null))).toBeUndefined()
  })
})

describe('the three machines this was measured on', () => {
  it('keeps "there is no init system here" as an answer rather than a failure', () => {
    // Measured inside both an Alpine and a Debian container. Neither has one,
    // and both are somebody's real server.
    expect(asFacts({ init: fact('yes', { value: 'container-none' }) }).init).toMatchObject({
      known: 'yes',
      value: 'container-none',
    })
  })

  it('never turns "we could not count them" into zero', () => {
    // Measured on a Debian container with neither counting tool installed. Zero
    // would be a claim about a machine we could not ask.
    const facts = asFacts({ listeners: { known: 'cannot', measuredAt: AT, why: 'no way to count' } })
    expect(facts.listeners).toMatchObject({ known: 'cannot' })
    expect(facts.listeners).not.toMatchObject({ known: 'yes' })
  })

  it('counts a list of things as a number, because the calm page shows a count', () => {
    const facts = asFacts({ listeners: fact('yes', { value: [{ port: 80 }, { port: 443 }] }) })
    expect(facts.listeners).toMatchObject({ known: 'yes', value: 2 })
  })

  it('refuses a share of something whose total is zero', () => {
    // A percentage of nothing is `NaN` or `Infinity` on screen, and neither is a
    // number anybody can act on. Unreadable is the honest answer.
    expect(asFacts({ disk: fact('yes', { value: { usedKb: 5, totalKb: 0 } }) }).disk).toBeUndefined()
  })

  it('reads memory however the server reported it', () => {
    // Disk arrives as used-and-total and memory as total-and-free, because that
    // is what the two measurements natively are. Nothing that draws them should
    // have to remember which is which.
    expect(asFacts({ memory: fact('yes', { value: { totalKb: 100, freeKb: 40 } }) }).memory).toMatchObject({
      known: 'yes',
      value: { usedKb: 60, totalKb: 100 },
    })
  })

  it('reads both spellings of the facts the two layers disagree about', () => {
    /*
     * A genuine collision rather than tolerance for its own sake: the probe's
     * record calls this sign-in's power `privilege` and the action layer's
     * slice calls it `root`. Reading both here is one small function; reading
     * them at every call site is a bug waiting for whichever site is written
     * last.
     */
    expect(asFacts({ root: fact('yes', { value: 'sudo-password' }) }).privilege).toMatchObject({
      known: 'yes',
      value: 'sudo-password',
    })
    expect(asFacts({ load1: fact('yes', { value: 0.4 }) }).load).toMatchObject({ known: 'yes', value: 0.4 })
    expect(asFacts({ web: fact('yes', { value: 'caddy' }) }).webServer).toMatchObject({ known: 'yes' })
  })
})

describe('what a card may ask a person to do', () => {
  it('drops a preview whose class is not one of the three', () => {
    /*
     * The three classes are the whole safety model: nothing changes, one press
     * puts it back, or the way back was recorded first. Anything outside them is
     * an action with no way back, which is the thing this version does not
     * ship — so it is dropped rather than drawn, because a drawn button is a
     * promise that it does.
     */
    expect(asPreview({ actionId: 'delete', label: 'Delete', klass: 'destructive', sentence: 'Gone.' })).toBeNull()
    expect(asPreview({ actionId: 'restart', label: 'Restart', klass: 'reversible', sentence: 'Brief.' })).toEqual({
      actionId: 'restart',
      klass: 'reversible',
      label: 'Restart',
      target: '',
      sentence: 'Brief.',
      wayBack: null,
      keeps: null,
    })
  })

  it('drops a preview with no word on its button', () => {
    expect(asPreview({ actionId: 'restart', klass: 'safe', sentence: 'x' })).toBeNull()
  })
})

describe('one server, measured', () => {
  const raw = {
    cards: [
      { id: 'c1', kind: 'site', name: 'Shop', detail: 'Served by nginx', running: true, url: 'https://example.com' },
      { id: 'c2', kind: 'app', name: 'Worker', detail: '', running: null },
      { id: '', kind: 'app', name: 'Nameless' },
    ],
    facts: { os: fact('yes', { value: 'Ubuntu 24.04' }) },
    offered: { c1: ['open', 'restart'], c2: [] },
    absent: { c1: [{ actionId: 'backup', because: 'We cannot tell what kind it is.' }, { actionId: 'x' }] },
    how: ['asked what is listening', ''],
    cannot: [{ what: 'containers', why: 'this sign-in may not ask' }, { what: 'nothing', why: '' }],
    measuredAt: AT,
  }

  it('keeps "we could not tell whether it is running" apart from "it is stopped"', () => {
    const view = asView(raw)
    expect(view?.cards[0].running).toBe(true)
    expect(view?.cards[1].running).toBeNull()
  })

  it('drops a card nothing can be done to, and keeps the rest', () => {
    expect(asView(raw)?.cards.map((card) => card.id)).toEqual(['c1', 'c2'])
  })

  it('drops an absence with no reason, because an empty line says nothing', () => {
    expect(asView(raw)?.absent.c1.map((entry) => entry.actionId)).toEqual(['backup'])
  })

  it('drops a gap with no reason for the same reason', () => {
    expect(asView(raw)?.cannot).toEqual([{ what: 'containers', why: 'this sign-in may not ask' }])
  })

  it('answers null for a reply that is not a view at all', () => {
    expect(asView('nope')).toBeNull()
  })
})

describe('nothing secret has a way across', () => {
  /*
   * The renderer has no field for a password, a key or a passphrase, so one sent
   * by mistake has nowhere to land. This is the cheap half of the guarantee —
   * the expensive half is that the main process never sends one — and it is
   * worth pinning because the failure is silent: an extra property on a JSON
   * object type-checks perfectly and rides along for free.
   */
  it('discards a credential that somehow arrives with a server', () => {
    const servers = asServers([
      {
        id: 's1',
        name: 'Shop',
        address: 'example.com',
        username: 'admin',
        credential: 'key',
        password: 'hunter2',
        key: '-----BEGIN OPENSSH PRIVATE KEY-----',
        passphrase: 'letmein',
      },
    ])
    const seen = JSON.stringify(servers)
    expect(seen).not.toContain('hunter2')
    expect(seen).not.toContain('letmein')
    expect(seen).not.toContain('PRIVATE KEY')
    // Which *kind* is stored is the one thing about a sign-in that may cross.
    expect(servers[0].credential).toBe('key')
  })

  it('carries the identity, which is public and checkable elsewhere', () => {
    const servers = asServers([
      { id: 's1', address: 'example.com', hostKey: { fingerprint: 'SHA256:abc', algorithm: 'ssh-ed25519' } },
    ])
    expect(servers[0].fingerprint).toBe('SHA256:abc')
  })
})

describe('a list that cannot be read is an empty one, not a crash', () => {
  it('drops rows with nothing to identify them and keeps the rest', () => {
    const servers = asServers([{ id: '', address: 'nowhere' }, { id: 's2', address: 'example.com' }, 'rubbish'])
    expect(servers.map((server) => server.id)).toEqual(['s2'])
    // A server with no name of its own is called by its address, which is what
    // the person typed and therefore what they will recognise.
    expect(servers[0].name).toBe('example.com')
  })

  it('answers an unreadable reply with an empty list rather than throwing', () => {
    expect(asServers(null)).toEqual([])
    expect(asServers('nope')).toEqual([])
  })
})

describe('answers that come back from a press', () => {
  it('treats anything that did not say it worked as not having worked', () => {
    expect(succeeded({ ok: true })).toBe(true)
    expect(succeeded({ ok: 'yes' })).toBe(false)
    expect(succeeded(null)).toBe(false)
    expect(succeeded(undefined)).toBe(false)
  })

  it('renders the refusal it was given and always has words for a silent one', () => {
    expect(asRefusal({ ok: false, sentence: 'That address did not answer.' }).sentence).toBe(
      'That address did not answer.',
    )
    expect(asRefusal(null).sentence).not.toBe('')
  })

  /*
   * The one failure that is not a failure to try again: the page stops. It has
   * to be *recognisable* rather than merely readable, because the whole value of
   * the check is that there is no way past it — and a sentence in a notice with
   * a "Try again" beside it is a way past it.
   */
  it('recognises the identity having changed, however it was reported', () => {
    expect(asRefusal({ ok: false, sentence: 'x', kind: 'identity-changed' }).identityChanged).toBe(true)
    expect(
      asRefusal({ ok: false, sentence: 'x', identity: { expected: 'SHA256:a', offered: 'SHA256:b' } }),
    ).toMatchObject({ identityChanged: true, identity: { expected: 'SHA256:a', offered: 'SHA256:b' } })
    expect(asRefusal({ ok: false, sentence: 'x' }).identityChanged).toBe(false)
  })

  it('reads the way back off an outcome, and drops a half-written one', () => {
    expect(asOutcome({ done: 'Restarted your website.', wayBack: { actionId: 'start', label: 'Start' } })).toEqual({
      done: 'Restarted your website.',
      wayBack: { actionId: 'start', label: 'Start' },
    })
    // A way back with no word on it is a button nobody can read, and one with no
    // action behind it is a button that does nothing.
    expect(asOutcome({ done: 'x', wayBack: { actionId: 'start' } }).wayBack).toBeNull()
  })

  it('reads a page of output only from a reply that said it worked', () => {
    expect(asLogLines({ ok: true, lines: ['a', 'b'] })).toEqual(['a', 'b'])
    expect(asLogLines({ ok: false, sentence: 'no' })).toEqual([])
  })

  it('reads a refusal to add a server, and never a success by omission', () => {
    expect(asAddResult({ ok: false, kind: 'needs-passphrase', sentence: 'That key is locked.' })).toEqual({
      ok: false,
      reason: 'needs-passphrase',
      message: 'That key is locked.',
    })
    const silent = asAddResult(null)
    expect(silent.ok).toBe(false)
    expect(silent.ok === false && silent.message !== '').toBe(true)
    const odd = asAddResult({ ok: false, reason: 'gremlins' })
    expect(odd.ok === false && odd.reason).toBe('unknown')
    // "It worked" with nothing to open is not a success.
    expect(asAddResult({ ok: true }).ok).toBe(false)
    expect(asAddResult({ ok: true, id: 's9' })).toEqual({ ok: true, id: 's9' })
  })
})

describe('the terminal', () => {
  it('takes a shell id only from a reply that opened one', () => {
    expect(asShellId({ ok: true, shellId: 's1 abc' })).toBe('s1 abc')
    expect(asShellId({ ok: false, sentence: 'no' })).toBeNull()
    expect(asShellId({ ok: true })).toBeNull()
  })

  it('drops a chunk of output that names no shell', () => {
    expect(asShellOutput({ data: 'hello' })).toBeNull()
    expect(asShellOutput({ shellId: 'a', data: 'hello' })).toEqual({ shellId: 'a', data: 'hello' })
  })
})

describe('the permission', () => {
  it('reads one that has an end, and refuses one that does not', () => {
    expect(asGrant({ serverId: 's1', expiresAt: AT, grantedAt: 1 })).toEqual({
      serverId: 's1',
      expiresAt: AT,
      grantedAt: 1,
    })
    // A permission with no expiry is the one thing a grant may never be.
    expect(asGrant({ serverId: 's1' })).toBeNull()
    expect(asGrant(null)).toBeNull()
  })
})

describe('the host over the relay, as the server page reads it', () => {
  it('reads a status, and keeps "no note" as null', () => {
    const wire = asHostControlWire({
      running: true,
      version: '0.14.0',
      address: '',
      pid: 4321,
      startedAt: 1000,
      uptimeSeconds: 3600,
      managed: 'systemd',
      note: null,
    })
    expect(wire).toEqual({
      running: true,
      version: '0.14.0',
      address: '',
      pid: 4321,
      startedAt: 1000,
      uptimeSeconds: 3600,
      managed: 'systemd',
      note: null,
    })
  })

  it('carries the note a restart sends, and falls unreadable supervision back to unknown', () => {
    const wire = asHostControlWire({
      running: true,
      version: '',
      managed: 'made up',
      note: 'Restarting — back in a moment.',
    })
    expect(wire?.managed).toBe('unknown')
    expect(wire?.note).toBe('Restarting — back in a moment.')
  })

  it('is null for anything that is not a reading', () => {
    expect(asHostControlWire(null)).toBeNull()
    expect(asHostControlWire('nope')).toBeNull()
  })
})

describe('that machine’s GitHub, as the server page reads it', () => {
  it('reads a connected login', () => {
    const wire = asGitHubHostWire({
      connected: true,
      login: 'asadev',
      name: 'Asad',
      avatarUrl: null,
      source: 'device-flow',
      appConfigured: true,
      installUrl: 'https://github.com/apps/x/installations/new',
      pending: null,
      failure: null,
      disconnect: 'This signs the machine out.',
    })
    expect(wire).toMatchObject({ connected: true, login: 'asadev', name: 'Asad' })
    expect(wire?.pending).toBeNull()
  })

  it('reads a device-flow prompt, and drops one with no code to type', () => {
    const good = asGitHubHostWire({
      connected: false,
      appConfigured: true,
      pending: { userCode: 'WXYZ-1234', verificationUri: 'https://github.com/login/device', expiresAt: 9000 },
    })
    expect(good?.pending?.userCode).toBe('WXYZ-1234')

    // A prompt with no code is not a prompt — it would draw a sign-in screen with
    // nothing on it. Dropped, so the card falls back to whatever else the reading
    // names.
    const empty = asGitHubHostWire({ connected: false, appConfigured: true, pending: { verificationUri: 'x' } })
    expect(empty?.pending).toBeNull()
  })

  it('is null for anything that is not a reading', () => {
    expect(asGitHubHostWire(null)).toBeNull()
    expect(asGitHubHostWire(42)).toBeNull()
  })
})
