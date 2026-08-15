import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
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
})
