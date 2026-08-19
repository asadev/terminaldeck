import { describe, expect, it } from 'vitest'
import { keyRoutes, keyRowSays, pasteBoxText } from './key-routes'

/**
 * Which of the three ways of giving a key is on screen, and when.
 *
 * The walk that produced this work found the old screen saying *"open the key
 * file in any text editor and paste the whole thing here"* — a text-editor
 * instruction, for the audience this form is explicitly built for. The routes
 * below are the answer, and the one that must survive every future edit is the
 * last: **pasting is never taken away**, because it is the only one that cannot
 * fail for a reason the screen would then have to explain.
 */

describe('the three ways of giving a key', () => {
  it('is a paste box and nothing else when this window cannot ask', () => {
    // The harness, a test, an older preload. A list that could only ever be
    // empty and a panel that never opens are worse than not offering either.
    expect(keyRoutes({ hasChooser: false, found: 0, chosen: false, pasting: false })).toEqual({
      list: false,
      panel: false,
      paste: true,
      offerPaste: false,
    })
  })

  it('shows the keys it found, and keeps pasting one press away', () => {
    const routes = keyRoutes({ hasChooser: true, found: 3, chosen: false, pasting: false })
    expect(routes.list).toBe(true)
    expect(routes.panel).toBe(true)
    // Not gone — offered. Somebody whose key is in none of those three rows has
    // to be able to get to the box without going back a screen.
    expect(routes.paste).toBe(false)
    expect(routes.offerPaste).toBe(true)
  })

  it('falls back to the paste box on a computer with no keys on it', () => {
    /*
     * The ordinary case for the person this screen is for, and it must not read
     * as a failure: no list, no "none found" notice, just the two routes that
     * still work.
     */
    const routes = keyRoutes({ hasChooser: true, found: 0, chosen: false, pasting: false })
    expect(routes.list).toBe(false)
    expect(routes.paste).toBe(true)
    expect(routes.panel).toBe(true)
  })

  it('keeps the box open once somebody has asked for it, even with a list beside it', () => {
    const routes = keyRoutes({ hasChooser: true, found: 3, chosen: false, pasting: true })
    expect(routes.paste).toBe(true)
    expect(routes.list).toBe(true)
    expect(routes.offerPaste).toBe(false)
  })

  it('puts the box away once a key has been chosen from a panel', () => {
    // Nothing was found in the folder, but something was picked, so the empty
    // box below it would be a second unanswered question about a question that
    // is already answered.
    const routes = keyRoutes({ hasChooser: true, found: 0, chosen: true, pasting: false })
    expect(routes.paste).toBe(false)
    expect(routes.offerPaste).toBe(true)
  })
})

describe('what a row says about a key', () => {
  const offer = { path: '/home/x/.ssh/id_ed25519', name: 'id_ed25519', what: 'A key made by OpenSSH' }

  it('says a key needs a password only when the file said so', () => {
    expect(keyRowSays({ ...offer, locked: true })).toContain('needs a password to open')
    expect(keyRowSays({ ...offer, locked: false })).toBe('A key made by OpenSSH')
  })

  it('says nothing at all about a lock it could not read', () => {
    /*
     * The third state, carried intact. "No password" would be a claim we cannot
     * make from a blob we could not parse, and the form asks for a passphrase
     * after the attempt either way.
     */
    expect(keyRowSays({ ...offer, locked: null })).toBe('A key made by OpenSSH')
  })
})

describe('what the paste box holds when it is asked for', () => {
  it('is empty when the key came out of a file', () => {
    /*
     * Found by looking at the screen rather than at the code. Choosing a key
     * says "its contents are not shown here" — and pressing **Paste it
     * instead** put the entire private key in a textarea, because the chooser
     * and the box write to the same field.
     */
    expect(pasteBoxText({ fromFile: true, typed: '-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blb…\n' })).toBe('')
  })

  it('keeps what somebody typed by hand', () => {
    // It was already on screen, and putting it away would be losing their work
    // to a toggle.
    expect(pasteBoxText({ fromFile: false, typed: '-----BEGIN' })).toBe('-----BEGIN')
  })
})
