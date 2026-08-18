# Account model — one switch for the whole app, or two logins side by side?

Measured 2026-08-17 against the real CLI (`2.1.233`) on this machine.
Nothing in this file is inferred from documentation.

> *"Maybe we can give multiple account connections in one application overall…
> store all the accounts in the settings, switch once, and all the sessions
> switch to that."*

He arrived at it from the plain CLI:

> *"I start a new session and change the account, and I come back to the original
> one — it comes with a new limit with the new account. If I do a slash command
> and check the usage it shows me the newer account."*

That observation is **correct, and it is a mechanism, not a coincidence.** It is
reproduced below, on macOS, on the keychain — the store his own accounts
actually live in.

---

## How this was measured, and why nothing prompted

Two stand-ins made the whole question answerable offline, with **zero access to
the login keychain** and no real API traffic.

**1. A local Anthropic.** `ANTHROPIC_BASE_URL=http://127.0.0.1:8919` pointed at a
40-line HTTP server that logs the `Authorization` header of every request and
answers `POST /v1/messages` with a valid SSE stream. Turns complete normally, so
sessions stay alive across many turns — and every request records *exactly which
token went on the wire*. That is the measurement instrument for all of this.

**2. A fake keychain.** The CLI reaches the macOS keychain by shelling out to
`security`. A shim named `security`, first on `PATH`, intercepted every one of
those calls and answered from a file I control:

    SECURITY-CALLED: find-generic-password -a apple -w -s Claude Code-credentials-70e2e799
    SECURITY-CALLED: find-generic-password -a apple -w -s Claude Code-70e2e799

15 calls were made during these tests. **All 15 were absorbed by the shim.** The
real login keychain was never read, never written, never unlocked, and nothing
appeared on screen.

**3. A credential-free discovery oracle.** Conversation lookup happens *before*
the auth check, so "can this account find that conversation" needs no login:

    $ CLAUDE_CONFIG_DIR=/tmp/tdam/fresh claude --resume 00000000-0000-0000-0000-000000000000 -p x
    No conversation found with session ID: 00000000-0000-0000-0000-000000000000

    $ CLAUDE_CONFIG_DIR=/tmp/tdam/fresh claude --resume <a real id> -p x
    Not logged in · Please run /login          # found it, then failed on auth

An unauthenticated run still writes its transcript, which is what makes the
whole of Option C testable with no account at all.

Verified afterwards: nothing of this landed in `~/.claude/projects` or in any
Terminal Deck profile. Every config directory used was under `/tmp/tdam/`.

---

## The foundation: where the credential actually comes from

`profiles.ts` says macOS keeps the credential in the login keychain and
`credential-store.ts` treats a `.credentials.json` as the answer "only where
nothing better is known". Both are right, but the picture is bigger than either
records, and the missing part is what decides this whole question.

**The precedence chain, measured end to end:**

| # | Source | Beats what is below it |
|---|---|---|
| 1 | `CLAUDE_CODE_OAUTH_TOKEN` (environment, per process) | ✅ measured |
| 2 | macOS login keychain, service `Claude Code-credentials-<hex>`, account = unix username | ✅ measured |
| 3 | `<configDir>/.credentials.json` | — |

The evidence, each line a separate run, the token read off the local sink:

    # file only
    .credentials.json = FILE-SAYS-THIS,  keychain empty
      → Bearer sk-ant-oat01-FILE-SAYS-THIS

    # both present
    .credentials.json = FILE-SAYS-THIS,  keychain = KEYCHAIN-SAYS-THIS
      → Bearer sk-ant-oat01-KEYCHAIN-SAYS-THIS      ← keychain wins

    # keychain plus env var
    keychain = KEYCHAIN-ACCOUNT-ONE,  CLAUDE_CODE_OAUTH_TOKEN = ENVVAR-WINS
      → Bearer sk-ant-oat01-ENVVAR-WINS             ← env wins

Three things follow, and each one changes an answer below:

- **On macOS a `.credentials.json` is a real, honoured login.** `claude auth
  status --json` on a directory holding nothing but that file returns
  `{"loggedIn": true, "authMethod": "claude.ai"}`. It is not merely an
  observation about isolation, as `credential-store.ts` treats it — it is a
  working credential store. It is also the *lowest* priority one, so writing it
  next to a keychain-held login does nothing.
