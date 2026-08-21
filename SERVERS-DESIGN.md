# Machines: Servers

Asad, 2026-08-18. The feature is in one sentence of his:

> *"Full control to any server, should be universal to be able to run most of
> the types, where we can see everything exists in the server and we can easily
> control and drive here… but very comfortable to non technical people."*

And its placement is in another:

> *"Let's replace Remote with **Machines**, and inside Machines we can have
> **server** and **remote other devices**."*

Five rules were set alongside those, in his words, and every decision in this
document is settled by one of them rather than by taste:

1. **It must be usable by someone who knows nothing about servers.** *"User
   friendly with a smooth and simple user experience for non technical people
   who knows nothing about server."*
2. **It is a control room, not a status page.** *"It's not existing to only
   connect, it exists here to be controlled too, so we need its cockpit or
   control room."*
3. **It must not clutter the working view.** *"We will place it somewhere
   without making our tool more busy UI, so make a placement to reach to its own
   private area."*
4. **Nothing may assume this machine, or any machine.** *"Make sure we don't
   design it as per our design, it's gonna be used for all so they might have
   different settings, we need something common."*
5. **Weight matters.** Measured, so that it can stop being an open question: the
   installed app is 291 MB and the entire renderer is 3.7 MB, so bytes are not
   the constraint. The transport chosen below adds **1.04 MB** to a 24.7 MB
   `app.asar`. What is actually at stake is *runtime* cost, and the standing
   rule that governs it is his: **events, not polling.** §5.4 is how this
   feature obeys it.

Rule 4 is the one with a history. It has bitten this project before — see *judge
as a product, not his setup* — and it is the reason §3 exists in the shape it
does. **Detect, do not assume.** Not every server has systemd; plenty are
OpenRC, containers, or BSD. Not every server has a container runtime, or the
same package manager, or a web server. A card that lies about a stranger's
server is worse than a card that is absent.

---

## 1 · The vocabulary

Pick the words once. Every agent building against this document uses these and
no synonyms. Where the code already uses a different word, §1.3 says what
happens to it.

### 1.1 The three nouns that matter

| Word | What it means to the person | How they can tell |
|---|---|---|
| **Machine** | Anything that is not this computer and that this app can reach. The umbrella, and the name of the rail row. | It is the panel. There are two kinds inside it. |
| **Device** | One of *your own* computers or phones, that you also sit at. Paired both ways with a six-digit code. | **You sit at it.** It runs this app too. |
| **Server** | A computer that runs things for other people. You do not sit at it; you rent it or own it and it is always on. | **Nobody sits at it.** It does not run this app and never will. |

The discriminator is deliberately a *mechanical* fact and not a matter of taste,
because a person has to be able to apply it without being taught: **a device
runs Terminal Deck on the far end, a server does not.** That is why the pairing
ceremonies differ and cannot be merged — a device is paired by a code minted by
the app at the other end, which presupposes the app is there; a server is
reached by an address and a sign-in, because there is nothing at the far end to
mint anything. Two ceremonies, one panel, and the panel says which is which.

This also settles a question that would otherwise be argued three ways: **a
server is never "paired" and a device is never "signed in to".** Use the verb
that belongs to the kind.

### 1.2 The nouns inside a server

These are the cards in the middle zone. Three nouns, and a heading for the
things that are none of them.

| Word | Definition, exactly | The give-away that classifies it |
|---|---|---|
| **Site** | Something with a web address that people visit. | It answers on a port that a web server is holding, or a reverse proxy names it. It has a real URL we can put behind an Open button. |
| **App** | A program the server keeps running that has no web address of its own. | A service or container the server restarts on its own, not matched to a URL. |
| **Database** | Where information is kept for the sites and apps. | Its program name or image is one of the known engines *and* it is listening. |
| *(no fourth noun)* | Anything found running that we cannot classify goes under a heading — **Other things running** — and each row is named by whatever the server called it. | Everything else. |

There is no fourth noun on purpose. The temptation is to add "service" for the
unclassified remainder, and it must be resisted: "service" is a word a
non-technical person does not own, and once it exists every ambiguous case gets
filed under it until it is the largest group on the page. A heading costs
nothing and admits ignorance honestly, which is what rule 4 asks for.

### 1.3 Words the code uses today, and what happens to them

This is the collision that will otherwise produce three different vocabularies,
so it is settled here rather than discovered later.

**`machine` in the existing code means what this document calls a device.**
`src/main/remote/machines/`, `machines.json`, `MachineLinks.tsx` and the
`Machine` interface in `renderer/machines/types.ts` all describe a paired
desktop. That is the narrower thing; the word is being promoted to the umbrella.

> **The rename is in copy only. Not one stored filename, IPC channel or type
> name changes.**
>
> `machines.json` holds a bearer credential per paired desktop. Renaming the
> file drops everybody's pairings at their next launch, silently, and they would
> have to re-pair from two keyboards to find out why. The identical argument is
> already written down one directory over, about the `hooks` panel id: *"it is
> what a saved rail position and the feature registry are keyed on, and renaming
> it would silently drop somebody back to Overview at their next launch. Only
> what a person reads changed."*
>
> So: `Machine`, `MachineLinkState`, `listMachines`, `pairMachine` and the rest
> keep their names in the code and mean *device* in prose. A comment at the top
> of `renderer/machines/types.ts` says so, in one sentence, so the next reader
> is not left to infer it.

**`Remote` as the rail row becomes `Machines`.** The `PanelId` member stays
`'remote'`, for the reason above. Only `label` in `panels.ts` changes, and the
`blurb` with it — from *"Phones and computers that can reach this machine"* to
something that covers both kinds, because the row now leads to servers too.

### 1.4 Words never used in copy

`daemon`, `unit`, `process`, `PID`, `sudo`, `root`, `systemd`, `stdout`,
`SIGTERM`, `port` in the top two zones, `SSH` anywhere except the one hint in
§2.5. These describe the mechanism to someone who already knows it, and rule 1
says the reader does not.

The rule is **not** that a real program's name may never appear. `src/neutral-naming.test.ts`
bans naming an AI tool or editor, and its own argument draws the line this
feature needs: the rule *"bans naming a vendor while describing a mechanism any
vendor could serve; naming the vendor you are actually talking to is not that."*
So:

- The **card** speaks in the person's words. *Your website.* *Restart.*
- The **detail line under it** names what was actually found, because that is a
  fact about their server and they are entitled to it. *Served by nginx.*
  *Running in a container.*

Naming a thing we measured is honesty. Naming a thing we assumed is the bug this
whole document is arranged against.

---

## 2 · The transport

**Bundle `ssh2`. Do not shell out to the system `ssh`.**

### 2.1 Why not the system `ssh`

Shelling out inherits whatever each person happens to have: their `~/.ssh/config`,
their agent, their key formats, their `known_hosts`, their corporate policy, and
their OpenSSH version's defaults. OpenSSH 8.8 dropped `ssh-rsa` signatures;
older builds did not. Windows ships the client as an optional feature that
policy can remove. That is maximum variance across exactly the population rule 4
is about, and every failure would be unreproducible from here. A bundled
implementation gives every user the same version, the same defaults and the same
error messages.

The baseline flow is therefore three things anyone can answer — **address,
username, and a password or a pasted key** — with nothing configured in advance.
If somebody happens to have an agent or a config file, read it as a
*convenience*, never as a requirement. §2.5.

