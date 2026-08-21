import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The scraping panel, held as source.
 *
 * It is a `Modal`, and `Modal` portals into `<body>` — `createPortal` throws
 * under `renderToStaticMarkup`, which is the only rendering this project does in
 * a test. `HistoryPanel.test.ts` and `ProfileSettings.test.ts` carry the same
 * note, and the behaviour underneath is tested where it can be run:
 * `scraping-view.test.ts` for what the panel is allowed to say, and
 * `scraping-bridge.test.ts` for what it is allowed to believe.
 *
 * What is pinned here is the handful of decisions that are one edit away from
 * being quietly undone, and every one of them is about a screen not lying: the
 * lift cannot be reached except by a person pressing twice, an unwired section
 * draws no controls, an unverified tool has no Install, and no number is
 * defaulted to zero on its way to the page.
 */
const source = readFileSync(join(__dirname, 'ScrapingPanel.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('every capability is on the screen, grouped', () => {
  it('draws all seven sections', () => {
    for (const title of ['Workers', 'Session', 'Requests', 'Capture', 'Assets', 'Checks', 'Store']) {
      expect(onScreen).toContain(`title="${title}"`)
    }
  })

  it('says whose settings each section is', () => {
    // The fleet and the store belong to the browser; the rest belong to the
    // profile named on the head. A per-profile screen that does not say which
    // profile is how a configuration gets set twice and lost once.
    expect(onScreen).toContain('scope="browser"')
    expect(onScreen).toContain('scope="profile"')
    expect(onScreen).toContain('scopeLabel(scope, profileName)')
  })

  it('lets a person edit a profile other than the one the browser is on', () => {
    expect(onScreen).toContain('Settings for')
    expect(onScreen).toContain('setEditing(event.target.value)')
  })

  it('offers a rule for each of the resource types, with the reason Fulfill exists', () => {
    expect(onScreen).toContain('RESOURCE_TYPES.map')
    expect(onScreen).toContain('{FULFILL_NOTE}')
    expect(onScreen).toContain('ruleChange(type, rule)')
  })
})

