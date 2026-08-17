import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { PaceTransport, ReadingSpeedControl } from './PaceControls'
import { PACES, paceSampleLabel, stopDwellMs, type PacedStop } from './estimate'
import { PACE_CONTROL_ATTR } from './interruption'
import { initialPacerState, pacerReducer, type PacerState } from './pacer'

/**
 * The controls, rendered.
 *
 * Static markup, like every other component test in this repository — there is
 * no DOM here deliberately, and `CLAUDE.md` is blunt about why that is not
 * enough on its own: *"Compiling is not working. Two bugs shipped clean
 * typechecks and clean console output while being visibly wrong on screen."*
 *
 * So this file does not try to prove the bar looks right. It proves the things
 * that are true or false in the markup, and which a change can silently break:
 *
 *  - every control is present in every state, because a dead button in a bar
 *    that is driving the screen reads as the app having hung;
 *  - the reader is always told what is happening and how much is left;
 *  - the speed control describes itself in seconds rather than in words a
 *    minute, which is the whole reason it is a list of names;
 *  - every class the markup uses exists in the stylesheet, which is the check
 *    that catches a renamed rule — the failure mode `finish.test.ts` was written
 *    for, where the CSS reads correct and the screen is wrong.
 */

const PROSE =
  'The migration ran twice against the same database, so two of the tables now hold ' +
  'duplicate rows and the session has stopped to ask what you want done about it.'

const STOPS: readonly PacedStop[] = [
  { quote: PROSE, note: 'It is waiting on you.' },
  { quote: 'npm test', note: 'It passed.' },
  { quote: PROSE.slice(0, 90), note: 'Then it carried on.' },
]

const playing = (): PacerState =>
  pacerReducer(initialPacerState(), { kind: 'play', at: 0, stops: STOPS })

const render = (state: PacerState): string =>
  renderToStaticMarkup(<PaceTransport state={state} onCommand={() => {}} />)

const CSS = readFileSync(join(__dirname, 'pace-controls.css'), 'utf8')

/* ------------------------------------------------------------- the transport -- */

describe('the transport is always all there', () => {
  const states: Array<[string, PacerState]> = [
    ['playing', playing()],
    ['travelling', pacerReducer(initialPacerState(), { kind: 'play', at: 0, stops: STOPS, travel: true })],
    ['paused', pacerReducer(playing(), { kind: 'pause', at: 1, reason: 'scrolled' })],
    [
      'holding',
      pacerReducer(initialPacerState(), {
        kind: 'play',
        at: 0,
        stops: [{ quote: PROSE.repeat(4), note: '' }],
      }),
    ],
  ]

  for (const [name, state] of states) {
    it(`shows back, pause, next and stop while ${name}`, () => {
      /*
       * "Always visible, always enabled." There is no state in which a button
       * here does nothing when pressed — Back at the first stop re-shows it,
       * Pause while paused is the resume, Next during travel jumps straight to
       * the destination. This is the one moment in the product where the user's
       * model of cause and effect is already suspended; a control that ignores
       * them here reads as a hang.
       */
      const html = render(state)
      for (const label of ['Back', 'Next stop', 'End the tour']) {
        expect(html).toContain(`aria-label="${label}"`)
      }
      expect(html).toMatch(/aria-label="(Pause|Carry on)"/)
      expect(html).not.toContain('disabled')
    })

    it(`says something while ${name}`, () => {
      // `statusSentence` never returns an empty string for a running tour, and
      // this is the rendering half of that claim.
      const html = render(state)
      const line = /<p class="pace-line">(.*?)<\/p>/s.exec(html)
      expect(line).not.toBeNull()
      expect((line as RegExpExecArray)[1].replace(/<[^>]+>/g, '').trim().length).toBeGreaterThan(0)
    })
  }

  it('marks itself as the transport, so touching it is a command and not an interruption', () => {
    expect(render(playing())).toContain(`${PACE_CONTROL_ATTR}="transport"`)
    expect(
      renderToStaticMarkup(
        <ReadingSpeedControl
          speed={{ pace: 'steady', scale: 1 }}
          onPick={() => {}}
          onForget={() => {}}
        />,
      ),
    ).toContain(`${PACE_CONTROL_ATTR}="speed"`)
  })
})

