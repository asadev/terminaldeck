/**
 * The names this browser gives ports, and where they are allowed to live.
 *
 * Two properties are being defended here and only one of them is about names.
 *
 * The first is the ordinary one: a name is cleaned on the way in, cleared by an
 * empty field, keyed per machine so a Mac's port 3000 and a PC's port 3000 are
 * two different things, and read back through the same bound it was written under.
 *
 * The second is the one that would be a real defect. This client exists for the
 * computer somebody does **not** own, and "just for this visit" promises that
 * nothing is left on it. A port name is the person's own text about their work —
 * *"client billing app"* — so it has to follow the pairing into `sessionStorage`
 * and out of `localStorage`, exactly as the credential does. The tests at the
 * bottom are that promise, written as assertions about which store holds what.
 */

import { describe, expect, it } from 'vitest'
import { MAX_NAME_LENGTH, PORT_BOOK_KEY, PortBook, cleanName, readBook } from './port-book'
import { memoryStorage, type StorageLike, type Stores } from './remember'

function stores(): Stores {
  return { browser: memoryStorage(), tab: memoryStorage() }
}

/** What one store is holding, as the object it holds. */
function bookIn(storage: StorageLike): unknown {
  const raw = storage.getItem(PORT_BOOK_KEY)
  return raw === null ? null : JSON.parse(raw)
}

const MAC = 'M9G95TNJT64Q928VW3HVRYDR8J'
const PC = 'K2X4PQRS7T9V1W3Y5Z6A8B0C2D'

describe('cleaning a name on the way in', () => {
  it('takes whitespace off and folds an empty answer onto nothing', () => {
    expect(cleanName('  Client billing  ')).toBe('Client billing')
    // Null, empty and whitespace all clear it: the rename field starts populated,
    // so selecting it all and deleting is the obvious way somebody undoes a name.
    expect(cleanName('')).toBeNull()
    expect(cleanName('   ')).toBeNull()
    expect(cleanName(null)).toBeNull()
  })

  it('drops a pasted newline rather than turning it into a space', () => {
    // A name with a line break in it is a paste accident, not an intention, and
    // joining the halves with a space guesses at what was meant.
    expect(cleanName('billing\napp')).toBe('billingapp')
    // And every other control byte with it. Escaped, never literal: a raw byte
    // in a test string is invisible in a diff, which is the same trap the
    // character class it is checking exists to avoid.
    expect(cleanName('be\u0007ll')).toBe('bell')
  })

  it('cuts to what a row can draw, and leaves no trailing space behind', () => {
    const long = `${'a'.repeat(MAX_NAME_LENGTH)} and more`
    expect(cleanName(long)).toHaveLength(MAX_NAME_LENGTH)
    // Trimmed again after the cut: a name that runs out mid-word would otherwise
    // come back from storage as a different string than the one the field showed.
    expect(cleanName(`${'a'.repeat(MAX_NAME_LENGTH - 1)} tail`)).toBe('a'.repeat(MAX_NAME_LENGTH - 1))
  })
})

describe('the book', () => {
  it('keeps a name against one machine and not the other', () => {
    // A browser paired with a Mac and a PC is holding two completely unrelated
    // port 3000s. A store keyed on the number alone would show one's name over
    // the other's server.
    const book = new PortBook(stores(), 'this-browser')
    book.setName('Site', MAC, 3000)
    expect(book.name(MAC, 3000)).toBe('Site')
    expect(book.name(PC, 3000)).toBeNull()
  })

  it('clears a name when the field is emptied, and forgets the machine with its last one', () => {
    const kept = stores()
    const book = new PortBook(kept, 'this-browser')
    book.setName('Site', MAC, 3000)
    book.setName('  ', MAC, 3000)
    expect(book.name(MAC, 3000)).toBeNull()
    expect(book.snapshot().names[MAC]).toBeUndefined()
    // And nothing is left in the store at all. Somebody who clears the last name
    // they gave has asked for nothing to be left, and a stub `{}` record on a
    // borrowed computer still says this app was used on it.
    expect(kept.browser.getItem(PORT_BOOK_KEY)).toBeNull()
  })

  it('folds a group the way the category says until somebody disagrees', () => {
    const book = new PortBook(stores(), 'this-browser')
    expect(book.isFolded(MAC, 'other')).toBe(true)
    expect(book.isFolded(MAC, 'web')).toBe(false)

    book.setFolded(false, MAC, 'other')
    expect(book.isFolded(MAC, 'other')).toBe(false)
    // Per machine, like the names: a WSL box where `wslrelay` is the whole point
    // is a real machine, and the Mac next to it is not.
    expect(book.isFolded(PC, 'other')).toBe(true)
  })

  it('writes a choice that matches the default, so a changed default cannot undo it', () => {
    const kept = stores()
    const book = new PortBook(kept, 'this-browser')
    book.setFolded(true, MAC, 'web')
    expect(new PortBook(kept, 'this-browser').isFolded(MAC, 'web')).toBe(true)
    // The point of writing it rather than clearing back to "unset": if `web` ever
    // stops being open by default, this person's answer still stands.
    expect(book.snapshot().folds[MAC].web).toBe(true)
  })

  it('hands the catalog a snapshot keyed by port', () => {
    const book = new PortBook(stores(), 'this-browser')
    book.setName('Site', MAC, 3000)
    book.setName('API', MAC, 4000)
    expect(book.namesFor(MAC, [3000, 4000, 5000])).toEqual({ 3000: 'Site', 4000: 'API' })
    // No machine is no names, and never somebody else's.
    expect(book.namesFor('', [3000])).toEqual({})
  })

  it('forgets everything about one machine and nothing about the rest', () => {
    const book = new PortBook(stores(), 'this-browser')
    book.setName('Site', MAC, 3000)
    book.setFolded(false, MAC, 'other')
    book.setName('Build', PC, 3000)
    book.forget(MAC)
    expect(book.name(MAC, 3000)).toBeNull()
    expect(book.isFolded(MAC, 'other')).toBe(true)
    expect(book.name(PC, 3000)).toBe('Build')
  })
})

