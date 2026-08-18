import { useEffect, useRef, type FormEvent, type ReactNode, type RefObject } from 'react'
import { securityLabel, type OmniboxResolution, type Security } from './omnibox'
import type { WorkspaceTab } from './tabs'

interface Props {
  tab: WorkspaceTab | null
  security: Security
  /** 0 to 1. Anything below 1 draws the bar. */
  progress: number
  resolution: OmniboxResolution
  /** Bumped by the workspace to pull focus into the bar (Cmd-L, a new tab). */
  focusToken: number

  onDraft(value: string): void
  onEditing(editing: boolean): void
  onSubmit(): void
  onBack(): void
  onForward(): void
  onReload(): void
  onStop(): void
  onHome(): void

  onInspect(): void
  onRecord(): void
  onScreenshot(): void
  onDevtools(): void
  devtoolsOpen: boolean
  recording: boolean
  /**
   * Mark the page up and send the picture to a session.
   *
   * Absent when the preload has not wired draw mode's two channels — the button
   * then explains itself rather than vanishing, the same bargain
   * `IsolationToggle` makes. See `draw-bridge.ts` for why those two methods are
   * allowed to be missing at all.
   */
  onDraw?: () => void
  drawing: boolean
  deviceOpen: boolean
  onToggleDevice(): void

  /**
   * The action group, handed back so the panel can place its popups against it.
   *
   * *"Whatever is required should be on the top right corner."* Every popup this
   * panel opens is anchored to this one rectangle, which is why the ref belongs
   * to the group rather than to each button: `anchorPopup` slides a popup back
   * inside the viewport, so a group already at the right edge lands all of them
   * in the corner without eight refs travelling up through here.
   */
  actionsRef?: RefObject<HTMLDivElement | null>
  /** The overflow menu — profiles, saved logins, cookies, the start page. */
  onMenu(): void
  menuOpen: boolean
  /**
   * How many steps are in the recording so far.
   *
   * On the Stop button, because during a recording there is nowhere else for it
   * to be: the flow panel used to live in a permanent band at the bottom of this
   * panel and that band is gone, and it cannot be a popup while recording
   * because a popup parks the page being recorded. One number on the button that
   * is already there says the recorder is working, which is what the band was
   * really being read for.
   */
  steps: number

  /**
   * Switch this tab between the shared session and one of its own.
   *
   * Absent when the preload has not wired isolation yet, in which case the
   * control explains itself instead of disappearing — a security control that
   * silently vanishes is worse than one that says it is unavailable.
   */
  onToggleIsolation?: () => void

  /**
   * The machine picker, built by the panel and placed here.
   *
   * A slot rather than five more props, and the reason is ownership: which
   * machines exist, which one is chosen and what happens when one goes offline
   * are all the workspace's business, and threading them through a presentation
   * component would make this file the second place that had an opinion about
   * remote machines. What this file owns is *where it sits* — beside the address
   * bar, which is what he asked for and where it belongs, because it says what
   * the thing next to it means.
   *
   * Absent when no other machine is paired, and then the bar is the bar it has
   * always been.
   */
  machinePicker?: ReactNode
  /**
   * The machine behind the page in the bar, when the page came from one.
   *
   * Read from the URL rather than remembered, so it survives links, Back and a
   * reload — see `servedBy` in `machines-bridge.ts`. It is here rather than in a
   * band because it is a fact about the address, and the address bar is where
   * somebody looks to find out where they are.
   */
  servedBy?: { name: string; port: number; localPort: number; sameNumber: boolean } | null
}

/**
 * The address bar and everything that acts on the page as a whole.
 *
 * Two things here are deliberate. The URL bar shows the *page's* URL whenever
 * the user is not typing — an address bar that keeps showing what you last
 * typed is lying about where you are, which matters most on a redirect. And
 * every button that can be pointless is disabled rather than hidden: Back with
 * no history, Stop while nothing is loading, anything at all with no tab open.
 */
