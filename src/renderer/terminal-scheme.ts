/**
 * Which terminal colour scheme this window is on, and who to tell when it moves.
 *
 * ## Why a module and not a prop
 *
 * Three components build a terminal — the local pane, the remote one and the
 * server one — and none of them is handed the settings. `TerminalView` already
 * takes `fontSize` and `fontFamily` as props from `App.tsx`, and the two remote
 * panes take neither, which is why a session opened on another machine has
 * always rendered at 13px however big the local one was set. Threading a
 * twenty-one-colour object down two more trees would repeat that mistake at
 * greater length.
 *
 * So the scheme lives here, the same shape `theme.ts` uses for the app's own
 * light/dark: one value, a setter the settings layer calls, and a subscription
 * a terminal holds for its lifetime. A terminal asks what the colours are when
 * it is built and is told again when they change; nothing in between has to
 * know a scheme exists.
 *
 * ## What "no scheme" means
 *
 * `null`, and it is the default: nothing is pinned, so the terminal keeps
 * taking its colours from the app's own theme exactly as it always has. That is
 * `FOLLOW_APP_SCHEME_ID` on disk and `appPaletteTheme()` on screen — see
 * `TerminalView.tsx`, which owns the tokens-to-literals half.
 */

import {
  customSchemesFrom,
  FOLLOW_APP_SCHEME_ID,
  schemeById,
  TERMINAL_SCHEME_SETTING,
  type TerminalScheme,
} from '../shared/terminal-theme'

/**
 * The scheme pinned in settings, or null for "follow the app".
 *
 * Pure, and exported for the test: everything about resolution is decidable
 * from a settings map, and the module state below is only a place to keep the
 * answer.
 */
export function resolveTerminalScheme(
  values: Readonly<Record<string, unknown>>,
): TerminalScheme | null {
  const chosen = values[TERMINAL_SCHEME_SETTING]
  if (typeof chosen !== 'string' || chosen === '' || chosen === FOLLOW_APP_SCHEME_ID) return null
  /*
   * A scheme that has gone missing falls back to following the app rather than
   * to a built-in that happens to be first.
   *
   * This is the state somebody reaches by deleting the custom scheme they were
   * using — the picker deletes the key and rewrites the choice, but a second
   * window that has not read the new file yet holds the old id for a moment —
   * and the state a downgrade reaches, where an id this build has never heard of
   * is sitting in a settings file it must not rewrite. Both want the same
   * answer: the appearance the app had before any of this existed.
   */
  return schemeById(chosen, customSchemesFrom(values))
}

let current: TerminalScheme | null = null
const listeners = new Set<() => void>()

/**
 * The one CSS token a scheme has to move, and the defect that found it.
 *
 * xterm only paints the box it was given. Everything *around* a session — the
 * padding `.terminal-host` puts between the emulator and the pane's edge, the
 * copilot's body, a split pane's ground, the shelf behind a remote session — is
 * painted by the stylesheet, from `--terminal-bg`. So a pinned scheme repainted
 * the terminal and left a sixteen-pixel frame of the app's own dark grey drawn
 * around it, which with Solarized Light on screen looks like a rendering fault
 * rather than a choice.
 *
 * Overriding the token on `<html>` fixes all four surfaces at once and needs no
 * edits in four stylesheets other lanes own. It deliberately does **not** move
 * `--tab-active`, which is declared as a literal in `tokens.css` rather than as
 * `var(--terminal-bg)`: the selected tab stays the app's colour, so pinning a
 * cream terminal in a dark window does not put a cream tab in the title bar.
 *
 * `--terminal-fg` is not overridden, and that is not an oversight — no
 * stylesheet in the renderer reads it. It exists for `appPaletteTheme()`, which
 * is only called when nothing is pinned.
 */
const PAPER_TOKEN = '--terminal-bg'

function paintPaper(scheme: TerminalScheme | null): void {
  // No DOM under vitest, and `resolveTerminalScheme` is the half that is tested.
  if (typeof document === 'undefined') return
  const root = document.documentElement
  if (scheme === null) root.style.removeProperty(PAPER_TOKEN)
  else root.style.setProperty(PAPER_TOKEN, scheme.background)
}

/** What every terminal in this window should be painting. */
export function pinnedScheme(): TerminalScheme | null {
  return current
}

/**
 * Watch for a change. Returns an unsubscribe function, matching `subscribeTheme`.
 *
 * A subscriber is somebody else's code — a terminal that is mid-teardown, a
 * pane that has just been unmounted — so one that throws must not swallow the
 * rest of the list. The same argument `theme.ts` makes beside its own notify.
 */
export function subscribeTerminalScheme(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

/** Whether two resolutions would paint the same terminal. */
function same(a: TerminalScheme | null, b: TerminalScheme | null): boolean {
  if (a === null || b === null) return a === b
  // By value rather than by id: editing a colour keeps the id and changes the
  // picture, and that is the case this whole module exists to repaint.
  return JSON.stringify(a) === JSON.stringify(b)
}

/**
 * Set the scheme from a settings map, and tell every terminal if it moved.
 *
 * Called from two places on purpose. `useAppSettings` calls it whenever the
 * stored settings change, which covers launch, the settings window, the copilot
 * and a paired phone; and the appearance pane calls it directly with the patch
 * it is about to save, so dragging a colour picker repaints the session behind
 * the dialog on the frame it moves rather than after a round trip to disk.
 * Idempotent, so the second call for one change does nothing.
 */
export function applyTerminalScheme(values: Readonly<Record<string, unknown>>): void {
  const next = resolveTerminalScheme(values)
  if (same(current, next)) return
  current = next
  paintPaper(current)
  for (const listener of [...listeners]) {
    try {
      listener()
    } catch (error) {
      console.error('terminal scheme: subscriber threw', error)
    }
  }
}

/**
 * Paint a scheme that is not stored anywhere, for as long as somebody is
 * dragging a colour picker.
 *
 * The alternative was to write every intermediate value to `settings.json` and
 * let it come back around through {@link applyTerminalScheme}, which is thirty
 * disk writes for one gesture and — worse — thirty schemes created, because the
 * first edit of a built-in makes a copy. What a drag means is *"show me this"*,
 * and the store is only involved when the picker is let go.
 *
 * The next {@link applyTerminalScheme} overwrites this, which is exactly right:
 * a preview that outlived the thing previewing it would be a terminal painted
 * in colours nothing on disk agrees with.
 */
export function previewTerminalScheme(scheme: TerminalScheme): void {
  if (same(current, scheme)) return
  current = scheme
  paintPaper(current)
  for (const listener of [...listeners]) {
    try {
      listener()
    } catch (error) {
      console.error('terminal scheme: subscriber threw', error)
    }
  }
}

/** For tests, which must not leak a pinned scheme into the next one. */
export function resetTerminalScheme(): void {
  current = null
  paintPaper(null)
  listeners.clear()
}
