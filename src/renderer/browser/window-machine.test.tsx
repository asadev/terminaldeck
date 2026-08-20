import { renderToStaticMarkup } from 'react-dom/server'
import { beforeEach, describe, expect, it } from 'vitest'
import { Toolbar } from './Toolbar'
import { newTab } from './tabs'
import { WindowMachineMark } from './BindChip'
import { resetWindowMachinesForTests, setWindowMachine, forgetWindowMachine } from './window-machine'

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

describe('the store', () => {
  it('holds only windows that are somewhere else', () => {
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    expect(renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)).toContain('Office PC')
    // Null is "this computer", and this computer is an absence rather than a
    // row — every reader draws nothing for it.
    setWindowMachine('b1', null)
    expect(renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)).toBe('')
  })

  it('forgets a window that has gone, and does not mind one it never knew', () => {
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    forgetWindowMachine('b1')
    forgetWindowMachine('never-existed')
    expect(renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)).toBe('')
  })

  it('falls back to the id when the machine has no name yet', () => {
    // A machine that has been paired but has not reported a name is still a
    // machine, and printing nothing would be the absence this whole file is
    // about. The menus in the main process make the same substitution.
    setWindowMachine('b1', { id: 'mach-1', name: '' })
    expect(renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)).toContain('mach-1')
  })
})

describe('the mark a tab wears', () => {
  it('says nothing at all for a window on this computer', () => {
    // Not a greyed glyph, not a placeholder. A mark on every tab to report that
    // nothing unusual is true is the same defect as the browser status dot the
    // strip refused.
    expect(renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)).toBe('')
  })

  it('names the machine where a screen reader and a hover can both reach it', () => {
    setWindowMachine('b1', { id: 'mach-1', name: 'Office PC' })
    const html = renderToStaticMarkup(<WindowMachineMark browserTabId="b1" />)
    expect(html).toContain('title="Office PC"')
    expect(html).toContain('aria-label="on Office PC"')
  })
})

/* ------------------------------------------------------------ the chip -- */

function bar(servedBy: { name: string; port: number | null; localPort: number; sameNumber: boolean } | null): string {
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

  it('carries the port for a page reached through a tunnel', () => {
    const html = bar({ name: 'Office PC', port: 5199, localPort: 5199, sameNumber: true })
    expect(html).toContain('Office PC:5199')
  })

  it('says the port arithmetic in the hover when the numbers had to differ', () => {
    const html = bar({ name: 'Office PC', port: 3000, localPort: 53412, sameNumber: false })
    expect(html).toContain('title="Office PC:3000 → :53412"')
  })

  it('names this machine with no colon when the page did not move', () => {
    /*
     * The state the whole change is for: the picker says `Office PC` and the
     * page is being fetched here. There is no tunnel and so no port, and a
     * `This machine:0` would be a number invented to fill a slot.
     */
    const html = bar({ name: 'This machine', port: null, localPort: 0, sameNumber: true })
    expect(html).toContain('>This machine<')
    expect(html).not.toContain('This machine:')
  })
})
