/**
 * THE ONLY PLACE THE PRODUCT NAME LIVES.
 *
 * Renaming the app = change the values here, then update the four places that
 * cannot import TypeScript:
 *   - package.json           -> "name", "productName"
 *   - electron-builder.yml   -> appId, productName, the macOS usage strings
 *   - src/renderer/index.html -> <title>, on screen before React mounts
 *   - docs (README.md, BUILDING.md) and the CSS file headers that name it
 * No application code hardcodes the name; everything else imports BRAND.
 */
export const BRAND = {
  /** Display name, shown in the UI and window title. */
  name: 'Terminal Deck',
  /** Lowercase slug used for folders, npm name, CLI command. */
  id: 'terminaldeck',
  /** macOS bundle identifier. */
  bundleId: 'dev.terminaldeck.app',
  /** Per-project config directory created inside a user's project. */
  projectConfigDir: '.terminaldeck',
  /** Env var injected into each spawned session. */
  sessionEnvVar: 'TERMINALDECK_SESSION_ID',
  /** One-line description. */
  tagline: 'Run your coding agents on one deck',
} as const

export type Brand = typeof BRAND
