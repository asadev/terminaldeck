import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  idleBlockedNote,
  lidAwakeCaution,
  lidAwakeHelp,
  PowerView,
  resolveLidAwakeBridge,
  toLidAwakeResult,
  toLidAwakeState,
  unknownStateNote,
  type LidAwakeState,
} from './PowerSection'
import { sectionMeta } from '../settings-schema'

/**
 * What this pane must never do.
 *
 * It draws a switch for a setting that belongs to the operating system, so the
 * two ways it can lie are the two things tested hardest here:
 *
 *  1. **It must not draw a state it does not have.** A read that failed has to
 *     produce a disabled switch and a sentence admitting it, never a confident
 *     "off" — because an off switch on a machine that is in fact being held
 *     awake hides a running battery drain behind something that looks harmless.
 *  2. **It must warn before the click, not after it.** Heat and battery drain
 *     are the cost of the feature, and they belong on screen while somebody is
 *     deciding rather than in a note afterwards.
 *
 * Static markup only, like every other test in this window: `renderToStaticMarkup`
 * runs no effects, which is exactly why `PowerView` takes everything it draws.
 */

const HELD: LidAwakeState = {
  supported: true,
  on: true,
  known: true,
  needsAuthorization: true,
  preexisting: false,
  battery: { present: true, discharging: false, percent: 100 },
  detail: null,
  warning: null,
  idleBlocked: true,
}

function render(props: Partial<Parameters<typeof PowerView>[0]> = {}): string {
  return renderToStaticMarkup(
    <PowerView
      state={HELD}
      loading={false}
      changing={false}
      result={null}
      unwired={false}
      platform="mac"
      onChange={() => {}}
      {...props}
    />,
  )
}

/* --------------------------------------------------------------- narrowing -- */

describe('toLidAwakeState', () => {
  it('reads a full state off the bridge', () => {
    expect(toLidAwakeState(HELD)).toEqual(HELD)
  })

  it('treats anything it does not understand as unknown, never as off', () => {
    // The pessimistic default. `known: false` draws a disabled switch and an
    // admission; a default of `known: true, on: false` would draw a calm, wrong
    // answer for a machine nobody managed to read.
    for (const raw of [{}, { on: 'yes' }, { known: 'true' }]) {
      expect(toLidAwakeState(raw)?.known).toBe(false)
    }
    expect(toLidAwakeState(null)).toBeNull()
    expect(toLidAwakeState('nonsense')).toBeNull()
  })

  it('claims no wake lock a build did not send one for', () => {
    // Same pessimism, on the field added when the wake lock was decoupled from
    // the privileged setting: an older main process that has never heard of
    // `idleBlocked` must draw no promise, not a promise it cannot keep.
    expect(toLidAwakeState({ supported: true, on: true, known: true })?.idleBlocked).toBe(false)
    expect(toLidAwakeState({ idleBlocked: 'yes' })?.idleBlocked).toBe(false)
  })
})

describe('toLidAwakeResult', () => {
  it('keeps the main process’s own sentence', () => {
    const result = toLidAwakeResult({ outcome: 'cancelled', message: 'Nothing changed.', state: HELD })
    expect(result.outcome).toBe('cancelled')
    expect(result.message).toBe('Nothing changed.')
    expect(result.state?.on).toBe(true)
  })

  it('falls back to failed, never to changed', () => {
    expect(toLidAwakeResult({ outcome: 'sort-of' }).outcome).toBe('failed')
    expect(toLidAwakeResult(undefined).outcome).toBe('failed')
    expect(toLidAwakeResult({}).message).toBeTruthy()
  })
})

describe('resolveLidAwakeBridge', () => {
  it('takes only the methods that are really there', () => {
    expect(Object.keys(resolveLidAwakeBridge({ lidAwakeStatus: () => {} }))).toEqual(['lidAwakeStatus'])
    expect(resolveLidAwakeBridge(null)).toEqual({})
    expect(resolveLidAwakeBridge({ lidAwakeStatus: 'not a function' })).toEqual({})
  })

  it('calls through the host rather than detaching the method', () => {
    // A preload whose functions live on a prototype throws on `this` the first
    // time a switch is pressed, and only in a packaged build.
    const host = {
      marker: 'deck',
      lidAwakeStatus(this: { marker: string }) {
        return this.marker
      },
    }
    expect(resolveLidAwakeBridge(host).lidAwakeStatus?.()).toBe('deck')
  })
})

