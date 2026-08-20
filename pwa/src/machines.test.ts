/**
 * The collection of machines, and the migration that must not sign anybody out.
 *
 * `app.terminaldeck.dev` is live and people are paired to it right now, under the
 * one-credential key `pair.ts` owns. The single most damaging thing this change
 * could do is not a layout bug — it is a deploy that greets every one of them with
 * a pair screen and no explanation. The first block below is that case, written
 * as a test so it cannot be removed by accident.
 *
 * The rest are the three verbs a Machines screen has to be right about — switch,
 * rename, forget — and the one property that makes them safe: a machine is
 * identified by its **endpoint**, not by its credential, so re-pairing after a
 * revoke updates a row rather than growing a second one for the same computer.
 */

import { describe, expect, it } from 'vitest'
import { DIRECT, type DeckEndpoint } from './endpoint'
import { CREDENTIAL_KEY, REMEMBERED_TTL_MS, type StoredCredential } from './pair'
import {
  DIRECT_MACHINE_ID,
  MACHINES_KEY,
  MAX_NICKNAME_LENGTH,
  cleanNickname,
  clearBook,
  currentMachine,
  endpointSummary,
  forgetMachine,
  lastReachedSentence,
  loadMachines,
  machineById,
  machineId,
  machineLabel,
  machineLabels,
  readBook,
  renameMachine,
  saveBook,
  selectMachine,
  withCredential,
  withMachine,
  type MachineBook,
  type StoredMachine,
} from './machines'
import { memoryStorage, type Stores } from './remember'

const NOW = 1_760_000_000_000
const MAC = 'M9G95TNJT64Q928VW3HVRYDR8J'
const PC = 'K2X4PQRS7T9V5W3Y5Z6A8B7C2D'

function stores(): Stores {
  return { browser: memoryStorage(), tab: memoryStorage() }
}

function relay(hostId: string): DeckEndpoint {
  return {
    kind: 'relay',
    url: 'wss://relay.terminaldeck.dev',
    hostId,
    // Thirty-two bytes, because `asEndpoint` decodes the key before it will call
    // something a relay endpoint — a shorter one reads back as a direct pairing.
    hostKey: Buffer.alloc(32, 7).toString('base64'),
  }
}

function credential(endpoint: DeckEndpoint, over: Partial<StoredCredential> = {}): StoredCredential {
  return {
    token: 'dev1.secret',
    deviceId: 'dev1',
    deviceName: 'Chrome on Mac',
    pairedAt: NOW - 60_000,
    hostPlatform: 'mac',
    endpoint,
    expiresAt: NOW + REMEMBERED_TTL_MS,
    ...over,
  }
}

function machine(hostId: string, over: Partial<StoredMachine> = {}): StoredMachine {
  return { id: hostId, nickname: null, hostName: null, credential: credential(relay(hostId)), ...over }
}

