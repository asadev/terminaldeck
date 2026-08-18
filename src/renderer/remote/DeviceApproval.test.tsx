import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceApproval,
  nextStep,
  previousStep,
  stepsFor,
  type DeviceApprovalProps,
  type DeviceKind,
} from './DeviceApproval'

/**
 * The flow that stands between six digits and a shell.
 *
 * What it replaces was one button called **Approve**, and the folder choice was
 * a separate block further down the same page. So the ordinary path let a phone
 * in with every project open at the desk reachable, which is what he watched
 * happen:
 *
 *   > *"Folder approval never happened. I entered the six-digit code and
 *   > immediately had access to every folder."*
 *
 * The tests here are about the two things that make this a fix rather than a
 * nicer form:
 *
 *   1. **There is no path to "let in" that skips the questions.** Continue is
 *      refused until whose device it is has been answered, and the last step is
 *      the only one with the button on it.
 *   2. **The two kinds are different flows, not one flow with a flag.** One of
 *      your own machines is never shown a folder picker, and a guest is never
 *      shown anything about the copilot.
 *
 * `renderToStaticMarkup` never runs an effect, which is why every prop is
 * passed in: a component that held its own step would be testable in exactly one
 * state, the first.
 */

const DEVICE = {
  id: 'dev-1',
  name: 'Asad’s iPhone',
  fingerprint: 'H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY',
}

function view(overrides: Partial<DeviceApprovalProps> = {}): string {
  const props: DeviceApprovalProps = {
    device: DEVICE,
    platform: 'mac',
    folders: [],
    step: 'check',
    kind: null,
    busy: false,
    problem: null,
    onStep: () => {},
    onKind: () => {},
    onAddFolder: () => {},
    onRemoveFolder: () => {},
    onApprove: () => {},
    onCancel: () => {},
    ...overrides,
  }
  return renderToStaticMarkup(<DeviceApproval {...props} />)
}

/** The rendered text, with tags and entities out of the way. */
function text(html: string): string {
  return html
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x27;|&#39;/g, '’')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim()
}

describe('the order of the questions', () => {
  it('puts the folder step in a guest’s flow and leaves it out of your own', () => {
    expect(stepsFor('guest')).toEqual(['check', 'kind', 'folders', 'confirm'])
    // Not a skipped step — an absent one. A person approving their own laptop is
    // not making a security decision, and a picker in front of that is a form
    // standing between somebody and their own files.
    expect(stepsFor('mine')).toEqual(['check', 'kind', 'confirm'])
  })

  it('shows the longer flow before the kind is answered', () => {
    // Three dots that become four would read as the app having added work; four
    // that become three read as a step having been saved.
    expect(stepsFor(null)).toHaveLength(4)
  })

  it('walks forwards and back without falling off either end', () => {
    expect(nextStep('check', null)).toBe('kind')
    expect(nextStep('kind', 'mine')).toBe('confirm')
    expect(nextStep('kind', 'guest')).toBe('folders')
    expect(nextStep('confirm', 'guest')).toBe('confirm')
    expect(previousStep('check', null)).toBeNull()
    expect(previousStep('confirm', 'mine')).toBe('kind')
    expect(previousStep('confirm', 'guest')).toBe('folders')
  })
})

describe('nothing is let in before the questions are answered', () => {
  it('offers Continue and not the approve button, on every step but the last', () => {
    for (const step of ['check', 'kind', 'folders'] as const) {
      const html = view({ step, kind: 'guest' })
      expect(html).toContain('>Continue</button>')
      expect(html).not.toContain('>Let it in</button>')
    }
  })

  it('refuses Continue until whose device it is has been answered', () => {
    const html = view({ step: 'kind', kind: null })
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Continue<\/button>/)
    // A disabled control with no stated reason is half of a dead control: the
    // app knows why and the person looking at it does not.
    expect(html).toContain('Pick whose device it is first.')
  })

  it('lets it in only from the last step', () => {
    const html = view({ step: 'confirm', kind: 'guest' })
    expect(html).toContain('>Let it in</button>')
    expect(html).not.toContain('>Continue</button>')
  })
})

describe('the words he chose, on the screen where the choice is made', () => {
  it('prints both kinds in full, including the sentence about the copilot', () => {
    const said = text(view({ step: 'kind' }))
    expect(said).toContain('My device')
    expect(said).toContain('Full access. It’s you at another keyboard.')
    expect(said).toContain('Guest')
    expect(said).toContain('You choose what they can reach. The copilot is never shared.')
  })

  it('says a kind cannot be changed afterwards, before it is chosen for good', () => {
    const said = text(view({ step: 'confirm', kind: 'guest' }))
    expect(said).toContain('fixed once you let it in')
    expect(said).toContain('revoke the device and pair it again')
  })

  it('never mentions the copilot to a guest except to say it is not shared', () => {
    for (const step of ['check', 'kind', 'folders', 'confirm'] as const) {
      const said = text(view({ step, kind: 'guest' }))
      for (const sentence of said.split('.')) {
        if (!/copilot/i.test(sentence)) continue
        expect(sentence).toMatch(/never shared|not be offered/i)
      }
    }
  })
})

describe('choosing folders', () => {
  it('says that nothing chosen means nothing reachable', () => {
    const said = text(view({ step: 'folders', kind: 'guest', folders: [] }))
    // The old default was the opposite — an unanswered folder question meant
    // every project this desktop had open — so the empty state has to be a
    // sentence rather than a blank list.
    expect(said).toContain('Nothing yet — and nothing is what it gets')
    expect(said).toContain('will not see the other folders')
  })

  it('lists a chosen folder by name with its full path beside it', () => {
    const html = view({
      step: 'folders',
      kind: 'guest',
      folders: ['/Users/apple/Projects/terminaldeck'],
    })
    expect(html).toContain('>terminaldeck</span>')
    // Two projects can share a last segment, and the line ellipsises inside a
    // settings pane — so the whole value stays reachable through `title`.
    expect(html).toContain('title="/Users/apple/Projects/terminaldeck"')
  })

  it('summarises what a guest will get, in a count rather than a list of paths', () => {
    const said = text(
      view({ step: 'confirm', kind: 'guest', folders: ['/a/alpha', '/b/beta'] }),
    )
    expect(said).toContain('able to open 2 folders')
    expect(said).toContain('alpha')
    expect(said).toContain('beta')
  })

  it('tells the truth about a guest let in with nothing chosen', () => {
    const said = text(view({ step: 'confirm', kind: 'guest', folders: [] }))
    expect(said).toContain('able to open nothing yet')
  })
})

describe('the device being looked at', () => {
  it('shows the fingerprint to compare, and what a mismatch means', () => {
    const said = text(view({ step: 'check' }))
    expect(said).toContain('H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY')
    expect(said).toContain('cancel, do not continue')
  })

  it('says a device with no key cannot come in through the relay at all', () => {
    const said = text(view({ step: 'check', device: { ...DEVICE, fingerprint: null } }))
    // Not a cosmetic gap, and said at the moment somebody is deciding rather
    // than discovered the first time it fails from a hotel.
    expect(said).toContain('nothing to compare')
    expect(said).toContain('Pair it again')
  })
})

describe('one of the owner’s own machines', () => {
  it('is told it has everything, and is asked nothing about folders', () => {
    const said = text(view({ step: 'confirm', kind: 'mine' as DeviceKind }))
    expect(said).toContain('full access')
    expect(said).toContain('use the copilot')
    expect(said).not.toContain('Add a folder')
  })
})
