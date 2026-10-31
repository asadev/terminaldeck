import { useEffect, useRef } from 'react'
import { ShortcutsList } from '../components/ShortcutsSheet'

/**
 * The shortcut reference, as a popover over the settings sheet.
 *
 * ## Why it stopped being a pane
 *
 *   > "then this is a huge shortcut page — maybe rather than this we can have
 *   > another pop-up by clicking on this or something… maybe it can be only an
 *   > icon here where we click and see the shortcut as pop-up."
 *
 * He is describing the difference between a setting and a reference. Every
 * other entry in that rail is something you change; this one is something you
 * look at, twice, and it was the longest pane in the window — four screens of
 * chords under a heading that promised a place to configure them, which none of
 * them can be. As a popover it is one click from anywhere in Settings and takes
 * nothing from the rail.
 *
 * `ShortcutsList` is imported rather than reimplemented, which is the whole
 * point of that component being split out: it builds the list from `KEYMAP`
 * itself, so a printed copy cannot rot. The ⌘/ sheet in the main window renders
 * the same component, so both routes show the same chords.
 *
 * ## Escape, and why this is not a `Modal`
 *
 * `Modal` binds Escape on `window` in the bubble phase, and the settings sheet
 * is already a `Modal`. Nesting one inside the other means one Escape closes
 * both — the outer listener was registered first, so it runs first, and
 * `stopPropagation` from the inner one cannot reach backwards in time. Pressing
 * Escape to dismiss a shortcut list and losing the settings window with it is
 * exactly the kind of small wrongness this codebase keeps finding by looking.
 *
 * So this listens on `document` in the **capture** phase, which runs before the
 * event ever reaches the window's bubble listeners, and stops it there. Escape
 * closes the popover; a second Escape closes Settings.
 */
export function ShortcutsPopover({ onClose }: { onClose(): void }) {
  const panelRef = useRef<HTMLDivElement>(null)
  // Read through a ref so the listener is installed once and still calls the
  // current handler — a re-created closure would re-bind on every render.
  const close = useRef(onClose)
  close.current = onClose

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      // Capture phase: this is what keeps the settings sheet open behind it.
      event.stopPropagation()
      close.current()
    }
    document.addEventListener('keydown', onKeyDown, true)
    return () => document.removeEventListener('keydown', onKeyDown, true)
  }, [])

  // The panel itself, not its first row: a screen reader then announces what
  // opened before reading a list of forty chords.
  useEffect(() => {
    panelRef.current?.focus()
  }, [])

  return (
    <div className="settings-popover-layer">
      {/*
        A scrim that closes on click, and is invisible.

        Not a dimming layer: this sits inside a dialog that is already over a
        scrim, and a second one would read as the app going two steps away. It
        exists to catch the click that means "somewhere else", which is how a
        popover is dismissed everywhere else in this window.
      */}
      <button
        type="button"
        className="settings-popover-scrim"
        aria-label="Close the shortcut list"
        onClick={() => close.current()}
      />
      <div
        ref={panelRef}
        className="settings-popover"
        role="dialog"
        aria-modal="false"
        aria-label="Keyboard shortcuts"
        tabIndex={-1}
      >
        <header className="settings-popover-head">
          <h3 className="settings-popover-title">Keyboard shortcuts</h3>
          {/* Read-only, deliberately. Nothing in the app can rebind a chord
              yet, and a control that looked editable would be a promise the
              keymap cannot keep. */}
          <span className="settings-popover-note">They cannot be changed yet.</span>
          <button
            type="button"
            className="settings-popover-close"
            aria-label="Close"
            onClick={() => close.current()}
          >
            <span aria-hidden="true">✕</span>
          </button>
        </header>
        <div className="settings-popover-body scroll-fade">
          <ShortcutsList />
        </div>
      </div>
    </div>
  )
}
