/**
 * Whether two agent profiles really are two logins, on this platform.
 *
 * ## What the feature actually rests on
 *
 * `profiles.ts` isolates profiles by pointing `CLAUDE_CONFIG_DIR` at different
 * directories. That part is an environment variable and works anywhere. The
 * part that decides whether the *logins* are separate is where the agent CLI
 * keeps its credentials, which is not this app's choice and not something this
 * app can see into.
 *
 * On macOS it was checked, first-hand, against the real CLI: credentials live in
 * the login Keychain under a service name that carries a suffix derived from the
 * config directory — `Claude Code-credentials` for the default install and
 * `Claude Code-credentials-<hex>` for a redirected one, both present on that
 * machine. Two profiles therefore cannot overwrite each other's token, and
 * deleting a profile's directory does not sign it out.
 *
 * On Windows none of that has been checked, because nothing in this repo can run
 * there. So it is not claimed. The one thing that *can* be observed at runtime is
 * whether the profile's own config directory contains a `.credentials.json` —
 * and if it does, the answer is settled in the good direction: the credential is
 * inside the directory that the profile already isolates.
 *
 * That observation is used **only where nothing better is known**. On macOS the
 * same file is a normal thing to find (`prerequisites.ts` looks for it before it
 * looks in the Keychain), so treating it as proof there would overwrite a
 * verified answer with an inferred one — and would have the app tell a macOS
 * user that deleting a profile signed it out when the Keychain entry the CLI
 * actually uses is still sitting there.
 *
 * ## Why Electron's `safeStorage` is not the answer here
 *
 * `safeStorage` (Keychain on macOS, DPAPI on Windows) encrypts secrets *this
 * application owns*. This application never sees, receives or stores an agent's
 * credentials — the CLI authenticates in its own process and writes them
 * wherever it writes them. Encrypting something we do not hold is not a thing
 * that can be done, so wiring `safeStorage` in here would be a call that
 * compiles, runs, and changes nothing about whether two logins are separate.
 * That is precisely the kind of decorative fix that makes an unsolved problem
 * look solved, so the honest degradation below is used instead.
 */

import type { Platform } from './host'

export type CredentialStore =
  /** The login Keychain, keyed per config directory. Verified on macOS. */
  | 'macos-keychain'
  /** A `.credentials.json` inside the profile's own config directory. */
  | 'config-directory'
  /** Not established on this platform. */
  | 'unknown'

export interface ProfileIsolation {
  store: CredentialStore
  /** True only when a second profile is *known* to get its own login. */
  isolated: boolean
  /** One sentence, written to be shown to a person. Rendered verbatim. */
  note: string
}

/**
 * @param credentialsInConfigDir whether `<configDir>/.credentials.json` exists.
 *   A plain `stat`, so it costs nothing and never prompts for Keychain access —
 *   which is the reason profile *login* state is still not reported anywhere.
 */
export function profileIsolation(
  platform: Platform,
  credentialsInConfigDir: boolean,
): ProfileIsolation {
  // macOS first, and the file in the directory does **not** override it.
  //
  // A `.credentials.json` under the config directory is ordinary on macOS —
  // `prerequisites.ts` probes for exactly that file before it falls back to the
  // Keychain — so letting its presence win would flip every such profile to
  // "deleting these files signs you out" on the one platform where the opposite
  // was checked first-hand. It would also make `deleteProfile` report
  // `credentialsRetained: false` for a login the Keychain still holds, which is
  // a wrong answer about the verified platform arrived at by inference. The
  // observation below is what settles the question where nothing else can.
  if (platform === 'darwin') {
    return {
      store: 'macos-keychain',
      isolated: true,
      note:
        'Logins are kept in the macOS Keychain under a name derived from this profile’s config directory, so profiles cannot overwrite each other’s login, and deleting this profile’s files does not sign it out.',
    }
  }

  if (credentialsInConfigDir) {
    return {
      store: 'config-directory',
      isolated: true,
      note:
        'This profile keeps its own credentials file inside its config directory, so its login is separate from the others — and deleting this profile’s files does sign it out.',
    }
  }

  return {
    store: 'unknown',
    isolated: false,
    note:
      platform === 'win32'
        ? 'Profile isolation is unverified on Windows. The config directory is redirected, but where the agent keeps its credentials there has not been checked, so two profiles may share one login until this one has been signed into at least once.'
        : `Profile isolation is unverified on ${platform}. The config directory is redirected, but where the agent keeps its credentials there has not been checked, so two profiles may share one login until this one has been signed into at least once.`,
  }
}
