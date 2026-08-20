/**
 * The browser panel's toolbar, on its own, in a real browser, measured.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/toolbar.html
 *
 * Why this page exists rather than a static-markup test: the two things the
 * 2026-08-20 review asked of this bar are both *widths*. "Let's make these icons
 * smaller and make this maybe bigger" is a claim about how many pixels the
 * address field ends up with, and no assertion on a string can see that. So the
 * bar is drawn at the two panel widths that matter — a 1440 window with the
 * sidebar open, and the 792 half-split where the container query used to strip
 * the captions — and the address field measures itself and prints the number
 * into the page, so the screenshot carries its own evidence.
 *
 * Both themes on one page for the same reason `usagebar.tsx` does it: the bar
 * has a tinted chip and an accent state in it, and "it looks fine" has meant
 * "it looks fine in dark" more than once here.
 */
import { StrictMode, useCallback, useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/browser/BrowserWorkspace.css'
import { Toolbar } from '../src/renderer/browser/Toolbar'
import { MachinePicker } from '../src/renderer/browser/MachinePicker'
import { THIS_MACHINE, type MachineChoice } from '../src/renderer/browser/machines-bridge'
import { newTab } from '../src/renderer/browser/tabs'
import { Tooltips } from '../src/renderer/shell/Tooltips'
import '../src/renderer/shell/tooltip.css'
import { BrowserMenu } from '../src/renderer/browser/BrowserMenu'
import { ProfileMenu } from '../src/renderer/browser/ProfileMenu'
import type { AccountsApi } from '../src/renderer/browser/accounts-bridge'
import type { Box } from '../src/renderer/browser/popup-anchor'

/**
 * A preload that answers the way a real one does, with two profiles in it.
 *
 * The second profile is the whole point of the board below: the menu the review
 * called empty had one row and a tick in it, and the question is whether the new
 * one says anything a person could not have guessed. So `Work` is signed into
 * two sites and `Default` into one, and the counts come back out of these lists
 * through the same `readLoginList` the app uses.
 */
const PROFILES = {
  profiles: [
    { id: 'default', name: 'Default', partition: 'persist:terminaldeck-browser', createdAt: 0, isDefault: true },
    {
      id: '6f1a2b3c-4d5e-4f60-8a71-9b2c3d4e5f60',
      name: 'Work',
      partition: 'persist:terminaldeck-browser-6f1a2b3c-4d5e-4f60-8a71-9b2c3d4e5f60',
      createdAt: 1_755_000_000_000,
      isDefault: false,
    },
  ],
  activeId: 'default',
}

const LOGINS: Record<string, { profileId: string; origin: string; username: string; updatedAt: number }[]> = {
  default: [{ profileId: 'default', origin: 'https://github.com', username: 'asadev', updatedAt: 0 }],
  '6f1a2b3c-4d5e-4f60-8a71-9b2c3d4e5f60': [
    { profileId: '6f1a2b3c-4d5e-4f60-8a71-9b2c3d4e5f60', origin: 'https://app.imza.ae', username: 'asad', updatedAt: 0 },
    { profileId: '6f1a2b3c-4d5e-4f60-8a71-9b2c3d4e5f60', origin: 'http://staging.local', username: 'admin', updatedAt: 0 },
  ],
}

/**
 * The state he will actually open this menu in: one profile, nothing saved.
 *
 * `?profiles=one` swaps to it. The audit's whole point about the profile menu is
 * that it read fine on a seeded machine and read as a bare name on his, so the
 * empty case has to be a screenshot and not an argument.
 */
const ONE = {
  profiles: [
    { id: 'default', name: 'Default', partition: 'persist:terminaldeck-browser', createdAt: 0, isDefault: true },
  ],
  activeId: 'default',
}

const bare = new URLSearchParams(location.search).get('profiles') === 'one'
const STATE = bare ? ONE : PROFILES

const ACCOUNTS: AccountsApi = {
  browserProfiles: async () => STATE,
  browserProfileCreate: async () => STATE,
  browserProfileRename: async () => STATE,
  browserProfileActivate: async (id: string) => ({ ...STATE, activeId: id }),
  browserProfileDelete: async () => ONE,
  browserPasswordsAvailable: async () => true,
  browserPasswords: async (profileId: string) => (bare ? [] : (LOGINS[profileId] ?? [])),
  browserPasswordForget: async () => ({ ok: true, message: '' }),
  browserPasswordCopy: async () => true,
  browserPasswordAnswer: async () => ({ ok: true, message: '' }),
  browserSignInHandover: async () => undefined,
}

/** Two paired machines, so the picker is drawn the way it is in the real bar. */
const MACHINES: MachineChoice[] = [
  { kind: 'this', id: THIS_MACHINE, name: 'Local', noun: 'Mac', ports: [], refusal: null },
  { kind: 'desktop', id: 'office-pc', name: 'office-pc', noun: 'PC', ports: [], refusal: null },
] as unknown as MachineChoice[]

const TAB = {
  ...newTab('tab-1', 'http://localhost:3000/some/path?with=a&query=string'),
  url: 'http://localhost:3000/some/path?with=a&query=string',
  canGoBack: true,
  canGoForward: false,
}

/**
 * One bar at one width, with the address field's own rectangle read back.
 *
 * The measurement is taken after layout and after fonts settle — a first read
 * lands before the UI font is swapped in and comes back a few pixels short,
 * which is exactly the kind of number that gets written into a comment and
 * quoted for a year.
 */
function Bar({ width, label }: { width: number; label: string }) {
  const host = useRef<HTMLDivElement | null>(null)
  const [note, setNote] = useState('measuring…')

  useEffect(() => {
    const read = (): void => {
      const root = host.current
      if (!root) return
      const field = root.querySelector('.bw-address')
      const actions = root.querySelector('.bw-actions')
      const nav = root.querySelector('.bw-nav')
      if (!field || !actions || !nav) return
      const w = (el: Element): number => Math.round(el.getBoundingClientRect().width)
      setNote(`address ${w(field)}px · actions ${w(actions)}px · nav ${w(nav)}px`)
    }
    read()
    void document.fonts?.ready.then(read)
  }, [width])

  return (
    <div style={{ marginBottom: 18 }}>
      <div style={{ font: '11px/1.6 ui-monospace, monospace', opacity: 0.7, padding: '2px 6px' }}>
        {label} — <span data-measure={label}>{note}</span>
      </div>
      <div ref={host} className="bw" style={{ width, height: 'auto' }}>
        <Toolbar
          tab={TAB}
          progress={1}
          resolution={{ kind: 'url', url: TAB.url, display: TAB.url }}
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
          onProfiles={() => {}}
          profilesOpen={false}
          profileName="Default"
          steps={0}
          onToggleIsolation={() => {}}
          machinePicker={
            <MachinePicker machines={MACHINES} selected={THIS_MACHINE} onSelect={() => {}} />
          }
          servedBy={null}
        />
      </div>
    </div>
  )
}

/**
 * The bar with its two menus live, so the anchoring can be looked at.
 *
 * *"if I am clicking on three dots, it's opening very far from the three dots.
 * It should open just like here."* That is a claim about a rectangle, and the
 * only way to check it is to open the menu against a real button in a real
 * layout and look at where it lands. `?open=menu` and `?open=profile` open one
 * from the URL so a screenshot run does not have to guess at a click target.
 */
function Live({ width }: { width: number | undefined }) {
  const menuButtonRef = useRef<HTMLButtonElement | null>(null)
  const profileButtonRef = useRef<HTMLButtonElement | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [profileOpen, setProfileOpen] = useState(false)
  const [anchor, setAnchor] = useState<Box>({ x: 0, y: 0, width: 0, height: 0 })

  const openAt = useCallback((node: HTMLElement | null, open: () => void): void => {
    if (node) {
      const box = node.getBoundingClientRect()
      setAnchor({ x: box.x, y: box.y, width: box.width, height: box.height })
    }
    open()
  }, [])

  useEffect(() => {
    const wanted = new URLSearchParams(location.search).get('open')
    if (wanted === 'menu') openAt(menuButtonRef.current, () => setMenuOpen(true))
    if (wanted === 'profile') openAt(profileButtonRef.current, () => setProfileOpen(true))
  }, [openAt])

  return (
    <div className="bw" style={{ width, height: 'auto' }}>
      <Toolbar
        tab={TAB}
        progress={1}
        resolution={{ kind: 'url', url: TAB.url, display: TAB.url }}
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
        menuRef={menuButtonRef}
        profileRef={profileButtonRef}
        menuOpen={menuOpen}
        onMenu={() =>
          openAt(menuButtonRef.current, () => {
            setProfileOpen(false)
            setMenuOpen((open) => !open)
          })
        }
        onProfiles={() =>
          openAt(profileButtonRef.current, () => {
            setMenuOpen(false)
            setProfileOpen((open) => !open)
          })
        }
        profilesOpen={profileOpen}
        profileName="Default"
        steps={0}
        onToggleIsolation={() => {}}
        machinePicker={
          <MachinePicker machines={MACHINES} selected={THIS_MACHINE} onSelect={() => {}} />
        }
        servedBy={{ name: 'office-pc', port: 3000, localPort: 53412, sameNumber: false }}
      />

      {menuOpen && (
        <BrowserMenu
          api={ACCOUNTS}
          anchor={anchor}
          url="http://localhost:3000/some/path"
          startUrl="http://localhost:5173/"
          onStartUrl={() => {}}
          onFlow={() => {}}
          onClose={() => setMenuOpen(false)}
        />
      )}

      {profileOpen && (
        <ProfileMenu
          api={ACCOUNTS}
          anchor={anchor}
          countSites={async () => (bare ? 0 : 7)}
          onSiteData={() => {}}
          onReopen={() => {}}
          onClose={() => setProfileOpen(false)}
        />
      )}
    </div>
  )
}

function Board() {
  return (
    <div style={{ padding: 16 }}>
      <Bar width={1180} label="1440 window, sidebar open" />
      <Bar width={792} label="792 half-split" />
      <Bar width={560} label="560 narrow" />
    </div>
  )
}

/**
 * Both themes stacked, each in its own `data-theme` subtree.
 *
 * The attribute is set on a wrapper rather than on `<html>` because the point of
 * the page is to see the two side by side; `tokens.css` scopes every palette to
 * `[data-theme]`, so a nested subtree gets the whole palette.
 */
function Page() {
  // `?live` swaps the measuring board for the one with working menus. They are
  // not on one page because `AnchoredPopup` portals into `<body>` and positions
  // itself against the *window*, so two of them in two themes would land on top
  // of each other and prove nothing about either.
  const live = new URLSearchParams(location.search).has('live')
  const theme = new URLSearchParams(location.search).get('theme') ?? 'light'

  if (live) {
    /*
     * The theme goes on `<html>`, not on this element.
     *
     * `AnchoredPopup` and `Tooltips` both portal into `<body>`, so a wrapper
     * carrying `data-theme` is a wrapper they escape — the first run of this
     * board drew a dark menu on a light page and the fault was the harness, not
     * the menu. Full-bleed for the same reason: in the app this panel reaches the
     * window's right edge, and a padded board would place the ⋯ button somewhere
     * the real one never is, which is exactly the measurement being checked.
     */
    document.documentElement.setAttribute('data-theme', theme)
    return (
      <div style={{ background: 'var(--bg-primary)', color: 'var(--text-primary)', height: '100vh' }}>
        <Live width={undefined} />
        <Tooltips />
      </div>
    )
  }

  return (
    <>
      <div data-theme="light" style={{ background: 'var(--bg-primary)', color: 'var(--text-primary)' }}>
        <Board />
      </div>
      <div data-theme="dark" style={{ background: 'var(--bg-primary)', color: 'var(--text-primary)' }}>
        <Board />
      </div>
    </>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