export function Toolbar({
  tab,
  security,
  progress,
  resolution,
  focusToken,
  onDraft,
  onEditing,
  onSubmit,
  onBack,
  onForward,
  onReload,
  onStop,
  onHome,
  onInspect,
  onRecord,
  onScreenshot,
  onDevtools,
  devtoolsOpen,
  recording,
  onDraw,
  drawing,
  deviceOpen,
  onToggleDevice,
  actionsRef,
  onMenu,
  menuOpen,
  steps,
  onToggleIsolation,
  machinePicker,
  servedBy = null,
}: Props) {
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (focusToken === 0) return
    const input = inputRef.current
    if (!input) return
    input.focus()
    input.select()
  }, [focusToken])

  const has = tab !== null
  const loading = tab?.loading === true
  const value = tab ? (tab.editing ? tab.draft : tab.url || tab.draft) : ''

  const submit = (event: FormEvent): void => {
    event.preventDefault()
    onSubmit()
  }

  return (
    <div className="bw-toolbar">
      <div className="bw-nav">
        <IconButton label="Back" disabled={!tab?.canGoBack} onClick={onBack}>
          <path d="M15 5 8 12l7 7" />
        </IconButton>
        <IconButton label="Forward" disabled={!tab?.canGoForward} onClick={onForward}>
          <path d="M9 5l7 7-7 7" />
        </IconButton>
        {loading ? (
          <IconButton label="Stop loading" onClick={onStop}>
            <path d="M7 7l10 10M17 7L7 17" />
          </IconButton>
        ) : (
          <IconButton label="Reload" disabled={!has} onClick={onReload}>
            <path d="M20 12a8 8 0 1 1-2.6-5.9" />
            <path d="M20 4v4h-4" />
          </IconButton>
        )}
        <IconButton label="Home" disabled={!has} onClick={onHome}>
          <path d="M4 11l8-6.5 8 6.5" />
          <path d="M6.5 9.8V19h11V9.8" />
        </IconButton>
      </div>

      {/* Outside the field, not inside it. The field carries one focus ring
          around one text input; a button living inside that ring reads as part
          of the text you are typing, and pressing it would take the ring with
          it. */}
      {machinePicker}

      <form className="bw-address" onSubmit={submit}>
        <span className="bw-security" data-level={security} title={securityTitle(security)}>
          {security === 'secure' ? (
            <Glyph>
              <path d="M7 10V8a5 5 0 0 1 10 0v2" />
              <rect x="5" y="10" width="14" height="10" rx="2" />
            </Glyph>
          ) : security === 'local' ? (
            <Glyph>
              <rect x="4" y="5" width="16" height="11" rx="2" />
              <path d="M9 20h6" />
            </Glyph>
          ) : security === 'insecure' ? (
            <Glyph>
              <path d="M12 4.5 3 20h18z" />
              <path d="M12 10v4M12 17h.01" />
            </Glyph>
          ) : (
            <Glyph>
              <circle cx="12" cy="12" r="8" />
            </Glyph>
          )}
          <span className="bw-security-text">{securityLabel(security)}</span>
        </span>

        {/*
          Where this loopback page actually comes from.

          Only ever drawn for a page this window opened a tunnel for, so it is
          never a decoration: the address really does read `127.0.0.1:<n>` and
          the server really is on another computer, and without this line
          nothing on screen says which one. The title carries the port
          arithmetic, because that is the part that only matters when it goes
          wrong.
        */}
        {servedBy && (
          <span
            className="bw-served"
            title={
              servedBy.sameNumber
                ? `Served from port ${servedBy.port} on ${servedBy.name}, carried to this machine.`
                : `Served from port ${servedBy.port} on ${servedBy.name}. It is on port ${servedBy.localPort} here because ${servedBy.port} is already in use on this machine.`
            }
          >
            {servedBy.name}:{servedBy.port}
          </span>
        )}

        <input
          ref={inputRef}
          className="bw-url"
          type="text"
          value={value}
          disabled={!has}
          spellCheck={false}
          autoCorrect="off"
          autoCapitalize="off"
          aria-label="Address and search"
          placeholder="Enter a URL, or search"
          onChange={(event) => onDraft(event.target.value)}
          onFocus={(event) => {
            onEditing(true)
            event.target.select()
          }}
          onBlur={() => onEditing(false)}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.stopPropagation()
              onEditing(false)
              event.currentTarget.blur()
            }
          }}
        />

        {tab?.editing && resolution.kind === 'search' && (
          <span className="bw-address-hint">Search</span>
        )}
      </form>

      {/*
        Six icons and not one word, was how this read on camera. Every button
        here now carries its name beside its glyph, the way `IsolationToggle`
        already did and the way Vibeyard labels all of its — because there is no
        icon anybody reads correctly for "record a flow", and a row of six
        unlabelled glyphs is a quiz.

        `word` is the label on screen; `label` stays the longer sentence, and it
        is still the accessible name and the tooltip. They are separate on
        purpose: "Inspect" is enough to click, "Inspect an element in the page"
        is what you want when you have hovered because you are not sure.
      */}
      <div className="bw-actions" ref={actionsRef}>
        <IsolationToggle tab={tab} onToggle={onToggleIsolation} />
        <IconButton
          label="Inspect an element in the page"
          word="Inspect"
          pressed={tab?.inspecting === true}
          disabled={!has}
          onClick={onInspect}
        >
          <path d="M5 3l6.5 17 2.4-6.9 7-2.4z" />
        </IconButton>
        <IconButton
          label={recording ? 'Stop recording the flow' : 'Record what you do on this page'}
          word={recording ? (steps > 0 ? `Stop (${steps})` : 'Stop') : 'Record'}
          pressed={recording}
          disabled={!has}
          onClick={onRecord}
          tone={recording ? 'critical' : undefined}
        >
          {recording ? <rect x="7" y="7" width="10" height="10" rx="1.5" /> : <circle cx="12" cy="12" r="6" />}
        </IconButton>
        <IconButton
          label="Screenshot the page"
          word="Shot"
          disabled={!has}
          onClick={onScreenshot}
        >
          <path d="M4 8h3l1.5-2h7L17 8h3v11H4z" />
          <circle cx="12" cy="13" r="3.2" />
        </IconButton>
        {/*
          Beside Shot, because that is what it is: a screenshot you drew on
          first, saved next to the plain ones and sent through the same popup.
          A marker nib rather than a pencil — a pencil is what an app uses for
          "edit this text", and half this toolbar is already about editing
          nothing.
        */}
        <IconButton
          label={
            onDraw
              ? 'Mark the page up and send it to a session'
              : 'Marking up the page is not available in this build.'
          }
          word="Draw"
          pressed={drawing}
          disabled={!has || !onDraw}
          onClick={() => onDraw?.()}
        >
          <path d="M4 20h4l10-10-4-4L4 16z" />
          <path d="M13.5 6.5l4 4" />
        </IconButton>
        <IconButton
          label="Show the page at a phone or tablet size"
          word="Size"
          pressed={deviceOpen}
          disabled={!has}
          onClick={onToggleDevice}
        >
          <rect x="7" y="3" width="10" height="18" rx="2" />
          <path d="M11 18.5h2" />
        </IconButton>
        <IconButton
          label="Open Chrome devtools for the page"
          word="Devtools"
          pressed={devtoolsOpen}
          disabled={!has}
          onClick={onDevtools}
        >
          <path d="M9 8l-4 4 4 4M15 8l4 4-4 4" />
        </IconButton>
        {/*
          The overflow, and the last thing on the bar.

          Cookies used to be a button of its own here and is a row in this menu
          now, along with the start page, the profiles and the saved logins. Not
          to save width: those four are all answers to *"which of me is this, and
          what does this browser remember"*, and a menu is where a person looks
          for that. A toolbar is for things that act on the page in front of you.
        */}
        <IconButton
          label="Profiles, saved logins, cookies and the start page"
          word="More"
          pressed={menuOpen}
          onClick={onMenu}
        >
          <circle cx="5" cy="12" r="1.4" />
          <circle cx="12" cy="12" r="1.4" />
          <circle cx="19" cy="12" r="1.4" />
        </IconButton>
      </div>

      {progress < 1 && progress > 0 && (
        <div className="bw-progress" role="progressbar" aria-label="Loading" aria-valuenow={Math.round(progress * 100)}>
          <span style={{ width: `${Math.round(progress * 100)}%` }} />
        </div>
      )}
    </div>
  )
}

