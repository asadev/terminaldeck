import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DeviceFoldersView,
  confinesSessions,
  folderName,
  resolveDeviceFoldersBridge,
  summaryFor,
  toDeviceFolders,
  type DeviceFoldersViewProps,
} from './DeviceFolders'
import { grantableDevices } from './RemoteSection'
import type { RemoteDevice } from './RemoteSection'

/**
 * What this panel says, in each state it can be in.
 *
 * The states are the whole feature. This screen is the answer to "why does my
 * phone only offer one folder", so the one thing it may never do is describe a
 * device inaccurately — and its three states look alike enough that flattening
 * two of them is an easy edit to make and an impossible one to notice:
 *
 *   - **not chosen** — nobody has picked, so the device gets whatever the
 *     desktop has open. Every phone paired before this feature is here.
 *   - **a list** — those folders and no others.
 *   - **empty** — somebody removed the last one, so it can start nothing.
 *
 * "Not chosen" and "empty" are the pair that matters. Draw one as the other and
 * the panel tells someone a working phone is dead, or that a phone they
 * deliberately cut off is fine.
 *
 * `renderToStaticMarkup` never runs an effect, which is why the view takes its
 * grants as a prop — the component that reads them would otherwise be testable
 * in exactly one state, the empty one, and the states worth pinning are the
 * other three.
 */

const DEVICES = [
  { id: 'dev-phone', name: "Asad's iPhone" },
  { id: 'dev-tablet', name: 'iPad' },
]

function view(over: Partial<DeviceFoldersViewProps> = {}): string {
  return renderToStaticMarkup(
    <DeviceFoldersView
      devices={DEVICES}
      grants={new Map()}
      wired={true}
      problem={null}
      busy={null}
      onAdd={() => {}}
      onRemove={() => {}}
      platform="mac"
      {...over}
    />,
  )
}

/** Markup without its tags, so an assertion reads the sentence a person reads. */
function text(markup: string): string {
  return markup
    .replace(/<[^>]*>/g, ' ')
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim()
}

/* ========================================================== what it claims -- */

