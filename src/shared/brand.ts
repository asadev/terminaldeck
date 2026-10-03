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
 *
 * The assistant's name (`BRAND.assistant`) lives here too, for the same
 * reason. It has no copies outside TypeScript yet; the phone apps still carry
 * their own spelling (see the note on the field).
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
  /**
   * The assistant built into the app: the owl pinned at the top of the
   * sidebar, its own page, its Settings section, its MCP tools.
   *
   * It was called "Copilot" until 2026-10-03, which is Microsoft's trademark,
   * and Asad named it **Hoot**: a friendly character for people who are not
   * technical, so every sentence reads it as a name ("Hoot is working on it",
   * "Ask Hoot"), never "the Hoot".
   *
   * This is the one spelling. Everything a person or an outside AI reads
   * interpolates it, so the next rename is this line and nothing else;
   * `assistant-name.test.ts` fails if the old name comes back in any string
   * the app shows. What is NOT derived from it, on purpose: storage and wire
   * identifiers that existing installs and paired phones already hold, such as
   * the `copilot.*` settings keys, the `copilot/` folders under userData, the
   * `copilot:*` IPC channels and the relay's `copilot.*` frames. Renaming those
   * would break a working install to change a word nobody sees.
   *
   * A person can still give it a name of their own in its setup flow; that
   * name is user data (`shared/copilot-identity.ts`) and wins where it is
   * known. This is the name it has when nobody has given it another.
   */
  assistant: 'Hoot',
} as const

export type Brand = typeof BRAND
