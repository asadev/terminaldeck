import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Toolbar } from './Toolbar'
import { newTab, type WorkspaceTab } from './tabs'

/**
 * The Shared / Isolated switch, checked as markup.
 *
 * There is no DOM in this project's test setup, so this holds the control's
 * accessible shape rather than its behaviour — which is the half that has to be
 * right anyway. The state it reports decides whether the tab can see the
 * cookies imported from Chrome, so a switch that renders the wrong word, or
 * renders nothing at all when it cannot work, is the whole bug.
 */

function render(
  tab: WorkspaceTab | null,
  onToggleIsolation?: () => void,
  draw?: { onDraw?: () => void; drawing?: boolean },
): string {
  return renderToStaticMarkup(
    <Toolbar
      tab={tab}
      security="local"
      progress={1}
      resolution={{ kind: 'url', url: 'http://localhost:3000/', display: 'localhost:3000' }}
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
      onDraw={draw?.onDraw}
      drawing={draw?.drawing === true}
      deviceOpen={false}
      onToggleDevice={() => {}}
      onMenu={() => {}}
      menuOpen={false}
      steps={0}
      onToggleIsolation={onToggleIsolation}
    />,
  )
}

describe('the isolation toggle', () => {
  it('says Shared for an ordinary tab', () => {
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toContain('Session: Shared')
    expect(markup).toContain('>Shared<')
    expect(markup).toContain('aria-pressed="false"')
  })

  it('says Isolated for an isolated tab, and says so where a reader can find it', () => {
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).toContain('Session: Isolated')
    expect(markup).toContain('>Isolated<')
    expect(markup).toContain('aria-pressed="true"')
  })

  it('explains what switching costs, because it reopens the page', () => {
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).toMatch(/reopens the page/)
  })

  it('stays on screen and disabled when the preload has not wired it', () => {
    // Hiding it would read as "this app has no isolation", which is a different
    // and worse claim than "this build cannot do it".
    const markup = render(newTab('tab-1'))
    expect(markup).toContain('Session: Shared')
    expect(markup).toContain('not available in this build')
    expect(markup).toContain('disabled')
  })

  it('is disabled with no tab open', () => {
    expect(render(null, () => {})).toContain('disabled')
  })
})

/**
 * *"So this draw option we need to have also, and we can send it to the agent
 * like this."* — 2026-08-16, said in passing and dropped from every plan file.
 * This is the control it asked for, held to the same bargain as the isolation
 * toggle: present and explaining itself when it cannot work, rather than absent.
 */
describe('the draw button', () => {
  it('is a labelled button beside the rest of the page actions', () => {
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {} })
    expect(markup).toContain('Mark the page up and send it to a session')
    expect(markup).toContain('>Draw<')
  })

  it('reads as pressed while a canvas is over the page', () => {
    // The page is parked behind that canvas, so a button that did not look on
    // would leave the one visible explanation for a frozen website unstated.
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {}, drawing: true })
    expect(markup).toMatch(/aria-label="Mark the page up[^"]*" aria-pressed="true"/)
  })

  it('stays on screen and disabled when the preload has not wired it', () => {
    // Draw mode's two channels are deliberately outside `BRIDGE_METHODS` — see
    // `draw-bridge.ts` — so "this build cannot do it" is a state that really
    // happens, and it has to say so rather than quietly disappear.
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toContain('Marking up the page is not available in this build.')
    expect(markup).toContain('>Draw<')
  })

  it('is disabled with no tab open', () => {
    const markup = render(null, () => {}, { onDraw: () => {} })
    expect(markup).toMatch(/aria-label="Mark the page up[^"]*"[^>]*disabled/)
  })
})

/**
 * The bar after the bottom band was removed.
 *
 * *"Remove everything from the bottom. I need a clear view of the websites.
 * Whatever is required should be on the top right corner."* These two pin the
 * consequences on this bar: the menu that took the band's contents exists, and
 * the recorder — which no longer has a panel on screen while it runs — reports
 * its count on the button that is already there.
 */
describe('the top-right corner carries what the bottom used to', () => {
  it('has a menu for the things that are not actions on the page', () => {
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toContain('Profiles, saved logins, cookies and the start page')
  })

  it('counts the recorded steps on the Stop button, since nothing else shows them', () => {
    const markup = renderToStaticMarkup(
      <Toolbar
        tab={newTab('tab-1')}
        security="local"
        progress={1}
        resolution={{ kind: 'url', url: 'http://localhost:3000/', display: 'localhost:3000' }}
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
        recording={true}
        drawing={false}
        deviceOpen={false}
        onToggleDevice={() => {}}
        onMenu={() => {}}
        menuOpen={false}
        steps={8}
      />,
    )
    expect(markup).toContain('Stop (8)')
  })
})

/**
 * The machine picker's place, and the badge that says where a page came from.
 *
 * *"Maybe give a drop down next to somewhere here with the bar, to choose which
 * device we are talking to right now."*
 *
 * The picker itself is `MachinePicker`; what is held here is the toolbar's half
 * of the bargain — that it makes room for one beside the address bar and not
 * inside the field, and that a page served from another machine says so where
 * somebody looks to find out where they are.
 */

function withMachines(
  machinePicker?: React.ReactNode,
  servedBy?: { name: string; port: number; localPort: number; sameNumber: boolean } | null,
): string {
  return renderToStaticMarkup(
    <Toolbar
      tab={newTab('tab-1')}
      security="local"
      progress={1}
      resolution={{ kind: 'url', url: 'http://127.0.0.1:53412/', display: '127.0.0.1:53412' }}
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
      drawing={false}
      deviceOpen={false}
      onToggleDevice={() => {}}
      onMenu={() => {}}
      menuOpen={false}
      steps={0}
      machinePicker={machinePicker}
      servedBy={servedBy}
    />,
  )
}

describe('the toolbar with another machine in play', () => {
  it('is exactly the bar it always was when nothing is paired', () => {
    // The whole point of the item: *"shape of the application should not be
    // changing for local and remote devices."* With one computer there is
    // nothing to choose between, so there is nothing extra on the bar.
    const bare = withMachines(undefined, null)
    expect(bare).not.toContain('bw-served')
    expect(bare).toContain('aria-label="Address and search"')
  })

  it('places the picker outside the address field, not inside its focus ring', () => {
    const markup = withMachines(<span data-test-picker="1">office-pc</span>, null)
    const picker = markup.indexOf('data-test-picker')
    const field = markup.indexOf('class="bw-address"')
    expect(picker).toBeGreaterThan(-1)
    expect(field).toBeGreaterThan(-1)
    // Before the form opens. A button living inside that ring reads as part of
    // the text being typed, and pressing it would take the ring with it.
    expect(picker).toBeLessThan(field)
  })

  it('names the machine a loopback page is really being served from', () => {
    const markup = withMachines(undefined, {
      name: 'office-pc',
      port: 3000,
      localPort: 3000,
      sameNumber: true,
    })
    expect(markup).toContain('office-pc')
    expect(markup).toContain('3000')
    expect(markup).toContain('carried to this machine')
  })

  it('says why the numbers differ, on the one page where they do', () => {
    const markup = withMachines(undefined, {
      name: 'office-pc',
      port: 3000,
      localPort: 53412,
      sameNumber: false,
    })
    expect(markup).toContain('53412')
    expect(markup).toContain('already in use on this machine')
  })
})
