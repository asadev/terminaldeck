/**
 * The vault's cipher on the desktop: Electron's `safeStorage`.
 *
 * On macOS that is AES under a key the login keychain holds for this app — an
 * entry named after the app, readable by the signed app and by nothing else
 * without asking. It is the same store `servers/credentials.ts`,
 * `browser-passwords.ts` and `voice.ts` already use, so keeping agent logins in
 * it adds no new kind of prompt and no new kind of key.
 *
 * Its own file, and the only one under `account-vault/` that imports Electron,
 * so the rest of the vault loads under plain Node — `store.ts` says why.
 */

import { safeStorage } from 'electron'
import type { VaultCipher } from './store'

export const electronCipher: VaultCipher = {
  available: () => safeStorage.isEncryptionAvailable(),
  encrypt: (plain) => safeStorage.encryptString(plain),
  decrypt: (blob) => safeStorage.decryptString(blob),
}