describe('the sentence at the top', () => {
  /*
   * Pinned to the words, not to the existence of a paragraph, and now pinned
   * *per platform* — which is the part that matters.
   *
   * Someone will decide who holds a device on the strength of whichever of these
   * two sentences they read, and the two failures are not symmetrical. Claiming
   * a boundary on a machine that has none is the dangerous one; failing to
   * mention one that exists is merely a shame. So the Windows copy is checked
   * for the absence of every word that could be read as a lock, and the macOS
   * copy is checked for the presence of the specific things that are true.
   */
  it('on a PC, says plainly that this is not a boundary', () => {
    const said = text(view({ platform: 'windows' }))
    expect(said).toContain('Pick where each guest can start a session')
    expect(said).toContain('that is all this does')
    // The mechanism, in words a non-engineer can act on: it moves.
    expect(said).toContain('it can move to any other folder')
    expect(said).toContain('not for keeping anyone out')
    /*
     * And it says why — but no longer by claiming the mechanism does not exist.
     *
     * Until 2026-08-19 this asserted the words "only been built for macOS", and
     * that sentence was false: Windows confinement is built on AppContainer and
     * measured against real hardware. What was missing was the button, which
     * now exists — so this branch is the one a machine reaches when it genuinely
     * cannot hold a session: a build with no launcher, or a preload too old to
     * be asked. The words have to be about *this build*, not about the port.
     */
    expect(said).toContain('This build cannot hold a session inside its folder')
    expect(said).not.toContain('only been built for macOS')
  })

  it('on a PC that could be granted, offers the permission instead of denying the boundary', () => {
    /*
     * The state that used to be unreachable, and the reason this whole panel
     * was misleading: everything needed to hold a Windows session was built and
     * switched off, and this screen told people the feature did not exist —
     * which does not merely undersell it, it stops anybody turning it on.
     */
    const said = text(
      view({
        platform: 'windows',
        confine: { confining: false, canGrant: true, folders: ['C:\\Program Files\\nodejs'], note: 'A note.' },
        onGrantConfinement: () => {},
      }),
    )
    expect(said).toContain('Hold sessions inside their folders')
    expect(said).toContain('a session from a device runs unconfined')
    expect(said).toContain('C:\\Program Files\\nodejs')
    expect(said).toContain('A note.')
    // And it must not still be denying the boundary in the same breath.
    expect(said).not.toContain('not for keeping anyone out')
  })

  it('says a Windows session is held once the permission has been granted', () => {
    const said = text(
      view({
        platform: 'windows',
        confine: { confining: true, canGrant: true, folders: [], note: '' },
      }),
    )
    expect(said).toContain('held inside them')
    expect(said).not.toContain('runs unconfined')
    expect(said).not.toContain('Hold sessions inside their folders')
  })

  it('on a PC, never claims the device is held where it was put', () => {
    const said = text(view({ platform: 'windows' })).toLowerCase()
    for (const lie of ['sandbox', 'restricted to', 'cannot leave', 'only access', 'held inside them']) {
      expect(said).not.toContain(lie)
    }
  })

  it('on a Mac, says what is held and what is not', () => {
    const said = text(view({ platform: 'mac' }))
    expect(said).toContain('held inside them')
    expect(said).toContain('read and write those folders and nothing else')
    // The three things a person would actually worry about, named.
    expect(said).toContain('not your home folder')
    expect(said).toContain('not your keys')
    // And the two costs, which are real and must not be discovered later.
    expect(said).toContain('signed out of those tools')
    expect(said).toContain('does not start at all')
  })

  it('on a Mac, says what confinement does not cover', () => {
    /*
     * The gap that would otherwise be found the hard way. Confinement holds for
     * a session a device *starts*; attaching to a session the owner started has
     * no folder check at all and never has had one — that is the product's
     * headline feature, driving your own desktop session from your phone.
     *
     * A screen that said "held inside them" and stopped there would be true
     * about the sentence and misleading about the feature, which is the exact
     * failure the careful old wording existed to avoid.
     */
    const said = text(view({ platform: 'mac' }))
    // What confinement does not cover, restated for the two kinds: a guest sees
    // the sessions *you* started inside a folder it was given, and yours are
    // your own shell rather than something held anywhere.
    expect(said).toContain('including ones you started')
    expect(said).toContain('stops being reachable the moment you take a folder away')
  })

  it('on a Mac, does not pretend the tools or the network are gone', () => {
    // Rule five of the brief, said on screen: a confinement that broke node or
    // git would not be usable, and a screen that implied it had would send
    // people looking for a bug that is not there.
    const said = text(view({ platform: 'mac' }))
    expect(said).toContain('still runs node, git and the agent tools')
    expect(said).toContain('still reaches the internet')
  })

  it('says what the section is for in its heading and its first line', () => {
    /*
     * *"the folder section is there but I don't know what is this for"* — and,
     * twice in the same review, *"we don't need big descriptions as I discussed
     * before"*. The second complaint is length; the first is worse, because a
     * reader who cannot tell what a block is for cannot skip it either.
     *
     * So the heading names the thing and the first line carries the purpose.
     * Pinned on both platforms, because the purpose is the half of this panel
     * that does *not* differ.
     */
    for (const platform of ['mac', 'windows'] as const) {
      const said = text(view({ platform }))
      expect(said).toContain('Folders a guest may open')
      expect(said).toMatch(/Pick (which folders each guest can use|where each guest can start a session)/)
    }
  })

  it('leaves the standing explanation behind the dot instead of on the page', () => {
    /*
     * Four paragraphs of `settings-prose` stood between the heading and the
     * first control. What is drawn now is one, and everything else is in the
     * span `HoverNote` keeps in the document — which is why the assertions
     * above still find every sentence: nothing was cut, it moved.
     *
     * Counted rather than matched, because the failure this catches is a
     * paragraph creeping back rather than a specific sentence returning.
     */
    // Every device already has folders chosen, so the one *other* paragraph
    // this panel can draw — the one telling somebody a device paired before
    // folder approval can open nothing — is not in play. It is conditional,
    // actionable and short, and it is not part of what he was complaining
    // about; this test is about the standing explanation, which is not.
    const held = view({
      platform: 'mac',
      grants: new Map([
        ['dev-phone', ['/Users/asad/Projects/terminaldeck']],
        ['dev-tablet', ['/Users/asad/site']],
      ]),
    })
    expect(held).toContain('class="hovernote-dot"')
    // One visible paragraph before the list: the purpose and the verdict.
    expect(held.match(/class="settings-prose"/g) ?? []).toHaveLength(1)

    // And the detail really is behind the dot rather than beside it.
    const behind = /<span id="[^"]*" class="hovernote-text">([^<]*)</.exec(held)?.[1] ?? ''
    expect(behind).toContain('read and write those folders and nothing else')
    expect(behind).toContain('still runs node, git and the agent tools')
    expect(behind).toContain('including ones you started')
  })

  it('never puts the verdict about holding behind the dot, on any platform', () => {
    /*
     * The line this rewrite was not allowed to cross, and the reason it is its
     * own test rather than a comment.
     *
     * Somebody decides who to hand a device to on the strength of the clause
     * that says whether a session is *held*, and the two mistakes are not
     * symmetrical: reading "held inside them" on a machine where nothing holds
     * it is how a stranger ends up with a shell, and "they should have hovered"
     * is not an answer for that. So the clause stays in the visible paragraph
     * on every platform — the confined one, the one that can be granted, and
     * the one where nothing holds anything.
     */
    const visible = (markup: string): string => {
      // Everything except the span HoverNote hides its paragraph in.
      return text(markup.replace(/<span id="[^"]*" class="hovernote-text">[^<]*<\/span>/g, ' '))
    }

    expect(visible(view({ platform: 'mac' }))).toContain('held inside them')
    expect(visible(view({ platform: 'windows' }))).toContain('not for keeping anyone out')
    expect(
      visible(
        view({
          platform: 'windows',
          confine: { confining: false, canGrant: true, folders: [], note: '' },
          onGrantConfinement: () => {},
        }),
      ),
    ).toContain('runs unconfined')
  })

  it('never sends one sentence to both platforms', () => {
    // The instruction, as a test. The two answers are different facts and a
    // shared sentence could only be true of one of them.
    expect(text(view({ platform: 'mac' }))).not.toEqual(text(view({ platform: 'windows' })))
  })

  it('calls the machine what the reader would call it', () => {
    expect(text(view({ platform: 'windows' }))).toContain('this PC')
    expect(text(view({ platform: 'mac' }))).toContain('this Mac')
  })

  it('treats an unknown platform as unconfined', () => {
    // A new build target arrives with no measurement behind it, so it must read
    // as "nothing holds this" until somebody does the work.
    expect(confinesSessions('other')).toBe(false)
    expect(text(view({ platform: 'other' }))).toContain('not for keeping anyone out')
  })
})

