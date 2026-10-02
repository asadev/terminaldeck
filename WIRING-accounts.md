# WIRING — lane `accounts` (0.16.0)

The app now keeps each account's login itself, encrypted, and hands it only to
that account's sessions. Everything is built and tested on this branch; it is
**off until `src/main/index.ts` calls `wireAccountVault`** — with no vault
installed every account behaves exactly as it did in 0.15.0.

## 1. `src/main/index.ts` — three additions

**Imports** (next to the other `./profiles` imports):

```ts
import { wireAccountVault, type AccountVaultHandle } from './account-vault/wire'
import { electronCipher } from './account-vault/electron-cipher'
```

**Module scope** (beside `copilotRuns` and the other things `before-quit` stops):

```ts
/** The account vault. Null until boot starts it, and null for ever off macOS. */
let accountVault: AccountVaultHandle | null = null
```

**Boot — before anything can start a session.** In `app.whenReady().then(...)`,
the vault must be installed **before `createWindow()`** (the window's load is
what restores remembered tabs) and before `routines.engine.start()` (a routine
can start a session). A session spawned before the vault is installed runs
without its ticket, and an account the app keeps then reads as "not logged in".
`wireAccountVault` is async (it binds a socket), so make that callback `async`
or chain it:

```ts
  // after registerIpc(), before routines.engine.start() and createWindow()
  accountVault = await wireAccountVault({
    userDataDir: app.getPath('userData'),
    cipher: electronCipher,
    log: (message, detail) => logger.info('accounts', message, detail),
  })
```

It never throws: no secure store, a socket another copy is serving, or no
`/usr/bin/security` each turn the vault off with one log line, and accounts
behave as before.

**Quit.** In `app.on('before-quit', …)`, **after `ptys.killAll()`** (so the
agents have stopped writing) and anywhere before the handler returns:

```ts
  void accountVault?.dispose()
```

Everything that matters in `dispose` runs before its first `await`: Codex's
newest login is captured and its plaintext file removed, the runtime is
uninstalled, the shim is deleted. Only the socket close is async.

That is the whole wiring. **No preload change, no new IPC channel, no
`shared/types.ts` change.**

## 2. Signatures — what changed, what did not

Unchanged, every one: `profiles:*`, `accounts:history-*`, `session:switch-plan`,
`session:switch-account`, `session:switch-later/-cancel/-armed`,
`profiles:signin`, `profiles:signout`, `machines:account:*`, `machines:logins:*`
and `createSessionSwitch` / `HostCoreOptions.switchAccount|signInAccount|signOutAccount`.

Additive only:

| Where | Change |
|---|---|
| `profiles:list` → `ProfilesSnapshot` | new field `vault: Record<accountId, AccountVaultView>` — `{ keptBy: 'app'\|'adopting'\|'agent', signedIn: boolean\|null, updatedAt: number\|null, plan: string\|null }`. **Never a value.** |
| `Profile` (persisted in `profiles.json`) | optional `credentials?: 'app'` — set when the app keeps the login. Old files read fine; unknown values are dropped. |
| `profiles:signin` → `SignInReport` | for an account the app keeps (Claude Code), answered from the vault with `command: ''` and no process spawned. Same shape. |
| `session:switch-plan` / `session:switch-account` | new refusal sentence when the target is kept by the app and holds no login: *"X is not signed in yet, so this session was left as it is. Sign in to it first, then switch."* |
| `switchRefusal(input)` / `planSwitch(input)` (`session-switch.ts`) | optional `targetSignedIn?: boolean \| null` on the input object. Existing callers compile unchanged. |
| `profiles:delete` → `DeleteProfileResult.credentialsRetained` | `false` for an account the app kept (its login is deleted with it). |
| `sessionEnv(profile, provider)` | for a kept Claude account also returns `TERMINALDECK_ACCOUNT_VAULT` + `TERMINALDECK_ACCOUNT_TICKET`. |
| new exports in `profiles.ts` | `profileKeptBy(profile)`, `markCredentialsKept(id)`, `keptManaged(profile)`, `accountVaultView(profile)`, type `AccountVaultView`. |

