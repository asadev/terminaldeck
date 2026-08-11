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
  name: 'Pawl',
  /** Lowercase slug used for folders, npm name, CLI command. */
  id: 'pawl',
  /** macOS bundle identifier. */
  bundleId: 'com.asadiqbal.pawl',
  /** Per-project config directory created inside a user's project. */
  projectConfigDir: '.pawl',
  /** Env var injected into each spawned session. */
  sessionEnvVar: 'PAWL_SESSION_ID',
  /** One-line description. */
  tagline: 'Run and watch your Claude sessions',
} as const

export type Brand = typeof BRAND