### 2.2 The candidates, measured

| | `ssh2` | `@microsoft/dev-tunnels-ssh` | `node-ssh`, `ssh2-promise`, `ssh2-sftp-client`, `simple-ssh` |
|---|---|---|---|
| Licence | MIT | MIT | MIT / Apache-2.0 |
| Latest | 1.17.0, published 2026-05-13 | 3.12.40, published 2026-07-29 | — |
| Installed, no compiler | **1.8 MB, 5 packages, 199 ms** | 2.8 MB, 14 packages | — |
| Native files after install | **none** | none | — |
| High-level interactive shell | **`conn.shell({term, cols, rows})`** | none — `pty-req` exists only as a message type; you hand-roll the channel | — |
| Also provides | `exec`, `sftp`, `forwardOut`, agent auth, keyboard-interactive | — | — |
| Verdict | **chosen** | rejected | rejected: every one is a wrapper *over* `ssh2`, so it adds a dependency and a second opinion about defaults without adding a capability |

`@microsoft/dev-tunnels-ssh` is the only genuinely independent implementation and
it was measured rather than dismissed. It is rejected on three grounds, in order
of weight. It has **no high-level shell API** — the interactive terminal, which
is the single most important thing this feature does, would be hand-rolled from
raw `pty-req` / `shell` / `window-change` messages, which is the largest and
riskiest part of an SSH client to write and the part `ssh2` has had in
production for a decade. Its dependency tree is a **browser crypto stack**
(`buffer`, `base64-js`, `ieee754`, `bn.js`, `brorand`, `randombytes`,
`diffie-hellman`, `miller-rabin`), which means it does its own bignum arithmetic
rather than deferring to the runtime's crypto — slower, and, decisively, it does
not inherit the self-correcting behaviour described in §2.3. And it is built for
Microsoft's dev tunnels rather than for connecting to arbitrary servers, which
is visible in it dragging `vscode-jsonrpc` along.

No maintained N-API SSH client exists. `libssh2` was unpublished from npm in
2021; `ssh2-streams` has been unmaintained since 2022. The field is `ssh2` and
wrappers of `ssh2`.

### 2.3 The trap this repository has already fallen into, and why `ssh2` is immune

**Electron links BoringSSL, and BoringSSL has no ChaCha of any kind.** That fact
already killed a whole feature in this repository once: every sealed-channel
handshake threw silently in the app while 3,628 Node tests stayed green, because
the suite ran under a Node that links OpenSSL. `scripts/check-electron-crypto.mjs`
exists because of it.

It is a live risk here, not a theoretical one. Measured on Electron 41.10.5:

```
chacha20            false
chacha20-poly1305   false
aes-128-ctr         true      aes-128-gcm   true
aes-256-ctr         true      aes-256-gcm   true
```

And the server this was proved against — Ubuntu 24.04, OpenSSH 9.6p1 — offers
`chacha20-poly1305@openssh.com` **first** in its cipher list.

`ssh2` is immune by construction: `lib/protocol/constants.js` builds
`DEFAULT_CIPHER` and then filters it through the runtime's own
`crypto.getCiphers()`. Measured, same module, two runtimes:

```
node 26.5.1    aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr, chacha20-poly1305
electron 41.10.5  aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr
```

It drops the cipher it cannot perform, on its own, with no configuration. This
is the single strongest reason to prefer it over an implementation that carries
its own crypto.

**This must be pinned by a test**, because it is exactly the class of thing that
regresses invisibly. `scripts/check-electron-crypto.mjs` already runs a probe
under Electron's own Node and already fails rather than skipping; the server
transport gets a case in that harness asserting that the negotiated cipher list
under Electron is non-empty and contains no ChaCha. A green `vitest` run cannot
report on this and must not be trusted to.

### 2.4 Proof it connects

Run against `terminaldeck-server` — a real Hetzner box, Ubuntu 24.04, OpenSSH
9.6p1, over the public internet — under **Electron 41.10.5's own Node**, with
`ssh2` installed the way a user with no compiler gets it (`--ignore-scripts
--omit=optional`, zero native files):

| Test | Result |
|---|---|
| Key auth, ed25519 from a file | **PASS**, 5.8 s |
| Password auth, real account | **PASS**, 5.4 s |
| Wrong password | **refused**, `client-authentication: All configured authentication methods failed` |
| Running a command | **PASS** — `exec` exit 0, correct user, correct hostname |
| Interactive shell | **PASS** — real pty (`tty` answered `/dev/pts/N`), window size honoured (`tput cols` answered 100) |
| Negotiated | kex `curve25519-sha256@libssh.org`, cipher `aes128-gcm@openssh.com`, host key `ssh-ed25519` |
| Host key fingerprint | `SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0` — **identical** to `ssh-keyscan` and to the system's own `known_hosts` |

That last row is the one that matters for §3.6: the fingerprint `ssh2` computes
is byte-identical to the one OpenSSH computes, so a fingerprint this app shows a
person is one they can check against any other tool.

Key parsing, also under Electron — every format the "paste a key" flow will meet:

| Format | Result |
|---|---|
| ed25519, OpenSSH format | PASS |
| ed25519, encrypted | PASS with passphrase; refused without, refused with the wrong one |
| RSA 3072 / RSA 2048 encrypted / ECDSA nistp256 | PASS |
| RSA in legacy PEM format | PASS |

And it distinguishes the two failures in words we can hand straight to a person:
*"Encrypted private OpenSSH key detected, but no passphrase given"* versus
*"integrity check failed -- bad passphrase?"*. That distinction is what lets the
sign-in step ask for a passphrase instead of just saying no.

### 2.5 What ships, and what must not

**Add `"ssh2": "^1.17.0"` to `dependencies` and nothing else.** `node-ssh` and
friends are wrappers; we want the defaults we measured, not somebody else's.

> **Install it without its optional dependencies, and keep them out.**
>
> `ssh2` declares `cpu-features` and `nan` as `optionalDependencies` and ships a
> postinstall that tries `node-gyp` on a bundled crypto binding. Measured
> consequences on this Mac:
>
> - The bundled binding **fails to build** and says so — harmlessly. `ssh2`
>   reports `bindingAvailable: false` and works in pure JS.
> - `cpu-features` **does** build, and `electron-builder install-app-deps` then
>   picks it up and rebuilds it for Electron's ABI. It succeeded here because
>   this machine has the Xcode command line tools.
>
> It should still be kept out, and the reason is a measurement rather than a
> worry. `cpu-features` exists solely to reorder the cipher preference list
> according to whether the CPU has AES-NI. Under Electron the list is AES-only
> regardless, and the two lists are **byte-identical** with and without it:
>
> ```
> with cpu-features:    aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr
> without cpu-features: aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr
> ```
>
> So it buys nothing and costs a third native module in a repository whose
> `BUILDING.md` documents exactly two and their packaging quirks at length. A
> native module that changes no behaviour is pure surface area.

**`electron-builder.yml` needs no change at all.** Its existing rule at line 31,
`'!**/node_modules/*/{test,tests,__tests__,example,examples,benchmark,benchmarks}/**'`,
already drops `ssh2/test` (604 KB) and `ssh2/examples`, and both platform blocks
restate it. Verify rather than assume: after the first packaged build, `node
scripts/check-package.mjs mac` must still pass.

**Measured cost of shipping it:** 69 files, **1.04 MB**, against a 24.7 MB
`app.asar` — +4.2%, and well under half a megabyte on the compressed DMG.

