import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { serverAddress, serverWhere } from '../../shared/server-where'
import { serverSummary } from './summary'
import { DEFAULT_PORT, ServerStore } from './store'

/**
 * What crosses the bridge about a server — through the **real store**, not a
 * literal shaped like one.
 *
 * ## Why a real store and not a fixture
 *
 * Because the bug was in the seam between the two. `StoredServer` has carried a
 * port since the store was written; the add form has asked for one since the
 * channel was; `connection.ts` dials it. Every one of those had tests and every
 * one passed. What had no test was the four-line mapping that turns a stored
 * row into the thing the window is handed — and that mapping simply did not
 * mention `port`, so the app dialled a server on 2222 correctly and then told
 * every screen it was at `192.0.2.11`.
 *
 * A fixture written by hand here would have had the same hole, because it would
 * have been written from the same field list. Starting from `store.add` means
 * the test cannot know less about a server than the store does.
 */

let dir = ''
let store: ServerStore

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-server-summary-'))
  store = new ServerStore(dir)
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('a stored server, as the window is handed it', () => {
  it('carries the port a person typed all the way across', () => {
    // Asad's own case: the Office PC on 2222.
    const stored = store.add({ name: 'office pc', address: '192.0.2.11', port: 2222, username: 'admin' })
    expect(stored.port).toBe(2222)

    const summary = serverSummary(stored)
    expect(summary.port).toBe(2222)

    // And the line the four surfaces actually draw. This is the assertion that
    // would have failed for the whole life of the servers area.
    expect(serverAddress(summary)).toBe('192.0.2.11:2222')
    expect(serverWhere(summary)).toBe('admin at 192.0.2.11:2222')
  })

  it('carries the usual port too, and draws nothing extra for it', () => {
    /*
     * The default is *stored* — `store.add` fills it in through `validPort` —
     * so it crosses as a real 22 rather than as an absence. Which means the
     * "don't print the usual one" rule has to hold against a present 22, not
     * only against a missing field. Get that wrong and every row in the app
     * grows a `:22`.
     */
    const stored = store.add({ name: 'the box', address: 'example.com', username: 'ada' })
    expect(stored.port).toBe(DEFAULT_PORT)

    const summary = serverSummary(stored)
    expect(summary.port).toBe(DEFAULT_PORT)
    expect(serverAddress(summary)).toBe('example.com')
    expect(serverWhere(summary)).toBe('ada at example.com')
  })

  it('tells two servers on one machine apart', () => {
    // The case the port is *for*. Two rows with the same address and the same
    // login were two identical lines before this; now they are two addresses.
    const a = serverSummary(store.add({ name: 'a', address: '192.0.2.11', username: 'admin' }))
    const b = serverSummary(store.add({ name: 'b', address: '192.0.2.11', port: 2222, username: 'admin' }))
    expect(serverWhere(a)).not.toBe(serverWhere(b))
  })

  it('hands over every fact a screen draws, out of the real list', () => {
    /*
     * Read back through `store.list()` rather than from `add`'s return, because
     * that is the call the app makes — a field that survives the object but not
     * the file would be a different bug with the same symptom.
     */
    store.add({ name: 'office pc', address: '192.0.2.11', port: 2222, username: 'admin' })
    const [summary] = store.list().map(serverSummary)
    expect(summary).toEqual({
      id: expect.any(String),
      name: 'office pc',
      address: '192.0.2.11',
      port: 2222,
      username: 'admin',
      credential: 'none',
      drivesWindows: true,
    })
  })

  it('leaves the sign-in and the clock behind', () => {
    /*
     * The other direction, and the reason the mapping is a hand-written field
     * list rather than a spread: §3.7 — *"the renderer learns that a server has
     * a saved sign-in, and never what it is."* `credentials-never-cross.test.ts`
     * guards the secret itself; this guards the habit that would let one
     * through, which is a field arriving because nobody stopped it.
     */
    const stored = store.add({ name: 'office pc', address: '192.0.2.11', username: 'admin' })
    const summary = serverSummary(stored) as unknown as Record<string, unknown>
    for (const field of ['addedAt', 'lastConnectedAt', 'startIn']) {
      expect(Object.hasOwn(summary, field), field).toBe(false)
    }
    // A host key is public by construction and does cross — when there is one.
    // A server nobody has dialled has none, and an absent field draws "it has
    // not told us one yet" rather than a confident blank.
    expect(Object.hasOwn(summary, 'hostKey')).toBe(false)
  })
})