describe('what identifies a machine', () => {
  it('is the relay host id, which survives a re-pair', () => {
    expect(machineId(relay(MAC))).toBe(MAC)
  })

  it('is a constant for a direct pairing, because there is only ever one', () => {
    // The direct route is the page being served by the very process it then talks
    // to, so the address is `location` — and keying on it would give one desktop
    // two rows when it is reached at two addresses.
    expect(machineId(DIRECT)).toBe(DIRECT_MACHINE_ID)
  })

  it('names a machine by its nickname, then by the name the machine gave itself', () => {
    expect(machineLabel(machine(MAC, { nickname: 'Studio Mac' }), 'x')).toBe('Studio Mac')
    expect(machineLabel(machine(MAC, { hostName: 'MacBookPro' }), 'x')).toBe('MacBookPro')
    // The person's word always wins over the machine's own.
    expect(machineLabel(machine(MAC, { nickname: 'Studio Mac', hostName: 'MacBookPro' }), 'x')).toBe('Studio Mac')
  })

  it('falls back to the platform noun before the slot code', () => {
    /*
     * The regression: two chips reading `2JJGF8` and `9ZA6K3` for somebody who
     * owns one Mac and one Windows PC. Those are relay slot codes and they name
     * nothing anybody owns. A machine paired before the name was kept has no
     * `hostName`, but it does have `hostPlatform`, which it stored from the
     * `welcome` frame — so the fallback is a word rather than a code.
     */
    expect(machineLabel(machine(MAC), 'x')).toBe('Mac')
    expect(machineLabel(machine(MAC, { credential: credential(relay(MAC), { hostPlatform: 'windows' }) }), 'x')).toBe('PC')
    // Except when the machine never said what it was — every chip reading
    // "desktop" would be worse than every chip reading a code.
    const mute = machine(MAC, { credential: credential(relay(MAC), { hostPlatform: 'unknown' }) })
    expect(machineLabel(mute, 'x')).toBe(MAC.slice(0, 6))
    // Shortened at the *front*, because the pairing screen and the desktop both
    // show the full id and the eye compares the beginning.
    expect(MAC.startsWith(machineLabel(mute, 'x'))).toBe(true)
  })

  it('breaks a tie between two chips that would read the same', () => {
    // `machineLabel` cannot see the other machines, so two Macs paired before
    // names were kept would both read "Mac" — the same defect wearing a
    // different mask. The list-level function is where the tie is broken.
    const two = [machine(MAC), machine(PC)]
    expect(machineLabels(two, 'x')).toEqual([`Mac ${MAC.slice(0, 6)}`, `Mac ${PC.slice(0, 6)}`])
    // Nothing is appended when the labels already differ.
    expect(machineLabels([machine(MAC, { hostName: 'MacBookPro' }), machine(PC, { hostName: 'Office' })], 'x')).toEqual([
      'MacBookPro',
      'Office',
    ])
  })

  it('says where a machine is and who can read the session', () => {
    // The last clause is the point rather than decoration: it is the difference
    // between the two routes.
    expect(endpointSummary(machine(MAC), 'x')).toBe(`${MAC} via relay.terminaldeck.dev — end-to-end sealed`)
    expect(
      endpointSummary({ id: 'direct', nickname: null, hostName: null, credential: credential(DIRECT) }, 'mac.ts.net'),
    ).toBe(
      'mac.ts.net — direct, over your own network',
    )
  })

  it('holds a nickname to a length a header can draw', () => {
    expect(cleanNickname('  Studio  ')).toBe('Studio')
    expect(cleanNickname('')).toBeNull()
    expect(cleanNickname('m'.repeat(80))).toHaveLength(MAX_NICKNAME_LENGTH)
  })
})

describe('the migration nobody may notice', () => {
  it('finds the single pairing every existing browser is holding', () => {
    /*
     * The case that would be a public regression: somebody paired to the live site
     * opens it after this ships. There is no book yet, and the one-credential
     * record is what they have.
     */
    const kept = stores()
    kept.browser.setItem(CREDENTIAL_KEY, JSON.stringify(credential(relay(MAC))))

    const found = loadMachines(kept, NOW)
    expect(found?.remember).toBe('this-browser')
    expect(found?.book.machines).toHaveLength(1)
    expect(found?.book.currentId).toBe(MAC)
    expect(found?.book.machines[0].credential.token).toBe('dev1.secret')
  })

  it('prefers the book once there is one, and does not read the mirror twice', () => {
    const kept = stores()
    kept.browser.setItem(CREDENTIAL_KEY, JSON.stringify(credential(relay(MAC))))
    saveBook(kept, 'this-browser', { machines: [machine(MAC), machine(PC)], currentId: PC })

    const found = loadMachines(kept, NOW)
    expect(found?.book.machines.map((held) => held.id)).toEqual([MAC, PC])
    expect(found?.book.currentId).toBe(PC)
  })

  it('reads the tab’s book over the durable one, like the credential', () => {
    const kept = stores()
    saveBook(kept, 'this-browser', { machines: [machine(MAC)], currentId: MAC })
    saveBook(kept, 'this-tab', { machines: [machine(PC)], currentId: PC })
    // `saveBook` clears the other store as it writes, so this is also the
    // assertion that a durable book does not survive a "just for this visit"
    // answer given afterwards.
    expect(loadMachines(kept, NOW)?.book.currentId).toBe(PC)
    expect(kept.browser.getItem(MACHINES_KEY)).toBeNull()
  })

  it('answers null when there is nothing anywhere', () => {
    expect(loadMachines(stores(), NOW)).toBeNull()
  })

  it('forgets every machine in both stores', () => {
    const kept = stores()
    saveBook(kept, 'this-browser', { machines: [machine(MAC)], currentId: MAC })
    clearBook(kept)
    expect(loadMachines(kept, NOW)).toBeNull()
  })
})

