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

It never throws. It opens (decrypts) the vault **before** installing anything,
so the one decrypt that can raise a keychain prompt never happens inside a
session's lookup. No secure store, a vault that will not unlock (a denied or
locked keychain, or a dev and a release build sharing userData), a socket
another copy is serving, or no `/usr/bin/security` each turn the vault off with
one log line. The vault file is never moved or rewritten in any of those cases.
Accounts the app has never kept behave as before; an account the app **has**
kept reads `unavailable` and is refused (below) — never quietly handed back to
the keychain.

**Quit.** In `app.on('before-quit', …)`, **after `ptys.killAll()`** (so the
agents have stopped writing) and anywhere before the handler returns:

```ts
  void accountVault?.dispose()
```

Everything that matters in `dispose` runs before its first `await`: Codex's
newest login is captured and its plaintext file removed, the runtime is
uninstalled, the shim is deleted. Only the socket close is async.

**"Switch at my next message" — one argument.** Where `index.ts` builds the
register (`const pending = new PendingSwitches()`, in the account-switch block),
hand it the live status the sidebar already shows:

```ts
  const pending = new PendingSwitches({ statusOf: (id) => liveStatus.get(id)?.status ?? null })
```

Without it the deferred switch already ignores an Enter with nothing typed (a
dialog's highlighted choice); with it, it also ignores "2 + Enter" while the
agent is asking a question, which is what stops it killing the agent mid-turn
when a permission prompt is approved.

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
| `profiles:list` → `ProfilesSnapshot` | new field `vault: Record<accountId, AccountVaultView>` — `{ keptBy: 'app'\|'adopting'\|'unavailable'\|'agent', signedIn: boolean\|null, updatedAt: number\|null, plan: string\|null }`. **Never a value.** |
| `Profile` (persisted in `profiles.json`) | optional `credentials?: 'app'` (born in the vault) and `keptSlots?: string[]` (slots of a pre-vault account that have moved in, one by one). Old files read fine; unknown values are dropped. |
| `profiles:signin` → `SignInReport` | for an account the app keeps (Claude Code), answered from the vault with `command: ''` and no process spawned. Same shape. |
| `session:switch-plan` / `session:switch-account` | two new refusals: the target is kept by the app and holds no login (*"X is not signed in yet, so this session was left as it is. Sign in to it first, then switch."*), and the target is `unavailable` (`UNAVAILABLE_SENTENCE`). |
| `switchRefusal(input)` / `planSwitch(input)` (`session-switch.ts`) | optional `targetSignedIn?: boolean \| null` and `targetUnavailable?: string \| null` on the input object. Existing callers compile unchanged. |
| `session:switch-plan` → `SwitchPlan.conversation` | new value `'separate'` (Codex: each account's conversations live in its own folder, so the switch starts fresh and the sheet says so before anything happens). The renderer mirror and sentence are updated. |
| `session:switch-account` | waits for the replacement to be **ready** (its prompt or a question on its own screen, read through the same classifier the sidebar uses) with a 15-second ceiling, instead of a fixed 1.5 s. Refuses when the replacement comes up at a sign-in screen or exits while waiting; the old session keeps running. A plain-terminal tab is refused with a sentence saying why. |
| `createSessionSwitch(core, hooks)` | `hooks.readiness?` `{ ceilingMs, pollMs, wait }` — tests only. |
| `PendingSwitches` (`switch-later.ts`) | optional constructor `{ statusOf(id) }` — see §1. |
| `argsForSpawn` (`one-conversation.ts`) | optional `conversationId`: a named resume collides only with a tab on that same conversation. `SessionInFolder` gains optional `agentSessionId`. |
| `SessionMeta.agentSessionId` | now also set for a tab restored with `--continue` (recovered from the transcripts at spawn; `conversation-id.ts`). |
| ledger `SavedSession.profileId` | the account the tab actually ran as (`rememberedAccount`), no longer `null` for a tab opened on "the default". |
| `shareProjects` / `adoptSharedHistory` | folders both histories have are merged file by file instead of the account's history being moved aside; history an earlier build set aside (`projects.not-merged-*`) is brought back at boot. |
| `HostCore.startSession` | **rejects** with `UNAVAILABLE_SENTENCE` for an account the app keeps when this process cannot reach the vault (the headless host shares `profiles.json` and has no `safeStorage`). Checked before any probe or spawn. Every other account is unaffected. |
| `profiles:signin` / `profiles:signout` / usage probe | for an `unavailable` account: `state: 'unknown'` / `ok: false` with that sentence, and nothing is spawned. |
| `profiles:delete` → `DeleteProfileResult` | `credentialsRetained` is `false` for an account the app kept (its login is deleted with it) — `true` plus a new `warning` string if that delete could not be saved. |
| `sessionEnv(profile, provider)` | for a kept Claude account also returns `TERMINALDECK_ACCOUNT_VAULT` + `TERMINALDECK_ACCOUNT_TICKET`. |
| new exports in `profiles.ts` | `profileKeptBy(profile)`, `markSlotKept(id, slot)`, `keptManaged(profile)`, `keptUnavailable(profile)`, `accountVaultView(profile)`, type `AccountVaultView`. |
| new export in `session-env.ts` | `withoutVaultEnv(env)` — the sign-in and usage probes build their environment from `process.env` through it, so a ticket this app inherited never reaches a probe. |

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
| `keychain-shim.ts` | The `security` script a kept Claude session finds first on PATH (`<userData>/account-vault-shim/security` — a folder of its own, deliberately not inside the vault folder and not called `bin`, because a confined plan grants a `bin` entry's parent). Answers that session's own login from the socket and passes everything else to `/usr/bin/security` untouched. |
| `server.ts` | The unix socket the shim talks to (`account-vault/vault.sock`, 0600), the per-account `TicketBook`, and the pure `answerShim` / `acceptCapture`. A lookup is answered only when its keychain name carries **this account's own folder hash** (`sha256(configDir)[:8]`, as the CLI names it) — a nested agent with another `CLAUDE_CONFIG_DIR` holding an inherited ticket is passed to the real `security`. |
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

## 5. Confined (paired-device) sessions — a decision for Asad

A device's held session is denied the keychain by its sandbox, so today its
agent cannot read the owner's login. The vault could hand it that login over
the socket. **It does not**: a confined session is started without a ticket and
behaves exactly as it did before. Whether a paired device should be able to use
an account the owner granted it is a product call about what a device may reach,
not a side effect of where logins are stored — so it is left to him. Changing it
is one line in `host-core.ts` (the `confined ? withoutVaultEnv(…) : …` spread).

## 6. Headless host

Not wired, deliberately: plain Node has no `safeStorage`, so `src/headless/` gets
no vault. Accounts it has never kept behave exactly as before. An account the
desktop **has** kept (it shares `profiles.json`) reads `unavailable` there and a
session on it is refused with a sentence — the agent is never left to read a
keychain item the app stopped keeping up to date. The desktop's quit-time removal
of a Codex `auth.json` checks `ps` first and leaves the file if any process
outside the app is running Codex on that folder.

## 7. What the integrator should check with a real login (I could not)

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
