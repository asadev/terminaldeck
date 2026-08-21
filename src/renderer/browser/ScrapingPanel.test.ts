import { readdirSync, readFileSync } from 'node:fs'
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
    expect(onScreen).toContain('liftBlockedReason(pageOpen, liftFrom, liftInto)')
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

  it('says the session comes off the page in front, not out of the picker', () => {
    /*
     * `browser-worker:lift` takes the session from the page the person is
     * looking at — that is what makes it a gesture rather than an action
     * against a profile named in a field. The picker names which account it is
     * *expected* to be, and a disagreement copies nothing. A screen that
     * implied the dropdown was the source would be promising a lift this app
     * deliberately cannot do.
     */
    expect(onScreen).toContain('The session is taken from the page in front of you')
    expect(onScreen).toContain('nothing is copied and this says so')
  })

  it('promises an inbox only on a build that has one', () => {
    // There is no channel behind the ask inbox today. A standing sentence
    // saying asks show up here would be a claim about a mechanism this build
    // does not have.
    const inbox = onScreen.slice(onScreen.indexOf('Lifting copies'))
    expect(inbox.slice(0, inbox.indexOf('</p>'))).toContain('liftRequestsAvailable(api) &&')
  })

  it('has no way to lift into everything at once', () => {
    // A control meaning "and whatever else is a worker next week" is not
    // something a person can be said to have agreed to.
    expect(onScreen).not.toMatch(/All workers|Select all/)
  })
})

describe('the fleet, which is the half with an engine behind it', () => {
  it('takes the answer as the new fleet rather than reloading and hoping', () => {
    // `registerWorker` refuses the default profile and a full fleet in silence.
    // A panel that only reloaded would put the same name back in the dropdown
    // and leave somebody pressing a control that does nothing.
    expect(onScreen).toContain('const storeFleet = async (')
    expect(onScreen).toContain('${nameOf(id)} was not enrolled. ${NOT_ENROLLED}')
  })

  it('offers minting as a total, with no button where a press would add nothing', () => {
    expect(onScreen).toContain('mintPlan(mintTo, rows.length)')
    expect(onScreen).toContain('mintTotal !== null && (')
    expect(onScreen).toContain('void mint(mintTotal)')
  })

  it('draws neither control on a build that cannot do that half', () => {
    expect(onScreen).toContain('{workersAvailable(api) && (')
    expect(onScreen).toContain('{mintAvailable(api) && (')
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
      '!blockCaptureAvailable(api) ? (',
      '!storeAvailable(api) ? (',
    ]) {
      expect(onScreen, `no gate for ${gate}`).toContain(gate)
    }
  })

  it('says so once at the top as well, so the panel is not read as broken', () => {
    expect(onScreen).toContain('This build has no scraping configuration behind it')
  })

  it('does not claim nothing can be set when one control can', () => {
    /*
     * The banner used to read "nothing on this screen can be set", which stopped
     * being true the day the block camera got a seam of its own — and the switch
     * it was wrong about governs a feature with no visible output, so the banner
     * would have been the only thing on screen about it, and wrong.
     */
    expect(onScreen).not.toContain('nothing on this screen can be set')
    expect(onScreen).toContain('the exception is the block camera under Checks')
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

describe('one door to the job', () => {
  const files = readdirSync(__dirname)

  it('has no second workers panel to reach the same engine through', () => {
    /*
     * *"inside three dot give a feature of scrapping and inside that give all
     * the features and modifications options with ui also."* The workers lane
     * built its own panel behind the profile menu while this one was being
     * written, so the same fleet, the same pace and the same lift had two
     * screens. One of them had to go, and the one that stayed is the one he
     * asked for.
     */
    expect(files).not.toContain('WorkersPanel.tsx')
    expect(readFileSync(join(__dirname, 'ProfileMenu.tsx'), 'utf8')).not.toContain('Workers…')
    expect(readFileSync(join(__dirname, 'BrowserWorkspace.tsx'), 'utf8')).not.toContain('WorkersPanel')
  })

  it('keeps every act that panel offered', () => {
    // Deleting a screen must not delete a capability. Minting, enrolling,
    // retiring, the pace and the lift are all on this one.
    for (const act of ['void mint(', 'void enrol(', 'void retire(', 'void lift()']) {
      expect(onScreen, `${act} is not on this panel`).toContain(act)
    }
    expect(onScreen).toContain("patch({ fleet: { concurrency: next } })")
    expect(onScreen).toContain("patch({ fleet: { delayMs: next } })")
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