describe('reading a book back', () => {
  it('drops a machine whose credential has expired, and keeps the rest', () => {
    /*
     * The expiry is `pair.ts`'s rule and it is deliberately not restated here —
     * the record goes through `loadCredential`, which is the function that owns
     * the sliding window, the endpoint migration and the host-platform folding.
     */
    const storage = memoryStorage()
    const stale = machine(PC, { credential: credential(relay(PC), { expiresAt: NOW - 1 }) })
    storage.setItem(MACHINES_KEY, JSON.stringify({ machines: [machine(MAC), stale], currentId: PC }))

    const book = readBook(storage, NOW)
    expect(book?.machines.map((held) => held.id)).toEqual([MAC])
    // And the selection follows: pointing at a machine that expired out of the
    // list would leave the client connecting to nothing with no way back.
    expect(book?.currentId).toBe(MAC)
  })

  it('keeps the other machines when one record is unreadable', () => {
    // One bad record does not discard the list, for the same reason `parseSession`
    // does not: a browser that can still reach two of its three machines is
    // useful, and one that shows a pair screen because the third was half-written
    // is not.
    const storage = memoryStorage()
    storage.setItem(
      MACHINES_KEY,
      JSON.stringify({ machines: [machine(MAC), { id: PC }, null, 7], currentId: MAC }),
    )
    expect(readBook(storage, NOW)?.machines.map((held) => held.id)).toEqual([MAC])
  })

  it('re-keys a record whose id disagrees with its endpoint', () => {
    // The id and the endpoint are one fact written twice, and the endpoint decides
    // — the port book and the switcher both index on the result.
    const storage = memoryStorage()
    storage.setItem(MACHINES_KEY, JSON.stringify({ machines: [{ ...machine(MAC), id: 'edited' }], currentId: 'edited' }))
    const book = readBook(storage, NOW)
    expect(book?.machines[0].id).toBe(MAC)
    expect(book?.currentId).toBe(MAC)
  })

  it('treats an unreadable store as nothing to say, not as an empty list', () => {
    // Null is what lets `readAcross` fall through to the other store; an empty
    // book is a person who forgot their last machine. Folding them together would
    // make a browser that had just unpaired pick a stale record back up.
    const storage = memoryStorage()
    storage.setItem(MACHINES_KEY, 'not json')
    expect(readBook(storage, NOW)).toBeNull()
    storage.setItem(MACHINES_KEY, JSON.stringify({ machines: [], currentId: null }))
    expect(readBook(storage, NOW)).toEqual({ machines: [], currentId: null })
  })
})

