import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { readAgentFromScreen, readComposer, refuseToType } from './agent-controls'

/**
 * The screen readers, run against real Windows screens rather than imagined ones.
 *
 * ## Why a fixture and not a mock
 *
 * Everything in `agent-controls.ts` is a claim about what a specific program
 * paints in a terminal, and the file's own header says the values came from
 * driving that program rather than from documentation. The Windows half could
 * not be written that way from this machine, and the result was a feature that
 * typechecked, passed every test, and refused every single control on Windows
 * because the CLI draws `>` where a Mac draws `❯`.
 *
 * A test written from the same misunderstanding would have agreed with the bug.
 * So these screens are not composed here: they were captured on
 * `DESKTOP-DDGMNCV` (Windows 11 Pro 10.0.26200) from `claude 2.1.233`, spawned
 * exactly the way `providers.ts` spawns it on Windows — `%COMSPEC% /c <cli>` —
 * through `node-pty`'s ConPTY backend, and read out of the same
 * `@xterm/headless` terminal at the same size that `session-activity.ts` gives
 * a session, with the same `translateToString(true)` per visible row. The file
 * beside this one is that capture, unedited.
 *
 * ## What each shot is
 *
 * The probe typed nothing that could reach the API. `/model` with no argument
 * opens a local picker; Escape closes it, and the CLI's own reply — `⎿ Kept
 * model as Opus 5 (1M context) (default)` — is in the capture confirming that
 * nothing changed.
 *
 *   `idle-after-boot`     the composer, empty, under the banner
 *   `typed-slash-model`   `> /model` on the command line, unsent
 *   `model-picker-open`   the numbered dialog, cursor on row 1
 *   `after-escape`        dialog dismissed, composer empty again
 *   `typed-slash-effort`  a second draft, unsent
 *   `after-ctrl-u`        the line cleared, with the CLI's own
 *                         `Ctrl+Y to paste deleted text` hint
 *
 * ## What it protects
 *
 * The two states that decide whether anything is typed at all — `ready` and
 * `choosing` — and the one that decides whether a return is committed,
 * `typing` with the exact text. Undo the pointer change and four of these fail
 * naming the state that broke, on this Mac, with no Windows machine needed.
 */

interface Capture {
  capturedOn: string
  cli: string
  spawn: string
  pty: string
  shots: { label: string; screen: string }[]
}

const CAPTURE: Capture = JSON.parse(
  readFileSync(resolve(__dirname, 'agent-controls.conpty.json'), 'utf8'),
) as Capture

function shot(label: string): string {
  const found = CAPTURE.shots.find((entry) => entry.label === label)
  expect(found, `no ${label} shot — has the capture been replaced?`).toBeTruthy()
  return found?.screen ?? ''
}

describe('the composer, read off a real ConPTY screen', () => {
  it('is ready when the CLI has booted and nothing is typed', () => {
    // `> ` alone between the two rules. On a Mac the same line is `❯`.
    expect(readComposer(shot('idle-after-boot'))).toEqual({ kind: 'ready' })
  })

  it('holds exactly the command that was written, before any return is sent', () => {
    /*
     * This is the load-bearing one. `typeCommand` writes the command *without*
     * a return and refuses to send one until the composer reads back as exactly
     * that command — so if this reading is wrong on Windows, the return is
     * never sent and every control on the platform is dead. It was.
     */
    expect(readComposer(shot('typed-slash-model'))).toEqual({
      kind: 'typing',
      text: '/model',
    })
    expect(readComposer(shot('typed-slash-effort'))).toEqual({
      kind: 'typing',
      text: '/effort',
    })
  })

  it('sees a numbered dialog and refuses, rather than answering it', () => {
    const state = readComposer(shot('model-picker-open'))
    expect(state.kind).toBe('choosing')
    // The row it saw, verbatim, because the refusal quotes it back to the user.
    expect(state.kind === 'choosing' ? state.asking : '').toContain('1. Default (recommended)')
    // And the refusal has to be the one about answering a choice, not the one
    // about a missing prompt: a `\r` here would pick a model.
    expect(refuseToType(state)).toContain('Pressing return now would answer it')
  })

  it('is ready again once the dialog is dismissed', () => {
    /*
     * The screen still shows the echoed `> /model` and the CLI's reply above
     * the composer, so this also pins the read-from-the-bottom rule: the older
     * line must not win.
     */
    expect(shot('after-escape')).toContain('Kept model as Opus 5')
    expect(readComposer(shot('after-escape'))).toEqual({ kind: 'ready' })
  })

  it('is ready after ctrl+u takes the typing back', () => {
    // `CLEAR_COMPOSER` is the rollback `typeCommand` uses when the echo never
    // arrives. Confirmed here on Windows: the line is empty and the CLI is
    // offering its own undo.
    expect(shot('after-ctrl-u')).toContain('Ctrl+Y to paste deleted text')
    expect(readComposer(shot('after-ctrl-u'))).toEqual({ kind: 'ready' })
  })

  it('never answers unknown on a screen the CLI is plainly drawing', () => {
    /*
     * The shape of the original bug, stated as its own assertion.
     *
     * Every one of these screens is Claude Code's, and before the pointer was
     * understood every one of them read as `unknown` — which `refuseToType`
     * turns into "this session's prompt is not on screen". A future change that
     * breaks the reading in some new way will almost certainly land back on
     * `unknown`, and this is the check that names it as such.
     */
    for (const entry of CAPTURE.shots) {
      expect(readComposer(entry.screen).kind, `${entry.label} read as unknown`).not.toBe('unknown')
    }
  })
})

describe('the agent is recognised on Windows too', () => {
  it('finds the banner, which is the same on both platforms', () => {
    // `╭─── Claude Code v2.1.233 ───…`. The box-drawing characters survive
    // ConPTY intact, which is the thing that could not be assumed: the pointer
    // dropped to ASCII on this platform and the box did not, so "the CLI uses
    // an ASCII glyph set on Windows" would have been the wrong conclusion to
    // draw from one glyph.
    expect(readAgentFromScreen(shot('idle-after-boot'))).toContain('Claude Code v')
    expect(readAgentFromScreen(shot('model-picker-open'))).toContain('Claude Code v')
  })
})

describe('the capture says where it came from', () => {
  it('names the machine, the CLI and the spawn line', () => {
    /*
     * Not decoration. The whole value of this file is that it is a recording of
     * one specific arrangement, and a reader who cannot tell which arrangement
     * cannot tell what a failure here means. If somebody replaces the capture
     * from a different setup — a Windows Terminal session, say, which advertises
     * Unicode and would bring `❯` back — these fields are how the next reader
     * finds out.
     */
    expect(CAPTURE.capturedOn).toContain('Windows 11')
    expect(CAPTURE.cli).toContain('2.1.233')
    expect(CAPTURE.spawn).toContain('COMSPEC')
    expect(CAPTURE.pty).toContain('ConPTY')
  })
})