`package.json` is a file no agent may edit while others are working, per
`CLAUDE.md`. The dependency line is therefore a **wiring instruction handed back
to the coordinator**, not an edit any of the three agents makes. §8.

---

## 3 · The facts model

This is the section rule 4 is about. Every fact has **three** states, never two,
and the third is not an error — it is the honest answer for a server that does
not work the way the question assumes.

### 3.1 The type every fact has

```ts
/**
 * One thing the app believes about a server, and the grounds for believing it.
 *
 * The third state is the whole point. `no` and `cannot` look the same on a
 * screen that only models presence — both draw an empty card — and they mean
 * completely different things to the person reading it. "There is no web server
 * here" is a fact about their server. "This account is not allowed to ask" is a
 * fact about their sign-in, and the fix is different.
 */
export type Fact<T> =
  | { known: 'yes'; value: T; measuredAt: number; how: string }
  | { known: 'no'; measuredAt: number; how: string }
  | { known: 'cannot'; measuredAt: number; why: string }
```

- `how` names the actual check that ran, in plain words — *"asked what is
  listening"*. It is shown, not hidden, behind the detail disclosure on each
  card. A person who wonders why the app thinks something is entitled to the
  answer, and an agent that has to debug a wrong card on a stranger's box has
  nothing else to go on.
- `why` on `cannot` is the sentence shown *in place of* the value. Never draw a
  blank, a zero, or a dash where a `cannot` lives. A dash reads as "zero"; that
  is how a card starts lying.
- `measuredAt` is stamped on all three, because §5.4 shows the age rather than
  re-polling.

**There is no fourth state and no `undefined`.** A fact that has not been
gathered yet is simply absent from the record, and the card renders its own
loading state. A `Fact` in hand is always one of the three.

### 3.2 The probe

One round trip, one POSIX `sh` script, no assumption of `bash`. Measured at
**179 ms** on the real box. Every line is `key=value`; anything the server
cannot answer says `unknown`, and `unknown` becomes `cannot` on this side.

The script below is the measured one, not a sketch. It ran on Ubuntu 24.04 with
systemd, and inside Alpine and Debian containers with no init system at all, and
produced correct answers in all three.

```sh
p() { printf '%s=%s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

p os      "$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || uname -s )"
p kernel  "$(uname -sr 2>/dev/null || echo unknown)"
p arch    "$(uname -m 2>/dev/null || echo unknown)"
p user    "$(id -un 2>/dev/null || echo unknown)"

# privilege
if   [ "$(id -u 2>/dev/null)" = "0" ];            then p root yes
elif have sudo && sudo -n true 2>/dev/null;       then p root sudo-nopasswd
elif have sudo;                                   then p root sudo-password
else                                                   p root no; fi

# init system — detected, never assumed
if   [ -d /run/systemd/system ];                  then p init systemd
elif have rc-status;                              then p init openrc
elif [ "$(uname -s)" = "Darwin" ];                then p init launchd
elif [ -f /etc/inittab ] && have service;         then p init sysvinit
elif [ -f /.dockerenv ] || grep -qa 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null; then p init container-none
else                                                   p init unknown; fi

# container runtime
if   have docker && docker info >/dev/null 2>&1;  then p containers docker
elif have podman && podman info >/dev/null 2>&1;  then p containers podman
elif have docker || have podman;                  then p containers present-no-permission
else                                                   p containers none; fi

# package manager, web server, resources, listeners — each falls back to unknown
for m in apt-get dnf yum apk pacman zypper pkg brew; do have "$m" && { p packages "$m"; break; }; done
for w in nginx apache2 httpd caddy lighttpd;      do have "$w" && { p web "$w"; break; }; done
p disk    "$(df -Pk / 2>/dev/null | awk 'NR==2{print $3"/"$2"KB"}' || echo unknown)"
p cpus    "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
if   have ss;      then p listeners "$(ss -H -tlnp 2>/dev/null | wc -l | tr -d ' ')"
elif have netstat; then p listeners "$(netstat -tln 2>/dev/null | grep -c LISTEN)"
else                    p listeners unknown; fi
```

### 3.3 What it actually answered, on three different machines

This table is the evidence for rule 4 and should be read before writing any card.

| Fact | Ubuntu 24.04, root | Ubuntu 24.04, ordinary account | Alpine container | Debian slim container |
|---|---|---|---|---|
| `os` | Ubuntu 24.04.4 LTS | Ubuntu 24.04.4 LTS | Alpine Linux v3.24 | Debian GNU/Linux 12 |
| `root` | `yes` | `sudo-password` | `yes` | `yes` |
| `init` | `systemd` | `systemd` | **`container-none`** | **`container-none`** |
| `containers` | `docker` | **`present-no-permission`** | `none` | `none` |
| `packages` | `apt-get` | `apt-get` | `apk` | `apt-get` |
| `web` | `caddy` | `caddy` | `none` | `none` |
| `listeners` | `9` | `9` | `0` | **`unknown`** |

The OpenRC branch was proved separately by installing `openrc` into an Alpine
container, where it correctly answered `init=openrc`. Three of these cells are
the third state doing its job, and each would have been a lie under a two-state
model: `present-no-permission` would have been "no containers", `unknown`
listeners would have been "0 listeners" — on a box where the tool to count them
simply is not installed.

### 3.4 Two traps found while measuring, which cards must not fall into

> **Inside a container, `df`, `/proc/meminfo`, `/proc/loadavg` and `/proc/uptime`
> report the *host's* numbers, not the container's.**
>
> Measured: the Alpine container reported 39 GB of disk and a 232,603-second
> uptime, which are the Hetzner box's, not its own. A "Disk 16% full" figure on
> a container card is therefore not merely imprecise, it is about a different
> computer.
>
> So: **when `init` is `container-none`, disk, memory, load and uptime are
> `cannot`, with the reason *"this is running inside a container, so these
> numbers would be the host computer's, not this one's."*** Do not show them
> and do not correct them. Reading cgroup limits to get the real figures is a
> reasonable v2; inventing them in v1 is the exact failure this document exists
> to prevent.

> **`sudo-password` and "not permitted to use sudo at all" are indistinguishable
> without trying.**
>
> Measured: an ordinary account with the `sudo` binary present but no entry in
> the sudoers file answers `sudo-password`, identically to an account that
> merely needs to type one. There is no offline check that separates them.
>
> So the model must never *promise* an action will work on the strength of
> `sudo-password`. It is not a permission, it is an unknown. §4.5 says what the
> UI does with it: the action is offered, the failure is caught, and the
> resulting sentence is *"this sign-in isn't allowed to do that on this
> server"* — which is true in both cases.

### 3.5 From facts to cards

The middle zone is built by classification, and every classification has an
"unclassified" outcome that is drawn rather than dropped.

| Card kind | Requires | If the requirement is missing |
|---|---|---|
| **Site** | a URL we can actually open — from the reverse proxy's own config, or a port answering HTTP | it is not a Site. It falls through to App, or to *Other things running*. |
| **App** | a named thing the server restarts on its own: a service unit, an OpenRC service, or a container | falls through to *Other things running* |
| **Database** | a known engine name **and** it is listening | falls through to App |
| **Other things running** | nothing — this is the remainder | — |