- **There are two keychain items per config directory**, not one: `Claude
  Code-<hex>` *and* `Claude Code-credentials-<hex>`. `profiles.ts` names only the
  second. The `<hex>` differs per config directory (`70e2e799` vs `8e404012` for
  two scratch dirs), confirming the per-directory suffix that profile isolation
  rests on.
- **`CLAUDE_CODE_OAUTH_TOKEN` overrides everything, per process.** That single
  fact is what makes a fourth option exist at all — see D.

### The thing his observation is actually about

**A running session re-resolves its credential on every request.** Proven twice,
on both stores, each time as one process taking two turns:

*File store* — one process, session `9f011b0e`, credential file rewritten between
turns:

    turn 1  →  Bearer sk-ant-oat01-ACCOUNT-ONE
    >>> swap .credentials.json, process still alive
    turn 2  →  Bearer sk-ant-oat01-ACCOUNT-TWO

*Keychain store* — one process, session `f7d12ffa`, the keychain's answer changed
between turns:

    turn 1  →  Bearer sk-ant-oat01-KEYCHAIN-ACCOUNT-ONE
    >>> swap the keychain entry, process still alive
    turn 2  →  Bearer sk-ant-oat01-KEYCHAIN-ACCOUNT-TWO   (500 ms later)
    turn 3  →  Bearer sk-ant-oat01-KEYCHAIN-ACCOUNT-TWO   (12 s later)

Same PID, same session id, same conversation — new account. There is a stale
cache in there (`[keychain] read failed; serving stale cache`), but it is a
fallback for read *failures*, not a TTL that delays a successful change.

**So his claim is true of the real macOS mechanism**, not just by analogy from
Linux. He is describing the CLI working exactly as designed.

---

## Option A — one config directory per account (what ships today)

Two accounts genuinely side by side. Each keeps its own directory, its own
keychain item, its own transcripts.

Same folder, two accounts, taken in order:

    ONE  -p "remember the word PLATYPUS"       → conversation 6fcb822c
    ONE  --continue -p "what word"             → appended to 6fcb822c
    TWO  --continue -p "what word"             → NEW conversation 4f131dc1
    TWO  --resume 6fcb822c                     → No conversation found with session ID

The transcripts, read back:

    6fcb822c (account ONE):  user: remember the word PLATYPUS
                             user: what word
    4f131dc1 (account TWO):  user: what word          ← starts from nothing

That is the *"this is your first message to me"* result, reproduced. It is not a
bug and it is not fixable inside A: the conversation lives in the store, and the
store is what the switch changes.

**What it costs him, in his terms.** He hits a limit at 40 minutes into a piece
of work. He switches account. The new account cannot see the conversation, cannot
`--continue` it and cannot `--resume` it by id. He restates the problem from
scratch, and the context — the files read, the decisions taken, the corrections
he made — is on the other side of a wall. Every running session keeps running on
the exhausted account until he restarts it, one at a time.

---

## Option B — one shared store, credential swapped

The CLI's own model, and the one his observation describes. **It works, and it
does exactly what he asked for.**

Two live sessions, two folders, two session ids, **one shared config directory**.
Account ONE hits its limit; the credential is rewritten once; nothing is
restarted:

    == both sessions running, credential = ACCOUNT-ONE ==
      [sessionA] result err=false  "SINK-REPLY-0"          a4ab1b43
      [sessionB] result err=false  "SINK-REPLY-1"          c9b8bdb8

    == ACCOUNT-ONE hits its limit ==
      [sessionA] err=true  "API Error: … 5-hour limit reached for this account"
      [sessionB] err=true  "API Error: … 5-hour limit reached for this account"

    == ONE switch. No restarts. ==
      [sessionA] result err=false  "SINK-REPLY-3"          a4ab1b43   ← same session
      [sessionB] result err=false  "SINK-REPLY-5"          c9b8bdb8   ← same session

    tokens on the wire, in order:
      ACCOUNT-ONE 200 · ACCOUNT-ONE 200
      ACCOUNT-ONE 429 · ACCOUNT-ONE 429 · ACCOUNT-ONE 429 · ACCOUNT-ONE 429
      ACCOUNT-TWO 200 · ACCOUNT-TWO 200 · ACCOUNT-TWO 200 · ACCOUNT-TWO 200

