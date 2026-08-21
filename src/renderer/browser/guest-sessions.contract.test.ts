import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

import { readSessions } from './agent-target'

/**
 * The roster this app's own host publishes, and the picker that reads it.
 *
 * The two sides are in files that may not import each other — `tsconfig.web.json`
 * keeps the renderer out of `src/main`, and that is the right boundary — so the
 * only thing holding them together is four field names crossing an `unknown`.
 * The same seam has cost this project a screen once already: `dev:ports` sent
 * `{ port, process, guessed }` and the start page read `{ port, command, likely }`,
 * and every row simply rendered blank, which reads as a design choice rather than
 * a bug.
 *
 * It is worth guarding here more than anywhere, because a blank answer on *this*
 * seam is invisible in a different way: an empty session picker is exactly what
 * a desktop with no devices connected correctly shows. The whole reason the
 * fourth arrangement of the browser feature could never fire was a list that was
 * always honestly empty, and a typo in one of these four names would put it back
 * with no symptom at all.
 *
 * `machines/live.test.ts` proves the other half over a real relay: a real link
 * announces, and `RemoteConnection` really carries the sessions. This is the half
 * that test cannot reach.
 */

const read = (...parts: string[]): string => readFileSync(join(__dirname, ...parts), 'utf8')

/** Field names declared on an `export interface RemoteConnection` block. */
function fieldsOf(source: string): string[] {
  const block = /export interface RemoteConnection \{([\s\S]*?)\n\}/.exec(source)?.[1] ?? ''
  return [...block.matchAll(/^ {2}(\w+)\??:/gm)].map((match) => match[1]).sort()
}

describe('the picker reads the roster main actually publishes', () => {
  const declared = fieldsOf(read('..', '..', 'main', 'remote', 'server.ts'))

  it('main declares the fields this picker was written against', () => {
    // Allowed to change — but the reader below has to change with it, which is
    // the whole point of failing here rather than silently listing nothing.
    expect(declared).toEqual([
      'address',
      'connectedAt',
      'deviceId',
      'deviceName',
      'id',
      'platform',
      'sessionIds',
      'sessions',
      'tunnels',
    ])
  })

  it('every field the picker reads off a connection is one main sends', () => {
    // The four it actually depends on. `sessionIds` is deliberately not among
    // them and must never be confused with `sessions`: that one is *this*
    // machine's sessions the device is watching, the opposite computer and the
    // opposite direction.
    for (const field of ['deviceId', 'deviceName', 'connectedAt', 'sessions']) {
      expect(declared, `the picker reads \`${field}\``).toContain(field)
    }
  })

  it('reads a row shaped exactly as main publishes it, field for field', () => {
    /*
     * Written out in full rather than picked down to the four, so that a row
     * carrying everything main sends is proved to produce a target — the failure
     * this guards is a reader that is right about four names and wrong about the
     * shape around them.
     */
    const roster = [
      {
        id: 'connection-1',
        deviceId: 'device-1',
        deviceName: 'Office PC',
        platform: 'win32',
        address: '127.0.0.1',
        connectedAt: 1_700_000_000_000,
        sessionIds: [],
        sessions: [
          {
            id: 'pty-1',
            title: 'terminaldeck',
            cwd: '/Users/apple/Projects/terminaldeck',
            provider: 'claude',
            status: 'idle',
            exitCode: null,
          },
        ],
        tunnels: [],
      },
    ]

    const rows = readSessions({ here: [], elsewhere: null, guests: roster })
    expect(rows).toHaveLength(1)
    expect(rows[0].id).toBe('pty-1')
    expect(rows[0].machineId).toBe('device-1')
    expect(rows[0].dialledIn).toBe(true)
    expect(rows[0].label).toBe('Office PC · terminaldeck · Session 1')
  })
})