describe('the session lift, which is the dangerous one', () => {
  it('is reached from exactly one place, and that place is a button', () => {
    const calls = onScreen.match(/browserScrapingLift\(/g) ?? []
    expect(calls).toHaveLength(1)
    expect(onScreen).toContain('onClick={() => void lift()}')
  })

  it('takes two presses, and the second one names both ends', () => {
    // Not a count. "Copy into 4 workers" is the shape of confirmation somebody
    // presses without reading; this one cannot be pressed without reading which
    // account goes into which profiles.
    expect(onScreen).toContain('setLiftArming(true)')
    expect(onScreen).toMatch(/liftArming \? \(/)
    const armed = onScreen.slice(onScreen.indexOf('liftArming ? ('))
    expect(armed.slice(0, armed.indexOf('</div>'))).toContain('liftLine(nameOf(liftFrom), liftNames)')
  })

  it('puts the escape on the focus, not the act', () => {
    const armed = onScreen.slice(onScreen.indexOf('liftArming ? ('))
    expect(armed.slice(0, armed.indexOf('</div>'))).toContain('autoFocus')
  })

  it('refuses with a sentence rather than a grey button and no reason', () => {
    expect(onScreen).toContain('liftBlockedReason(liftFrom, liftInto)')
    expect(onScreen).toContain('{liftRefusal}')
  })

  it('arms an approval too, and the armed one names both ends', () => {
    // Granting an ask copies a live logged-in session into other profiles on
    // disk. A request that arrived on its own must not be answerable with one
    // press landing where Decline was a moment ago.
    expect(onScreen).toContain("setApproving(ask.id)")
    const armed = onScreen.slice(onScreen.indexOf('approving === ask.id ? ('))
    const block = armed.slice(0, armed.indexOf(') : ('))
    expect(block).toContain('liftLine(nameOf(ask.fromProfileId)')
    expect(block).toContain('autoFocus')
  })

  it('surfaces an ask as a request with two answers, never as a completed act', () => {
    // An agent that wants a session lifted gets to ask. The ask lands in the
    // panel above the control it is about, and only a person answers it.
    expect(onScreen).toContain('liftRequestLine(')
    expect(onScreen).toContain('answerAsk(ask, true)')
    expect(onScreen).toContain('answerAsk(ask, false)')
    expect(onScreen).toContain('Approve this lift')
    expect(onScreen).toContain('Decline')
  })

  it('has no way to lift into everything at once', () => {
    // A control meaning "and whatever else is a worker next week" is not
    // something a person can be said to have agreed to.
    expect(onScreen).not.toMatch(/All workers|Select all/)
  })
})

describe('nothing here reports what it has not measured', () => {
  it('never defaults a count to zero on the way to the screen', () => {
    expect(onScreen).not.toContain('?? 0')
  })

  it('puts every number through the helpers that can say "not measured"', () => {
    expect(onScreen).toContain('countLine(')
    expect(onScreen).toContain('bytesLine(')
    expect(onScreen).toContain('droppedLine(')
  })

  it('says a lift is unconfirmed when nothing counted what moved', () => {
    expect(onScreen).toContain('Nothing counted what moved')
  })

  it('does not claim a setting was stored when the reply could not be read', () => {
    expect(onScreen).toContain('That change was not confirmed')
  })

  it('says "no workers yet" rather than drawing an example row', () => {
    expect(onScreen).toContain('No workers yet.')
  })

  it('shows the coverage verdict rather than a tick', () => {
    expect(onScreen).toContain('coverageVerdict(status?.lastCheck ?? null)')
    expect(onScreen).toContain('{verdict.line}')
  })
})

describe('a seam nobody has wired yet', () => {
  it('draws the section as unavailable rather than hiding it', () => {
    expect(onScreen).toContain('function Unavailable(')
    expect(onScreen).toContain('Not available here')
  })

  it('draws no control inside one', () => {
    // Every section is `unavailable ? <Unavailable/> : <controls/>`, so there is
    // no arrangement in which a control for a missing engine reaches the screen.
    for (const gate of [
      '!canConfigure ? (',
      '!liftAvailable(api) ? (',
      '!canConfigure || capture === null ? (',
      '!canConfigure || assets === null ? (',
      '!canConfigure || checks === null ? (',
      '!storeAvailable(api) ? (',
    ]) {
      expect(onScreen, `no gate for ${gate}`).toContain(gate)
    }
  })

  it('says so once at the top as well, so the panel is not read as broken', () => {
    expect(onScreen).toContain('This build has no scraping engine behind it')
  })
})

describe('the store', () => {
  it('shows what a tool reaches before it is on disk', () => {
    expect(onScreen).toContain('reachLine(tool)')
  })

  it('offers no Install at all for a tool that could not be verified', () => {
    // Absent rather than disabled: what is underneath that button is somebody
    // else's code arriving on his disk, and the reason is on the row instead.
    expect(onScreen).toContain('canInstall(tool) && (')
    expect(onScreen).not.toMatch(/disabled=\{!canInstall/)
    expect(onScreen).toContain('installBlockedReason(tool)')
  })

  it('can take one out again', () => {
    expect(onScreen).toContain('void remove(tool)')
  })
})

describe('headful, and no switch for it', () => {
  it('says the window is visible on purpose', () => {
    expect(onScreen).toContain('There is no hidden mode')
  })

  it('offers no hidden or headless mode to turn on', () => {
    // The targets worth scraping refuse a browser with no screen. A toggle here
    // would be a control that makes the product worse and cannot say so.
    expect(onScreen).not.toMatch(/headless/i)
    expect(onScreen).not.toMatch(/Hide the window|Run hidden|Background mode/i)
  })
})