Switch once, every running session follows, conversations untouched. That is the
feature, demonstrated.

### The two prices, and the second one is not small

**1. Two accounts cannot run at once.** One store holds one credential. This is
not a limitation of the implementation; it is what "one store" means.

**2. One session's auth failure signs out every session, instantly.** The same
per-request re-read that makes switching work makes this happen. Measured:

    == sink returns 401 for the current token (a revoked or expired one) ==
      [sessionA] err=true  "Failed to authenticate: OAuth session expired…"
      cred file present after sessionA got 401:  false        ← the CLI deleted it

    == sessionB never made a bad request. Its next turn: ==
      [sessionB] err=true  "Not logged in · Please run /login"

sessionB did nothing wrong and was working seconds earlier. A 401 in any one
session removes the credential from the shared store, and the blast radius is
every session in the app.

---

## Option C — separate config directories, shared `projects/`

The one that needs **no credentials at all**, which is its whole appeal. Each
account keeps its directory and its own keychain-held login; only `projects/` is
a symlink to one shared location.

    /tmp/tdam/C/cfgA/projects -> /tmp/tdam/C/shared-projects
    /tmp/tdam/C/cfgB/projects -> /tmp/tdam/C/shared-projects

**Does the CLI tolerate it? Yes, completely.**

    ONE  -p "remember the word PLATYPUS"
      → /tmp/tdam/C/shared-projects/-private-tmp-tdam-C-work/dbebd1aa….jsonl
      → cfgA/projects is still a symlink afterwards (not replaced by a real dir)

    TWO  --continue -p "what word"     → appended to dbebd1aa   (one file, 11795 b)
    TWO  --resume dbebd1aa -p "…"      → appended again          (14138 b)

Read back, one linear conversation written by two different accounts:

    user: remember the word PLATYPUS | sid dbebd1aa      ← ACCOUNT-ONE
    asst: SINK-REPLY-10              | sid dbebd1aa
    user: what word                  | sid dbebd1aa      ← ACCOUNT-TWO
    asst: SINK-REPLY-11              | sid dbebd1aa

**So a conversation survives a switch, with the app holding nothing.** That is
the result that makes C interesting.

### What must not be shared

Only `projects/`. Everything else in a config directory is per-account:

| Path | Why it must stay separate |
|---|---|
| `.credentials.json` | the login itself |
| `.claude.json` | holds `oauthAccount`, `userID`, `machineID`, and the account-scoped caches `modelAccessCache`, `passesEligibilityCache`, `cachedUsageUtilization`, `additionalModelCostsCache`, `orgModelDefaultCache` |
| `.claude.json` → `projects.<path>` | `allowedTools`, `hasTrustDialogAccepted`, `lastSessionId`, `lastCost`, `lastTotalInputTokens`, `lastModelUsage` — permission grants and per-account spend |
| `sessions/` | `<n>.json` + `<n>.<hash>.key` pairs; keyed session state |
| `backups/` | `.claude.json.backup.<ts>` — backups *of* the per-account file |
| `history.jsonl` | one account's prompt history |

Sharing `.claude.json` would mean two accounts fighting over one `oauthAccount`
field and one set of trust-dialog approvals. Note that `--continue` does **not**
read `lastSessionId` — account TWO found ONE's conversation from a directory
whose `.claude.json` had never heard of that folder, so it scans `projects/`.
That is precisely why C works.

### What happens when two accounts write the same project at once

This is the point of running two at once, and it is where C breaks.

Both accounts `--continue` in the same folder, concurrently:

      [acctONE] init session=dbebd1aa
      [acctTWO] init session=dbebd1aa        ← both adopted the same conversation

Both wrote into the one file. The result is not corruption — every line parses —
it is worse than that, because it is silent:

    user  parent=ffa46102  uuid=de3a640d   ONE says alpha
    asst  parent=d858cb82  uuid=86ddf7a7   SINK-REPLY-14
    user  parent=86ddf7a7  uuid=e4d1a461   ONE says gamma
    user  parent=ffa46102  uuid=b9680b97   TWO says beta      ← same parent
    asst  parent=081a58a7  uuid=9ab171db   SINK-REPLY-13
    user  parent=9ab171db  uuid=530873cf   TWO says delta

    forked parents (same parent claimed by >1 message): 1
        ffa46102 -> 2 children