/* ============================================================ three states -- */

describe('a device nobody has chosen for', () => {
  /*
   * The state every already-paired phone is in. It is written as a sentence
   * rather than drawn as an empty list because those two are the states this
   * panel most easily confuses, and this is the one where the device works.
   */
  it('says so, and says what it gets instead', () => {
    const said = text(view({ grants: new Map() }))
    // "Not chosen" is no longer a state a device can be approved into: approval
    // writes a list, including an empty one. What is left is a device approved by
    // a build older than the choice, and it reaches nothing rather than
    // everything — which is the whole security fix, said on the row.
    expect(said).toContain('Approved before this existed')
    expect(said).toContain('can open nothing on this Mac')
  })

  it('is not described as having no folders', () => {
    expect(text(view({ grants: new Map() }))).not.toContain('cannot start a session')
  })
})

describe('a device whose folders were all removed', () => {
  it('is told apart from one nobody has chosen for', () => {
    const said = text(view({ grants: new Map([['dev-phone', []]]) }))
    expect(said).toContain('No folders. This device cannot start a session.')
    // And the *other* device, which has no row at all, still reads as untouched.
    expect(said).toContain('Approved before this existed')
  })
})

describe('a device with a list', () => {
  const grants = new Map([['dev-phone', ['/Users/asad/Projects/terminaldeck', '/Users/asad/site']]])

  it('shows every folder, with the full path under the name', () => {
    const said = text(view({ grants }))
    expect(said).toContain('terminaldeck')
    expect(said).toContain('/Users/asad/Projects/terminaldeck')
    expect(said).toContain('site')
    expect(said).toContain('2 folders')
  })

  /*
   * The path line ellipsises, and a browser does not add a tooltip to text it
   * clipped — an assumption that is widely held and has never been true. Without
   * the attribute the tail of a deep path is unreachable rather than hidden, on
   * the one screen whose job is telling two similar folders apart.
   */
  it('keeps the whole path reachable once the line is clipped', () => {
    expect(view({ grants })).toContain('title="/Users/asad/Projects/terminaldeck"')
  })

  it('offers a Remove on each one and an Add on the device', () => {
    const markup = view({ grants })
    expect(markup.match(/Remove/g)).toHaveLength(2)
    expect(markup).toContain('Add a folder…')
  })

  /*
   * Rule 1.1: a hover state is a promise. Every button drawn here does
   * something, so the only honest way to show a write in flight is to stop
   * them — a Remove that stayed live during a save would queue a second write
   * against a list the panel is about to replace.
   */
  it('stops every button while one device is being written', () => {
    const markup = view({ grants, busy: 'dev-phone' })
    expect(markup).toContain('Saving…')
    expect(markup.match(/disabled/g)?.length).toBeGreaterThanOrEqual(3)
  })
})

