import { useEffect, useState } from 'react'
import { toAbout, type SettingsBridge } from './settings-bridge'

/**
 * The two things at the bottom of the rail that are not sections.
 *
 * Both were rail entries until this pass, and both were the same kind of
 * mistake: a *reference* filed among *settings*. You do not change anything on
 * either of them.
 *
 *   > "this is a huge shortcut page — maybe rather than this we can have
 *   > another pop-up by clicking on this… maybe it can be only an icon here
 *   > where we click and see the shortcut as pop-up."
 *
 *   > "Help — also extend it and make it more proper. Maybe we can make it like
 *   > help button. When they click on it, it should take to terminal website,
 *   > our marketing website… instead of inside the application. Let's make it
 *   > like that. It's more professional."
 *
 * ## The Help link goes to a URL this app actually knows
 *
 * `package.json`'s `homepage`, read back through `app:about` — not a string
 * typed here. A hardcoded marketing URL is exactly the kind of copied fact this
 * codebase keeps being bitten by, and it would also be a second place the site
 * address lives. When the read has not landed, or the field is absent, the link
 * is not drawn at all: a Help button that opens nothing is worse than a rail
 * with one icon on it.
 *
 * The in-app help did not go anywhere. `HelpDialog` — the same generated panel
 * this section used to embed a second copy of — is still one keystroke away in
 * the main window, which is why removing the duplicate here loses nothing.
 */
export function RailFooter({
  bridge,
  onShortcuts,
}: {
  bridge: SettingsBridge
  onShortcuts(): void
}) {
  const [website, setWebsite] = useState<string | null>(null)

  useEffect(() => {
    if (!bridge.appAbout) return
    let live = true
    void bridge.appAbout().then(
      (raw) => {
        if (live) setWebsite(toAbout(raw)?.homepage ?? null)
      },
      () => undefined,
    )
    return () => {
      live = false
    }
  }, [bridge])

  return (
    <div className="settings-rail-foot">
      <button
        type="button"
        className="settings-rail-btn"
        onClick={onShortcuts}
        // The tooltip layer turns this into the app's own bubble; the label is
        // what a screen reader reads, since the glyph is decoration.
        title="Keyboard shortcuts"
        aria-label="Keyboard shortcuts"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <rect x="2" y="6" width="20" height="12" rx="2.5" strokeWidth="1.6" />
          <path
            d="M6 10h.01M9.5 10h.01M13 10h.01M16.5 10h.01M7.5 14h9"
            strokeWidth="1.8"
            strokeLinecap="round"
          />
        </svg>
        <span className="settings-rail-btn-label">Shortcuts</span>
      </button>

      {website && (
        <a
          className="settings-rail-btn"
          href={website}
          target="_blank"
          rel="noreferrer"
          title={`Help — opens ${website}`}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
            <circle cx="12" cy="12" r="9" strokeWidth="1.6" />
            <path
              d="M9.6 9.2a2.5 2.5 0 1 1 3.3 2.4c-.6.2-.9.7-.9 1.3v.4"
              strokeWidth="1.7"
              strokeLinecap="round"
            />
            <path d="M12 16.6h.01" strokeWidth="2" strokeLinecap="round" />
          </svg>
          <span className="settings-rail-btn-label">Help</span>
          {/* The arrow is the promise that this leaves the app, made before the
              click rather than discovered after it. */}
          <span className="settings-rail-btn-out" aria-hidden="true">
            ↗
          </span>
        </a>
      )}
    </div>
  )
}