**For the MCP lanes** (`mcp-agents`, `mcp-sessions`, `mcp-machines`): a tool built
on `profiles:list` now gets `vault[accountId].keptBy` / `.signedIn` for free —
worth surfacing as "kept in this app / signed in". Two things must never reach a
tool result or the action log: the env var `TERMINALDECK_ACCOUNT_TICKET` (it
lets a process read that account's login from the vault) and anything from
`AccountVault.read`. Nothing in this lane returns either; a tool that dumps a
session's environment would have to scrub the ticket.

**Actions checklist** (`deck-control/actions/*.ts`): nothing new to list — this
lane added no IPC channel.

## 3. Files

New, all under `src/main/account-vault/`:

| File | What it is |
|---|---|
| `store.ts` | `AccountVault` — the encrypted store (`account-vault/account-vault.bin` in userData, `safeStorage` blob, `writeSecretFile`: atomic, fsynced, 0600, dir 0700). Any number of accounts and slots. Refuses to save without a secure store. No Electron import. |
| `electron-cipher.ts` | `safeStorage` as a `VaultCipher`. The only file here that imports Electron. |
| `keychain-requests.ts` | Reads the exact `security` commands Claude Code 2.1.287 sends (read off the shipped binary) into vault requests; everything else is "not ours". |
| `keychain-shim.ts` | The `security` script a kept Claude session finds first on PATH; answers that session's own login from the socket and passes everything else to `/usr/bin/security` untouched. |
| `server.ts` | The unix socket the shim talks to (`account-vault/vault.sock`, 0600), the per-account `TicketBook`, and the pure `answerShim` / `acceptCapture`. |
| `codex-auth.ts` | `CodexAuthKeeper` — places a kept Codex login at `$CODEX_HOME/auth.json` while the app runs, captures every write Codex makes (sign-in, refresh, logout), removes the file at quit. |
| `runtime.ts` | Module state + the one rule (`keptBy`), `vaultEnv`, `vaultPath`, `vaultSignedIn`, `forgetKeptLogin`, `followNewAccount`, `recheckKeptLogin`. |
| `wire.ts` | `wireAccountVault(...)` → `{ runtime, dispose }`. |
| `fake-cipher.fixture.ts` | Test-only cipher + fake logins (listed in `reachable.test.ts`). |
| tests | `store`, `keychain-requests`, `server` (incl. the real `sh` shim against a real socket), `codex-auth`, `vault-profiles` (through `profiles.ts`, the switch and the sign-in check), `vault.cli` (the real Claude CLI; off unless `TD_LIVE_CLAUDE` is set). |

Edited: `profiles.ts`, `profiles-signin.ts`, `host-core.ts` (4 lines: the shim on
a kept session's PATH), `usage-probe.ts` (same, for the usage probe),
`session-env.ts` (never inherit the vault's two variables), `session-switch.ts`,
`session-switch-run.ts`, renderer `accounts.ts`, `AccountsSection.tsx`,
`AddAccountDialog.tsx`, `AgentsSection.tsx`, `SettingsWindow.css`, and their tests;
`reachable.test.ts` (one fixture entry); `.harness/stub.ts` (the `vault` field);
new `.harness/accounts.{html,tsx}`.

## 4. Gates you will see

- `src/reachable.test.ts` lists `account-vault/wire.ts` and
  `account-vault/electron-cipher.ts` as orphans **until §1 is applied** — they are
  reached only through `index.ts`. (It also lists `deck-control/actions/*`, which
  were orphans at base `04e58b3`.)
- `npm run typecheck`: clean on this branch.

## 5. Headless host

Not wired, deliberately: plain Node has no `safeStorage`, so `src/headless/` gets
no vault and its accounts behave exactly as before (`sessionEnv` adds nothing when
no runtime is installed). If the headless host ever runs inside Electron, the
same `wireAccountVault` call works there unchanged.

## 6. What the integrator should check with a real login (I could not)

Every test here used fake credentials, a scratch config dir, a fake `security`
and a local stand-in for the API and the OAuth server — the login keychain was
never touched. What remains is one real pass, on a scratch `--user-data-dir`:

1. **New account:** Add account → Claude Code → sign in in the terminal. The row
   should read *Signed in · Kept in this app*. Quit, relaunch: still signed in,
   no prompt.
2. **Switch:** two kept accounts, a session on each; switch one. No sign-in, and
   the other session keeps working.
3. **Codex:** add a Codex account, sign in; after quitting, its folder should no
   longer hold `auth.json`; after relaunch it is back and signed in.
4. **The one path never run against a real keychain — an account made before
   this release.** Its first session reads its old keychain item through the
   shim once (the same `security find-generic-password` the CLI always ran) and
   keeps what it got; from then on the vault answers. Expect no prompt and no
   re-login. If macOS does show a keychain prompt, that is the measurement
   `ACCOUNT-MODEL.md` says Asad should make himself — denying it just leaves that
   account signed out, and signing in once fixes it.
