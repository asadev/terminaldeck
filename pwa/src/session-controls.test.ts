/**
 * The rules the phone's control cluster reads and applies a session's controls
 * with.
 *
 * Only the pure half is exercised, and that is why the pure half exists as
 * exported functions rather than as expressions inside a DOM builder — the same
 * split, for the same reason, as `session-bar.test.ts` beside it: vitest runs
 * in this repo with no DOM at all, so a rule that lives inside `render()` is a
 * rule nothing can ask a question of.
 *
 * The fixtures go through the wire for real. Every inbound frame here is a
 * JSON string handed to `decodeServerMessage` — the one reader this client has
 * — so what the assertions see is what a phone would see after the shared
 * parser has had its say, not a shape this file invented and then agreed with.
 * Outbound frames are `encode`d and parsed back for the same reason.
 */

import { describe, expect, it } from 'vitest'
import { decodeServerMessage, encode } from './protocol-client'
import type { ControlsReadingWire, ServerMessage } from '../../src/main/remote/protocol'
import { CONTROL_IDS, MAX_CONTROL_VALUE_LENGTH } from '../../src/main/remote/protocol'
import {
  appliedTo,
  blockedFor,
  chipText,
  chosen,
  clusterShown,
  fastFlip,
  NO_ANSWER,
  rowsFor,
} from './session-controls'
import { FAST_OPTIONS } from '../../src/renderer/chat/controls/catalog'

/* ------------------------------------------------------------- fixtures -- */

/** A live agent session's reading, the way `readControls` composes one. */
function reading(overrides: Partial<ControlsReadingWire> = {}): ControlsReadingWire {
  return {
    model: { value: 'opus', label: 'Opus 5', source: 'screen' },
    effort: { value: 'xhigh', label: 'Extra high', source: 'settings' },
    fast: { value: 'off', label: 'Off', source: 'screen' },
    permission: { value: 'bypass', label: 'Bypass', source: 'screen' },
    live: true,
    agent: { running: true, saw: 'claude' },
    gate: { canType: true, reason: null },
    ...overrides,
  }
}

/** Through the real parser, so the shape asserted is the shape received. */
function arrived(frame: Record<string, unknown>): ServerMessage {
  const decoded = decodeServerMessage(JSON.stringify(frame))
  if (!decoded.ok) throw new Error(decoded.reason)
  return decoded.message
}

/* ----------------------------------------------------------- vocabulary -- */

describe('the vocabulary is the desktop’s', () => {
  it('offers exactly the permission modes the far end can enter, in the menu’s order', () => {
    /*
     * Pinned against `PERMISSION_MODES` in `src/main/agent-controls.ts` by
     * value rather than by import — that module reaches Electron — the same
     * way `protocol.test.ts` pins `CONTROL_IDS`. `applyControl` refuses a mode
     * id it does not know, so a drifted id here is a menu row that always
     * fails; this list failing is how that is found at the desk instead.
     */
    expect(rowsFor('permission').map((option) => option.id)).toEqual([
      'plan',
      'manual',
      'acceptEdits',
      'auto',
      'bypass',
    ])
  })

  it('offers exactly the effort levels the CLI told us it accepts', () => {
    // "Valid options are: low, medium, high, xhigh, max, ultracode, auto" —
    // the CLI's own rejection line, quoted in `agent-controls.ts`.
    expect(
      rowsFor('effort')
        .map((option) => option.id)
        .sort(),
    ).toEqual(['auto', 'high', 'low', 'max', 'medium', 'ultracode', 'xhigh'])
  })

  it('keeps every offered value inside the wire’s own cap', () => {
    // `parseClientMessage` refuses a `controls.apply` whose value is longer,
    // and the server answers a refused frame by closing the socket. No row
    // this cluster draws may be a press that disconnects the phone.
    const rows = [...rowsFor('model'), ...rowsFor('effort'), ...rowsFor('permission'), ...FAST_OPTIONS]
    for (const option of rows) {
      expect(option.id.length, option.id).toBeLessThanOrEqual(MAX_CONTROL_VALUE_LENGTH)
      expect(option.id.length).toBeGreaterThan(0)
    }
  })

  it('has rows for every control the wire names', () => {
    // `CONTROL_IDS` is the frozen wire list. Three get sheets, fast gets the
    // switch at the end of the model sheet — but each must be reachable.
    expect([...CONTROL_IDS].sort()).toEqual(['effort', 'fast', 'model', 'permission'])
    expect(rowsFor('model').length).toBeGreaterThan(0)
    expect(FAST_OPTIONS.map((option) => option.id)).toEqual(['off', 'on'])
  })
})

/* -------------------------------------------------------------- reading -- */