describe('the three verbs', () => {
  const book: MachineBook = { machines: [machine(MAC), machine(PC)], currentId: MAC }

  it('adds a machine at the end and makes it current', () => {
    const third = machine('Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9')
    const next = withMachine(book, third)
    expect(next.machines.map((held) => held.id)).toEqual([MAC, PC, third.id])
    expect(next.currentId).toBe(third.id)
  })

  it('updates a machine in place when it is re-paired, keeping its name and place', () => {
    /*
     * The property the whole id scheme exists for. A re-pair after a revoke mints
     * a brand-new credential for the same computer, and a second row for it would
     * split the machine's port names — which are keyed on the same id — across two
     * entries nobody can tell apart.
     */
    const named: MachineBook = { machines: [machine(MAC, { nickname: 'Studio' }), machine(PC)], currentId: PC }
    const next = withMachine(named, machine(MAC, { credential: credential(relay(MAC), { token: 'dev2.fresh' }) }))
    expect(next.machines).toHaveLength(2)
    expect(next.machines[0].nickname).toBe('Studio')
    expect(next.machines[0].credential.token).toBe('dev2.fresh')
    expect(next.currentId).toBe(MAC)
  })

  it('renews a credential without moving the selection', () => {
    // What every `welcome` does. It must not switch machines: a background
    // reconnect that stole the screen would be worse than one that failed.
    const next = withCredential(book, PC, credential(relay(PC), { token: 'renewed' }))
    expect(next.currentId).toBe(MAC)
    expect(machineById(next, PC)?.credential.token).toBe('renewed')
  })

  it('renames one and cleans what was typed', () => {
    const next = renameMachine(book, PC, '  The office PC  ')
    expect(machineById(next, PC)?.nickname).toBe('The office PC')
    expect(machineById(renameMachine(next, PC, ''), PC)?.nickname).toBeNull()
  })

  it('switches only to a machine that is on the list', () => {
    expect(selectMachine(book, PC).currentId).toBe(PC)
    expect(selectMachine(book, 'nobody').currentId).toBe(MAC)
  })

  it('forgets one and leaves every other machine alone', () => {
    // The sentence on the screen promises exactly this.
    const next = forgetMachine(book, PC)
    expect(next.machines.map((held) => held.id)).toEqual([MAC])
    expect(next.currentId).toBe(MAC)
  })

  it('moves the selection when the machine being used is the one forgotten', () => {
    const next = forgetMachine(book, MAC)
    expect(next.currentId).toBe(PC)
    expect(currentMachine(next)?.id).toBe(PC)
  })

  it('leaves no current machine when the last one goes', () => {
    // Which is the state the pair screen is drawn for.
    const next = forgetMachine({ machines: [machine(MAC)], currentId: MAC }, MAC)
    expect(next).toEqual({ machines: [], currentId: null })
    expect(currentMachine(next)).toBeNull()
  })
})

describe('what a row says about a machine nothing is talking to', () => {
  it('reports when this browser last actually reached it', () => {
    /*
     * A fact rather than a guess. `renewed()` pushes the window out on every
     * `welcome`, and a `welcome` is the only frame that proves this browser got
     * through — a socket that merely opened proves nothing, because the relay will
     * open one against a host id whose owner revoked this device an hour ago.
     */
    const reached = (agoMs: number): string =>
      lastReachedSentence(
        machine(MAC, { credential: credential(relay(MAC), { expiresAt: NOW - agoMs + REMEMBERED_TTL_MS }) }),
        NOW,
      )
    expect(reached(30_000)).toBe('reached moments ago')
    expect(reached(20 * 60_000)).toBe('reached 20m ago')
    expect(reached(5 * 3_600_000)).toBe('reached 5h ago')
    expect(reached(26 * 3_600_000)).toBe('reached yesterday')
    expect(reached(9 * 86_400_000)).toBe('reached 9d ago')
  })

  it('says only "paired" when it has never got through', () => {
    // A browser that has only ever been refused has never reached the machine, and
    // a time would be a claim nobody checked.
    expect(lastReachedSentence(machine(MAC, { credential: credential(relay(MAC), { expiresAt: 0 }) }), NOW)).toBe(
      'paired',
    )
  })
})