/**
 * Shared or Isolated, for this tab.
 *
 * A word, not a glyph. Everything else on this bar is an icon, and that is
 * right for actions — but this reports a *state* that decides whether the tab
 * can see the cookies imported from Chrome and whatever the other tabs are
 * signed into. There is no icon anyone reads correctly for that, and being
 * wrong about it is how someone demonstrates a bug while logged in as the
 * wrong person.
 *
 * Switching replaces the page rather than reconfiguring it, because a
 * WebContents' session is fixed when it is constructed. The title says so —
 * a control that reloads the page without warning reads as a glitch.
 */
function IsolationToggle({
  tab,
  onToggle,
}: {
  tab: WorkspaceTab | null
  onToggle?: () => void
}) {
  const isolated = tab?.isolated === true
  const unavailable = !onToggle

  const title = unavailable
    ? 'Per-tab isolation is not available in this build.'
    : isolated
      ? 'Isolated: this tab has its own cookie jar, kept in memory and thrown away when the app quits. It cannot see imported cookies or the other tabs’ logins. Switching back reopens the page.'
      : 'Shared: this tab uses the browser session every other tab uses, including any cookies imported from Chrome. Switching to Isolated reopens the page in an empty one.'

  return (
    <button
      type="button"
      className="bw-isolation"
      title={title}
      aria-label={`Session: ${isolated ? 'Isolated' : 'Shared'}`}
      aria-pressed={isolated}
      data-on={isolated || undefined}
      disabled={!tab || unavailable}
      onClick={() => onToggle?.()}
    >
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {isolated ? (
          <>
            <rect x="4" y="10" width="16" height="10" rx="2" />
            <path d="M8 10V7a4 4 0 0 1 8 0v3" />
          </>
        ) : (
          <>
            <circle cx="9" cy="9" r="3" />
            <circle cx="16" cy="15" r="3" />
            <path d="M11.4 11.1 13.6 12.9" />
          </>
        )}
      </svg>
      <span>{isolated ? 'Isolated' : 'Shared'}</span>
    </button>
  )
}

