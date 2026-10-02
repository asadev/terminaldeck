/**
 * Starting the account vault — one call from the desktop shell.
 *
 * Everything the vault needs exists by the time `registerIpc` runs: the data
 * folder, the profile list, `safeStorage`. This opens the vault, starts the
 * socket the shim talks to, writes the shim, settles every Codex account's
 * file, and installs the runtime every session start then reads. The returned
 * `dispose` undoes it in the order that keeps every login: capture Codex's
 * files, then stop answering, then remove the shim.
 *
 * ## Failing is allowed, and it is quiet
 *
 * Every step that can fail turns the vault off rather than the app. No secure
 * store, a socket somebody else is serving, no `/usr/bin/security` to fall back
 * to — in each case accounts behave exactly as they did before this release:
 * the agent keeps its own login. A log line says which step and why. What must
 * never happen is a half-installed vault, where sessions are handed a ticket
 * for a socket nothing is listening on; so the runtime is installed last, and
 * only once everything under it is up.
 */

import { createHash } from 'node:crypto'
import { homedir } from 'node:os'
import { join, posix } from 'node:path'
import { BRAND } from '../../shared/brand'
import { currentPlatform, type Platform } from '../platform/host'
import { findProfile, getState, keptManaged, markSlotKept, profileKeptBy } from '../profiles'
import { CODEX_AUTH_SLOT, CodexAuthKeeper, type DirWatch } from './codex-auth'
import { REAL_SECURITY, removeSecurityShim, writeSecurityShim } from './keychain-shim'
import {
  installAccountVault,
  slotAdopting,
  uninstallAccountVault,
  type AccountVaultRuntime,
} from './runtime'
import { startVaultSocket, TicketBook, type VaultServerDeps, type VaultSocket } from './server'
import { AccountVault, type VaultCipher } from './store'

/** The vault's own folder inside the app's data folder. */
export const VAULT_DIR = 'account-vault'

/** `sun_path` is 104 bytes on macOS; the hook server keeps under 100 and so does this. */
const MAX_SOCKET_PATH_BYTES = 100

/**
 * Where the socket goes: inside the vault's folder when the path fits, else a
 * digest of it under the app's dot-folder in the home directory — the same two
 * steps `hook-server.ts` takes, for the same 104-byte reason. Null when neither
 * fits, which turns the vault off rather than binding somewhere surprising.
 */
export function vaultSocketPath(vaultDir: string, home: string = homedir()): string | null {
  const natural = posix.join(vaultDir, 'vault.sock')
  if (Buffer.byteLength(natural) <= MAX_SOCKET_PATH_BYTES) return natural
  const digest = createHash('sha256').update(vaultDir).digest('hex').slice(0, 16)
  const short = posix.join(home, `.${BRAND.id}`, `vault-${digest}.sock`)
  return Buffer.byteLength(short) <= MAX_SOCKET_PATH_BYTES ? short : null
}

export interface WireAccountVaultOptions {
  /** `app.getPath('userData')`. */
  userDataDir: string
  cipher: VaultCipher
  platform?: Platform
  /** The real `security`, for tests that must never touch the real keychain. */
  realSecurity?: string
  home?: string
  watch?: DirWatch
  /** Is a Codex folder in use outside this app? Tests answer it; see `codex-auth.ts`. */
  inUse?: (dir: string) => boolean
  /** One line per notable event. Never a value — only ids, slots and kinds. */
  log?(message: string, detail?: Record<string, unknown>): void
  /**
   * Told the account id whenever a login is kept, refreshed or signed out, so
   * the shell can tell its window to re-read the account list.
   */
  onChanged?(accountId: string): void
}

export interface AccountVaultHandle {
  runtime: AccountVaultRuntime
  dispose(): Promise<void>
}

/** Every Codex account the vault keeps, as the keeper needs them. */
function keptCodexAccounts(): Array<{ id: string; configDir: string }> {
  return getState()
    .profiles.filter((profile) => profile.provider === 'codex' && profileKeptBy(profile) === 'app')
    .map((profile) => ({ id: profile.id, configDir: profile.configDir }))
}

