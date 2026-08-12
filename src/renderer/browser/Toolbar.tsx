import { useEffect, useRef, type FormEvent, type ReactNode } from 'react'
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
  deviceOpen: boolean
  onToggleDevice(): void
  onOpenSession(): void
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
  deviceOpen,
  onToggleDevice,
  onOpenSession,
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

      <div className="bw-actions">
        <IconButton
          label="Inspect an element"
          pressed={tab?.inspecting === true}
          disabled={!has}
          onClick={onInspect}
        >
          <path d="M5 3l6.5 17 2.4-6.9 7-2.4z" />
        </IconButton>
        <IconButton
          label={recording ? 'Stop recording the flow' : 'Record a flow'}
          pressed={recording}
          disabled={!has}
          onClick={onRecord}
          tone={recording ? 'critical' : undefined}
        >
          {recording ? <rect x="7" y="7" width="10" height="10" rx="1.5" /> : <circle cx="12" cy="12" r="6" />}
        </IconButton>
        <IconButton label="Screenshot the page" disabled={!has} onClick={onScreenshot}>
          <path d="M4 8h3l1.5-2h7L17 8h3v11H4z" />
          <circle cx="12" cy="13" r="3.2" />
        </IconButton>
        <IconButton
          label="Responsive sizes"
          pressed={deviceOpen}
          disabled={!has}
          onClick={onToggleDevice}
        >
          <rect x="7" y="3" width="10" height="18" rx="2" />
          <path d="M11 18.5h2" />
        </IconButton>
        <IconButton
          label="Open devtools for the page"
          pressed={devtoolsOpen}
          disabled={!has}
          onClick={onDevtools}
        >
          <path d="M9 8l-4 4 4 4M15 8l4 4-4 4" />
        </IconButton>
        <IconButton label="Cookies and site data" onClick={onOpenSession}>
          <circle cx="12" cy="12" r="8" />
          <path d="M9.5 10h.01M14 9h.01M13 14.5h.01M9.5 14h.01" />
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
  label: string
  onClick(): void
  disabled?: boolean
  pressed?: boolean
  tone?: 'critical'
  children: ReactNode
}

function IconButton({ label, onClick, disabled, pressed, tone, children }: IconButtonProps) {
  return (
    <button
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
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {children}
      </svg>
    </button>
  )
}
