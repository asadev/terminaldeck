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
   * *"Whatever is required should be on the top right corner."* The popups that
   * are about the group as a whole — the recorded flow, which belongs to a
   * button in the middle of it — are anchored to this one rectangle, so they
   * land in the corner without a ref per button travelling up through here.
   *
   * The two *menus* are the exception and have refs of their own; see
   * {@link menuRef}.
   */
  actionsRef?: RefObject<HTMLDivElement | null>
  /**
   * The ⋯ button itself, so its menu opens against it.
   *
   * *"if I am clicking on three dots, it's opening very far from the three
   * dots. It should open just like here."* It was opening against the whole
   * action group, and `anchorPopup` left-aligns with what it is given — so the
   * menu landed at the group's *left* edge, half a toolbar away from the button
   * that opened it. A group is the wrong anchor for a menu that belongs to one
   * button in it.
   */
  menuRef?: RefObject<HTMLButtonElement | null>
  /** The profile button, anchoring its own menu for the same reason. */
  profileRef?: RefObject<HTMLButtonElement | null>
  /** The overflow menu — the start page, cookies, the recorded flow. */
  onMenu(): void
  menuOpen: boolean
  /**
   * Switch which set of cookies and logins the browser is using.
   *
   * *"we should keep vertical with maybe profile icon like this. So we can have
   * these profiles over here as icon, so we can switch between profiles also if
   * we want to."* Its own button rather than a row inside ⋯, because a profile
   * is not an overflow item — it is who you are while you browse, and Chrome
   * puts it in this exact place for that reason.
   *
   * Absent when the preload has not wired profiles, and then there is no button.
   * A profile control that cannot switch profiles is the half-feature the whole
   * review is about.
   */
  onProfiles?: () => void
  profilesOpen?: boolean
  /** The active profile's name, which is what the button's hover label says. */
  profileName?: string
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
 * ## Glyphs, and the name on hover
 *
 * From the recorded review of 2026-08-20:
 *
 *   > *"on the top of the browser, remove all of these titles. Just keep the
 *   > logos. And when I hover, it should show the title, like shade, inspect,
 *   > record. Instead of this line, show only the name."*
 *
 * So every button here is a glyph, and `title` carries **one or two words** —
 * not the sentence it used to carry. That reversal is deliberate and it is not
 * a loss: `Tooltips.tsx` draws these in the app's own type and palette after a
 * chosen delay, so the hover label is a real part of the UI rather than the
 * yellow OS box a `title` used to summon. The sentences went because he asked
 * for them to go, everywhere: *"I don't want any kind of long descriptions
 * anywhere."*
 *
 * ## Two things that were always deliberate
 *
 * The URL bar shows the *page's* URL whenever the user is not typing — an
 * address bar that keeps showing what you last typed is lying about where you
 * are, which matters most on a redirect. And every button that can be pointless
 * is disabled rather than hidden: Back with no history, Stop while nothing is
 * loading, anything at all with no tab open.
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
  menuRef,
  profileRef,
  onMenu,
  menuOpen,
  onProfiles,
  profilesOpen = false,
  profileName = '',
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

      {/*
        The word beside the padlock is gone, and the padlock is not.

        *"Since we already have here a selection, why do we show inside the link
        bar also local? … from inside the link bar, it should be only the link,
        not this thing."* The machine picker immediately to the left of this
        field already prints `Local`, so the field was printing the same word a
        centimetre away from it. The *glyph* stays — three levels of it, tinted
        — because that is the one thing in a URL bar that is not the URL and is
        still worth a pixel, and it is now the same bargain as every button on
        this bar: an icon, with its name on hover.
      */}
      <form className="bw-address" onSubmit={submit}>
        <span className="bw-security" data-level={security} title={securityLabel(security)}>
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
        </span>

        {/*
          Where this loopback page actually comes from — and the one label in
          this field that survived the cull, by his own instruction.

          *"Maybe in this kind of situation, we will need to keep this so we know
          actually where it is running right now … because we always need a
          truth."* Only ever drawn for a page this window opened a tunnel for, so
          it is never a decoration: the address really does read `127.0.0.1:<n>`
          and the server really is on another computer.

          The hover used to be two sentences of port arithmetic and is now the
          arithmetic itself — `office-pc:3000 → :53412` says the same thing to
          anybody who needs it, in the length the rest of this bar now uses.
        */}
        {servedBy && (
          <span
            className="bw-served"
            title={
              servedBy.sameNumber
                ? `${servedBy.name}:${servedBy.port}`
                : `${servedBy.name}:${servedBy.port} → :${servedBy.localPort}`
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
        Glyphs, and nothing else — the words came off on 2026-08-20.

        They were put on four days earlier because six unlabelled icons sat here
        and he could not name one of them on camera. What he asked for instead is
        not the old bare row: it is the same set of names, moved onto the hover.
        *"when I hover, it should show the title, like shade, inspect, record."*
        The difference that makes it work is `Tooltips.tsx`, which draws a
        `title` in the app's own type and palette rather than leaving it to the
        OS — a hover label that is part of the product is a place a name can
        actually live.

        The width this frees is the point of the exercise and it goes straight
        into the address field, which is the flexible element on this bar:
        *"we can have a bigger link bar … Let's make these icons smaller and make
        this maybe bigger."*
      */}
      <div className="bw-actions" ref={actionsRef}>
        <IsolationToggle tab={tab} onToggle={onToggleIsolation} />
        <IconButton
          label="Inspect"
          pressed={tab?.inspecting === true}
          disabled={!has}
          onClick={onInspect}
        >
          <path d="M5 3l6.5 17 2.4-6.9 7-2.4z" />
        </IconButton>
        <IconButton
          /* The count stays in the name, because during a recording there is
             nothing else on screen that says the recorder is working — the flow
             panel cannot be open while the page is being recorded. */
          label={recording ? (steps > 0 ? `Stop (${steps})` : 'Stop') : 'Record'}
          pressed={recording}
          disabled={!has}
          onClick={onRecord}
          tone={recording ? 'critical' : undefined}
        >
          {recording ? <rect x="7" y="7" width="10" height="10" rx="1.5" /> : <circle cx="12" cy="12" r="6" />}
        </IconButton>
        <IconButton label="Shot" disabled={!has} onClick={onScreenshot}>
          <path d="M4 8h3l1.5-2h7L17 8h3v11H4z" />
          <circle cx="12" cy="13" r="3.2" />
        </IconButton>
        {/*
          Beside Shot, because that is what it is: a screenshot you drew on
          first, saved next to the plain ones and sent through the same popup.
          A marker nib rather than a pencil — a pencil is what an app uses for
          "edit this text", and half this toolbar is already about editing
          nothing.

          The unwired build still gets a button and still gets a name; what it no
          longer gets is a sentence explaining itself on hover. Disabled is the
          statement, and `draw-bridge.ts` is where the reason belongs.
        */}
        <IconButton
          label="Draw"
          pressed={drawing}
          disabled={!has || !onDraw}
          onClick={() => onDraw?.()}
        >
          <path d="M4 20h4l10-10-4-4L4 16z" />
          <path d="M13.5 6.5l4 4" />
        </IconButton>
        <IconButton label="Size" pressed={deviceOpen} disabled={!has} onClick={onToggleDevice}>
          <rect x="7" y="3" width="10" height="18" rx="2" />
          <path d="M11 18.5h2" />
        </IconButton>
        <IconButton label="Devtools" pressed={devtoolsOpen} disabled={!has} onClick={onDevtools}>
          <path d="M9 8l-4 4 4 4M15 8l4 4-4 4" />
        </IconButton>

        {/*
          Who you are while you browse, next to the overflow — Chrome's own
          arrangement, and he asked for it by pointing at Chrome.

          *"we should keep vertical with maybe profile icon like this. So we can
          have these profiles over here as icon, so we can switch between
          profiles also if we want to."*

          The hover says the profile's *name*, not the word "Profile", because
          the name is the fact somebody opens this to check. Absent entirely when
          the preload cannot switch profiles: see `onProfiles`.
        */}
        {onProfiles && (
          <IconButton
            label={profileName === '' ? 'Profile' : profileName}
            buttonRef={profileRef}
            pressed={profilesOpen}
            onClick={onProfiles}
          >
            <circle cx="12" cy="8.5" r="3.5" />
            <path d="M5.5 19.5a6.5 6.5 0 0 1 13 0" />
          </IconButton>
        )}

        {/*
          The overflow, and the last thing on the bar.

          Vertical, because that is the shape everybody has learned: *"unlike
          Chrome, three dots are like horizontal. Here it's not horizontal, it's
          vertical."* — his phrasing inverts, but he was pointing at Chrome's
          vertical ⋮ and at our horizontal ⋯, and asking for Chrome's.

          Profiles and saved logins moved out of it and onto the button above,
          which leaves this menu with what it should always have held: the page
          in front of you, and what this browser remembers about it.
        */}
        <IconButton label="More" buttonRef={menuRef} pressed={menuOpen} onClick={onMenu}>
          <circle cx="12" cy="5" r="1.5" />
          <circle cx="12" cy="12" r="1.5" />
          <circle cx="12" cy="19" r="1.5" />
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
 * This carried its word on screen when everything else on the bar did too, and
 * it was the first thing he named in the list to strip — *"remove all of these
 * titles … like shade, inspect, record"*, "shade" being what the recording made
 * of "Shared". So it is a glyph like its neighbours now, and it leans on three
 * signals rather than one: the drawing changes (a padlock against two linked
 * rings), the button takes the app's accent while Isolated, and the hover says
 * the word.
 *
 * That is more than a caption gave it, because the caption read the same in both
 * states until you read the word itself. Being wrong about this is how somebody
 * demonstrates a bug while logged in as the wrong person, so it keeps the full
 * `aria-label` — a screen reader has no colour to read.
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
  const word = isolated ? 'Isolated' : 'Shared'

  return (
    <button
      type="button"
      className="bw-icon bw-isolation"
      title={word}
      aria-label={`Session: ${word}`}
      aria-pressed={isolated}
      data-on={isolated || undefined}
      disabled={!tab || unavailable}
      onClick={() => onToggle?.()}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
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
    </button>
  )
}

function Glyph({ children }: { children: ReactNode }) {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  )
}

interface IconButtonProps {
  /**
   * One or two words: the accessible name, and what the hover bubble reads.
   *
   * It used to be a sentence and the word beside the glyph was separate. He
   * asked for the sentence to go and the *name* to be what appears on hover —
   * *"Instead of this line, show only the name"* — so there is one string again,
   * and it is short. Anything that genuinely needs explaining belongs behind an
   * (i), not on a mouse-over of a toolbar button.
   */
  label: string
  /** Handed up when a popup has to open against this exact button. */
  buttonRef?: RefObject<HTMLButtonElement | null>
  onClick(): void
  disabled?: boolean
  pressed?: boolean
  tone?: 'critical'
  children: ReactNode
}

function IconButton({
  label,
  buttonRef,
  onClick,
  disabled,
  pressed,
  tone,
  children,
}: IconButtonProps) {
  return (
    <button
      ref={buttonRef}
      type="button"
      className="bw-icon"
      title={label}
      aria-label={label}
      aria-pressed={pressed}
      data-on={pressed || undefined}
      data-tone={tone}
      disabled={disabled}
      onClick={onClick}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {children}
      </svg>
    </button>
  )
}