function securityTitle(security: Security): string {
  switch (security) {
    case 'secure':
      return 'Served over HTTPS. This says nothing about the site itself.'
    case 'local':
      return 'A local address. Plain HTTP is normal here.'
    case 'insecure':
      return 'Plain HTTP to a remote host — anything sent is readable in transit.'
    case 'none':
      return 'Nothing loaded.'
  }
}

function Glyph({ children }: { children: ReactNode }) {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  )
}

interface IconButtonProps {
  /** The full sentence: the accessible name and the tooltip. */
  label: string
  /**
   * The one or two words printed beside the glyph.
   *
   * Absent leaves an icon-only button, which is right for the four navigation
   * controls — Back, Forward, Reload, Home are the four glyphs every browser
   * has used for thirty years, and labelling those would be noise. Everything
   * on the right-hand group says what it is.
   */
  word?: string
  onClick(): void
  disabled?: boolean
  pressed?: boolean
  tone?: 'critical'
  children: ReactNode
}

function IconButton({ label, word, onClick, disabled, pressed, tone, children }: IconButtonProps) {
  return (
    <button
      type="button"
      className="bw-icon"
      title={label}
      aria-label={label}
      aria-pressed={pressed}
      data-on={pressed || undefined}
      data-tone={tone}
      data-labelled={word ? '' : undefined}
      disabled={disabled}
      onClick={onClick}
    >
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {children}
      </svg>
      {word && <span className="bw-icon-word">{word}</span>}
    </button>
  )
}