/* -------------------------------------------------------------------- copy -- */

describe('the copy', () => {
  it('says a password is needed on macOS and not on Windows', () => {
    expect(lidAwakeHelp('mac')).toMatch(/password/i)
    expect(lidAwakeHelp('windows')).toMatch(/no password is needed/i)
    // The mistake this codebase has made in bulk: quoting one platform's
    // behaviour at the other.
    expect(lidAwakeHelp('windows')).not.toContain('macOS')
    expect(lidAwakeHelp('mac')).not.toContain('Windows')
  })

  it('says out loud that this changes the machine, not the app', () => {
    for (const platform of ['mac', 'windows'] as const) {
      expect(lidAwakeHelp(platform)).toMatch(/on the machine itself|not just in this app/i)
    }
  })

  it('warns about heat and about the battery, in the standing description', () => {
    for (const platform of ['mac', 'windows'] as const) {
      const caution = lidAwakeCaution(platform)
      expect(caution, 'airflow').toMatch(/airflow|hotter/i)
      expect(caution, 'battery').toMatch(/battery/i)
      // The decision, in the copy: it warns, it does not silently switch itself
      // off. Someone reading this should not be expecting a rescue.
      expect(caution).toMatch(/nothing here will stop it/i)
    }
  })

  it('names the reader’s own machine rather than assuming a Mac', () => {
    expect(lidAwakeHelp('windows')).toContain('this PC')
    expect(unknownStateNote('windows')).toContain('This PC')
    expect(unknownStateNote('mac')).toContain('This Mac')
  })

  it('capitalises a generic OS phrase without vandalising a product name', () => {
    /*
     * Two bugs, in sequence, both found by rendering the pane and reading it
     * rather than by any assertion here.
     *
     * The first: `osName('other')` is the phrase "your operating system", lower
     * case because every other caller uses it mid-sentence — and this section
     * puts it at the head of one, so the screen said "your operating system
     * asks for your password".
     *
     * The second was the naive fix for the first, which upper-cased the initial
     * letter of whatever came back and rendered **"MacOS"**. Apple's spelling
     * starts lower case on purpose. Both directions are pinned here because the
     * obvious repair for either one re-creates the other.
     */
    expect(lidAwakeHelp('other')).toContain('Your operating system')
    expect(lidAwakeHelp('other')).not.toContain('your operating system asks')

    expect(lidAwakeHelp('mac')).toContain('macOS')
    expect(lidAwakeHelp('mac')).not.toContain('MacOS')
  })

  it('drops the lid wording, and the whole caution, on a machine with no lid', () => {
    const help = lidAwakeHelp('mac', { hasLid: false })
    expect(help).not.toMatch(/close the lid/i)
    expect(help).toMatch(/no lid to close/i)
    // Still says the important part: it is the machine's setting, not the app's.
    expect(help).toMatch(/on the machine itself|not just in this app/i)
    // And still says who asks for the password.
    expect(help).toMatch(/password/i)

    expect(lidAwakeCaution('mac', { hasLid: false })).toBeNull()
    expect(lidAwakeCaution('windows', { hasLid: false })).toBeNull()
  })
})

/* -------------------------------------------------------------------- view -- */