describe('what the bar tells the reader about waiting', () => {
  it('shows where they are and how long the rest takes', () => {
    const html = render(playing())
    expect(html).toContain(`1 of ${STOPS.length}`)
    expect(html).toMatch(/about \d+ (sec|min) left/)
  })

  it('draws the ring empty at the start of a stop and full at the end of it', () => {
    /*
     * The ring is a picture of when Next happens on its own. An offset equal to
     * the circumference is an empty ring; zero is a full one. Checked as
     * numbers because this is the one part of the bar whose correctness is
     * arithmetic rather than layout.
     */
    const start = render(playing())
    const offsetOf = (html: string): number =>
      Number(/stroke-dashoffset:([\d.]+)/.exec(html)?.[1] ?? -1)
    const length = Number(/stroke-dasharray:([\d.]+)/.exec(start)?.[1] ?? -1)
    expect(length).toBeGreaterThan(0)
    expect(offsetOf(start)).toBeCloseTo(length, 3)

    const dwell = stopDwellMs(STOPS[0], initialPacerState().speed)
    // In frame-sized steps, because one tick half a stop wide is a stall as far
    // as the reducer is concerned — which is itself the right behaviour.
    let half = playing()
    for (let at = 16; at <= dwell / 2; at += 16) {
      half = pacerReducer(half, { kind: 'tick', at })
    }
    expect(offsetOf(render(half))).toBeLessThan(length * 0.55)
    expect(offsetOf(render(half))).toBeGreaterThan(length * 0.45)
  })

  it('prints the seconds left as a number as well as an arc', () => {
    /*
     * Both, always. A ring alone is a shape you have to estimate an angle from;
     * a number alone gives no sense of a rate. It is also why there is no
     * separate reduced-motion component: under `prefers-reduced-motion` the arc
     * simply stops sliding and the number is already there.
     */
    const html = render(playing())
    expect(html).toMatch(/<span class="pace-count">\d+<\/span>/)
  })

  it('shows an arrow rather than a fake countdown when nothing is counting', () => {
    const holding = pacerReducer(initialPacerState(), {
      kind: 'play',
      at: 0,
      stops: [{ quote: PROSE.repeat(4), note: '' }],
    })
    expect(render(holding)).toContain('<span class="pace-count">→</span>')
    expect(render(holding)).toContain('press →')
  })

  it('says in words what paused it', () => {
    const html = render(pacerReducer(playing(), { kind: 'pause', at: 1, reason: 'left-window' }))
    expect(html).toContain('you left the window')
    expect(html).toContain('Space to carry on')
  })
})

describe('the offer to stop watching', () => {
  it('is not there until the reader has got ahead three times', () => {
    expect(render(playing())).not.toContain('pace-skim')
  })

  it('appears once they have, and is an offer rather than a jump', () => {
    let state = pacerReducer(initialPacerState(), {
      kind: 'play',
      at: 0,
      stops: [STOPS[0], STOPS[0], STOPS[0], STOPS[0]],
    })
    for (let index = 0; index < 3; index += 1) {
      state = pacerReducer(state, { kind: 'tick', at: index * 300 + 200 })
      state = pacerReducer(state, { kind: 'next', at: index * 300 + 200 })
    }
    const html = render(state)
    expect(html).toContain('pace-skim')
    expect(html).toContain('ahead of it')
    /*
     * The duration goes in the sentence, never in the button. Concatenating it
     * into the label produced "Skim the remaining about 40 sec" on screen — the
     * vagueness `aboutDuration` is written for makes a fine sentence and an
     * ungrammatical control. Found by rendering it, not by reading it.
     */
    const label = /pace-skim-btn">([^<]+)</.exec(html)?.[1] ?? ''
    expect(label).not.toContain('about')
    expect(label).toBe('Show the rest as a list')
    // Still driving. Deciding on somebody's behalf that they would rather read
    // than watch is the same mistake as deciding they finished a paragraph.
    expect(state.status).toBe('playing')
  })
})

/* ---------------------------------------------------------- the preference -- */