export async function wireAccountVault(options: WireAccountVaultOptions): Promise<AccountVaultHandle | null> {
  const log = options.log ?? (() => undefined)
  const platform = options.platform ?? currentPlatform()
  /*
   * macOS only, in this release. The `security` shim is a macOS mechanism by
   * definition; the Codex file keeper is not, but a vault that kept one agent's
   * logins on Windows and not the other's would be a second, different answer
   * to "where is my login" on a platform nothing here has been run on.
   */
  if (platform !== 'darwin') return null

  const dir = join(options.userDataDir, VAULT_DIR)
  const vault = new AccountVault({ dir, cipher: options.cipher })
  if (!vault.available()) {
    log('account vault off: no secure store on this computer')
    return null
  }
  /*
   * Opened here, before anything is installed, and refused if it will not
   * open. The first decrypt is the one that can raise a keychain prompt, and it
   * must not happen inside a session's lookup, where it would outlast the
   * shim's timeout; and a vault that will not decrypt is a vault full of
   * somebody's logins behind a key that is not available right now — so the
   * app runs without it, every account it keeps reads "unavailable" rather than
   * falling back to the keychain, and nothing touches the file.
   */
  if (vault.open() === 'locked') {
    log('account vault off: the saved logins would not unlock; the file is left exactly as it is')
    return null
  }
  const socketPath = vaultSocketPath(dir, options.home)
  if (socketPath === null) {
    log('account vault off: no socket path short enough for this data folder', { dir })
    return null
  }

  const tickets = new TicketBook()
  const deps: VaultServerDeps = {
    vault,
    tickets,
    providerOf: (id) => findProfile(getState(), id)?.provider ?? null,
    configDirOf: (id) => findProfile(getState(), id)?.configDir ?? null,
    adopting: (id, slot) => {
      const profile = findProfile(getState(), id)
      return profile !== null && slotAdopting(profile, keptManaged(profile), slot)
    },
    markKept: (id, slot) => markSlotKept(id, slot),
    onCapture: (event) => {
      log('account vault: kept a login', { account: event.accountId, slot: event.slot, kind: event.kind })
      options.onChanged?.(event.accountId)
    },
  }

  let socket: VaultSocket
  try {
    socket = await startVaultSocket(socketPath, deps)
  } catch (cause) {
    log('account vault off: the socket could not be started', {
      reason: cause instanceof Error ? cause.message : String(cause),
    })
    return null
  }

  // In the data folder beside the vault, not inside it — see `vaultShimDir`.
  const shimDir = writeSecurityShim(options.userDataDir, socketPath, options.realSecurity ?? REAL_SECURITY)
  if (shimDir === null) log('account vault: no system security command, so Claude Code logins stay with the agent')

  const codex = new CodexAuthKeeper(vault, {
    ...(options.watch ? { watch: options.watch } : {}),
    ...(options.inUse ? { inUse: options.inUse } : {}),
    onCapture: (event) => {
      // Something was kept for it, or signed out of it: from now on an empty
      // vault means "signed out" for this account, not "cannot tell".
      markSlotKept(event.accountId, CODEX_AUTH_SLOT)
      log('account vault: kept a login', { account: event.accountId, slot: 'file:auth.json', kind: event.kind })
      options.onChanged?.(event.accountId)
    },
  })

  const runtime: AccountVaultRuntime = { vault, tickets, socketPath, shimDir, codex }
  installAccountVault(runtime)

  // Every Codex account's file and kept copy into agreement — the move for an
  // account made before this release, and the restore after a quit.
  for (const account of keptCodexAccounts()) {
    try {
      codex.settle(account)
    } catch (cause) {
      log('account vault: a Codex login could not be settled', {
        account: account.id,
        reason: cause instanceof Error ? cause.message : String(cause),
      })
    }
  }

  return {
    runtime,
    /*
     * Everything that matters happens before the first `await`, because this is
     * called from `before-quit`, which does not wait: capture Codex's newest
     * login and take its file away, stop answering, take the shim off disk.
     * Closing the socket is the only asynchronous step, and a socket left open
     * by a process that is exiting is closed by the exit.
     */
    dispose: async () => {
      // Capture before anything stops: a refresh Codex wrote a moment ago is
      // the copy the next launch needs.
      for (const account of keptCodexAccounts()) {
        try {
          codex.release(account)
        } catch {
          // A file that cannot be removed is left; the next launch settles it.
        }
      }
      codex.dispose()
      uninstallAccountVault()
      removeSecurityShim(options.userDataDir)
      await socket.close()
    },
  }
}
