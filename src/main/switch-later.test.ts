import { describe, expect, it } from 'vitest'
import type { SwitchPlan } from './session-switch'
import {
  armedNote,
  compose,
  EMPTY_LINE,
  PendingSwitches,
  SESSION_SWITCH_ARMED_CHANNEL,
  SESSION_SWITCH_CANCEL_CHANNEL,
  SESSION_SWITCH_FAILED_CHANNEL,
  SESSION_SWITCH_LATER_CHANNEL,
  SESSION_SWITCHED_CHANNEL,
  replayWrites,
  submitAt,
  switchedNote,
} from './switch-later'

/**
 * The deferred account switch, and specifically the half of it that can lose
 * somebody's words.
 *
 * The switch itself is `session-switch.ts`'s and is tested there. What is new
 * here is that a message is typed into one process and delivered by another, so
 * every case below is really the same question: *is what gets sent what he
 * typed?* The answer this module is allowed to give is either "yes" or "I am
 * not sure, so I will not send it" — never a guess, which is why `exact` is
 * asserted as carefully as `line` is.
 */

const plan: SwitchPlan = {
  sessionId: 's1',
  refusal: null,
  from: { id: 'a', name: 'Personal', provider: 'claude' },
  to: { id: 'b', name: 'Work', provider: 'claude' },
  conversation: 'theirs',
  resume: true,
}

const armed = (register: PendingSwitches, sessionId = 's1'): void => {
  register.arm({ sessionId, profileId: 'b', accountName: 'Work', plan })
}

describe('channels', () => {
  it('are distinct, and named for what they do', () => {
    const all = [
      SESSION_SWITCH_LATER_CHANNEL,
      SESSION_SWITCH_CANCEL_CHANNEL,
      SESSION_SWITCH_ARMED_CHANNEL,
      SESSION_SWITCHED_CHANNEL,
      SESSION_SWITCH_FAILED_CHANNEL,
    ]
    expect(new Set(all).size).toBe(all.length)
    // The two announcements are the pair most easily confused, and a consumer
    // that subscribes to the wrong one draws an account that was never reached.
    expect(SESSION_SWITCHED_CHANNEL).not.toBe(SESSION_SWITCH_FAILED_CHANNEL)
  })
})

/*
 * The keys a real keyboard sends, spelled out once so that every case below is
 * arguing about behaviour rather than about byte values. These are what a pty
 * receives from this app's own terminal in the default cursor mode, with the
 * `SS3` spellings beside them because a CLI that turns on application-cursor
 * mode gets those instead for the very same key.
 */
const ESC = '\u001b'
const KEY = {
  up: `${ESC}[A`,
  down: `${ESC}[B`,
  right: `${ESC}[C`,
  left: `${ESC}[D`,
  ss3Left: `${ESC}OD`,
  ss3Right: `${ESC}OC`,
  home: `${ESC}[H`,
  end: `${ESC}[F`,
  homeNumbered: `${ESC}[1~`,
  endNumbered: `${ESC}[4~`,
  del: `${ESC}[3~`,
  pageUp: `${ESC}[5~`,
  shiftTab: `${ESC}[Z`,
  ctrlLeft: `${ESC}[1;5D`,
  optionLeft: `${ESC}b`,
  f5: `${ESC}[15~`,
  pasteOn: `${ESC}[200~`,
  pasteOff: `${ESC}[201~`,
  backspace: '\u007f',
  ctrlA: '\u0001',
  ctrlE: '\u0005',
  ctrlK: '\u000b',
  ctrlU: '\u0015',
  ctrlW: '\u0017',
  ctrlC: '\u0003',
  tab: '\t',
}

/** Any C0 control byte, or DEL. None of these may ever reach the line. */
const CONTROL = /[\u0000-\u001f\u007f]/

