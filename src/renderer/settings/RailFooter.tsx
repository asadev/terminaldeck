/**
 * The one thing at the bottom of the rail that is not a section.
 *
 * It was a rail entry until this pass, and it was a *reference* filed among
 * *settings*. You do not change anything on it.
 *
 *   > "this is a huge shortcut page — maybe rather than this we can have
 *   > another pop-up by clicking on this… maybe it can be only an icon here
 *   > where we click and see the shortcut as pop-up."
 *
 * ## Help was here too, and is not any more
 *
 * There were two buttons. The second opened the marketing site in the user's own
 * browser, which was itself a change made on his instruction — *"maybe we can
 * make it like help button. When they click on it, it should take to terminal
 * website… instead of inside the application."* He has since asked for the
 * opposite, in terms that leave no room:
 *
 *   > "We should have a help page where we can see all the help-related
 *   > features, options — whatever you had before, those kinds of stuff. So
 *   > this can be a separate page."
 *
 * So Help is a pane in the rail again (`HelpSection`), and the website it used
 * to open is a row on that pane. Keeping the footer link as well would be two
 * Helps a centimetre apart doing different things, which is the duplication this
 * footer was invented to remove.
 *
 * The `appAbout` read went with it: this component asked the main process for
 * `package.json`'s `homepage` purely so the link could be drawn only when a real
 * URL existed. `AboutSection` already makes that same read, and already draws
 * the website row only when the field is there, so the honesty is not lost —
 * it moved to the file that was doing it anyway.
 */
export function RailFooter({ onShortcuts }: { onShortcuts(): void }) {
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
    </div>
  )
}