**When `init` is `unknown` and `containers` is `none`, there are no cards at
all**, and the middle zone says so in one sentence: *"We couldn't find anything
this server is set up to keep running. You can still open a terminal below."*
That empty state is a supported outcome, not a failure — a BSD box, a bare
container, or a machine using an init system this app has never heard of all
land there, and all three are somebody's real server.

### 3.6 The host key

The first connection to a server records its host key fingerprint. Every later
connection checks it. If it has changed, **the connection stops and nothing is
offered but the fingerprint and a way to cancel** — no "connect anyway" button
on the first screen, because the whole value of the check is that it is not
click-through.

The fingerprint we compute is provably the same string other tools show — §2.4
— so the sentence can be *"the server at this address answered with a different
identity than last time"* and a person can go and check it independently.

`hostVerifier` is where this lands, and it must be implemented on **every**
connection, including the ones the copilot opens. A connection path that skips
it is a hole with no dialog attached.

### 3.7 Where the credentials live

A password, a private key, or a key passphrase for a server is the same class of
secret as a saved website login, and the app already has exactly one right answer
for that: `safeStorage` (Keychain on macOS, DPAPI on Windows) written through
`writeSecretFile` from `src/main/remote/secret-file.ts`, which is the module
that already carries the argument about atomicity, `wx`, fsync-before-rename and
Windows ACLs. `browser-passwords.ts` is the pattern to copy.

Two rules on top of it:

- **Nothing about a credential crosses the preload bridge.** `renderer/machines/types.ts`
  already states this for paired devices — *"a screen that held one would be a
  screenshot away from publishing it"* — and it holds identically here. The
  renderer learns that a server has a saved sign-in, and never what it is.
- **A pasted key is offered a "don't save" option and that option is honoured
  for the session only.** Somebody trying this out on a borrowed machine should
  not have to trust us to be careful.

---

## 4 · The actions

His rule, in his words: **every action is a sentence with a consequence, and
nothing destructive happens without a way back.** *"Restart your website — it'll
be offline about five seconds."*

### 4.1 The three classes, and the fourth that does not ship

Every action in v1 is one of three classes. There is no fourth class in v1, and
that is the mechanism by which the second half of his rule is kept — not by
dialogs, but by construction.

| Class | Meaning | Confirmation |
|---|---|---|
| **Safe** | Changes nothing. Reading, opening, listing. | none |
| **Reversible** | One press puts it back exactly as it was, and the button that does it is named in the confirmation. | one sentence, one button |
| **Kept** | We record what it takes to go back *before* we change anything, and refuse to proceed if we could not. | one sentence, one button, plus what was recorded |

> **Anything genuinely irreversible is not in v1.**
>
> The alternative — shipping a destructive action behind a scarier dialog — is
> the thing that fails in practice, and this repository has already written down
> why in `deck-control/catalogue.ts`: a refusal that arrives after a run of
> harmless confirmations *"has already trained them to click yes."* Deleting a
> site, removing a database, and anything that runs `rm` are therefore absent
> from the action list rather than guarded. §7.

**A control that cannot act is removed, or disabled with a stated reason.** Never
drawn hopefully. If the facts say `cannot`, the button is not there, and the card
says which fact was missing.

### 4.2 The list

Every row is a real action with a real implementation. `{name}` is the person's
own name for the thing, never an internal id.

| Action | Class | The sentence shown | The way back |
|---|---|---|---|
| **Open** | Safe | — (opens the address in a browser) | — |
| **Logs** | Safe | — (shows the last 200 lines, newest last) | — |
| **Start** | Reversible | *"Start {name}. It'll be running again in a few seconds."* | **Stop** |
| **Restart** | Reversible | *"Restart {name}. It'll be offline for about five seconds while it starts again."* | it returns on its own; **Start** if it does not |
| **Stop** | Reversible | *"Stop {name}. It'll be off until you start it again — anyone visiting will see an error."* | **Start** |
| **Update** (container) | Kept | *"Update {name} to the newest version. It'll be offline for about ten seconds. We'll keep the current version so you can go back."* | **Go back to the previous version** — recreate from the recorded image digest |
| **Update** (from a repository) | Kept | *"Update {name} to the latest code. It'll restart, and be offline for about five seconds. We'll remember where it is now so you can go back."* | **Go back** — reset to the recorded commit and restart |
| **Backup** (database) | Safe | *"Copy everything in {name} to your computer. Nothing on the server changes."* | — (it only reads) |
| **Copy address** | Safe | — | — |

Notes that decide implementations rather than describe them:

- **Restart is one command, chosen from the detected `init` fact**, and there is
  no fallback chain. If `init` is `unknown`, the card has no Restart button and
  says *"we can't tell how this server starts and stops things, so we're not
  going to guess."* Guessing here means running a command that does something
  else on a machine we do not understand.
- **Update is per-card and never machine-wide.** "Update everything on this
  server" is an OS package upgrade, which cannot be undone, so it is not an
  action — it is a *number* in the third zone. §5.3.
- **Backup requires a recognised engine.** If the database's engine is not one
  we know how to dump, there is no Backup button, and the reason is written on
  the card: *"we can't tell what kind of database this is, so we don't know how
  to copy it safely."* An unrecognised engine dumped with the wrong tool
  produces a file that looks like a backup and is not one, which is worse than
  no button by a wide margin.
- **Logs are read-only and bounded.** Last 200 lines, fetched once when opened,
  with a **Load more** rather than a follow-mode. Follow-mode is a stream that
  stays open, which is the polling-shaped thing rule 5 is about; it is v2 and it
  is named in §7 so nobody adds it by accident.

### 4.3 The consequence sentence is written where the action is implemented

Not in the renderer. This is the same constraint the copilot's consent path
already lives under, and `remote/copilot-consent.ts` states the reason: a client
that wrote its own sentence *"would be describing an action it did not
implement, and the first time the two drifted somebody would approve one thing
having read another."*

So each action exposes `summary(args): string` — the same shape as
`ToolSpec.summary` in `deck-control/catalogue.ts` — and the confirmation dialog,
the action log and the copilot's consent question all render that one string.
Three surfaces, one sentence, written by the code that will do the thing.

### 4.4 Timings in the sentences are honest or absent

*"About five seconds"* is a claim. Where it is a reasonable claim for a restart,
say it. Where it is not — a container pulling a new image over an unknown link
— say *"this can take a minute or two"* rather than inventing a number. A
consequence sentence that is confidently wrong is worse than a vague one,
because the person planned around it.

### 4.5 Every action can fail, and the failure is a sentence too

Measured failure signals from `ssh2`, under Electron, against the real box —
these are the actual strings, not invented ones, and each maps to one sentence:

| What happened | Signal | What the person reads |
|---|---|---|
| Address doesn't exist | `ENOTFOUND` | *"We can't find a computer at that address. Check the address for a typo."* |
| Nothing answering | `client-timeout`, *"Timed out while waiting for handshake"* | *"That address didn't answer. The server may be off, or a firewall may be blocking it."* |
| Something else on that port | `protocol`, *"Connection lost before handshake"* | *"Something answered, but it isn't a server we can sign in to."* |
| Sign-in refused | `client-authentication` | *"That sign-in was refused. Check the username and the password or key."* |
| Encrypted key, no passphrase | throws *"Encrypted private OpenSSH key detected, but no passphrase given"* | *"That key is locked. What's its passphrase?"* — and the passphrase field appears |
| Wrong passphrase | throws *"integrity check failed -- bad passphrase?"* | *"That passphrase doesn't open the key."* |
| Not a key | throws *"Unsupported key format"* | *"That doesn't look like a key. Paste the whole file, including the first and last lines."* |
| Nothing in common | `handshake`, *"no matching key exchange algorithm"* | *"This server is set up in a way we can't connect to."* |
| Host key changed | our own `hostVerifier` returning false | §3.6 |
| Action refused by the server | non-zero exit from the action's command | *"This sign-in isn't allowed to do that on this server."* |