describe('compose', () => {
  it('builds the line from ordinary typing', () => {
    const state = compose(EMPTY_LINE, 'fix the bug')
    expect(state.line).toBe('fix the bug')
    expect(state.exact).toBe(true)
    expect(state.cursor).toBe(11)
  })

  it('applies backspace, in both spellings a terminal sends', () => {
    expect(compose(EMPTY_LINE, 'abc\u007f').line).toBe('ab')
    expect(compose(EMPTY_LINE, 'abc\u0008').line).toBe('ab')
  })

  it('clears the line on Ctrl-U and drops a word on Ctrl-W', () => {
    expect(compose(EMPTY_LINE, `hello there${KEY.ctrlU}`).line).toBe('')
    expect(compose(EMPTY_LINE, `hello there${KEY.ctrlW}`).line).toBe('hello ')
  })

  it('treats Ctrl-C as abandoning the line, and is certain again after', () => {
    // Certainty is restored on purpose: an empty line is a line both sides
    // agree about, whatever went before it.
    const state = compose({ ...EMPTY_LINE, line: 'half typed', cursor: 10, exact: false }, KEY.ctrlC)
    expect(state.line).toBe('')
    expect(state.exact).toBe(true)
    expect(state.cursor).toBe(0)
  })

  /*
   * ## The regression, and it is the one he watched happen
   *
   *   > *"See, what the fuck is this? This came in my message automatically."*
   *
   * Every one of these used to produce a line with escape-sequence bytes typed
   * into it — `run the tests[A` for a single press of the Up arrow — and that
   * line was then written into his prompt in the replacement session. The
   * property is asserted over the whole keyboard rather than key by key,
   * because a case-by-case list is exactly what missed it the first time: the
   * old model handled Escape *specifically* and let every byte after it through.
   */
  it('never lets an escape sequence put a character in the line', () => {
    const sequences = [
      KEY.up,
      KEY.down,
      KEY.left,
      KEY.right,
      KEY.ss3Left,
      KEY.ss3Right,
      KEY.home,
      KEY.end,
      KEY.homeNumbered,
      KEY.endNumbered,
      KEY.del,
      KEY.pageUp,
      KEY.shiftTab,
      KEY.ctrlLeft,
      KEY.optionLeft,
      KEY.f5,
      KEY.tab,
      `${ESC}]0;a window title\u0007`,
      `${ESC}Pq some device string${ESC}\\`,
      ESC,
    ]
    for (const keys of sequences) {
      const state = compose(EMPTY_LINE, `typed${keys}`)
      expect(state.line, `${JSON.stringify(keys)} leaked into the line`).toBe('typed')
      expect(CONTROL.test(state.line)).toBe(false)
    }
  })

  it('carries the cursor, so an edit made with the arrow keys is still exact', () => {
    // Type it wrong, walk back over the last letter, fix it, go to the end.
    // This is the ordinary way a person corrects a prompt, and before the
    // cursor existed it made every such message unsendable *and* corrupted.
    const state = compose(
      EMPTY_LINE,
      `run the tesst${KEY.left}${KEY.backspace}${KEY.end}`,
    )
    expect(state.line).toBe('run the test')
    expect(state.exact).toBe(true)
  })

  it('inserts where the cursor is, not at the end', () => {
    const state = compose(EMPTY_LINE, `world${KEY.home}hello `)
    expect(state.line).toBe('hello world')
    expect(state.cursor).toBe(6)
    expect(state.exact).toBe(true)
  })

  it('deletes forward with the delete key and backward with backspace', () => {
    expect(compose(EMPTY_LINE, `abcd${KEY.home}${KEY.del}`).line).toBe('bcd')
    expect(compose(EMPTY_LINE, `abcd${KEY.left}${KEY.backspace}`).line).toBe('abd')
  })

  it('honours the readline kills at the cursor rather than over the whole line', () => {
    expect(compose(EMPTY_LINE, `hello there${KEY.ctrlA}${KEY.ctrlK}`).line).toBe('')
    expect(compose(EMPTY_LINE, `hello there${KEY.left}${KEY.left}${KEY.ctrlK}`).line).toBe('hello the')
    expect(compose(EMPTY_LINE, `hello there${KEY.left}${KEY.left}${KEY.ctrlU}`).line).toBe('re')
    expect(compose(EMPTY_LINE, `hello there${KEY.ctrlA}${KEY.ctrlE}x`).line).toBe('hello therex')
  })

  it('stops at both ends rather than running the cursor off the line', () => {
    const start = compose(EMPTY_LINE, `ab${KEY.left}${KEY.left}${KEY.left}${KEY.left}x`)
    expect(start.line).toBe('xab')
    const finish = compose(EMPTY_LINE, `ab${KEY.right}${KEY.right}x`)
    expect(finish.line).toBe('abx')
    // A backspace at the very start is a no-op rather than an error or a
    // silent loss of certainty.
    expect(compose(EMPTY_LINE, `${KEY.backspace}ab`)).toMatchObject({ line: 'ab', exact: true })
  })

  /*
   * A modifier turns a cursor key into a *word* jump and the final byte is the
   * same one. Acting on it as though it were a character move would leave the
   * cursor somewhere it is not and then insert there — the same class of silent
   * wrongness as the leak, only with nothing visible to complain about. So the
   * sequence is consumed and the certainty goes.
   */
  it('does not pretend to model a modified cursor key', () => {
    const state = compose(EMPTY_LINE, `one two three${KEY.ctrlLeft}`)
    expect(state.line).toBe('one two three')
    expect(state.exact).toBe(false)
  })

  it('gives up certainty on history recall, and keeps the words he typed', () => {
    // Up and down compose a line somewhere this process cannot see. What it
    // holds is still his and safe to put in front of him; it is simply no
    // longer provably what is on screen, so it must not be sent.
    const state = compose(EMPTY_LINE, `draft${KEY.up}`)
    expect(state.line).toBe('draft')
    expect(state.exact).toBe(false)
  })

  it('takes a pasted line as text and neither of its brackets', () => {
    const state = compose(EMPTY_LINE, `${KEY.pasteOn}pasted text${KEY.pasteOff}`)
    expect(state.line).toBe('pasted text')
    expect(state.exact).toBe(true)
    expect(state.pasting).toBe(false)
  })

  it('keeps a multi-line paste whole and stops claiming it can send it', () => {
    const state = compose(EMPTY_LINE, `${KEY.pasteOn}first\rsecond${KEY.pasteOff}`)
    expect(state.line).toBe('first\nsecond')
    expect(state.exact).toBe(false)
  })

  /*
   * A pty splits where it likes, and a sequence torn between two writes is how
   * the tail of one gets typed even with the whole-sequence rule in place. The
   * parser's state therefore rides along in `Composing`, and this walks the
   * same keystrokes one byte per chunk to prove it.
   */
  it('survives a sequence split across chunks', () => {
    const keys = `abc${KEY.left}${KEY.left}X${KEY.end}!`
    let byByte = EMPTY_LINE
    for (const ch of keys) byByte = compose(byByte, ch)
    expect(byByte.line).toBe('aXbc!')
    expect(byByte).toMatchObject({ exact: true, pending: '' })
    expect(byByte.line).toBe(compose(EMPTY_LINE, keys).line)
  })

  it('is still mid-sequence when a chunk ends inside one', () => {
    const half = compose(EMPTY_LINE, `abc${ESC}[`)
    expect(half.line).toBe('abc')
    expect(half.pending).not.toBe('')
    const rest = compose(half, 'D!')
    expect(rest.line).toBe('ab!c')
    expect(rest.pending).toBe('')
  })
})