describe('the reading-speed preference', () => {
  const speedHtml = (scale: number): string =>
    renderToStaticMarkup(
      <ReadingSpeedControl speed={{ pace: 'steady', scale }} onPick={() => {}} onForget={() => {}} />,
    )

  it('offers the five named paces and marks the chosen one', () => {
    const html = speedHtml(1)
    for (const pace of PACES) expect(html).toContain(pace.label)
    // The chosen row is both checked and tinted; a checkmark with no tint is
    // the state a person misses at a glance in a list of five.
    expect(html).toMatch(/class="pace-opt on"><input type="radio"[^>]*checked[^>]*value="steady"/)
    expect(html.match(/checked/g)).toHaveLength(1)
  })

  it('describes each pace in seconds a person can judge, not in words a minute', () => {
    /*
     * The reason this is a list of names and not a spinner: nobody knows their
     * own reading speed in words a minute — it is not a fact anybody has ever
     * been told about themselves — so a numeric field can only be set by trial
     * and error. Everybody can answer "was fourteen seconds on that paragraph
     * too long?".
     */
    const html = speedHtml(1)
    for (const pace of PACES) expect(html).toContain(paceSampleLabel(pace.name))
    const options = html.split('pace-opt-help').slice(1)
    expect(options).toHaveLength(PACES.length)
    for (const option of options) expect(option.slice(0, 60)).not.toContain('words a minute')
  })

  it('says what it has measured, as a sentence rather than a second control', () => {
    expect(speedHtml(1)).toContain('Reading at about 190 words a minute')
  })

  it('offers a reset only once there is something to reset', () => {
    expect(speedHtml(1)).not.toContain('pace-reset')
    expect(speedHtml(1.4)).toContain('pace-reset')
    expect(speedHtml(1.4)).toContain('Reading at about 270 words a minute')
  })
})

/* ------------------------------------------------------------------- CSS -- */

describe('the stylesheet and the markup agree', () => {
  it('defines every class the components use', () => {
    /*
     * The failure this catches is the one `finish.test.ts` opens with: markup
     * and CSS that each read correctly and disagree. A renamed rule leaves the
     * bar unstyled, which in a panel that is driving the screen looks like the
     * feature is broken rather than like a stylesheet is stale.
     */
    const markup = [
      render(playing()),
      render(pacerReducer(playing(), { kind: 'pause', at: 1, reason: 'typed' })),
      renderToStaticMarkup(
        <ReadingSpeedControl
          speed={{ pace: 'steady', scale: 1.4 }}
          onPick={() => {}}
          onForget={() => {}}
        />,
      ),
    ].join('\n')

    const used = new Set<string>()
    for (const match of markup.matchAll(/class="([^"]+)"/g)) {
      for (const name of match[1].split(/\s+/)) if (name !== '') used.add(name)
    }
    expect(used.size).toBeGreaterThan(10)
    const missing = [...used].filter((name) => !CSS.includes(`.${name}`)).sort()
    expect(missing, 'classes rendered with no rule in pace-controls.css').toEqual([])
  })

  it('never truncates the line that says how to start it again', () => {
    /*
     * Both halves of this were found by rendering the bar at the rail's real
     * width and looking at it, which is the only way either could have been
     * found. The status ellipsised — "Paused — you scrolled — Space to car…" —
     * cutting the one actionable half of the sentence; and the position broke
     * across two lines as "1 of" / "4", which is a counter the reader has to
     * reassemble.
     */
    const rule = (selector: string): string =>
      new RegExp(`\\n${selector.replace('.', '\\.')} \\{([^}]*)\\}`).exec(CSS)?.[1] ?? ''
    expect(rule('.pace-status')).not.toContain('ellipsis')
    expect(rule('.pace-status')).not.toContain('nowrap')
    expect(rule('.pace-pos')).toContain('flex-shrink: 0')
    expect(rule('.pace-pos')).toContain('nowrap')
  })

  it('spends no raw colour, only tokens', () => {
    // `CLAUDE.md`: every size, colour, radius, spacing and duration comes from a
    // token. A hex here would be a colour that cannot follow the theme, and both
    // themes are first-class.
    const withoutComments = CSS.replace(/\/\*[\s\S]*?\*\//g, '')
    expect(withoutComments).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(withoutComments).not.toMatch(/\brgba?\(/)
  })

  it('never asks for the mono font, which would need a verbatim.css entry', () => {
    // `verbatim.test.ts` re-derives the list of mono surfaces from the
    // stylesheets and requires each one to disable ligatures. Nothing in this
    // bar is a code surface, so the correct answer is to not ask for the font.
    expect(CSS).not.toContain('--font-mono')
  })

  it('draws no line where space or a tint would do', () => {
    /*
     * *"a lot of separations is not a good idea, it's not Apple style"* — his
     * words, quoted in CLAUDE.md. The bar is separated from what is above it by
     * space and the skim offer by a fill, so there is no border rule in this
     * sheet at all. `border: 0` resets are not separations.
     */
    const rules = CSS.replace(/\/\*[\s\S]*?\*\//g, '')
    const declared = [...rules.matchAll(/border(?:-(?:top|bottom|left|right))?\s*:\s*([^;]+);/g)]
    expect(declared.map((match) => match[1].trim()).filter((value) => value !== '0')).toEqual([])
  })
})
