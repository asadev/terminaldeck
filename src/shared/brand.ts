/**
 * THE ONLY PLACE THE PRODUCT NAME LIVES.
 *
 * Renaming the app = change the values here, then update:
 *   - package.json  -> "name"
 *   - electron-builder.yml -> appId / productName
 * Nothing else in the codebase hardcodes the name.
 */
export const BRAND = {
  /** Display name, shown in the UI and window title. */
  name: 'Deck',
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