/*
 * The invariant, asserted against noise rather than against a list somebody
 * thought of. The old model passed every test written for it and still put
 * `[A` in his prompt, because those tests were about the keys anybody
 * remembered. This one is about the property: whatever arrives, the line holds
 * only characters that were typed as text.
 */
describe('the line holds nothing he did not type', () => {
  it('survives a stream of arbitrary keys', () => {
    const words = ['fix', 'the', 'bug', 'now', 'please'] as const
    const noise = [
      ...Object.values(KEY),
      `${ESC}[?2004h`,
      `${ESC}[6n`,
      `${ESC}[999;999R`,
      `${ESC}]0;title\u0007`,
      // Torn sequences on purpose. A parser that drops the byte that spoiled a
      // sequence types the next one, which is how the second leak was found.
      `${ESC}O`,
      `${ESC}[`,
      `${ESC}[1;`,
      ESC,
      '\u0007',
      '\u0000',
    ]
    // Deterministic, so a failure is reproducible: a small linear congruential
    // generator over a fixed seed rather than `Math.random`.
    let seed = 20260820
    const next = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648
      return seed
    }
    for (let round = 0; round < 2000; round += 1) {
      let stream = ''
      let typed = ''
      for (let n = 0; n < 12; n += 1) {
        if (next() % 3 === 0) {
          const word = words[next() % words.length] as string
          stream += word
          typed += word
        } else {
          stream += noise[next() % noise.length] as string
        }
      }
      const state = compose(EMPTY_LINE, stream)
      const text = state.line.replace(/\n/g, '')
      expect(CONTROL.test(text), `control byte in ${JSON.stringify(state.line)}`).toBe(false)
      // Nothing appears that was never typed: every character of the result has
      // to be one of the letters the words above are made of.
      expect(
        /^[fixthebugnowplase]*$/.test(text),
        `foreign text in ${JSON.stringify(state.line)}`,
      ).toBe(true)
      expect(text.length <= typed.length).toBe(true)
    }
  })
})

