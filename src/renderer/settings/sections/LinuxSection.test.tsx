import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  LinuxView,
  distroNote,
  resolveWslBridge,
  toSnapshot,
  type Distro,
  type WslSnapshot,
} from './LinuxSection'
import { sectionMeta } from '../settings-schema'

/**
 * What this pane must never do.
 *
 * It describes a machine it can only ask about, so the two ways it can lie are
 * the two things tested hardest here:
 *
 *  1. **It must not draw a distribution picker it does not have an answer for.**
 *     A malformed reply has to produce the "nothing installed" pane, not a list
 *     built out of whatever came off the wire — otherwise somebody chooses a
 *     distribution that is not there and every session afterwards fails in a
 *     terminal, naming something this screen showed them.
 *  2. **It must not present the choice as the routing decision.** The folder
 *     decides which side a session runs on; this only says *which* Linux. A
 *     pane that reads like a "use WSL" switch invites somebody to look for the
 *     switch that deliberately does not exist.
 *
 * Static markup only, like every other test in this window: `renderToStaticMarkup`
 * runs no effects, which is exactly why `LinuxView` takes everything it draws.
 */

const UBUNTU: Distro = { name: 'Ubuntu', version: 2, running: true, isDefault: true }
const DEBIAN: Distro = { name: 'Debian', version: 2, running: false, isDefault: false }

const READY: WslSnapshot = {
  supported: true,
  state: 'ready',
  distros: [UBUNTU, DEBIAN],
  chosen: null,
  active: 'Ubuntu',
  home: '/home/asad',
  detail: null,
  read: true,
}

function render(props: Partial<Parameters<typeof LinuxView>[0]> = {}): string {
  return renderToStaticMarkup(
    <LinuxView
      snapshot={READY}
      loading={false}
      unwired={false}
      error={null}
      platform="windows"
      onChoose={() => undefined}
      onRefresh={() => undefined}
      {...props}
    />,
  )
}

describe('the pane', () => {
  it('leads with the rule, so nobody goes looking for a switch', () => {
    // The whole mental model, and it is not the one people arrive with: there is
    // no "use Linux" toggle because the folder already decides.
    const html = render()
    expect(html).toContain('A session opens where its folder is')
    expect(html).toContain(sectionMeta('linux').label)
  })

  it('lists what is installed and marks the one in use', () => {
    const html = render()
    expect(html).toContain('Ubuntu')
    expect(html).toContain('Debian')
    expect(html).toContain('In use')
  })

  it('offers a change on every row except the one already in use', () => {
    // A disabled button on the selected row is a control that looks pressable
    // and is not. There is nothing to press there because there is nothing to do.
    const html = render()
    expect(html.match(/Use this one/g)?.length).toBe(1)
  })

  it('does not explain a choice a one-distribution machine does not have', () => {
    const html = render({ snapshot: { ...READY, distros: [UBUNTU] } })
    expect(html).not.toContain('Use this one')
    expect(html).not.toContain('remembered for this')
  })

  it('says a stopped distribution is normal rather than a problem', () => {
    // It starts itself the moment a session opens in it. Saying so is the
    // difference between a fact and a job the reader now thinks they have.
    expect(distroNote(DEBIAN)).toContain('starts when you open a session')
    expect(distroNote(UBUNTU)).toBe('Running now.')
    expect(render()).toContain('it starts when you open a session in it')
  })

  it('names the home directory in the terminal face, because it is a path', () => {
    expect(render()).toContain('<code class="settings-path">/home/asad</code>')
  })

  it('says nothing about a home directory it has not been told', () => {
    expect(render({ snapshot: { ...READY, home: null } })).not.toContain('settings-path')
  })
})

