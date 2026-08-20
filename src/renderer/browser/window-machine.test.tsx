import { renderToStaticMarkup } from 'react-dom/server'
import { beforeEach, describe, expect, it } from 'vitest'
import { Toolbar } from './Toolbar'
import { newTab } from './tabs'
import { WorkspaceTabStrip } from './WorkspaceTabStrip'
import { resetWindowMachinesForTests, setWindowMachine, forgetWindowMachine } from './window-machine'
import type { WorkspaceTab } from '../shell/workspace-tabs'
import type { ServedBy } from './served-mark'

/**
 * *"We always need a truth."*
 *
 * Two surfaces had to learn which computer a browser window's page is on, and
 * both of them learned it because of the same two sentences of Asad's, said a
 * minute apart on 2026-08-20:
 *
 * > *"if I open any browser here and if I connect it to, let's say, desktop, now
 * > this is in desktop, it should come under this table, under the desktop
 * > sessions. So all the desktop browser, including session, should be at one
 * > place."*
 *
 * > *"Now I don't know if it is actually there or here… Maybe in this kind of
 * > situation, we will need to keep this so we know actually where it is running
 * > right now, or it should be unsuccessful here also, because we always need a
 * > truth."*
 *
 * The failures those describe are both **absences**, which is what makes them
 * worth a test file: a tab that says nothing about its machine, and a chip that
 * says where a page is by not being drawn. Neither can be caught by asserting
 * that some string is present, so every case below asserts the pair — what is
 * drawn *and* what is not.
 */

beforeEach(() => {
  resetWindowMachinesForTests()
})

/**
 * The store's one consumer, which is how it is read here.
 *
 * It used to be probed through `WindowMachineMark` — a 12px glyph on the tab
 * whose tooltip held the machine's name. That mark is gone: the audit's verdict
 * on it was that the fact he asked to see was still on no surface without a
 * hover, and that nothing showed a machine's sessions and its windows together.
 * The name is a **heading over the machine's run of tabs** now, so this file
 * asks the strip, which is where the answer is drawn.
 */
const TABS: WorkspaceTab[] = [
  { id: 'here', kind: 'session', label: 'Session 1', status: 'idle', closable: true },
  { id: 'b1', kind: 'browser', label: 'New tab', closable: true },
]

function strip(): string {
  return renderToStaticMarkup(
    <WorkspaceTabStrip
      tabs={TABS}
      activeTabId="here"
      onSelect={() => {}}
      storage={{
        length: 1,
        clear: () => {},
        getItem: (key: string) =>
          key === 'terminaldeck.strip.promoted' ? '["here","b1"]' : null,
        key: () => null,
        removeItem: () => {},
        setItem: () => {},
      }}
    />,
  )
}

describe('the store', () => {
  it('holds only windows that are somewhere else', () => {
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    expect(strip()).toContain('Office PC')
    // Null is "this computer", and this computer is an absence rather than a
    // row — every reader draws nothing for it.
    setWindowMachine('b1', null)
    expect(strip()).not.toContain('Office PC')
  })

  it('forgets a window that has gone, and does not mind one it never knew', () => {
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    forgetWindowMachine('b1')
    forgetWindowMachine('never-existed')
    expect(strip()).not.toContain('Office PC')
  })

  it('falls back to the id when the machine has no name yet', () => {
    // A machine that has been paired but has not reported a name is still a
    // machine, and printing nothing would be the absence this whole file is
    // about. The menus in the main process make the same substitution.
    setWindowMachine('b1', { id: 'mach-1', name: '' })
    expect(strip()).toContain('mach-1')
  })
})

describe('what the bar says about it', () => {
  it('says nothing at all when every window is on this computer', () => {
    // Not a greyed glyph, not a heading reading "This computer". A mark on every
    // tab to report that nothing unusual is true is the same defect as the
    // browser status dot the strip refused.
    expect(strip()).not.toContain('strip-group')
  })

  it('puts the machine’s name over its own run, not inside a tooltip', () => {
    /*
     * The E11 fix, stated as the difference it makes: the name is *text on the
     * bar*, and the tabs under it are that machine's — its browser windows and,
     * when it has any, its sessions. Before this it was a `title` on a 12px
     * glyph, which is the state the audit called out.
     */
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    const html = strip()
    expect(html).toContain('class="strip-group-name">Office PC<')
    // And the tab itself carries no machine mark any more.
    expect(html).not.toContain('tab-machine-mark')
  })
})

/* ------------------------------------------------------------ the chip -- */

function bar(servedBy: ServedBy | null): string {
  return renderToStaticMarkup(
    <Toolbar
      tab={{ ...newTab('t', 'http://example.com/'), url: 'http://example.com/' }}
      progress={1}
      resolution={{ kind: 'url', url: 'http://example.com/', display: 'example.com' }}
      focusToken={0}
      onDraft={() => {}}
      onEditing={() => {}}
      onSubmit={() => {}}
      onBack={() => {}}
      onForward={() => {}}
      onReload={() => {}}
      onStop={() => {}}
      onHome={() => {}}
      onInspect={() => {}}
      onRecord={() => {}}
      onScreenshot={() => {}}
      onDevtools={() => {}}
      devtoolsOpen={false}
      recording={false}
      onDraw={() => {}}
      drawing={false}
      deviceOpen={false}
      onToggleDevice={() => {}}
      onMenu={() => {}}
      menuOpen={false}
      steps={0}
      servedBy={servedBy}
    />,
  )
}

describe('the chip inside the address field', () => {
  it('is absent when there is nothing to say that the picker does not', () => {
    // *"Since we already have here a selection, why do we show inside the link
    // bar also local? … from inside the link bar, it should be only the link."*
    expect(bar(null)).not.toContain('bw-served')
  })

  it('does not repeat the machine the picker is already naming', () => {
    /*
     * `Office PC` in the picker and `Office PC:5199` in the field, a centimetre
     * apart — his complaint about `local`, word for word. The port is in the
     * address the field is showing, so there is no remainder at all.
     */
    const html = bar({ name: 'Office PC', port: 5199, localPort: 5199, sameNumber: true, agrees: true })
    expect(html).not.toContain('bw-served')
  })

  it('carries the origin port when the address is showing a different one', () => {
    const html = bar({ name: 'Office PC', port: 3000, localPort: 53412, sameNumber: false, agrees: true })
    expect(html).toContain('>:3000<')
    expect(html).not.toContain('>Office PC:3000<')
    expect(html).toContain('title="Office PC:3000 → :53412"')
  })

  it('names this machine with no colon when the page did not move', () => {
    /*
     * The state the whole change is for: the picker says `Office PC` and the
     * page is being fetched here. There is no tunnel and so no port, and a
     * `This machine:0` would be a number invented to fill a slot.
     */
    const html = bar({ name: 'This machine', port: null, localPort: 0, sameNumber: true, agrees: false })
    expect(html).toContain('>This machine<')
    expect(html).not.toContain('This machine:')
  })
})