/**
 * The terminal's own reports, which are not keystrokes.
 *
 * Claude Code turns focus reporting on (`?1004h`, measured by spawning it in a
 * pty and reading the raw bytes), so `ESC [ I` and `ESC [ O` arrive up the same
 * pipe as his typing every time focus enters or leaves the terminal. Arming a
 * deferred switch *requires* leaving the terminal — the account menu is a
 * click away — so before this, every armed switch lost its certainty before he
 * had typed a character, and the message he pressed Enter on was placed in the
 * new prompt unsent.
 */
describe('focus and mouse reports pass straight through', () => {
  const focusIn = `${ESC}[I`
  const focusOut = `${ESC}[O`

  it('keeps the line exact across a focus report', () => {
    const state = compose(EMPTY_LINE, `${focusOut}${focusIn}what is the secret word`)
    expect(state.line).toBe('what is the secret word')
    expect(state.exact).toBe(true)
  })

  it('keeps it exact when focus changes mid-sentence', () => {
    const state = compose(EMPTY_LINE, `what is ${focusIn}the secret word`)
    expect(state.line).toBe('what is the secret word')
    expect(state.exact).toBe(true)
  })

  it('keeps it exact across an SGR mouse report', () => {
    // No agent here asks for mouse tracking today. One that did would put the
    // same fault back, and the report is the same kind of thing: the terminal
    // telling the program something, which cannot have changed his line.
    const state = compose(EMPTY_LINE, `run ${ESC}[<0;40;12M${ESC}[<0;40;12mthe tests`)
    expect(state.line).toBe('run the tests')
    expect(state.exact).toBe(true)
  })

  it('still gives up certainty for a real cursor move it cannot model', () => {
    // The guard rail. Up-arrow recalls history somewhere this process cannot
    // see, and that must still leave the line offered rather than sent.
    const state = compose(EMPTY_LINE, `hello${ESC}[A`)
    expect(state.exact).toBe(false)
  })
})

describe('submitAt', () => {
  it('finds the first Enter and nothing else', () => {
    expect(submitAt('hello')).toBe(-1)
    expect(submitAt('hello\r')).toBe(5)
    expect(submitAt('hello\nworld\r')).toBe(5)
  })
})