**The conversation forked.** Two divergent branches, one session id, one file,
no error anywhere. Whichever branch `--continue` lands on next, the other is
orphaned. Neither account ever saw the other's turns.

The benign case is fine, and worth stating: two accounts starting *fresh* in the
same folder get separate session ids and separate files (`31469456`, `8d68f384`)
with no interaction. The hazard is specific to two accounts continuing the *same*
conversation at the same time.

### Does the app's own reading still work? Mostly — with one trap

Run against the real modules (`transcriptDirs`, `projectPathSpellings`,
`isTranscriptPath`, `listTranscripts`, `readTranscript`, `attributeTranscript`):

    projectPathSpellings(work) = [ '/tmp/tdam/C/work', '/private/tmp/tdam/C/work' ]
    transcriptDirs(work, cfgA) = /tmp/tdam/C/cfgA/projects/-tmp-tdam-C-work
                                 /tmp/tdam/C/cfgA/projects/-private-tmp-tdam-C-work

    cfgA: sees 1 transcript for the folder: [ 'dbebd1aa' ]
    cfgB: sees 1 transcript for the folder: [ 'dbebd1aa' ]     ← both accounts, same conversation

Both spellings and both accounts resolve correctly through the symlink. Then:

    path as the app builds it  : /tmp/tdam/C/cfgA/projects/-private-…/dbebd1aa….jsonl
        isTranscriptPath        = true
    same file via realpath     : /private/tmp/tdam/C/shared-projects/-private-…/dbebd1aa….jsonl
        isTranscriptPath        = false      ← the guard refuses the shared location

`isTranscriptPath` compares string prefixes against `<configDir>/projects` and
`resolve()` does not follow symlinks, so it accepts the path the app builds and
**refuses the same file by its real path.** It works today only because
`transcriptDirs` never realpaths. Anything that ever does — a fs watcher
reporting canonical paths, a `realpathSync` added for tidiness — silently breaks
`chat:load` and `cost:session`. That is a latent trap C would install under a
security guard.

Two further costs, both real:

- **Attribution goes ambiguous.** With two sessions in the shared folder,
  `attributeTranscript` returns `{"kind":"ambiguous","candidates":2,"competing":1}`.
  That is the honest answer, and `ChatView` handles it — but `SessionInspector`
  calls `useSessionTranscript` with no `others` at all, so it takes the newest and
  can show the **other account's** conversation under this session's name. Under A
  that is impossible, because the other account's file is not in this store.
- **Cost per account becomes unanswerable.** A transcript line carries
  `cwd, effort, entrypoint, gitBranch, isSidechain, message, parentUuid,
  permissionMode, promptId, promptSource, sessionId, timestamp, type, userType,
  uuid, version` — **and nothing identifying the account.** `readTranscript` on the
  forked file returns `requests: 7` under one session id, both accounts' usage
  merged into one number. Today the store *is* the attribution; sharing `projects/`
  throws it away and there is nothing in the data to recover it from.

---

## Option D — one shared store, per-session `CLAUDE_CODE_OAUTH_TOKEN`

Not in the brief; it falls out of the precedence chain and is worth recording
because it is the only shape that gets two accounts at once *and* a shared
conversation.

One config directory, no credential in it at all, each session spawned with its
own token in the environment:

    ACCT-ONE  -p "remember PLATYPUS"    → conversation 060ed760
    ACCT-TWO  --continue -p "what word" → appended to 060ed760 (one file, both turns)

    both at once, different folders:
      ACCT-ONE 200 · ACCT-TWO 200

Two accounts side by side, one shared history, conversations that travel — and
because there is no `.credentials.json` in the store, a 401 has nothing to delete,
so B's blast radius disappears.

Its limit is structural: the environment of a running process cannot be changed
from outside, so a session pinned this way **cannot** follow a switch. And it
requires the app to hold a raw OAuth token.

---

## The four questions, per option

