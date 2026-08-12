import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { App } from 'electron'
import { BRAND } from '../shared/brand'

/** The one file in userData that is ours rather than Chromium's. */
const STATE = 'state.json'

/**
 * Pins the data directory to `BRAND.id` and carries settings over from the
 * directory Electron would otherwise have chosen.
 *
 * By default Electron derives userData from the *display* name, so renaming
 * the app silently moves every user's projects, preferences and window bounds
 * to a new folder and starts them over in an empty one. That already happened
 * here twice — `Pawl`, `pawl` and `Terminal Deck` are all sitting in
 * Application Support, each with its own `state.json` — and it happened with
 * no error, which is what makes it worth pinning rather than remembering.
 *
 * `id` is a slug, not a display name, so it does not move when the product is
 * renamed. Chromium's own caches are rebuilt wherever they land, so only
 * `state.json` is worth carrying.
 */
export function pinUserData(app: App): void {
  const fromName = app.getPath('userData')
  const pinned = join(dirname(fromName), BRAND.id)
  if (fromName === pinned) return

  try {
    mkdirSync(pinned, { recursive: true })
    // Only ever a first-run copy: once the pinned directory has state of its
    // own it is the truth, and a later rename must not overwrite it.
    if (!existsSync(join(pinned, STATE)) && existsSync(join(fromName, STATE))) {
      copyFileSync(join(fromName, STATE), join(pinned, STATE))
    }
    app.setPath('userData', pinned)
  } catch {
    /* A failure here must not stop the app booting; it just keeps the default
       location, which is the behaviour we had before. */
  }
}