describe('what a controls.reading draws', () => {
  it('draws the cluster for a live agent session', () => {
    const message = arrived({ t: 'controls.reading', rid: 'r1', id: 's1', reading: reading() })
    if (message.t !== 'controls.reading') throw new Error(message.t)
    expect(clusterShown(message.reading)).toBe(true)
    expect(chipText('model', message.reading)).toBe('Opus 5')
    expect(chipText('effort', message.reading)).toBe('Extra high')
    expect(chipText('permission', message.reading)).toBe('Bypass')
    expect(blockedFor('model', message.reading)).toBeNull()
  })

  it('draws nothing before a reading, over a corpse, or over a plain shell', () => {
    // Three different honesties, one absence. The shell case is the desktop's
    // own rule — model chips over /bin/zsh are a control acting on nothing.
    expect(clusterShown(null)).toBe(false)
    expect(clusterShown(reading({ live: false }))).toBe(false)
    expect(clusterShown(reading({ agent: { running: false, saw: null } }))).toBe(false)
  })

  it('shortens the model the way the desktop’s chip does', () => {
    const long = reading({
      model: { value: 'opus[1m]', label: 'Opus 5 with 1M context', source: 'screen' },
    })
    // The 1M marker survives — `Opus 5` and `Opus 5 with 1M context` are
    // different windows and must not land on the same chip text.
    expect(chipText('model', long)).toBe('Opus 5 1M')
  })

  it('says Unknown and Not reported in the desktop’s words, never a guess', () => {
    const unread = reading({
      model: { value: null, label: null, source: null },
      permission: { value: null, label: null, source: null },
    })
    expect(chipText('model', unread)).toBe('Unknown')
    expect(chipText('permission', unread)).toBe('Not reported')
  })

  it('carries the far end’s own sentence for a barred control', () => {
    const barred = reading({
      fast: {
        value: null,
        label: null,
        source: null,
        unavailableReason: 'Fast mode requires usage credits',
      },
    })
    const message = arrived({ t: 'controls.reading', rid: 'r2', id: 's1', reading: barred })
    if (message.t !== 'controls.reading') throw new Error(message.t)
    // Verbatim through the parser — the whole value of the field is the wording.
    expect(blockedFor('fast', message.reading)).toBe('Fast mode requires usage credits')
    expect(blockedFor('model', message.reading)).toBeNull()
  })

  it('closes every control behind a shut gate, with the gate’s reason', () => {
    const gated = reading({ gate: { canType: false, reason: 'A dialog is waiting on an answer.' } })
    for (const control of CONTROL_IDS) {
      expect(blockedFor(control, gated)).toBe('A dialog is waiting on an answer.')
    }
    // And a gate that closed without a sentence still claims only what is
    // known: nothing was sent.
    const mute = reading({ gate: { canType: false, reason: null } })
    expect(blockedFor('model', mute)).toBe('This session cannot be typed into right now, so nothing was sent.')
  })

  it('ticks the row the session is on, however the reading spells it', () => {
    const rows = rowsFor('model')
    // By alias — the settings-file spelling.
    const byAlias = reading().model
    expect(rows.some((option) => chosen(byAlias, option))).toBe(true)
    // And by the screen's own confirmation-line spelling, which is not an
    // alias at all: `isCurrent` folds both onto the same row via `modelKey`.
    const byScreen = { value: 'Opus 5 (1M context)', label: 'Opus 5 (1M context)', source: 'screen' }
    const ticked = rows.filter((option) => chosen(byScreen, option))
    expect(ticked.map((option) => option.label)).toEqual(['Opus 5 with 1M context'])
  })
})

/* -------------------------------------------------------------- applying -- */

describe('what a controls.applied settles', () => {
  it('writes the re-read value, so a refused apply reverts by construction', () => {
    const before = reading()
    const message = arrived({
      t: 'controls.applied',
      rid: 'a1',
      id: 's1',
      ok: false,
      message: 'Mythos 5 isn’t available for your account yet',
      // The far machine re-read the session after the refusal: still Opus.
      reading: { value: 'opus', label: 'Opus 5', source: 'screen' },
    })
    if (message.t !== 'controls.applied') throw new Error(message.t)
    expect(message.ok).toBe(false)
    const after = appliedTo(before, 'model', message.reading)
    // The chip shows what the session is actually on — never the pressed row.
    expect(after?.model.label).toBe('Opus 5')
    expect(after?.effort).toBe(before.effort)
  })

  it('reads a garbled ok as a failure, never as a change that landed', () => {
    // The parser's rule, exercised through the parser: `ok` must be the
    // literal true, so a frame that lost the field cannot tick a menu.
    const message = arrived({
      t: 'controls.applied',
      rid: 'a2',
      id: 's1',
      message: '',
      reading: { value: null, label: null, source: null },
    })
    if (message.t !== 'controls.applied') throw new Error(message.t)
    expect(message.ok).toBe(false)
  })

  it('flips fast mode from the reading, not from the picture', () => {
    expect(fastFlip({ value: 'on', label: 'On', source: 'screen' })).toBe('off')
    expect(fastFlip({ value: 'off', label: 'Off', source: 'screen' })).toBe('on')
    // Unread flips to on: the switch is only drawn once the state was read, so
    // this arm serves the two explicit rows — whose values are sent directly.
    expect(fastFlip({ value: null, label: null, source: null })).toBe('on')
  })

  it('never claims an unanswered apply failed', () => {
    // Word for word the guest's sentence (`setControl`, guest.ts): the far end
    // types before it answers, so "failed" would invite a second press at a
    // session that may already have moved.
    expect(NO_ANSWER).toBe('That machine did not answer, so it is not known whether the change was made.')
    expect(NO_ANSWER).not.toMatch(/fail/i)
  })
})

/* ------------------------------------------------------------- outbound -- */

describe('the frames this cluster sends', () => {
  it('sends the read and apply shapes the server routes', () => {
    // Through the real encoder, then parsed back: the fields the server's
    // `controlsServe` reads are the fields on the wire, spelled its way.
    expect(JSON.parse(encode({ t: 'controls.read', rid: 'r1', id: 's1' }))).toEqual({
      t: 'controls.read',
      rid: 'r1',
      id: 's1',
    })
    expect(JSON.parse(encode({ t: 'controls.apply', rid: 'a1', id: 's1', control: 'effort', value: 'ultracode' }))).toEqual(
      { t: 'controls.apply', rid: 'a1', id: 's1', control: 'effort', value: 'ultracode' },
    )
  })
})