| | A — dir per account (today) | B — shared store, credential swapped | C — separate dirs, shared `projects/` | D — shared store, per-session env token |
|---|---|---|---|---|
| **Two accounts at once** | ✅ yes | ❌ no — one store, one credential | ✅ yes | ✅ yes |
| **Conversation survives a switch** | ❌ no — `--continue` starts over, `--resume` says *No conversation found* | ✅ yes — same store | ✅ yes — measured across accounts, both `--continue` and `--resume` | ✅ yes |
| **A running session follows the switch** | ❌ no | ✅ **yes** — measured, per request, on the keychain and on the file | ❌ no — each keeps its own login | ❌ no — env is fixed at spawn |
| **One account hits its limit mid-work** | restate the whole problem under the other account; restart each session by hand | one switch, every session carries on mid-conversation | switch the account the *next* session uses; it `--continue`s the same conversation | same as C, plus the switch can be per session |
| **Does the app hold a credential** | ❌ never | ✅ **yes** — it must write the store | ❌ never | ✅ yes — a raw token in each child's environment |
| **Blast radius of one 401** | that account only | **every session in the app**, instantly | that account only | that session only |

---

## Recommendation

**Build C. Do not build B or D yet — not because they do not work, but because
the app cannot get a token to do them with.**

### Why not B, when B is exactly what he described

B is not a design problem. It works, it is smooth, and it is the CLI's own model.
The problem is upstream of the design: **Terminal Deck has no supported way to
obtain an OAuth token in the first place.** The CLI runs the login flow itself and
writes the result into the login keychain under `Claude
Code-credentials-<hex>`. For the app to swap that, it would have to:

1. **Read the keychain item back** — which is a `security find-generic-password`
   from a binary that is not the one that created the item, i.e. an ACL prompt on
   his screen. That is the exact failure that ended the previous run of this task,
   and it would happen not once but on every account he adds.
2. **Or run its own OAuth flow** against Claude Code's client id — the app
   presenting itself as Claude Code to Anthropic's authorisation server. Not
   something this app should do.
3. **Or ask him to paste a token in** — which works, and is honest, but is the
   opposite of *smooth*: it turns "add an account" from a button into a
   copy-paste chore, and it means the app holds a long-lived subscription
   credential in its own storage forever.

`profiles.ts` states the property plainly — *"this app never holds the
credential, so there is nothing here for DPAPI to protect"* — and every one of
those three routes gives it up. He said he was open to that. The measurements say
he would be paying for it and not getting a working feature, because there is no
route from "he clicks Add account" to "the app has the token" that does not go
through a prompt, an impersonation, or a paste.

**If that changes** — if the CLI grows a supported way to export a token, or
Terminal Deck ships its own signed OAuth client — B becomes the right answer and
the work is small: one shared config dir, write the credential, done. It is
measured and it works. Keep this file.

### Why C, and what "switch once" means under it

C gets the thing he is actually complaining about — *the conversation is gone* —
and gets it with the app holding nothing:

- **Switch once, in Settings.** Every *new* session spawns under the other
  account's config directory.
- **The conversation is not lost.** Because `projects/` is shared, that new
  session `--continue`s exactly where the old one was. Measured: account TWO
  continued account ONE's conversation, and resumed it by id.
- **Running sessions.** They do not follow by themselves — but Terminal Deck owns
  its sessions, which the plain CLI does not. "Move this session to the other
  account" is: stop the agent, respawn under the other config directory with
  `--continue`. Same tab, same terminal, same conversation, new account. From
  where he sits that *is* the session switching. It is the one piece of this that
  the app can do and the CLI cannot.
- **Both accounts stay usable at once**, which he has today and would lose
  under B.

### Three things C must be built with, or it will bite

1. **Do not symlink `~/.claude/projects`.** His own install holds 73 project
   directories of real history; the app must not restructure it (`CLAUDE.md`,
   "never touch the copy someone is working in"). Point it the other way: make
   the shared location **be** `~/.claude/projects`, and symlink each *managed*
   profile's `projects/` into it. Additive, reversible, and his own directory is
   never modified. Side effect worth telling him about: his terminal `claude` and
   his Deck sessions then share one history, which is probably what he wants and
   is definitely something he should be told rather than discover.
2. **Refuse the concurrent continue.** Two accounts continuing one conversation
   at the same time forks it silently, and nothing downstream can detect or repair
   that. The app already knows every session it has open in a folder — that is what
   `siblingStarts` is for. Use it: a session that would `--continue` a conversation
   another live session is already in gets a new conversation instead, or a
   refusal. This is the one C failure with no honest recovery, so it has to be
   prevented rather than reported.