> **The app must never claim to know which half of a sign-in was wrong.** SSH
> deliberately does not tell a client whether the username or the credential was
> the problem — measured: an unknown username and an unauthorised key produce
> the *identical* message. A sentence saying "that password is wrong" would be a
> guess, and the guess would send someone to change the right password.

### 4.6 The terminal is an action too, and it is the honest floor

Every server gets a real interactive shell, in the third zone. It is the answer
to *"we can see everything exists in the server"* for every case the cards do not
cover, and it is what makes the empty state of §3.5 acceptable rather than a
dead end.

It is `conn.shell({ term: 'xterm-256color', cols, rows })` — proved in §2.4 to
give a genuine pty that honours the window size — rendered through the `@xterm/*`
stack this app already ships, and resized through the returned channel's
`setWindow`. Nothing new is needed for it.

> **`shell()` takes `{ cols, rows }`; `setWindow()` takes `(rows, cols, height,
> width)`.** The order is reversed between the two, in the same library, on the
> same channel — `node_modules/ssh2/lib/Channel.js:221`. Getting it wrong
> produces a terminal that works until the window is resized and then wraps
> every line at the wrong column, which reads as a rendering bug rather than as
> a swapped pair of arguments. Pin it with a test that resizes to a
> deliberately non-square size and reads `tput cols` back from the far end;
> a square test window would pass either way.

The *door* to one lives one door further in, deliberately (§5.3). The terminal
itself is a session in the window, with a row in the rail and a pill in the
strip, and the control cluster is withdrawn from it — §5.5.1 carries that
reversal and the argument for both halves of it.

---

## 5 · The three zones

The ordering **is** the design. Sharp things live one door further in so the
everyday surface stays calm. A person who opens a server to check on it should
be able to answer "is everything OK" without reading anything they do not
understand, and without being one mis-click from stopping their website.

### 5.1 Zone one — is everything OK

**One sentence, a few numbers, nothing to press.**

The sentence is the whole zone's job, and it is composed from facts, never from
optimism:

- all cards running, no unread problem → *"Everything's running."*
- something stopped → *"{name} isn't running."* (one thing named, not a count)
- more than one → *"2 things aren't running."*
- we could not tell → *"We couldn't check everything on this server."* with the
  reason available, never a green tick over a `cannot`.

Then at most four numbers, each of which is dropped entirely — not zeroed, not
dashed — when its fact is `cannot`. On a container that is *all four of them*,
per §3.4, and the zone correctly shrinks to the sentence alone.

**Nothing in this zone is clickable.** The moment it has a button it is a
control surface and the person has to read it carefully. It is the one part of
the page that can be glanced at.

### 5.2 Zone two — the things they own

A card per Site, App and Database, in that order, then *Other things running*.

Each card is: the name, one line of detail naming what was actually found
(§1.4), a running/stopped indicator, and the actions from §4.2 that its facts
support. Nothing else. A card is a fill with a radius and no outline, and the
run of cards has no rules between them — `CLAUDE.md`'s standing instruction:
*"separate with space, then with a tint, and only then with a line."*

**Every button on a card is either a real action or absent.** Not greyed
hopefully, not present-with-a-tooltip. The one permitted exception is a button
disabled *with its reason written on the card*, which is the §4.2 Backup case.

### 5.3 Zone three — the machine itself, behind one more click

Ports, keys, updates, the terminal. One control opens it — a row at the bottom
of the server's page reading **Advanced**, and nothing else on the page hints at
it.

What lives here, and why each is here rather than up in zone two:

| | Why it is behind the door |
|---|---|
| **The way to a terminal** | It is unbounded. Everything else on the page is a named action with a known consequence; this is a shell, and a shell has no consequence sentence. What is behind the door is the *door*: pressing it opens an ordinary session in the window — a row in the rail, a pill in the strip — rather than a rectangle on this page. See §5.5.1, which reverses what §5.5 originally said and keeps the half of it that was right. |
| **What's listening** (ports) | Requires the word "port" to be useful, which §1.4 bans from the calm surface. |
| **Sign-in and keys** | Changing how you get in is how you lock yourself out. |
| **Operating system updates** | The count is shown; installing them is not offered in v1, because it cannot be undone (§4.1 and §7). |
| **The host key fingerprint** | Only ever wanted when checking something specific. |
| **Forget this server** | Destructive to *our* record only — it removes stored credentials and nothing on the server. Its sentence says exactly that, because "forget" beside a list of the person's websites will read as "delete" to somebody who does not know better. |

The door is one click, not a hidden gesture. Rule 3 asks for *"its own private
area"*, not for a secret.

### 5.4 When it connects, and when it does not

This is where rule 5 is actually paid, and his standing rule decides it:
**events, not polling.** *"Webhooks/APIs/push over crons and timers — they make
the system heavier."*

- **Opening a server's page opens one connection.** Closing it closes the
  connection. There is no background connection, no timer, no keep-alive sweep,
  and no connection at all to a server nobody is looking at.
- **Facts are gathered once per connection**, in the single round trip of §3.2,
  and then *cached with `measuredAt`*. The zone-one sentence for a server you
  are not looking at is the last one we measured, shown with its age — *"as of
  20 minutes ago"* — which is true, cheap, and better than a number that is
  fresh because something has been asking all night.
- **A refresh is a press, not a tick.** One control, in zone one's corner,
  because a person who wants to know *now* should be able to ask.
- **The one long-lived thing is the terminal**, and only while it is on screen.
  A pty is inherently a stream; that is not polling.
- **The list of servers costs nothing when closed.** It is a stored list of
  names and addresses. It does not dial anything to draw itself, and a server
  that has never been opened in this launch shows no state rather than a
  fabricated one.

The consequence to state plainly, because it will otherwise be "fixed": **a
server page can be showing stale facts, and that is correct behaviour.** The age
is on screen. Making it live would mean a timer per server, which is the thing
his rule bans.

### 5.5 Where all of this sits

Inside the existing rail row, which is renamed. Nothing new is added to the
sidebar, per rule 3.

```
Machines                          ← the rail row (PanelId stays 'remote')
├── Servers                       ← new
│   ├── + Add a server            ← address, username, password or key (§2.1)
│   └── (a server)                ← zone 1 / zone 2 / Advanced → zone 3
└── Devices                       ← everything RemoteSection.tsx does today
    ├── the pairing code + roster
    └── the machine links
```

> **A server page takes over the panel's content. It does not become a window,
> and it does not become a `PanelId`.**
>
> That is still true of the *page*: the cards, the zones, the Advanced door and
> Back all live inside the panel, and none of them is a window.

### 5.5.1 The terminal is a session, and that reverses what was written here

The paragraph that used to follow the box above said the opposite, and it is
worth keeping the argument rather than deleting it, because half of it is still
load-bearing:

> *The tempting alternative is a tab pill in the window strip, the way the
> copilot ended up. It is wrong here for two reasons and one of them is
> practical. A server terminal is not a session — it has no transcript, no
> account, no model, no cost, and none of the control cluster that makes the
> strip's chrome meaningful; a pill carrying six controls that all do nothing is
> the exact defect `panels.ts` records the copilot page having had, in reverse.
> And practically, the strip is fed by lists in `App.tsx`, which is one of the
> files no agent may touch while others are working. Taking over the panel's
> content needs no shared file at all.*

**The practical reason has expired.** It was a rule about which files agents
could edit in parallel on one night, not a fact about the product.

**The first reason was answered rather than accepted.** It confuses a *pill*
with a *control cluster*. A pill is the answer to "what do I have open"; the
cluster is a conversation with a session. So the feature was split in two:

- **The pill, the rail row, the ✕ and ⌘W are there**, because the shape of the
  application must not change between machines. Asad has now said this three
  nights running, and the third time was about exactly this screen: *"Keep the
  same one browser window for every device… the shape of the application should
  not be changing for local and remote devices. It should act like that same."*
  A shell on a server was getting a lesser product than a paired laptop — no row
  in the rail, no pill, no ⌘W, nothing you could drag to the top — and it lived
  inside a panel, so looking at anything else closed it.
- **The model, effort, connector and usage cluster is absent**, and so is the
  Chat/Split switch. Not because a server has no agent — that would be an
  assumption about somebody else's machine, which rule 4 forbids — but because
  every one of those controls is a conversation with a **local pty by session
  id**: `useSessionControls` reads `agent:controls:read` and writes
  `agent:controls:set`, and `main/agent-controls.ts` performs a change by typing
  `/model` into that pty and waiting for the screen to echo it back. A shell on a
  server has a channel, not a session id.

**And it stays absent on a server that does have an agent CLI installed.**
Installed is not running. `renderer/shell/agent-presence.ts` is explicit that for
a *shell* session the question cannot be answered from the record and has to be
read off the screen — through that same local channel — so for a server shell the
answer is permanently `null`, which is the state that file already says draws
neither control. Typing `/model` into a shell on a hunch does not change a model;
it submits the word to whatever happens to be in front of it, which on somebody's
live machine might be a database prompt.

The consequences, stated so they are not "fixed" later:

- **The heading in the rail appears only while something is open on that
  server.** A machine's heading is drawn whenever the machine is reachable,
  because being up is a live fact about a paired desktop. A server has no
  equivalent state — it is a stored address this app never dials to find out
  about — so a heading per stored server would be a permanent row saying nothing
  in the list whose whole job is to answer what you have open. The door to the
  first one is the Advanced section of the server's own page.
- **The pane is mounted for as long as its tab exists, and hidden rather than
  unmounted.** A local session survives an unmount because the main process
  hands back its scrollback; a session on a paired desktop survives because the
  far end replays it. A shell on a server has neither, so the terminal it is
  written into is the only thing holding what it printed.
- **Nothing survives a relaunch**, and no row is drawn on the way in. There is
  nothing to restore one from.
- **Closing is a close.** Taking the row off the list unmounts the pane, which
  closes the shell over there. The server is untouched, and the confirmation
  says so in its second clause — *"Nothing else on the server is touched."*

Pinned by `renderer/shell/server-session-wiring.test.ts`,
`renderer/shell/server-group.test.tsx`, `renderer/browser/server-pill.test.tsx`,
`renderer/machines/servers/server-sessions.test.ts` and
`renderer/machines/servers/terminal-is-a-session.test.ts`.

---

## 6 · Where the copilot fits

The copilot may drive this room. **Only on an explicit grant, never by default.**

> Full control of a production server driven by an agent is the largest blast
> radius in this product. Not the largest so far — the largest there is. The
> copilot can already start sessions and write settings on *this* machine, which
> is recoverable by somebody sitting at it. A server is somebody's live website,
> reached from a machine they are not sitting at, and the person who notices
> first may be a customer.

Nothing here is a new permission system. `deck-control/` already has tiers, an
escalation hook, a precheck, a consent gate and an append-only action log, and
the whole of this section is a use of them.

### 6.1 The tools, and their tiers

| Tool | Tier | Note |
|---|---|---|
| `servers.list` | `read` | names and addresses only, never a credential |
| `servers.facts` | `read` | the §3.2 probe result, `Fact`s and all |
| `servers.logs` | `read` | the same bounded window as the Logs button |
| `servers.start` · `servers.restart` · `servers.stop` · `servers.update` | **escalating** | see §6.2 |
| `servers.backup` | `act` when granted, `alter` otherwise | reads only, but it moves data onto this computer |

> **There is no `servers.run`, and there will not be one in v1.**
>
> An arbitrary-command tool is the whole machine, and it makes every rule above
> decorative: an agent that can run a command does not need `servers.restart`
> and is not bound by its consequence sentence, its class, or its way back.
> So the copilot gets the **named actions only** — each of which is Safe,
> Reversible or Kept by §4.1 — and the unbounded shell stays a thing a person
> does with their own hands in zone three.
>
> This is a real restriction with a real cost: the copilot cannot fix a server
> in a way we did not anticipate. That cost is accepted deliberately, and it is
> the kind of thing to revisit against a permission model that has been used in
> anger, not before.

### 6.2 The grant

The escalation is the same shape `browser-tools.ts` already uses for a browser
origin — `drive.originGranted(origin) ? 'act' : 'alter'` — and for the same
reason: the tier cannot be static, because the answer depends on *which* server.

```ts
escalate: (args, context) => serverGranted(optStr(args, 'serverId')) ? 'act' : 'alter'
```

So, precisely:

- **With no grant, every action on every server is `alter`** — a real question,
  put to a real person, with the action's own §4.3 sentence in it, that expires
  into a refusal. The copilot is never blocked from *asking*; it is blocked from
  *doing* silently.
- **A grant is per server.** Never global, never "all my servers". The blast
  radius of the grant is the blast radius of one machine.
- **A grant is asked for in that server's own page**, in zone three, next to the
  other sharp things — not in Settings, and not in the copilot's window. The
  place you grant control of a server is the page that shows what is on it.
- **A grant covers the `act` tier only.** It never covers zone three: not the
  terminal (there is no tool), not the sign-in, not the host key, not Forget.
- **A grant expires**, and its remaining life is shown on the server's page. An
  agent permission that outlives the reason it was given is one nobody
  remembers granting.
- **Every call is logged either way**, at every tier, into
  `<userData>/copilot-log/actions.jsonl` — which the copilot cannot write to,
  per the records fence in `confine/records.ts`. A log the audited party can
  edit is not a log.

`precheck` refuses two things outright, ahead of any dialog, because they must
not be reachable by answering yes: a server id the app does not know, and any
action on a server whose facts say the action `cannot` be performed.

### 6.3 What a routine may do

A routine runs through the copilot and **cannot answer a dialog** — this is
already true and already enforced in `deck-control/consent.ts`. The consequence
here is worth stating so nobody treats it as a bug to fix: **a routine can read
servers and cannot change them, unless that server has a live grant.** A nightly
"tell me if anything stopped" routine works with no grant at all. A nightly
"restart it if it stopped" routine requires one, deliberately.

---

## 7 · Out of scope for the first version

Named plainly, so nobody builds them by accident, and each with the reason.

