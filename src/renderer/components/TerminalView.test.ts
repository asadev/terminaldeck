import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { KEYMAP, chordMatches, parseChord } from '../keymap'
import {
  TERMINAL_COMMANDS,
  terminalChord,
  terminalLinkHandlers,
  type TerminalLink,
} from './TerminalView'

/**
 * The three chords the shortcuts sheet prints under "In a session".
 *
 * All three were in `KEYMAP` with no implementation anywhere — `run()` in
 * App.tsx does not know them, so they fell through to xterm, which does nothing
 * with any of them. These tests tie the handler to the table: if a binding's
 * chord changes, the matcher below stops agreeing with it.
 */
describe('terminalChord', () => {
  const key = (k: string, mods: Partial<Record<'metaKey' | 'ctrlKey' | 'shiftKey' | 'altKey', boolean>> = {}) => ({
    key: k,
    ...mods,
  })

  it('matches what the keymap declares, on both platforms', () => {
    for (const id of TERMINAL_COMMANDS) {
      const binding = KEYMAP.find((b) => b.id === id)
      expect(binding, `${id} is not in the keymap`).toBeDefined()
      const chord = parseChord(binding!.keys[0])
      expect(chord, `${id} has an unparseable chord`).not.toBeNull()

      for (const isMac of [true, false]) {
        const event = {
          key: chord!.key,
          metaKey: isMac && chord!.mod,
          ctrlKey: !isMac && chord!.mod,
          shiftKey: chord!.shift,
          altKey: chord!.alt,
        }
        expect(chordMatches(chord!, event, isMac), `${id} on ${isMac ? 'mac' : 'pc'}`).toBe(true)
        expect(terminalChord(event), `${id} on ${isMac ? 'mac' : 'pc'}`).toBe(id)
      }
    }
  })

  it('leaves everything else to the session', () => {
    // A terminal is a full keyboard application. Claiming a key it wanted is
    // the one failure mode worse than not implementing the shortcut at all.
    expect(terminalChord(key('f'))).toBeNull()
    expect(terminalChord(key('c', { ctrlKey: true }))).toBeNull()
    expect(terminalChord(key('k', { metaKey: true }))).toBeNull()
    expect(terminalChord(key('t', { metaKey: true }))).toBeNull()
    expect(terminalChord(key('f', { metaKey: true, altKey: true }))).toBeNull()
  })

  it('is case-insensitive, because Shift changes the character', () => {
    expect(terminalChord(key('K', { metaKey: true, shiftKey: true }))).toBe('terminal.clear')
    expect(terminalChord(key('C', { metaKey: true, shiftKey: true }))).toBe('terminal.copy')
  })
})

/**
 * A URL clicked in a terminal, which is the thing this app was worst at.
 *
 * ## What it did before
 *
 * Two packages, both handed the address and both throwing it away:
 *
 *  - `WebLinksAddon` was loaded with no handler, so it kept its own default —
 *    `window.open()` with **no argument**, then `location.href = uri` on the
 *    window it got back. Electron's window-open handler denies that (nothing in
 *    this app gets a bare Chromium window), `window.open()` answers `null`, and
 *    the addon's `else` branch writes a console warning and drops the URL. The
 *    denied `about:blank` still went on to open an **empty browser tab**, so the
 *    visible result was a blank page and a lost address from one click.
 *  - OSC 8 hyperlinks went to xterm's `defaultActivate`, which raises
 *    `confirm('… WARNING: This link could potentially be dangerous')` and then
 *    does the same discarded `window.open()`.
 *
 * ## Why the handlers are tested directly
 *
 * This project's test setup has no DOM — the rendered tests in this folder use
 * `react-dom/server` and say so — so a real `Terminal` cannot be mounted and a
 * click cannot be dispatched at one. `terminalLinkHandlers` is exported for
 * exactly that: it is the object handed to both packages, so driving it is
 * driving what xterm will call.
 *
 * That leaves one thing a behavioural test cannot see, and it is the failure
 * this repository has already shipped once (`link-open.channels.test.ts`): a
 * perfectly good handler that nothing is wired to. The last case below reads the
 * source for the two wirings, because both are silent when they are missing.
 */