3. **Fix `isTranscriptPath` before sharing anything.** It accepts the symlink path
   and refuses the same file's realpath. Compare realpaths on both sides, or the
   first caller that canonicalises a path takes down chat and cost with a guard
   that looks correct.

And one thing to accept honestly rather than paper over: **under C, "what did this
account spend" stops being answerable from transcripts**, because a transcript
line records nothing about the account. If per-account cost matters to him, that
is the price of the shared folder, and the usage strip should say "this folder"
rather than imply "this account".

---

## What I could not measure

- **`CLAUDE_CODE_HOST_CREDS_FILE`.** The binary carries it, plus
  `CLAUDE_CODE_HOST_AUTH_ENV_VAR`, `CLAUDE_CODE_HOST_AUTH_REFRESH_TIMEOUT_MS` and
  its own diagnostic *"ignoring CLAUDE_CODE_HOST_CREDS_FILE with group/other-readable
  mode or wrong owner"*. At mode 600, correct owner, `claudeAiOauth` shape, it was
  ignored (`Not logged in`), with or without the SDK companion flag. It would give
  the best of everything — a per-session credential *file* the app can rewrite, so
  running sessions follow **and** two accounts run at once. **What would settle
  it:** the shape it expects, from the SDK/background-agent path that uses it
  (`CLAUDE_BG_AUTH_SNAPSHOT_PATH` sits beside it). **Do not build on it either
  way** — it is undocumented, and this repo already has the rule, written out for
  `GEMINI_FORCE_FILE_STORAGE` in `provider-accounts.ts`: an undocumented flag that
  is renamed in a later release fails silently and takes the login with it.
- **Windows.** `CLAUDE_CODE_FORCE_WINDOWS_CREDMAN` exists in the binary, which
  strongly suggests Windows uses Credential Manager and **not** a file.
  `credential-store.ts` currently infers isolation on Windows from the presence of
  `<configDir>/.credentials.json`; if Credential Manager is the real store, that
  inference is reporting on a file the CLI may not be using. **What would settle
  it:** the same `security`-shim trick on a Windows box, shimming whatever the CLI
  shells out to, or simply `claude auth status` in a fresh `CLAUDE_CONFIG_DIR`
  after a login. Nothing in this repo can run there.
- **Whether a real token behaves like a synthetic one on refresh.** My tokens
  cannot be refreshed, so any code path that chose to refresh produced *"OAuth
  session expired and could not be refreshed"* and, once, deleted the credential
  file. The switching results are unaffected — they were taken on requests that
  completed — but the refresh path itself is untested with a live token.
- **Whether Terminal Deck writing `Claude Code-credentials-<hex>` prompts.** It
  almost certainly does, the first time, because the item's ACL names the CLI and
  not this app. **Deliberately not tested** — that prompt on his screen is the
  thing this whole exercise was told to avoid, and the answer is not worth the
  interruption. It is also the load-bearing reason B is not recommended, so if
  anyone wants to overturn that, this is the measurement to make, and **he should
  make it himself**, on purpose, knowing a prompt is coming.
- **Anything requiring an interactive `claude auth login`.** It opens a browser
  and steals focus. Every result above was obtained without one.

---

## Reproducing this

Everything ran under `/tmp/tdam/`, which has been removed. The rig is three small
pieces and worth rebuilding if any of this is ever revisited:

1. **`sink.mjs`** — HTTP server on `127.0.0.1:8919`; logs `Authorization` per
   request; answers `POST /v1/messages` with a valid SSE stream; can be told to
   return `429` or `401` for a given token. Point the CLI at it with
   `ANTHROPIC_BASE_URL`.
2. **A `security` shim** first on `PATH`, printing a `claudeAiOauth` JSON blob
   read from a file. This is what makes the macOS keychain measurable without
   touching the real one — and it is the only reason the keychain half of this
   document is *measured* rather than reasoned.
3. **`claude -p --input-format stream-json --output-format stream-json --verbose`**
   — a session that stays alive across many turns, so "does a *running* session
   follow" is a real question with a real answer.

Scrub the inherited `CLAUDE_*` variables before spawning (`CLAUDECODE`,
`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`, …) or the child inherits this
session's identity.