describe('PendingSwitches', () => {
  it('passes ordinary typing through and answers nothing for a session with nothing armed', () => {
    const register = new PendingSwitches()
    expect(register.observe('s1', 'hello').kind).toBe('pass')
  })

  it('accumulates the line while armed, still passing every keystroke through', () => {
    const register = new PendingSwitches()
    armed(register)
    expect(register.observe('s1', 'fix ').kind).toBe('pass')
    expect(register.observe('s1', 'the bug').kind).toBe('pass')
    expect(register.get('s1')?.composing.line).toBe('fix the bug')
  })

  it('fires on Enter, carrying the whole line and the bytes before it', () => {
    const register = new PendingSwitches()
    armed(register)
    register.observe('s1', 'fix the')
    const action = register.observe('s1', ' bug\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.line).toBe('fix the bug')
    // The old session still gets what was typed before the Enter, so the screen
    // he is watching does not drop characters in the moment before it is
    // replaced. The Enter itself is deliberately not among them.
    expect(action.before).toBe(' bug')
    expect(action.submit).toBe(true)
  })

  it('refuses to send on his behalf when it is not sure it read the line', () => {
    const register = new PendingSwitches()
    armed(register)
    register.observe('s1', 'draft\u001b[A')
    const action = register.observe('s1', '\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.submit).toBe(false)
  })

  /*
   * ## The stray message, end to end
   *
   *   > *"See, what the fuck is this? This came in my message automatically. I
   *   > don't know what is this. It's not even showing completely in one, maybe."*
   *
   * This is that, reproduced: type a message, press Up once, press Enter. What
   * the replacement session used to be handed was `run the tests\u001b[A`
   * minus the Escape — `run the tests[A` — which is what he watched appear in
   * his prompt. The line must now be exactly what he typed, and because Up is
   * not something this module can model, it must not be sent on his behalf.
   */
  it('carries his words and nothing else after an arrow key', () => {
    const register = new PendingSwitches()
    armed(register)
    register.observe('s1', 'run the tests')
    register.observe('s1', KEY.up)
    const action = register.observe('s1', '\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.line).toBe('run the tests')
    expect(action.submit).toBe(false)
  })

  it('sends the line when the only editing was something it can reproduce', () => {
    // The other half of the same fix. An edit made with the arrow keys used to
    // corrupt the line *and* block the send; now it does neither.
    const register = new PendingSwitches()
    armed(register)
    register.observe('s1', `run the tesst${KEY.left}${KEY.backspace}${KEY.end}`)
    const action = register.observe('s1', '\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.line).toBe('run the test')
    expect(action.submit).toBe(true)
  })

  it('does not fire on a newline inside a pasted block', () => {
    // A paste is one chunk with its own brackets round it, and the Enter that
    // fires a switch is the one he presses afterwards. Firing on the paste's
    // own first newline would carry one line of a paragraph across and drop
    // the rest — a fragment, arriving by a different door.
    const register = new PendingSwitches()
    armed(register)
    expect(register.observe('s1', `${KEY.pasteOn}first\rsecond${KEY.pasteOff}`).kind).toBe('pass')
    const action = register.observe('s1', '\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.line).toBe('first\nsecond')
    expect(action.submit).toBe(false)
  })

  it('will not send a line whose last keystroke has not finished arriving', () => {
    // A chunk that ends inside an escape sequence is a line whose next byte
    // could still change it. Pressing Enter on that is the whole failure this
    // flag exists for, so an unfinished sequence blocks the send by itself.
    const register = new PendingSwitches()
    armed(register)
    register.observe('s1', `hello${ESC}[`)
    const action = register.observe('s1', '\r')
    expect(action.kind).toBe('switch')
    if (action.kind !== 'switch') return
    expect(action.line).toBe('hello')
    expect(action.submit).toBe(false)
  })

  it('fires once — a switch armed is a switch spent', () => {
    const register = new PendingSwitches()
    armed(register)
    expect(register.observe('s1', 'one\r').kind).toBe('switch')
    expect(register.observe('s1', 'two\r').kind).toBe('pass')
    expect(register.get('s1')).toBeNull()
  })

  it('keeps sessions apart', () => {
    const register = new PendingSwitches()
    armed(register, 's1')
    register.observe('s1', 'mine')
    // A session with nothing armed contributes nothing to anybody's line.
    expect(register.observe('s2', 'theirs\r').kind).toBe('pass')
    expect(register.get('s1')?.composing.line).toBe('mine')
  })

  it('can be cancelled before it fires', () => {
    const register = new PendingSwitches()
    armed(register)
    expect(register.cancel('s1')).toBe(true)
    expect(register.observe('s1', 'hello\r').kind).toBe('pass')
  })
})

describe('what it says', () => {
  it('names the account and the moment, never just "pending"', () => {
    const register = new PendingSwitches()
    const record = register.arm({
      sessionId: 's1',
      profileId: 'b',
      accountName: 'Work',
      plan,
    })
    expect(armedNote(record)).toContain('Work')
    expect(armedNote(record)).toContain('next message')
  })

  it('says what became of the message, because that is the next thing he checks', () => {
    expect(switchedNote('Work', true, 'fix the bug')).toContain('sent your message')
    expect(switchedNote('Work', false, 'fix the bug')).toContain('press Enter')
  })

  it('does not send him looking for a message that was never carried', () => {
    // Nothing is replayed when there is no line, so "your message is in the
    // prompt" over an empty prompt is a sentence that starts a search.
    expect(switchedNote('Work', false, '')).toBe('Switched to Work.')
  })
})

describe('replayWrites', () => {
  /*
   * The regression these pin cost the whole feature and would never have shown
   * up in a short test message. `ptys.write(id, `${line}\r`)` is one chunk, and
   * the CLI reads a chunk of about 64 bytes or more as pasted text where a
   * carriage return is a newline — so the replayed prompt lands in the input box
   * and sits there, while the window says it was sent.
   */
  it('keeps the line and the Enter as two separate writes', () => {
    const [typed, enter] = replayWrites('carry on with the refactor and make sure the tests still pass')
    expect(typed).toBe('carry on with the refactor and make sure the tests still pass')
    expect(enter).toBe('\r')
  })

  it('puts a space after a line that mentions a file', () => {
    // With `@` and no space the CLI's completion popup eats the Enter and the
    // line collapses to a bare path. Measured; see `mentions.ts`.
    const [typed] = replayWrites('read @src/main/index.ts')
    expect(typed).toBe('read @src/main/index.ts ')
  })

  it('adds nothing at all to a line he is being asked to check', () => {
    // The space exists to protect an Enter. Where no Enter is coming it is a
    // character he did not type, sitting on the end of a line he has been
    // asked to read — the same rule as the rest of this fix, at its smallest.
    const [typed] = replayWrites('read @src/main/index.ts', false)
    expect(typed).toBe('read @src/main/index.ts')
  })
})