describe('reading a record this client did not write', () => {
  it('holds a stored name to the same bound the field was', () => {
    // A record written by an older build, or edited in a devtools console, must
    // not be able to get around what a row can draw.
    const storage = memoryStorage()
    storage.setItem(PORT_BOOK_KEY, JSON.stringify({ names: { [MAC]: { '3000': 'x'.repeat(120) } }, folds: {} }))
    expect(readBook(storage).names[MAC]['3000']).toHaveLength(MAX_NAME_LENGTH)
  })

  it('drops a key that is not a port, and a value that is not text', () => {
    const storage = memoryStorage()
    storage.setItem(
      PORT_BOOK_KEY,
      JSON.stringify({ names: { [MAC]: { '3000': 'Site', 'drop table': 'no', '80.5': 'no' } }, folds: {} }),
    )
    expect(readBook(storage).names[MAC]).toEqual({ '3000': 'Site' })
  })

  it('treats anything unreadable as an empty book rather than an error', () => {
    // The consequence is precise and survivable — the groups go back to their
    // defaults — and the alternative is a client that will not draw the localhost
    // screen because a preference was edited by hand.
    const storage = memoryStorage()
    storage.setItem(PORT_BOOK_KEY, 'not json')
    expect(readBook(storage)).toEqual({ names: {}, folds: {} })
    storage.setItem(PORT_BOOK_KEY, '[]')
    expect(readBook(storage)).toEqual({ names: {}, folds: {} })
  })
})

describe('where a name is allowed to live', () => {
  it('leaves nothing on a computer somebody said is not theirs', () => {
    /*
     * The property this file exists for. "Just for this visit" is the answer for a
     * borrowed machine, and a port name is the person's own text about their
     * work — so it belongs in the store that dies with the tab, not beside it.
     */
    const kept = stores()
    const book = new PortBook(kept, 'this-tab')
    book.setName('Client billing', MAC, 3000)
    expect(bookIn(kept.tab)).not.toBeNull()
    expect(bookIn(kept.browser)).toBeNull()
  })

  it('moves with the pairing when the answer changes, both ways', () => {
    const kept = stores()
    const book = new PortBook(kept, 'this-tab')
    book.setName('Client billing', MAC, 3000)

    book.setLifetime('this-browser')
    expect(bookIn(kept.browser)).not.toBeNull()
    // And the tab's copy is cleared rather than left behind, which is the half
    // that would otherwise leave a durable record of a pairing somebody made
    // durable *after* deciding the machine was theirs.
    expect(bookIn(kept.tab)).toBeNull()

    book.setLifetime('this-tab')
    expect(bookIn(kept.tab)).not.toBeNull()
    expect(bookIn(kept.browser)).toBeNull()
  })

  it('reads the tab’s book over the durable one, like the credential', () => {
    // A pairing made in this tab is the most recent decision the person made and
    // is the one that must win if anything else is lying around.
    const kept = stores()
    kept.browser.setItem(PORT_BOOK_KEY, JSON.stringify({ names: { [MAC]: { '3000': 'Durable' } }, folds: {} }))
    kept.tab.setItem(PORT_BOOK_KEY, JSON.stringify({ names: { [MAC]: { '3000': 'This tab' } }, folds: {} }))
    expect(new PortBook(kept, 'this-tab').name(MAC, 3000)).toBe('This tab')
  })

  it('falls through an empty tab record to the durable one', () => {
    /*
     * The trap in reading across two stores: an *empty* book has to read as
     * "nothing here" rather than as an answer, or a browser whose tab store had
     * been touched would shadow the names it actually has.
     */
    const kept = stores()
    kept.browser.setItem(PORT_BOOK_KEY, JSON.stringify({ names: { [MAC]: { '3000': 'Durable' } }, folds: {} }))
    kept.tab.setItem(PORT_BOOK_KEY, JSON.stringify({ names: {}, folds: {} }))
    expect(new PortBook(kept, 'this-browser').name(MAC, 3000)).toBe('Durable')
  })
})