describe('a machine with nothing to run in', () => {
  it('says WSL is not installed, and where to get it', () => {
    const html = render({
      snapshot: { ...READY, state: 'absent', distros: [], active: null, home: null },
    })
    expect(html).toContain('is not installed on this PC')
    expect(html).toContain('learn.microsoft.com/windows/wsl/install')
    expect(html).not.toContain('Use this one')
  })

  it('tells the two empty cases apart', () => {
    // "WSL is not here" and "WSL is here with nothing in it" are different
    // situations with different fixes, and flattening them leaves the second one
    // reading like a lie to somebody who can see WSL in their Start menu.
    const none = render({
      snapshot: { ...READY, state: 'no-distros', distros: [], active: null, home: null },
    })
    expect(none).toContain('has no Linux installed in it')
  })

  it('prints Windows’ own sentence rather than a summary of it', () => {
    // The real messages name the actual problem. A paraphrase would be the only
    // inaccurate line on the screen.
    const said = 'WslRegisterDistribution failed: the Virtual Machine Platform is not enabled.'
    const html = render({
      snapshot: { ...READY, state: 'no-distros', distros: [], detail: said, active: null },
    })
    expect(html).toContain(said)
  })
})

describe('before and instead of an answer', () => {
  it('says it is checking rather than drawing an empty machine', () => {
    // `read: false` is "the question has not come back", which is not the same
    // fact as "there is nothing installed" and must not look like it.
    const html = render({ snapshot: null })
    expect(html).toContain('Checking what this PC has')
    expect(html).not.toContain('is not installed on this PC')
  })

  it('admits a build with no channel instead of drawing a dead pane', () => {
    const html = render({ snapshot: null, unwired: true })
    expect(html).toContain('cannot read the Linux side yet')
    // And the button that would do nothing is disabled rather than inviting.
    expect(html).toContain('disabled')
  })

  it('shows a failure rather than an empty list', () => {
    expect(render({ error: 'EPERM' })).toContain('EPERM')
  })
})

describe('what comes off the wire', () => {
  it('reads a real snapshot', () => {
    expect(toSnapshot({ ...READY })).toEqual(READY)
  })

  it('treats anything it does not recognise as nothing installed', () => {
    // The pessimistic default matters: the optimistic one would draw a picker
    // from a malformed message and let somebody choose a distribution that is
    // not there.
    expect(toSnapshot({ state: 'anything', supported: true })?.state).toBe('absent')
    expect(toSnapshot('nope')).toBeNull()
    expect(toSnapshot(null)).toBeNull()
  })

  it('drops a distribution with no name instead of rendering a blank row', () => {
    const snapshot = toSnapshot({
      supported: true,
      state: 'ready',
      read: true,
      distros: [{ name: 'Ubuntu', version: 2, running: true, isDefault: true }, {}, 'Debian'],
    })
    expect(snapshot?.distros.map((entry) => entry.name)).toEqual(['Ubuntu'])
  })

  it('reads a missing flag as false rather than as unknown', () => {
    const snapshot = toSnapshot({ state: 'ready', read: true, distros: [{ name: 'Alpine' }] })
    expect(snapshot?.distros[0]).toEqual({
      name: 'Alpine',
      version: 0,
      running: false,
      isDefault: false,
    })
  })
})

describe('the bridge', () => {
  it('takes only the methods that are really functions', () => {
    const bridge = resolveWslBridge({ wslStatus: () => Promise.resolve(null), chooseWslDistro: 7 })
    expect(typeof bridge.wslStatus).toBe('function')
    expect(bridge.chooseWslDistro).toBeUndefined()
  })

  it('calls through the host rather than copying the function off it', async () => {
    // A preload whose methods sit on a prototype throws on `this` the first time
    // a button is pressed, and only in a packaged build.
    const host = {
      distro: 'Ubuntu',
      wslStatus(this: { distro: string }): Promise<string> {
        return Promise.resolve(this.distro)
      },
      chooseWslDistro: () => Promise.resolve(null),
    }
    // Awaited, and the test is `async` so that it can be. `.resolves` returns a
    // promise; unawaited it asserts nothing at all — this case would have gone
    // on passing if `resolveWslBridge` had started copying the function off the
    // host and losing `this`, which is the one thing it exists to catch. vitest
    // warns about it today and fails on it in the next major.
    await expect(resolveWslBridge(host).wslStatus?.()).resolves.toBe('Ubuntu')
  })

  it('answers empty for a host that is not there at all', () => {
    expect(resolveWslBridge(null)).toEqual({})
  })
})