describe('a link clicked in a terminal', () => {
  const opened: unknown[] = []

  /** A `window.deck` with the one method these handlers reach for. */
  const stubDeck = (): void => {
    opened.length = 0
    ;(globalThis as { window?: unknown }).window = {
      deck: {
        openLink: (request: unknown) => {
          opened.push(request)
          return Promise.resolve('tab')
        },
      },
      // Present and spied on, so "never called" is a real observation rather
      // than a method that was never there to call.
      open: vi.fn(),
      confirm: vi.fn(),
    }
  }

  /**
   * The stub above, read back as the spies it holds.
   *
   * Through `unknown`, because the real `Window` declares `open` and `confirm`
   * with their DOM signatures and TypeScript is right that a `Mock` is not one
   * of those. The cast is the honest spelling of "this is a stand-in", and it is
   * confined to one place rather than repeated at each assertion.
   */
  const spiedWindow = (): { open: ReturnType<typeof vi.fn>; confirm: ReturnType<typeof vi.fn> } =>
    (globalThis as unknown as {
      window: { open: ReturnType<typeof vi.fn>; confirm: ReturnType<typeof vi.fn> }
    }).window

  afterEach(() => {
    delete (globalThis as { window?: unknown }).window
    vi.restoreAllMocks()
  })

  /** xterm hands `activate` a buffer range; nothing in this path reads it. */
  const range = { start: { x: 0, y: 0 }, end: { x: 0, y: 0 } }
  const click = new (class {})() as MouseEvent

  it('sends the address and the session to the app, not to a new window', () => {
    stubDeck()
    const links = terminalLinkHandlers(() => ({ sessionId: 'session-7' }))

    links.web(click, 'https://terminaldeck.dev/docs')

    expect(opened).toEqual([{ url: 'https://terminaldeck.dev/docs', sessionId: 'session-7' }])
    // The whole of the old defect in one line: the address left through
    // `window.open()` with nothing in it, and never arrived anywhere.
    expect(spiedWindow().open).not.toHaveBeenCalled()
  })

  it('takes an OSC 8 hyperlink down the same path, and raises no dialog', () => {
    stubDeck()
    const links = terminalLinkHandlers(() => ({ sessionId: 'session-7' }))

    links.osc.activate(click, 'https://terminaldeck.dev/releases', range)

    expect(opened).toEqual([{ url: 'https://terminaldeck.dev/releases', sessionId: 'session-7' }])
    expect(spiedWindow().confirm).not.toHaveBeenCalled()
    expect(spiedWindow().open).not.toHaveBeenCalled()
  })

  it('carries a machine id when the terminal has one, and omits it when it does not', () => {
    stubDeck()
    terminalLinkHandlers(() => ({ sessionId: 's1', machineId: 'pc' })).web(click, 'https://a.test/')
    terminalLinkHandlers(() => ({ sessionId: 's1' })).web(click, 'https://b.test/')

    expect(opened).toEqual([
      { url: 'https://a.test/', sessionId: 's1', machineId: 'pc' },
      { url: 'https://b.test/', sessionId: 's1' },
    ])
  })

  /**
   * The identity is read at click time, not captured when the terminal was
   * built. `attach` runs once for the life of a terminal, so a handler that
   * closed over the session would keep opening links against whatever it was
   * on the day that terminal started.
   */
  it('reads the session at the moment of the click', () => {
    stubDeck()
    let identity: TerminalLink = { sessionId: 'first' }
    const links = terminalLinkHandlers(() => identity)

    links.web(click, 'https://one.test/')
    identity = { sessionId: 'second' }
    links.web(click, 'https://two.test/')

    expect(opened).toEqual([
      { url: 'https://one.test/', sessionId: 'first' },
      { url: 'https://two.test/', sessionId: 'second' },
    ])
  })

  /**
   * Leaving `allowNonHttpProtocols` off is a decision, not an omission. With it
   * on, a page could print an OSC 8 sequence carrying any scheme it liked and
   * this handler would pass it to the main process; xterm drops those before
   * `activate` while it is off.
   */
  it('does not ask xterm for non-http schemes', () => {
    stubDeck()
    expect(terminalLinkHandlers(() => ({})).osc.allowNonHttpProtocols).toBeFalsy()
  })

  it('is what the terminal is actually built with', () => {
    // Both wirings are silent when absent — that is how the old behaviour
    // survived: nothing threw, nothing logged where anyone would see it, and a
    // click just did the wrong thing.
    const source = readFileSync(join(__dirname, 'TerminalView.tsx'), 'utf8')
    expect(source, 'WebLinksAddon is back on its own default handler').toContain(
      'new WebLinksAddon(links.web)',
    )
    expect(source, 'OSC 8 links are back on xterm’s confirm() dialog').toContain(
      'term.options.linkHandler = links.osc',
    )
  })
})