describe('the Power pane', () => {
  it('heads itself with the schema wording rather than a second copy', () => {
    const meta = sectionMeta('power')
    const html = render()
    expect(html).toContain(meta.label)
    expect(html).toContain(meta.blurb)
  })

  it('shows the caution before anything has been clicked', () => {
    // Not after the first change, and not behind a disclosure. The cost of the
    // feature is on screen while the decision is being made.
    expect(render({ state: null, loading: true })).toContain('airflow')
  })

  it('draws the switch on when the OS says it is on', () => {
    expect(render()).toContain('checked=""')
  })

  it('disables the switch and admits it when the machine would not answer', () => {
    const html = render({
      state: { ...HELD, known: false, on: false, detail: 'pmset would not run.' },
    })
    expect(html).toContain('disabled=""')
    expect(html).toContain('cannot say whether it is on')
    expect(html).toContain('pmset would not run.')
  })

  it('says so, and offers nothing, on a platform that cannot do this', () => {
    const html = render({
      state: { ...HELD, supported: false, on: false, detail: 'Only macOS and Windows.' },
    })
    expect(html).toContain('Only macOS and Windows.')

    /*
     * "Offers nothing" means nothing, including the description.
     *
     * This used to render a *disabled* switch, which reads as honest and is
     * not: the paragraph above it went on describing the feature — closing the
     * lid, the screen going off, a password prompt — none of which is true on a
     * platform that cannot do any of it. Rendering the pane and reading it back
     * is what caught that; no assertion here had noticed, because each one was
     * checking a substring it expected to find rather than the sentence a user
     * would actually read.
     */
    expect(html).not.toContain('switch')
    expect(html).not.toMatch(/close the lid/i)
    expect(html).not.toMatch(/password/i)
    expect(html).not.toMatch(/airflow/i)
  })

  it('still draws the row while the machine has not answered yet', () => {
    // `supported` is also false before the first read lands, and the two must
    // not be treated alike: hiding the row during the read would make the pane
    // pop into existence a moment later.
    const html = render({ state: null, loading: true })
    expect(html).toMatch(/close the lid/i)
    expect(html).toContain('disabled=""')
  })

  it('does not blame the platform for a read that simply failed', () => {
    // state stays null when the status call rejects. That is not "this OS
    // cannot do it", and saying so would send someone looking for a limitation
    // that does not exist — the real reason is in the result notice.
    const html = render({
      state: null,
      loading: false,
      result: { outcome: 'failed', state: null, message: 'pmset could not be run.' },
    })
    expect(html).toContain('pmset could not be run.')
    expect(html).not.toMatch(/cannot hold this Mac awake/i)
  })

  it('does not describe a lid on a machine that has none', () => {
    /*
     * A Mac mini supports `disablesleep` perfectly well and has no lid, so the
     * row stays and the wording changes. The caution goes entirely: both halves
     * of it — heat with nowhere to go, a battery draining — are consequences of
     * a closed laptop, and a desktop has neither.
     */
    const html = render({
      state: { ...HELD, battery: { present: false, discharging: false, percent: null } },
    })
    expect(html).not.toMatch(/close the lid/i)
    expect(html).not.toMatch(/airflow/i)
    expect(html).toMatch(/no lid to close/i)
    expect(html).toContain('going to sleep')
  })

  it('tells the user a password box is waiting rather than looking frozen', () => {
    // This call can sit for a minute while somebody finds their password. A
    // spinner with no explanation is indistinguishable from a hang.
    const html = render({ changing: true })
    expect(html).toContain('disabled=""')
    expect(html).toMatch(/password box is on screen/i)
  })

  it('does not claim a password box on Windows, where there is none', () => {
    const html = render({
      changing: true,
      platform: 'windows',
      state: { ...HELD, needsAuthorization: false },
    })
    expect(html).not.toMatch(/password box/i)
  })

  it('surfaces the live battery warning the main process sent', () => {
    const html = render({
      state: {
        ...HELD,
        battery: { present: true, discharging: true, percent: 11 },
        warning: 'Battery is at 11% and this machine is being kept awake with the lid shut.',
      },
    })
    expect(html).toContain('11%')
  })

  it('says when the setting was already on before the app started', () => {
    // `disablesleep` outlives the app and a terminal can set it, so an on switch
    // at first launch is not necessarily this app's doing.
    expect(render({ state: { ...HELD, preexisting: true } })).toMatch(/already on before the app started/i)
  })

  it('reports a cancelled prompt as a fact, not as a failure', () => {
    const html = render({
      result: { outcome: 'cancelled', state: null, message: 'Nothing changed — the password prompt was dismissed.' },
    })
    expect(html).toContain('Nothing changed')
  })

  it('draws no switch it cannot honour when the build has no channel', () => {
    const html = render({ unwired: true, state: null })
    expect(html).toContain('disabled=""')
    expect(html).toContain('no way to read or change that setting')
  })

  /*
   * The wake lock, said out loud.
   *
   * These pin the reported fault at the layer a person actually meets it. The
   * app now holds an idle-sleep block whatever the privileged switch says, and
   * a screen that knew only about the switch had to imply the opposite — an off
   * switch reading as "nothing is protecting the session I left running". That
   * implication was true of the old behaviour, which is exactly why removing it
   * needs an assertion rather than a good intention.
   */
  describe('the app’s own wake lock', () => {
    it('says what it is doing while the privileged switch is off', () => {
      const html = render({ state: { ...HELD, on: false, preexisting: false } })
      expect(html).toMatch(/will not fall asleep on its own/i)
      expect(html).toMatch(/closing the lid or choosing sleep still does/i)
    })

    it('promises nothing when no lock is held', () => {
      const html = render({ state: { ...HELD, idleBlocked: false } })
      expect(html).not.toMatch(/will not fall asleep on its own/i)
    })

    it('still says it on a platform where the lid switch itself is not offered', () => {
      /*
       * The case that matters most for the report, and the one that would be
       * lost by putting this line inside the `unavailable` guard. Asad's own
       * Windows PC is a desktop: `powercfg /query SCHEME_CURRENT SUB_BUTTONS
       * LIDACTION` prints a scheme header and no setting block at all there —
       * checked on DESKTOP-DDGMNCV over SSH — so the pane reports the machine
       * as unsupported and offers no switch. The wake lock is this app's own
       * and needs no platform support, so that machine is precisely the one
       * that should still hear about it.
       */
      const html = render({
        state: { ...HELD, supported: false, on: false, detail: 'This machine reports no lid-close action.' },
      })
      expect(html).toContain('This machine reports no lid-close action.')
      expect(html).toMatch(/will not fall asleep on its own/i)
    })

    it('does not name a lid on a machine that has none', () => {
      const html = render({
        state: { ...HELD, on: false, battery: { present: false, discharging: false, percent: null } },
      })
      expect(html).toMatch(/will not fall asleep on its own/i)
      expect(html).not.toMatch(/closing the lid/i)
    })

    /**
     * The reported bug, as an assertion, and the reason this block exists at
     * all.
     *
     * With the switch on, the pane used to print "Closing the lid or choosing
     * Sleep still does" twenty pixels under a control whose own label promises
     * to keep the machine running with the lid closed. Both sentences were
     * generated by code that was individually correct — one describes
     * `powerSaveBlocker`, the other `disablesleep` — and neither knew the other
     * was on screen. This is what stops it coming back.
     */
    it('never argues with the switch above it', () => {
      const html = render({ state: { ...HELD, on: true, known: true } })
      // The switch is on, so it is drawn on…
      expect(html).toContain('Keep running with the lid closed')
      // …and nothing underneath may say a closed lid sleeps this machine.
      expect(html).not.toMatch(/closing the lid or choosing sleep still does/i)
      expect(html).not.toMatch(/will not fall asleep on its own/i)
    })

    /**
     * And the unknown case, which is not the off case.
     *
     * A machine that would not answer is not a machine whose lid setting is
     * off. Claiming "a closed lid still sleeps it" there would be an assertion
     * about a setting nobody could read — the exact failure the rest of this
     * file tests for on the switch itself.
     */
    it('makes no claim about the lid when the machine would not answer', () => {
      const html = render({ state: { ...HELD, known: false, on: false } })
      expect(html).toMatch(/will not fall asleep on its own/i)
      expect(html).not.toMatch(/closing the lid or choosing sleep still does/i)
      // And the reason for the silence is already on screen.
      expect(html).toMatch(/did not report this setting/i)
    })
  })
})

/**
 * The note, read directly rather than through a render.
 *
 * `PowerView` can only reach these three states by way of a `LidAwakeState`,
 * and the third one — "the machine would not answer" — is the one a render test
 * is least able to make unmistakable. The function takes the three-valued
 * argument, so it is tested with three values.
 */
describe('idleBlockedNote', () => {
  it('says nothing at all when the lid setting is on', () => {
    expect(idleBlockedNote('mac', { lidAwake: true })).toBe(null)
  })

  it('says what is and is not covered when the lid setting is off', () => {
    const note = idleBlockedNote('mac', { lidAwake: false })
    expect(note).toMatch(/will not fall asleep on its own/i)
    expect(note).toMatch(/closing the lid or choosing sleep still does/i)
  })

  it('drops the lid clause, not the whole note, when the setting is unknown', () => {
    const note = idleBlockedNote('mac', { lidAwake: null })
    expect(note).toMatch(/will not fall asleep on its own/i)
    expect(note).not.toMatch(/closing the lid/i)
  })
})
