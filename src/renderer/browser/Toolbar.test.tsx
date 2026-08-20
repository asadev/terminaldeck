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
 *
 * The word left the screen on 2026-08-20 — *"remove all of these titles. Just
 * keep the logos"*, and "shade" in his list is this control. It did not leave
 * the markup: `aria-label` is what a screen reader has instead of the colour
 * and the changed drawing, so the assertions below are about that.
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
    expect(markup).toContain('title="Shared"')
    expect(markup).toContain('aria-pressed="false"')
  })

  it('says Isolated for an isolated tab, and says so where a reader can find it', () => {
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).toContain('Session: Isolated')
    expect(markup).toContain('title="Isolated"')
    expect(markup).toContain('aria-pressed="true"')
  })

  it('carries no sentence on the hover, like everything else on this bar', () => {
    // *"I don't want any kind of long descriptions anywhere."* What switching
    // costs — the page is reopened, because a WebContents' session is fixed when
    // it is constructed — is documented in `browser-profiles.ts` and stated in
    // Settings → Browser. It is not a paragraph that appears under a pointer.
    const markup = render(newTab('tab-1', '', true), () => {})
    expect(markup).not.toMatch(/reopens the page/)
  })

  it('stays on screen and disabled when the preload has not wired it', () => {
    // Hiding it would read as "this app has no isolation", which is a different
    // and worse claim than "this build cannot do it". Disabled is that claim now
    // that the sentence has gone.
    const markup = render(newTab('tab-1'))
    expect(markup).toContain('Session: Shared')
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
  it('is a named button beside the rest of the page actions', () => {
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {} })
    expect(markup).toContain('title="Draw"')
    expect(markup).toContain('aria-label="Draw"')
  })

  it('reads as pressed while a canvas is over the page', () => {
    // The page is parked behind that canvas, so a button that did not look on
    // would leave the one visible explanation for a frozen website unstated.
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {}, drawing: true })
    expect(markup).toMatch(/aria-label="Draw" aria-pressed="true"/)
  })

  it('stays on screen and disabled when the preload has not wired it', () => {
    // Draw mode's two channels are deliberately outside `BRIDGE_METHODS` — see
    // `draw-bridge.ts` — so "this build cannot do it" is a state that really
    // happens. It shows as a disabled button rather than as a sentence on the
    // hover, and rather than by quietly disappearing.
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toMatch(/aria-label="Draw"[^>]*disabled/)
  })

  it('is disabled with no tab open', () => {
    const markup = render(null, () => {}, { onDraw: () => {} })
    expect(markup).toMatch(/aria-label="Draw"[^>]*disabled/)
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
    expect(markup).toContain('aria-label="More"')
  })

  it('draws the overflow glyph vertically, which is the one everybody knows', () => {
    // *"unlike Chrome, three dots are like horizontal. Here it's not horizontal,
    // it's vertical."* — he was pointing at Chrome's ⋮ and at our ⋯. Three
    // circles down one x, rather than three across one y.
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).toContain('<circle cx="12" cy="5" r="1.5"></circle>')
    expect(markup).toContain('<circle cx="12" cy="19" r="1.5"></circle>')
  })

  it('has no profile button until the preload can actually switch profiles', () => {
    // A profile icon that opens a menu that cannot switch is the half-feature
    // this whole review is about. The panel passes `onProfiles` only when all
    // five profile channels are wired; without it there is no button at all.
    expect(render(newTab('tab-1'), () => {})).not.toContain('aria-label="Profile"')
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
    expect(markup).toContain('aria-label="Stop (8)"')
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
    expect(markup).toContain('title="office-pc:3000"')
  })

  it('says why the numbers differ, on the one page where they do', () => {
    const markup = withMachines(undefined, {
      name: 'office-pc',
      port: 3000,
      localPort: 53412,
      sameNumber: false,
    })
    expect(markup).toContain('53412')
    expect(markup).toContain('title="office-pc:3000 → :53412"')
  })
})

/**
 * What the 2026-08-20 review took off this bar, held as absences.
 *
 * Absences are the only way to hold these: every one of them is a thing that was
 * on screen and is not, and a test that asserted the replacement would pass just
 * as happily with the old one still beside it.
 */
describe('icons, and the name on the hover', () => {
  it('prints no caption beside any glyph', () => {
    // *"on the top of the browser, remove all of these titles. Just keep the
    // logos."* The names moved to `title`, which `Tooltips.tsx` draws in the
    // app's own type — they did not simply disappear.
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {} })
    expect(markup).not.toContain('bw-icon-word')
    for (const word of ['Inspect', 'Record', 'Shot', 'Draw', 'Size', 'Devtools', 'More']) {
      expect(markup, `no hover name for ${word}`).toContain(`title="${word}"`)
    }
  })

  it('says only the name on the hover, never the old sentence', () => {
    const markup = render(newTab('tab-1'), () => {}, { onDraw: () => {} })
    expect(markup).not.toContain('Inspect an element in the page')
    expect(markup).not.toContain('Open Chrome devtools for the page')
    expect(markup).not.toContain('Show the page at a phone or tablet size')
  })

  it('leaves nothing but the address inside the address field', () => {
    /*
     * *"Since we already have here a selection, why do we show inside the link
     * bar also local? … from inside the link bar, it should be only the link,
     * not this thing."*
     *
     * The machine picker outside the field already prints `Local`. The padlock
     * itself stays — it is a glyph with its name on hover, like the rest of the
     * bar — and what has gone is the word beside it.
     */
    const markup = render(newTab('tab-1'), () => {})
    expect(markup).not.toContain('bw-security-text')
    expect(markup).toContain('class="bw-security" data-level="local" title="Local"')
  })
})

/**
 * The profile button, and the menu it has to open *at*.
 *
 * *"we should keep vertical with maybe profile icon like this. So we can have
 * these profiles over here as icon, so we can switch between profiles also if we
 * want to."*
 */
describe('the profile button', () => {
  it('is on the bar, named after the profile that is on', () => {
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
        recording={false}
        drawing={false}
        deviceOpen={false}
        onToggleDevice={() => {}}
        onMenu={() => {}}
        menuOpen={false}
        onProfiles={() => {}}
        profilesOpen={false}
        profileName="Work"
        steps={0}
      />,
    )
    // The name and not the word "Profile": which profile is on is the fact
    // somebody opens this to check, so it is the fact the hover answers.
    expect(markup).toContain('aria-label="Work"')
  })
})