| Not in v1 | Why |
|---|---|
| **Deleting anything** — a site, an app, a database, a file | §4.1: v1 ships no action without a way back, and these have none. |
| **Installing operating system updates** | Cannot be undone. v1 shows the count in zone three. |
| **Installing software** — a web server, a database, a runtime | This is *provisioning*, not control. It is a different product with a different failure mode: a half-installed server has no way back. **Two narrow exceptions now ship — see §7.1 and §7.2.** |
| **Editing files on the server** | An editor implies save, which implies overwrite. There is a terminal in zone three for people who want this and know what it means. |
| **Following logs live** | §4.2: a stream that stays open is the polling-shaped thing rule 5 bans. Bounded fetch plus **Load more** in v1. |
| **Uploading and downloading arbitrary files** | `sftp` is available and this is genuinely useful, but it is a file manager, and a file manager is its own surface with its own confirmation model. Backup (§4.2) is the one file transfer v1 has, because it only reads and goes one way. |
| ~~**Port forwarding / tunnelling to a private service**~~ — **shipped** | This was written before `forward.ts` and `reach.ts` existed. It has an answer to its own question now: a tunnel's lifetime is the page that opened it, and it closes when the connection does. Left in the table struck through rather than deleted, because the row's reasoning is still the reason the lifecycle is written down where it is. |
| **Reading `~/.ssh/config` as a source of servers** | §2.1: read it as a *convenience* if somebody has one, never as a requirement — and importing it wholesale would put a list of somebody's employer's servers in this app without them asking. Offer it as an explicit import in v2. |
| **Jump hosts / bastions / `ProxyJump`** | Real and common, and it multiplies every connection path by two. v2, once one path is solid. |
| **Cloud provider APIs** — resizing, snapshots, billing | Every one is a different vendor with different credentials. The whole premise here is that a server is reached the same way whoever it is rented from. |
| **Windows servers** | `ssh2` connects to them; nothing in §3.2 works there, so every card would be the third state. Being honest about that is fine; shipping it as if it were supported is not. |
| **`servers.run` for the copilot** | §6.1. |
| **Container-aware resource figures** (reading cgroup limits) | §3.4. v1 says `cannot` rather than showing the host's numbers. |

---

### 7.1 · The one exception: putting a coding assistant on a server

**Installing software** stays a non-goal and the row above stays true. This is
the single, named exception to it, and it is written down here rather than left
to be discovered in the code — a design document that quietly stops describing
the code is worse than one that never covered it.

What ships:

> **One named program — Claude Code — into the account's own home folder, with
> no administrator access, with a way back, and only when a person presses a
> button for it.**

It is not general provisioning, and each clause is what keeps it from becoming
that:

- **One named program.** There is no name field, no version field and no
  registry. The command is a constant in `servers/setup.ts` and nothing reads
  the program's name from anywhere else. Codex and Gemini are *detected* in the
  same probe — that costs nothing — and neither is offered an install button,
  because their sign-in flows have not been measured and a wizard that strands
  somebody halfway is worse than no wizard.
- **Into the account's own home.** Measured: the installer is a native binary
  that needs no Node, writes only under `$HOME`, and **refuses to run as the
  administrator**. So none of this app's privilege handling is involved, and
  nothing outside one person's own home folder changes.
- **With a way back.** §4.1 is not suspended. The app records that *it* did the
  installing and offers to remove exactly what it added — the program and its
  versions folder, never `~/.claude`, which is somebody's own transcripts and
  settings and may well predate this app. An install this app did not do is
  reported and offered nothing.
- **Driven by a person.** There is no tool for it in `tools.ts` and there must
  not be. §6.1 is unchanged: the copilot gets the named actions and nothing
  else, and `no-run-tool.test.ts` pins its tool list at three names.

The reason the exception is worth making is that the alternative is not
*"nothing gets installed"* — it is a person being told their server is ready and
then discovering, in a terminal, that the thing they came for is missing. The
half-installed-server failure the row above is about does not arise here: this
writes one file tree under one home folder, and the button that undoes it is on
the same screen as the button that did it.

**The sign-in is part of the same exception and is subject to a stricter rule.**
`ACCOUNT-MODEL.md` binds — *"this app never holds the credential"* — and this
flow does not break it. Claude Code on the server runs **its own** sign-in, with
its own client id, and writes **its own** credential; the app contributes a
browser window on this computer and a socket that carries the redirect back down
to the server's own waiting listener. The authorization code is bytes on that
socket and is never read, stored, logged or typed by this app. The app must
never read a code out of a browser and type it into a shell — `DRIVABLE-BROWSER.md`
§7 forbids exactly that — and where a server will not carry the socket, a person
finishes the sign-in themselves at the prompt that is already on their screen.

### 7.2 · The second exception: putting the host itself on a server

The same sentence, the same clauses, a different program — and it is written
down here for the same reason §7.1 is.

> **The headless host, into the account's own home folder, with no administrator
> access, with a way back, and only when a person presses a button for it.**

What makes it the *same* exception rather than a widening of it:

- **One named program, and this one is ours.** There is no name field and no
  registry lookup. The tarball is built by `scripts/build-headless.mjs`, carried
  inside the app as a resource, and copied to the server over the SFTP channel
  the page already has. It is deliberately **not** `npm install -g terminaldeck`:
  that name is a reservation, and a package with no `bin` entry installs
  perfectly and leaves a host that looks installed and answers nothing.
- **Into the account's own home.** `scripts/install-headless.sh` does the work,
  and it writes only under `$HOME` — `~/.local` for the package, and
  `~/.terminaldeck/runtime` for a private Node when the machine has none.
  Where root would genuinely help — `loginctl enable-linger`, which is what
  keeps a user service alive after the last logout — the app **asks without
  sudo, reads the answer, and says the command that would grant it**. It never
  asks for administrator access and never escalates.
- **With a way back.** The remove stops the service, deletes the unit file, the
  program and the private runtime, and **leaves the host's own data folder
  alone** unless the person ticks a box — because that folder holds the devices
  paired to this host and the folders each may use, and removing the program to
  install a newer one should not un-pair somebody's phone. Both answers state
  what they leave, before the press.
- **Driven by a person.** No entry in `tools.ts`, and `no-run-tool.test.ts`
  still pins the copilot's tool list at three names.

Two things about it are stated on screen rather than discovered:

1. **Whether it will still be there tomorrow.** A systemd user service without
   lingering stops when the last login ends, which is the WSL failure in
   different clothes — *"a phone that was paired to it then finds nothing there,
   which looks exactly like the app being broken."* A machine with no systemd at
   all gets the host started directly and is told that it will not survive a
   reboot. Neither is a failed install and neither is reported as one.
2. **A device paired to a server gets no copilot.** `HEADLESS.md` has the
   reason; what matters here is that on the wire *"this host has no copilot"*
   and *"you were approved as a guest"* arrive as the same absence, so the pane
   says it.

The pairing is the one place a person still does something, and that is
deliberate. The host prints a code, the app reads it out of the terminal and can
redeem it into this computer's own Machines list with one press — but the
`Approve it? [y/N]` question that follows carries the fingerprint, which is the
only part of pairing a person can actually check. An app that answered it would
have deleted the check while appearing to perform it.

---

## 8 · How the work splits

Three agents, in parallel. `CLAUDE.md`'s rule applies unchanged: **none of them
may edit `src/main/index.ts`, `src/preload/index.ts`, `src/renderer/App.tsx`,
`src/shared/types.ts`, `package.json` or `ROADMAP.md`.** New files only; wiring
is handed back. A fourth agent is live in `plan-limit.ts`, `usage-ipc.ts`,
`account-limits.ts` and `shell/{useUsageBar,UsageBar}.tsx` — stay out of those.