describe('before the first read lands', () => {
  it('says it is reading rather than claiming nobody has chosen', () => {
    const said = text(view({ grants: null }))
    expect(said).toContain('Reading…')
    expect(said).not.toContain('Not chosen')
  })
})

/* ================================================================ nothing -- */

describe('when there is nothing to choose for', () => {
  it('explains the empty screen instead of drawing an empty list', () => {
    expect(text(view({ devices: [] }))).toContain('No guest device has been let in')
  })

  /*
   * The `browserViewClaim`/`browserClaim` failure, one panel over: a component
   * whose preload method is missing renders a fallback that looks like an
   * unimplemented feature. Saying so is the difference between "this build
   * cannot do it" and a screen that appears broken.
   */
  it('says the build cannot do it, rather than showing dead controls', () => {
    const markup = view({ wired: false })
    expect(text(markup)).toContain('not available in this build')
    expect(markup).not.toContain('Add a folder…')
  })
})

describe('when a read or a write failed', () => {
  it('warns that what is on screen may be stale, and still shows it', () => {
    const markup = view({
      grants: new Map([['dev-phone', ['/Users/asad/site']]]),
      problem: 'Could not save that.',
    })
    expect(text(markup)).toContain('Could not save that. What is below may be out of date.')
    // The list stays. Blanking it would replace a stale answer with no answer,
    // which is worse: the user loses the only record of what they had chosen.
    expect(text(markup)).toContain('/Users/asad/site')
  })
})

/* =========================================================== the narrowing -- */

describe('reading what the main process sent', () => {
  it('keeps a device with an empty list, because empty is a decision', () => {
    const grants = toDeviceFolders([{ deviceId: 'dev-phone', folders: [] }])
    expect(grants.get('dev-phone')).toEqual([])
    // Present-and-empty, not absent. `has` and `get` disagree for exactly the
    // two states this panel must not merge.
    expect(grants.has('dev-phone')).toBe(true)
  })

  it('drops entries it cannot read rather than inventing a state for them', () => {
    const grants = toDeviceFolders([
      { deviceId: 'ok', folders: ['/a'] },
      { deviceId: '', folders: ['/b'] },
      { deviceId: 'no-list' },
      null,
      'nonsense',
    ])
    expect([...grants.keys()]).toEqual(['ok'])
  })

  it('survives an answer that is not a list at all', () => {
    expect(toDeviceFolders(undefined).size).toBe(0)
    expect(toDeviceFolders({ devices: [] }).size).toBe(0)
  })

  it('drops a folder that is not a string, keeping the rest of the device', () => {
    const grants = toDeviceFolders([{ deviceId: 'ok', folders: ['/a', 7, '', '/b'] }])
    expect(grants.get('ok')).toEqual(['/a', '/b'])
  })
})