### 8.1 The files

```
src/main/servers/
  connection.ts      one ssh2 connection: dial, host key, auth, exec, shell    ← A
  credentials.ts     safeStorage + writeSecretFile, per §3.7                   ← A
  store.ts           the list of servers: id, name, address, username          ← A
  probe.sh.ts        the §3.2 script as a string constant, and its parser       ← A
  facts.ts           the Fact<T> type and the fact record                       ← A
  classify.ts        facts → Site / App / Database / Other, per §3.5            ← B
  actions.ts         the §4.2 list: id, class, summary(), run()                 ← B
  tools.ts           the deck-control specs and the grant, per §6               ← B
  grants.ts          per-server grant with expiry                               ← B
  ipc.ts             registerServersIpc(ipcMain)                                ← B

src/renderer/servers/
  useServers.ts      bridge + state                                             ← C
  ServersSection.tsx the list, and Add a server                                 ← C
  ServerPage.tsx     zone 1 + zone 2 + the Advanced door                        ← C
  ServerCard.tsx     one Site / App / Database                                  ← C
  ServerAdvanced.tsx zone 3, including the terminal                             ← C
  servers.css                                                                   ← C
  types.ts           the mirrored types + the *Bridge interface                 ← C
```

`renderer/servers/types.ts` **must** export its bridge slice as an interface with
`Bridge` in the name — `src/preload/contract.test.ts` reads every such interface
and fails the build if the preload has stopped exposing a method. That seam has
broken three times here without a single type error; `renderer/machines/types.ts`
carries the argument.

### 8.2 The seams between the three

Agreed here so they can be built against before they exist:

- **A → B**: `connection.ts` exports `run(serverId, argv): Promise<{code, stdout, stderr}>`
  and `shell(serverId, size)`. B never constructs an `ssh2` `Client`.
- **A → B**: `facts.ts` exports `Fact<T>` and `ServerFacts`. B classifies from
  `ServerFacts` and never re-runs the probe.
- **B → C**: `ipc.ts` is the only thing C calls. Feature types cross the bridge
  as `unknown` and are narrowed in `renderer/servers/types.ts` — per `CLAUDE.md`,
  they are **not** duplicated into `shared/types.ts`.
- **All three**: the vocabulary in §1 and the sentences in §4.2. C renders
  `summary()` strings from B; C never writes a consequence sentence (§4.3).

### 8.3 Wiring handed back to the coordinator

Not applied by any agent:

1. `package.json` — add `"ssh2": "^1.17.0"` to `dependencies`. Install with
   optional dependencies suppressed (§2.5); confirm afterwards that
   `node_modules/cpu-features` is absent and that no `.node` file exists
   anywhere under `node_modules/ssh2`.
2. `src/main/index.ts` — `registerServersIpc(ipcMain)`.
3. `src/preload/index.ts` — the bridge methods named in `renderer/servers/types.ts`.
4. `src/renderer/shell/panels.ts` — `label: 'Machines'` and a new `blurb` on the
   `'remote'` entry. **The `id` does not change** (§1.3).
5. `src/renderer/remote/RemoteSection.tsx` — mount `ServersSection` above the
   existing device roster.
6. `.harness/stub.ts` — the new bridge methods, honestly: `on*` returns an
   unsubscribe function, everything else a promise. `CLAUDE.md` records a stub
   that disagreed with the preload inventing three bugs that did not exist.

### 8.4 What each agent must pin with a test

Behaviour that changes is pinned by a test that would fail if someone undid it.
These are the ones this document's decisions demand, beyond ordinary coverage:

| Test | Fails if |
|---|---|
| `servers/electron-cipher.test` — a case added to `scripts/check-electron-crypto.mjs` | the negotiated cipher list under Electron is empty, or ever contains ChaCha (§2.3) |
| `servers/facts-third-state.test.ts` | any probe key with no answer produces a `yes` or a `no` rather than a `cannot` — driven by the three recorded fixtures in §3.3 |
| `servers/container-numbers.test.ts` | disk, memory, load or uptime is reported as `yes` when `init` is `container-none` (§3.4) |
| `servers/no-action-without-a-way-back.test.ts` | any entry in the §4.2 action list has a class outside Safe / Reversible / Kept, or a Kept action can run without having recorded its way back |
| `servers/summary-is-server-side.test.ts` | any consequence sentence is composed in `renderer/` (§4.3) |
| `servers/no-run-tool.test.ts` | a tool exposing arbitrary command execution appears in the catalogue (§6.1) |
| `servers/grant-scope.test.ts` | an action reaches `act` on a server with no live grant, or a grant covers a second server (§6.2) |
| `servers/credentials-never-cross.test.ts` | a password, key or passphrase appears in anything the preload returns (§3.7) |
| `servers/host-key-checked.test.ts` | any connection path constructs a client without a `hostVerifier` (§3.6) |

The last one is the sort that has to be written structurally — scan the module
for `connect(` and assert the option is present — rather than by exercising one
happy path, because the hole it guards is a *second* code path somebody adds
later.

### 8.5 The test server

`ssh terminaldeck-server` reaches the Hetzner box used for every measurement in
this document: Ubuntu 24.04.4, OpenSSH 9.6p1, systemd, a container runtime, apt,
and a web server. It is **not** Asad's own machine.

Password auth is enabled on it (`passwordauthentication yes`) but root may not
use a password (`permitrootlogin without-password`), so testing the password
path needs an ordinary account. One was created for the measurements above and
**deleted afterwards** — a password account on a public host is not something to
leave lying around. Recreate and remove it the same way:

```sh
ssh terminaldeck-server "useradd -m -s /bin/bash tddemo; echo 'tddemo:<pw>' | chpasswd"
ssh terminaldeck-server "userdel -r tddemo"
```

Containers on that box are how the non-systemd cases in §3.3 were measured, and
they are the cheapest way to test rule 4 honestly:

```sh
ssh terminaldeck-server "docker run --rm -i -v /tmp/probe.sh:/probe.sh:ro alpine:3 sh /probe.sh"
```

Clean up after yourself: remove any image you pulled and any file you left in
`/tmp`. The box was returned to exactly its prior state after these
measurements.

---

## 9 · Open, and worth his answer

- **Does a server belong to a project, or to the app?** Everything in the
  `foot` group today is app-wide, on the stated grounds that *"the machines you
  can reach do not change when you open a different folder."* That argument
  holds for servers too, and it is what this document assumes. But the servers
  somebody deploys *from* a repository are plainly related to it, and if he
  wants Update-from-a-repository to know which project it came from, that is a
  link worth designing rather than inferring.
- **How long is a copilot grant?** §6.2 says it expires and shows its remaining
  life; it does not say how long, because that is a judgement about how he would
  actually use it. An hour is the safe guess. A grant that has to be re-given
  every ten minutes gets given carelessly.
- **Should a server ever be reachable from a paired phone?** The device link and
  the server link are separate subjects in this document, and nothing joins
  them. Joining them means a phone can restart a production website, which is
  either exactly what he wants on a Saturday or exactly what he does not. The
  copilot's own answer to this question took two rounds and ended at a *separate
  connection ceremony* rather than a checkbox, which is probably the shape of
  the answer here too.