describe('the name shown for a folder', () => {
  it('is the last segment, on either separator', () => {
    expect(folderName('/Users/asad/Projects/terminaldeck')).toBe('terminaldeck')
    expect(folderName('C:\\Users\\Asad\\proj')).toBe('proj')
  })

  it('survives a trailing separator rather than going blank', () => {
    expect(folderName('/Users/asad/site/')).toBe('site')
  })

  it('falls back to the path when there is no segment to show', () => {
    expect(folderName('/')).toBe('/')
  })
})

describe('the line under a device name', () => {
  it('counts in words a person reads, singular and plural', () => {
    expect(summaryFor(['/a'], true)).toBe('1 folder')
    expect(summaryFor(['/a', '/b'], true)).toBe('2 folders')
  })

  it('never says "not chosen" before anything has been read', () => {
    expect(summaryFor(null, false)).toBe('Reading…')
  })

  /*
   * It used to return the whole explanation — "Not chosen — this device can
   * start a session in whichever project is open on this Mac." — which three
   * devices in the ordinary state printed verbatim three times down one column.
   * The state is a label; what it means belongs above the list, once.
   */
  it('labels the state without explaining it on every card', () => {
    const line = summaryFor(null, true)
    expect(line).toBe('Approved before this existed — can open nothing')
    expect(line).not.toMatch(/session/)
  })
})

/* ================================================================ the bridge */

describe('resolving the preload', () => {
  it('reports nothing wired when the host has no methods', () => {
    expect(resolveDeviceFoldersBridge({})).toEqual({})
    expect(resolveDeviceFoldersBridge(null)).toEqual({})
  })

  /*
   * Called through the host object, never torn off it. A preload that exposed
   * methods on a prototype would throw on `this` the first time a button was
   * pressed — which is a runtime failure in a panel that tested fine, because
   * the detached function still exists and still has the right name.
   */
  it('keeps the host as the receiver', async () => {
    const host = {
      me: 'deck',
      listDeviceFolders(this: { me: string }) {
        return Promise.resolve(this.me)
      },
    }
    const bridge = resolveDeviceFoldersBridge(host)
    await expect(bridge.listDeviceFolders?.()).resolves.toBe('deck')
  })

  it('passes the arguments a write needs, in order', async () => {
    const seen: unknown[] = []
    const bridge = resolveDeviceFoldersBridge({
      setDeviceFolders: (...args: unknown[]) => {
        seen.push(...args)
        return Promise.resolve([])
      },
    })
    await bridge.setDeviceFolders?.('dev-phone', ['/a'])
    expect(seen).toEqual(['dev-phone', ['/a']])
  })
})

/* ====================================================== who gets a row at all */

describe('which devices this panel is drawn for', () => {
  const roster: RemoteDevice[] = [
    { id: 'ok', name: 'Phone', state: 'approved', addedAt: null, lastSeenAt: null, fingerprint: null },
    { id: 'wait', name: 'Unknown', state: 'pending', addedAt: null, lastSeenAt: null, fingerprint: null },
    { id: 'gone', name: 'Old phone', state: 'revoked', addedAt: null, lastSeenAt: null, fingerprint: null },
  ]

  /*
   * Approved only. A pending device cannot open anything, so choosing folders
   * for it is a decision about a device before the decision that matters; and a
   * revoked one is gone for good — the trust store never un-revokes, so its
   * grants have already been forgotten in the main process and a row here would
   * offer an edit to a record that no longer exists.
   */
  it('is the approved ones, and only those', () => {
    expect(grantableDevices(roster)).toEqual([{ id: 'ok', name: 'Phone' }])
  })

  it('carries the name the user gave the device, not its id', () => {
    expect(grantableDevices(roster)[0]?.name).toBe('Phone')
  })
})
