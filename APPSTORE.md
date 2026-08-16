# Getting Terminal Deck onto the App Store

Written 2026-08-15, after uploading 0.1.8 to TestFlight. Nothing here has been
submitted for review. This is the path and the honest cost of walking it.

---

## The plan, in one paragraph

Asad wants to submit now, while the app is small, because a small app is easier
to review. That instinct is right about *scope* and wrong about *readiness*, and
the difference is one guideline. Review is not made easy by there being less
code; it is made easy by a reviewer completing the app's core task inside two
minutes. Terminal Deck's core task is "attach to a session on a machine you
own", and an App Review engineer in Cupertino owns no machine running Terminal
Deck. They will open the app, meet a pairing screen, have nothing to pair with,
and file a **Guideline 2.1 — App Completeness** rejection. So the work between
here and a submission is not trimming features. It is making the first two
minutes work for somebody who has no desktop, plus the store paperwork that has
never been filled in.

---

## 1. Guideline 2.1 is the whole risk, and it is real

In substance — check the current wording at
<https://developer.apple.com/app-store/review/guidelines/#app-completeness>
before quoting it anywhere — **2.1** asks that a submission be a final version
with working metadata and URLs, and that an app needing particular hardware or
software say so in **App Review Information**. The clause that bites hardest is
the demo-account rule: if any part of the app is behind a sign-in or a paired
device, the reviewer must be handed a working one in that same section.

What a reviewer sees today, in order:

1. Launch. `PairingView`.
2. Three ways in: scan a QR code, paste a pairing link, type an eight-character
   code. Every one of them needs a machine on the other end that is already
   running Terminal Deck.
3. Nothing else. There is no other screen. `RootView` has no branch that does
   anything useful without a `HostLink`.

That is a dead end for anyone but the person who installed the desktop app, and
a dead end is a rejection, not a slow review. It is also not a bug — the app is
a client, and a client with no server is supposed to say so. The fix is to give
the reviewer a server.

### The second-order risk worth naming now

**Guideline 4.2 — Minimum Functionality.** An app that is a thin front end to
software bought or downloaded elsewhere gets looked at harder than most. The
answer is that this is the same category as an SSH client (Termius, Blink,
Prompt all ship on the store and all require a machine you already own), and the
app carries a real VT100 emulator, a real Noise-sealed transport and real file
transfer rather than a web view. That answer should be *written into the review
notes*, not left for the reviewer to reach on their own.

**Guideline 2.5.2 — no downloading or executing code.** Terminal apps attract
this one. It does not apply here and the notes should say why in one sentence:
nothing is compiled, downloaded or executed on the iPhone. The iPhone draws
characters and sends keystrokes; every process runs on the user's own computer.
Getting ahead of it costs a line and saves a rejection round-trip.

---

## 2. What would actually clear 2.1

Three candidates. Read them together — the recommendation is a combination.

### Option A — a demo mode inside the app

A "look around without a machine" path: a session that replays a recorded
transcript so the reviewer sees a terminal, a key bar, a session list.

**Against, and this is the strong argument:** it is fake. iOS does not let an
app spawn a process, so a local session cannot be a real session — it can only
be a scripted replay of one. That collides head-on with this project's own rule
that nothing is fake and no screen shows placeholder data, and it collides with
Apple's own dislike of demo content shipped to real users (2.3.1). A reviewer
who realises the terminal is a recording may reach for **2.3 — Accurate
Metadata** instead, which is a worse rejection than the one being avoided.

**For:** it works with no infrastructure and it never goes down.

**Verdict:** not as the answer to 2.1. Possibly worth building later as an
honestly-labelled tour — *"Preview — this is a recording, not a live machine"* —
because it also helps a real user decide whether to install the desktop app. It
must never be presented as a session.

### Option B — a real host, kept running, credentials in the review notes ✅

Stand up the headless host (`HEADLESS.md`) on a throwaway Linux VM that exists
only for App Review. Put a pairing link or code in App Review Information. The
reviewer pairs, attaches, types `ls`, sees output, and the app has demonstrated
exactly what the description claims.

This is the option Apple's own rules are written around, and it is honest: the
reviewer uses the real product on a real machine over the real relay.

**What it costs, stated properly:**

- **A machine that never goes down.** Review is days, re-review for every update
  is more days, and Apple re-tests old versions months later. If the host is off
  when they look, the rejection reads "we were unable to connect" and lands on
  the next update too. This is a permanent piece of infrastructure, not a
  one-afternoon prop.
- **A pairing that does not expire or burn.** The typed-code path is deliberately
  short-lived and dies after five wrong guesses (`43273bb`). A review pairing
  needs to be a stable link that survives the whole review window and can be
  re-used by a second reviewer without the first having invalidated it. That is
  work in the host, not a note in a form.
- **A security decision, taken on purpose.** The reviewer gets a real shell on a
  real machine. `CONFINEMENT.md` is blunt that folder confinement is implemented
  on macOS and **does not exist on Linux or Windows** — `confinementKind()`
  answers `'none'` there. So the review host must be a disposable VM with no
  credentials, no keys, no repositories, nothing mounted, and a lifetime that
  ends when review ends. Not the Hetzner box, not the office PC, not WSL on his
  own machine.
- **Reachability.** The relay has to answer from wherever the reviewer is, and
  review is not all done from one place. This has not been tested from outside
  the UAE and Europe, so it is an assumption, not a fact — worth measuring
  before it becomes a rejection nobody can reproduce.

### Option C — a video

Attach a screen recording in App Review Information showing the pairing and a
live session. Cheap, five minutes of work, and **it is not sufficient on its
own** — a video supports a reviewer who is already able to run the app; it does
not replace their being able to. Do it anyway. It is the thing that resolves an
ambiguous rejection in one reply instead of three.

### The recommendation

**B plus C.** Real review host, real pairing in the notes, video attached as
support, and every one of 4.2 and 2.5.2 pre-answered in the notes text. A
carefully labelled preview mode (A) is worth building for real users later and
should not be on the critical path to submission.

> **Superseded in its detail by [§6, Decision](#6-decision--how-the-reviewer-gets-in).**
> The direction above survived being measured; two of its sentences did not.
> "Real pairing in the notes" cannot be done — the iOS build accepts no pairing
> string that lives long enough to sit in a form — and "a disposable VM" is
> under-specified in a way that would have put a stranger's shell next to a
> client's WhatsApp gateway. Read §6 before building anything from this section.

---

## 3. What is not filled in yet

Checked against App Store Connect on 2026-08-15, not remembered. App record
`6801251458`, version record `1.0` exists in `PREPARE_FOR_SUBMISSION`, and it is
an empty shell:

| Field | State | Notes |
|---|---|---|
| Description | **null** | Nothing written. |
| Keywords | **null** | |
| Support URL | **null**, and `terminaldeck.dev/support` is **404** | Mandatory. The URL must resolve before submission. |
| Marketing URL | null | Optional. |
| Privacy policy URL | not set, and `terminaldeck.dev/privacy` is **404** | Mandatory for every app. |
| Screenshots | **zero sets** | 6.9" iPhone required at minimum. `ios/Screenshots/` has captures to work from. |
| App Review Information | **no record at all** | This is where the pairing for option B goes. |
| Age rating | not declared | |
| Privacy nutrition label | not declared | See below — the honest answer is short. |
| Export compliance | **done** | Answered per build over the API; the Info.plist key stays absent. See `scripts/ios/preflight.sh`. |

**The privacy label is the easy one.** The iOS app links exactly one third-party
package — SwiftTerm — and there is no analytics SDK, no crash reporter and no
network call to anything of ours except the relay, which carries ciphertext it
cannot read. So the answer is *Data Not Collected*, and it is true, which is
worth a sentence in the description because almost nothing else in this category
can say it.

---

## 4. Order of work

Nothing here is blocked on Apple. It is blocked on us.

1. **Publish the two pages.** `terminaldeck.dev/privacy` and
   `terminaldeck.dev/support`. Both currently 404 and both are mandatory. This
   is the cheapest item on the list and it gates submission on its own.
2. **Build the review host.** A disposable VM, the headless host on it, and a
   long-lived review pairing that neither expires nor burns. Decide its lifetime
   and who kills it.
3. **Write the review notes.** The pairing, plus the three pre-answers: this is
   a client for the user's own computer (2.1), it is the SSH-client category and
   here is what is native in it (4.2), and nothing executes on the phone (2.5.2).
4. **Screenshots and description.** From `ios/Screenshots/`, on a real device,
   showing a real session — the same rule as everywhere else in this project.
5. **Record the video.** Pair, attach, type, output. Two minutes, unedited.
6. **Then submit**, and expect the first round to come back asking something.
   That is normal and is not a sign anything is wrong.

## 5. What "small is easier" is actually right about

Keep the submitted feature set to what a reviewer can exercise in two minutes:
pair, list sessions, attach, type, scroll, copy. Everything else in the app —
file transfer, the credential proxy, localhost browsing, machine-to-machine
pairing — should stay in the build and stay *out of the description*, because
every claim in a description is a thing a reviewer will try to verify and a
thing that can be judged inaccurate under 2.3. Ship the small claim. The app can
be as large as it likes.

---

## 6. Decision — how the reviewer gets in

Written 2026-08-15, after measuring rather than reasoning. Everything asserted
below was run; the commands and their real output are in §6.9. Nothing here is
built yet.

### 6.0 The decision, in one paragraph

**A real host wins, and the shape it has to take is not the one §2 imagined.**
The reviewer gets a genuine shell on a genuine machine over the genuine relay —
but on **its own €4.49/month box, one throwaway container per visitor**, reached
through a **page that mints a real sixty-second pairing link at the moment they
tap it**. Not a standing code, because the product has none and inventing one
would weaken the file that was written for the attacker. Not a shared machine,
because a second reviewer would be able to see and type into the first one's
session — that is not a hypothesis, it is what `server.ts` does today. Not the
relay box, because a stranger's shell there sits one bridge network away from
`coolify-db`, from `/data/coolify/ssh`, and from a client's WhatsApp gateway.
And **not a demo mode in the app**, for a reason stronger than taste: Apple's own
text allows a built-in demo mode *"with prior approval by Apple"*, which is a
slow, uncertain round trip to buy something a five-euro server gives outright.

### 6.1 The finding that reorders everything: the notes cannot carry a code

§1 of this document says a reviewer has "three ways in: scan a QR code, paste a
pairing link, type an eight-character code." **The third one does not exist in
the iOS build.** `PairingCodeParser.parse`
(`ios/TerminalDeck/Transport/PairingCode.swift:188`) turns the string into a
`URL`, reads its scheme, and answers `.notACode` when there is not one. Eight
typed characters have no scheme. The text field on `PairingView` accepts a
*link* that a person may have typed; it has never accepted a code.

The browser client *does* have the typed-code path — `pwa/src/rendezvous.ts`
looks the address up through the relay's rendezvous slot from forty bits and
nothing else — and that asymmetry is worth knowing, because it means the web
demo in §6.7 is closer to finished than the iOS one.

So the only strings the iPhone accepts are:

    terminaldeck://pair?v=1&r=<relay ws url>&h=<host id>&k=<host key>&t=<token>
    https://<machine>.<tailnet>.ts.net/#t=<token>

Both carry `t`, the pairing token, and a token lives **sixty seconds and one
redemption** (`PAIRING_TTL_MS`, `src/main/remote/device-auth.ts:142`). A string
that dies sixty seconds after it is minted cannot be typed into an App Store
Connect form in advance. That kills "put the pairing in the review notes"
outright, and it is the single fact that decides the architecture: **the notes
carry a URL, and the pairing is minted when the reviewer arrives.**

Two things make that a pleasure rather than a workaround. The app registers the
`terminaldeck` URL scheme (`ios/Support/Info.plist:66`) and handles it —
`.onOpenURL { model.open($0) }`, `ios/TerminalDeck/App/TerminalDeckApp.swift:48`.
So a reviewer who opens the page **in Safari on the iPhone itself** and taps one
button is in the app, paired, with no typing, no QR and no second device. And
`machines:code` on the headless control socket already mints a code *and*
publishes the relay rendezvous beacon for its life
(`src/headless/main.ts:190-230`), so the page is asking the product for the real
thing rather than being given a special one.

### 6.2 Why not a demo mode in the app — and the argument is not the one we had

The in-app case was always going to lose on this project's own rule. What is
worth recording is that it also loses on Apple's, and on schedule risk.

Guideline **2.1(a)**, quoted from the live page on 2026-08-15:

> If you are unable to provide a demo account due to legal or security
> obligations, you may include a built-in demo mode in lieu of a demo account
> **with prior approval by Apple**. Ensure the demo mode exhibits your app's full
> features and functionality.

Three things follow. First, the escape hatch is conditional on *prior approval* —
an extra negotiation with Apple, of unknown length, before the thing is even
allowed to be the answer. Second, it is conditioned on being *unable* to provide
access, and we are plainly able for the price of a coffee, which makes the
request weak. Third, "full features and functionality" of this app means a live
pseudo-terminal; a recording that has to satisfy that sentence is a recording
elaborate enough to be indistinguishable from a lie, which is exactly the 2.3
exposure §2 already named. A demo mode is more work, more risk and more
dishonesty than a server. It is not close.

It remains worth building later, once, honestly labelled as a recording, for
people browsing the App Store page. It is not the answer to 2.1 and it is not on
the critical path.

### 6.3 Where the demo host lives, and what it costs

**Its own Hetzner Cloud box. Not the relay box. Not a Mac.**

*Priced 2026-08-15, ex-VAT, Germany/Finland, after the April 2026 increase:*

| Option | Spec | Monthly |
|---|---|---|
| **CX23 + IPv4** ← **recommended** | 2 vCPU, 4 GB, 40 GB NVMe, 20 TB | €3.99 + €0.50 = **€4.49** |
| CX33 + IPv4, if four slots is not enough | 4 vCPU, 8 GB, 80 GB | €6.49 + €0.50 = €6.99 |
| Share the existing relay box | — | €0 |
| A cloud Mac (real in-product confinement) | mac2.metal, 24-hour minimum lease | **≈ $470–865** |

€4.49/month is roughly AED 19 at about 4.3 dirhams to the euro — one flat white
in Dubai, per month, for the machine that stands between this app and a
Guideline 2.1 rejection on every update forever. Note also that this is not a
new vendor: the relay is already Hetzner, so it is a line on a bill that exists.

**IPv4 is worth its fifty cents even though the demo host needs no inbound port
at all** — it dials the relay outbound and nothing ever dials it. The reason is
measured: `relay.terminaldeck.dev` resolves to `178.105.248.86` and **has no AAAA
record**, so an IPv6-only box could not reach its own relay without a NAT64
resolver in the path. Pay the fifty cents; firewall inbound to nothing.

**Why sharing the relay box is false economy, with the numbers.** Read-only
inspection over ssh on 2026-08-15 found a 2 vCPU / 3.8 GB box, 2.2 GB available,
26 GB free, up 80 days, running nine containers. That is survivable. This is not:

- `coolify-db` (Postgres 15 — Coolify's own database, which holds the deploy
  credentials and environment for everything Asad hosts) sits at **10.0.1.2** on
  the `coolify` bridge. `terminaldeck-relay` sits at **10.0.1.7** on the same
  bridge. Anything else placed there can open a TCP connection to it.
- The `coolify` and `coolify-realtime` containers mount **`/data/coolify/ssh`** —
  private keys.
- `coolify-proxy` and `coolify-sentinel` mount **`/var/run/docker.sock`**, which
  is root on the host for anything that can reach it.
- The host listens on `0.0.0.0:8000` (Coolify's own web UI) and `0.0.0.0:8080`,
  both reachable from any container through the bridge gateway.
- `evolution-nlgyb7egyhd6np305n2b1dm9` has been up two months and is a paying
  client's WhatsApp gateway. `relay/deploy.sh` already calls it "the neighbour we
  must not disturb". A fork bomb or a filled disk from a demo session takes it
  down, and that is the *accident* case, before anyone is even trying.

We would be saving €4.49/month by putting an anonymous shell one `curl` away from
all of that. That is not economy, it is a decision to be surprised later.

**Why not a Mac, which is the only platform where our own confinement is real.**
Tempting, and rejected twice over. His own hardware is on his office network and
his tailnet, which is the opposite of what a stranger's shell needs, and an office
Mac's uptime is not review-grade — Apple re-tests old versions months later. A
*cloud* Mac buys the genuine Seatbelt boundary for a hundred times the price, to
protect a machine whose entire contents are a README and a git repo we put there.
The boundary is not worth buying when there is nothing behind it.

### 6.4 What the confinement actually has to stop

`CONFINEMENT.md`'s measured escape table is a table about **the filesystem**, and
it was measured against the threat of *a device the owner granted a folder to*.
The threat here is different in kind: an anonymous stranger, on purpose, with
time. Taking its rows first, then the rows it does not have.

**From the measured table — which apply, and how:**

| Measured escape | Applies here? |
|---|---|
| `umount /home` with capabilities not dropped → **ESCAPE** | **Only if we build the in-host Linux boundary.** If we do, `setpriv --bounding-set=-all --inh-caps=-all` is not optional; without it the fence is decoration and that was *measured*, not feared. |
| Nested user namespace to regain `CAP_SYS_ADMIN` → refused | Applies, and it is the escape a stranger reaches for second. |
| `/proc/1/root/home` → Permission denied | Applies. Depends on PID 1 being another uid, which is a fact about how we start things, not a kernel guarantee. |
| Symlink out of the granted folder → contained | Applies. |
| Absolute path to the owner's home → gone | Applies. |
| `/mnt/c` interop by path → not found | **Does not apply.** There is no WSL on a Linux VPS. |

And that last row is the good news buried in `CONFINEMENT.md`: the two reasons
the Linux boundary was measured-but-not-built are **the unmeasured `wsl.exe --cd`
launch path** and **`WSL_INTEROP`, a door straight back out**. Neither exists on
a plain Linux server. A demo VPS is therefore the *easiest place in the world*
to finish that work — which is an argument for doing it, later, and not an
argument for the demo depending on it now.

**What the table does not cover, which is most of the real risk:**

1. **Network egress.** A shell can `curl`, and the table says nothing about it.
   This is the largest practical danger: port-scanning, spam, mining, using our
   IP as a proxy, or simply attacking `178.105.248.86` from a machine we own.
   Hetzner suspends boxes for abuse and the reputation is ours. **Default-deny
   egress, allowing DNS and the relay and nothing else.** Yes, that means
   `git clone` and `npm install` do not work in the demo. Good: the app's claim
   is "attach to a session and type", not "free build farm".
2. **Resource exhaustion.** Fork bomb, disk fill, RAM. Needs `--memory`,
   `--cpus`, `--pids-limit` and a size-capped tmpfs, per visitor, enforced by
   the kernel rather than by hope.
3. **Persistence between visitors.** A line in `~/.bashrc` left by visitor one
   runs for visitor two. The only reliable answer is that visitor two gets a
   different container.
4. **The host's own secrets — and this is the sharpest one.** The headless
   daemon keeps its state dir at `0700` with the control token in a `0600` file
   (`src/headless/daemon.ts:57,111`), and a session spawned by that daemon runs
   **as the same uid**. So a session can read the control token, talk the control
   socket, and then `folders add /` and approve its own devices. On your own
   server that is not an escalation — it is your machine. On a public demo host
   it is a total compromise, and the product has no privilege separation to
   prevent it. **One container per visitor is what makes that harmless**: inside
   a container that holds one README and dies on detach, there is nothing left to
   escalate *to*.
5. **Reaching anything else of ours.** No tailnet membership, no ssh keys, no
   cloud API token, no git credential, no `gh`, no route to `178.105.248.86:22`.
   The box must be worth nothing to whoever ends up owning it.
6. **The capabilities the app itself hands out.** The host advertises what it
   will serve — `create`, `localhost`, `upload`, `credential`
   (`src/main/remote/protocol.ts`). The demo host should advertise **`create`
   only**. `localhost` is a byte pipe to loopback ports, `upload` is a way to
   fill a disk, and `credential` is a proxy for credentials the demo must not
   have. Narrowing there is one line of assembly, not a new mechanism.
7. **Session visibility between devices — an app-level leak, not an OS one.**
   See §6.6. It is the reason the pool exists.

**And the honest sentence that has to be said out loud:** on that box,
`confinementKind()` answers `'none'`, because it is Linux and the Linux boundary
is not built. The demo does **not** claim in-app confinement. The fence is the
container and the fact that the machine is worthless — an ordinary, measurable
mechanism placed *outside* the product. That is the version of this that does not
require shipping an unmeasured boundary to make a demo look good, which is
precisely the trade `CONFINEMENT.md` rule 1 forbids.

### 6.5 How the reviewer pairs, exactly

**In App Review Information, one URL and four sentences.** No credentials, no
code, nothing that expires.

> Terminal Deck is a client for a computer you own, like an SSH client. For
> review, we run a real machine you can attach to.
>
> **On the iPhone, open <https://terminaldeck.dev/review> in Safari and tap
> "Open in Terminal Deck".** The app opens, pairs with our demo machine, and a
> live Linux shell is one tap away. Type `ls` — that output is coming from a real
> server in Germany.
>
> The page can also show a QR code and a link to copy, if you prefer to pair from
> another device or a simulator. It works as many times as you like.
>
> Nothing is downloaded, compiled or executed on the iPhone (2.5.2): the app
> draws characters and sends keystrokes. Every process runs on the far machine.

**What has to change to support that, and none of it is a relaxation:**

- **A pairing page** at `terminaldeck.dev/review`, served by the existing Vercel
  site so its uptime is not the demo box's uptime. On load it asks the broker for
  a slot; on tap it renders `terminaldeck://pair?…` with a *freshly minted*
  token, plus a QR of the same string, plus a countdown and a "get a new one"
  button. The reviewer never sees a stale code, and nothing on the page outlives
  its sixty seconds.
- **A broker** on the demo box: allocate a container, ask it for a code through
  the control socket, hand back the link, reap on detach. Small, and it is the
  only new network-facing thing we own.
- **Auto-approval, declared rather than smuggled.** Redeeming a token creates a
  device in `pending`; a human at the machine approves it
  (`device-auth.ts`, "Two gates, not one"). There is no human at the demo box.
  So the demo host must approve a device that redeemed a code **it just minted
  for one allocated visitor** — the broker's allocation replaces the human as the
  second gate, which is a defensible trade *only* because the thing being
  unlocked is a disposable container. This must be an explicit mode that a normal
  host cannot enter by accident or configuration drift, it must be visible in
  `status` in its own sentence, and it should be in the session's motd. Note that
  no change to `device-auth.ts` is needed for it: `redeemPairingToken` already
  returns the new device, and the demo assembly can call `approveDevice(id)`.
  **Do not add an auto-approve flag to the trust store.** Keep the policy in the
  demo host, where it can be read in one file.
- **An event when a device redeems.** Today `terminaldeck pair` asks a person to
  *"Press Enter once the device says it is waiting to be approved"*, and its own
  comment explains why: there is no event to subscribe to, and the standing rule
  is events, not polling. A broker cannot press Enter, and making it poll would
  break the same rule for a worse reason. So the daemon should emit the moment it
  refuses a pending device — which it already knows about. That is a small change
  that pays for itself twice, because it also deletes the "press Enter" step from
  the human flow.
- **`PAIRING_TTL_MS` does not change. Neither does single-use.** That is the
  point of this design. Every property the security model rests on stays exactly
  as it is; the only thing we added is a page that asks for a code at the moment
  somebody wants one.

### 6.6 Two reviewers at once, and a reviewer who breaks it

**Two reviewers on one host would be a leak, and this is verified, not feared.**
`server.ts` sends `sessions: options.sessions.list()` on `welcome` and on every
`sessions` request (`src/main/remote/server.ts:1327,1502`) with **no device
filter**, and `SessionFanout` lets several devices watch and type into the same
pty. That is correct for the product it is — every device is the owner's, and
"drive the session on your desk from your phone" is the headline feature. On a
shared demo host it means reviewer B sees reviewer A's session in the list, can
attach to it, and can type into it. Fixing that by filtering the list per device
would be a real product decision about a real feature, taken under schedule
pressure, for the benefit of strangers — exactly the "special mode for outsiders"
that `CONFINEMENT.md` rule 5 rules out.

**So: one container per visitor.** `docker run --rm` per allocation, a hard cap
of four concurrent, each with its own host identity, its own state dir, its own
enrolment. Two reviewers get two machines and cannot observe each other at all.
The cap is honest: past four, the page says the demo is busy and to try again in
a minute, which is a true sentence about a small machine rather than a queue we
have to build.

**A reviewer who breaks the session** is the easy case and it is why the
container shape is right. Kill the shell, fill the disk, fork bomb, `rm -rf`
their playground — the blast radius is a container with a `--memory` ceiling and
a `--pids-limit`, and the cure is that the next visitor gets a new one. Add a
hard twenty-minute lifetime so an abandoned session cannot hold a slot, and reap
on detach. **The reset between sessions is structural** — the container is
destroyed — rather than a cleanup script, which matters because a cleanup script
is a thing that runs on the machine the attacker is standing on.

**Reachability is still assumed, and §2 was right to flag it.** The relay answers
from Dubai — `{"ok":true,"hosts":1,"guests":0}`, measured today — and that is one
vantage point. App Review is not all in one place. Measure it from a US and an
Asian egress before submitting; it is cheap, and "we were unable to connect" is
the one rejection nobody here can reproduce.

### 6.7 Yes, it is the browser demo — and that changes its value a lot

It is the same machine, the same broker and the same page. `app.terminaldeck.dev`
is live (HTTP 200 today), the browser client already speaks the relay endpoint
shape (`pwa/src/endpoint.ts`), and — unlike iOS — it already accepts a **typed
eight-character code** through the relay rendezvous (`pwa/src/rendezvous.ts`). So
"try it in your browser, right now, no download" is the *same* build with a
different button on the same page: allocate a slot, open `app.terminaldeck.dev`
pointed at it, done.

That is worth a great deal. It is the best available answer to Guideline 4.2 as
well — an app you can watch working before installing anything is not a thin
front end — and on the marketing site it converts far better than a screenshot.

**But it is a strictly larger exposure and must not ship on the same day.** The
review path is one URL given to a handful of named people; the public path is
every stranger and every bot on the internet, continuously. Before it goes on the
homepage it needs a per-IP rate limit, a real concurrency cap, an abuse contact,
and a week of watching the egress rules with the door only half open. So: build
it at `/review`, unlisted, for submission. Promote it to `/demo` and link it from
the homepage afterwards, on purpose, as its own decision.

### 6.8 First three things to build

1. **The demo box and its image.** A CX23, Debian or Ubuntu, unattended
   upgrades, inbound firewalled to nothing, **egress default-deny except DNS and
   the relay**, no tailnet, no keys. On it, a container image built from
   `npm run dist:headless` — *not* from npm, because `npm view terminaldeck
   version` is **0.0.1**, a 3 KB name reservation whose own description says
   "This package is not the app". The image runs a non-root `demo` user, a
   read-only root filesystem, a size-capped tmpfs home, one seeded playground
   folder with a real small git repo in it, and a plain `bash` — no agent CLI,
   because a signed-out CLI looks broken and a signed-in one is our token in a
   stranger's shell. Definition of done: pair a real iPhone to it over the real
   relay and read `uname -a` on the phone.
2. **Public-host mode in the headless build, plus the redeem event.** The
   explicit mode that advertises `create` only, approves a device that redeemed a
   code it minted, prints what it is in `status` and in the session's motd, and
   cannot be entered by a normal host. Alongside it, the control-socket event
   when a device redeems — which also deletes "Press Enter" from `terminaldeck
   pair` for everyone.
3. **The broker and the `/review` page.** Allocate a container, ask it for a
   code, return `terminaldeck://pair?…` plus a QR plus a countdown, reap on
   detach and at twenty minutes, refuse past four. Unlisted. Then write the review
   notes around it, and record the two-minute video (§2, option C) as the thing
   that resolves an ambiguous rejection in one reply instead of three.

Everything else in §4 stands and is not blocked by any of this — in particular
`terminaldeck.dev/privacy` and `terminaldeck.dev/support` are still **404**, and
so is `terminaldeck.dev/install.sh`, which `scripts/install-headless.sh` prints as
the way to install a host.

### 6.9 Measured, not assumed — 2026-08-15

Everything above that claims a fact came from one of these. Read-only throughout;
nothing on the relay box was changed.

    curl -fsS https://relay.terminaldeck.dev/healthz
      → {"ok":true,"hosts":1,"guests":0}

    curl -o /dev/null -w '%{http_code}' https://app.terminaldeck.dev/   → 200
    …/terminaldeck.dev/            → 200
    …/terminaldeck.dev/install.sh  → 404
    …/terminaldeck.dev/privacy     → 404
    …/terminaldeck.dev/support     → 404
    …/terminaldeck.dev/demo        → 404

    dig +short relay.terminaldeck.dev A     → 178.105.248.86
    dig +short relay.terminaldeck.dev AAAA  → (nothing)

    ssh root@178.105.248.86 'nproc; free -m; df -h /; uptime; docker ps'
      → 2 vCPU; 3805 MB total, 2276 MB available; 38G disk, 26G free;
        up 80 days; 9 containers — terminaldeck-relay, coolify,
        coolify-proxy, coolify-db, coolify-redis, coolify-realtime,
        coolify-sentinel, evolution-… (up 2 months), postgres-… (up 2 months)

    ssh root@178.105.248.86 'docker network inspect coolify …'
      → coolify 10.0.1.5 · terminaldeck-relay 10.0.1.7 · coolify-proxy 10.0.1.6
        coolify-redis 10.0.1.4 · coolify-realtime 10.0.1.3 · coolify-db 10.0.1.2

    ssh root@178.105.248.86 '… docker inspect … .Mounts …'
      → coolify-proxy   ⇒ /var/run/docker.sock
        coolify-sentinel⇒ /var/run/docker.sock
        coolify         ⇒ /data/coolify/ssh, /data/coolify/source/.env, …
        coolify-realtime⇒ /data/coolify/ssh

    ssh root@178.105.248.86 'ss -tlnp'
      → 0.0.0.0:8000, 0.0.0.0:8080, 0.0.0.0:6001, 0.0.0.0:6002,
        0.0.0.0:443, 0.0.0.0:80, 0.0.0.0:22

    npm view terminaldeck version   → 0.0.1
    npm view terminaldeck description
      → "Name reservation for Terminal Deck … This package is not the app"
    npm view terminaldeck dist.unpackedSize → 3094

Read in the tree, with the line that matters:

    ios/TerminalDeck/Transport/PairingCode.swift:188  parse() requires a URL scheme
    ios/Support/Info.plist:66                          CFBundleURLSchemes = terminaldeck
    ios/TerminalDeck/App/TerminalDeckApp.swift:48      .onOpenURL { model.open($0) }
    src/main/remote/device-auth.ts:142                 PAIRING_TTL_MS = 60_000
    src/main/remote/server.ts:1327,1502                sessions.list() — no device filter
    src/headless/daemon.ts:57,111                      control token 0600 beside a 0700 state dir
    src/headless/main.ts:190-230                       machines:code mints a code + relay beacon
    src/main/confine/index.ts                          confinementKind('linux') === 'none'

Guideline text read from <https://developer.apple.com/app-store/review/guidelines/>
on the day. Hetzner pricing is post-April-2026 and ex-VAT; EC2 mac2 figures are
the 24-hour-minimum lease, quoted only to show the order of magnitude.

**Not run:** no build, no `electron-builder`, no deploy, no git operation, and
nothing was created on any server. The demo box does not exist yet.

---

## 7. Built — 2026-08-15

§6 was a decision. This is what exists, measured on the machine it runs on. The
sentence at the end of §6.9 — *"The demo box does not exist yet"* — is no longer
true, and nothing else in §6 has been contradicted.

### 7.1 The demo machine

`terminaldeck-server`, Hetzner **CX23**, `178.105.239.176`, Ubuntu 24.04,
**Nuremberg** — `nbg1-dc3`, read from the instance's own metadata service rather
than from the order page, because an earlier draft of this line said Falkenstein
and the demo's motd tells a reviewer which country they are in.
Labelled `project=terminaldeck, role=demo-host`. It is not the relay
box. It carries no tailnet, no ssh key of ours but the one that reaches it, no
cloud token, no git credential and no repository. Its entire contents are a
Docker image, a broker and the two scripts in `demo/`.

- **Inbound**: Hetzner cloud firewall `terminaldeck-demo-firewall` (id
  `11469876`), attached, allowing **22, 80, 443** and nothing else.
- **Egress for visitors**: default-deny on the `td-demo` bridge
  (`172.31.240.0/24`), reapplied at boot by `td-demo-firewall.service`. DNS and
  `178.105.248.86:443` — the relay — are the only ways out. Everything else,
  including the host itself, is dropped.
- **Docker runs with `userns-remap`**, so a container's root is host uid
  `100000`, an account that owns nothing. Measured: a `sleep` started as root
  inside a container shows as uid `100000` in `ps` on the host.
- Unattended upgrades installed.

Rebuild it with `./demo/deploy.sh`, check it with `./demo/deploy.sh --check`.

### 7.2 One container per visitor

`demo/broker/broker.mjs`, a zero-dependency Node service behind Caddy. `POST
/allocate` starts a container, waits for it to report that it is **on the relay**,
asks it for a pairing code and returns a `terminaldeck://pair?…` link. `POST
/code` mints another code for the same machine, which is what the page's "get a
new code" button is for. Four concurrent, one allocation per address every twenty
seconds and ten an hour, and an honest refusal past that.

The container is `--rm`, so the reset between visitors is structural rather than
a cleanup script — a cleanup script is a thing that runs on the machine the
stranger was standing on. It ends itself: five minutes if nobody pairs, ninety
seconds after the last device leaves, twenty minutes whatever happens.

TLS is on `178-105-239-176.sslip.io`, with a real Let's Encrypt certificate.
terminaldeck.dev's nameservers are at GoDaddy and nothing in this repository can
create a record there, so a subdomain was not available; `sslip.io` resolves the
address in its own domain, which makes HTTP-01 answerable here. It is an origin
the review page fetches from, never a hostname anybody types.

### 7.3 The confinement, and what was measured rather than assumed

The visitor's shell is `/usr/local/bin/demo-shell`, reached the ordinary way: the
image sets `SHELL`, and `providers.ts` starts a plain session as `$SHELL -l`.
Nothing in the product knows the demo exists. `confinementKind()` still answers
`'none'` on Linux and the demo does not claim otherwise.

It is CONFINEMENT.md's measured mechanism: a private mount namespace, a tmpfs
over `/home` with the playground bound back in, a private `/proc` in its own PID
namespace, and then **`setpriv --bounding-set=-all --inh-caps=-all`** dropping to
an unprivileged uid. That last line is the one that file measured as the
difference between a boundary and a decoration, and it is measured again here:
with the capability bounding set emptied, `umount /home` answers *"must be
superuser to unmount"*.

`demo/escapes.sh` runs the escape table against a live container, through the
same `demo-shell` a real session runs through, with the flags the broker actually
uses (read out of `broker.mjs --print-run-flags`, so the suite cannot drift into
measuring a container nobody runs). Latest run, 2026-08-16, after the network was
rebuilt with `enable_icc=false`: **23 held, 0 escaped.**

It refuses to score a run whose shell did not start, and that rule was earned:
the first version of `demo-shell` could not build its mount namespace on a
read-only root filesystem, exited before running anything, and sixteen escape
tests reported *held* against a shell that had never existed. A suite that scores
silence as safety is worse than no suite.

| Row | Result |
|---|---|
| `umount /home` after `setpriv` | refused; the tmpfs is still there |
| nested user namespace to regain `CAP_SYS_ADMIN` | refused at `/proc/self/uid_map` |
| `/proc/1/root` to the host's files | denied |
| the host process visible in `/proc` at all | not visible — own PID namespace |
| symlink out of the playground | resolves into the tmpfs; nothing gained |
| absolute path to the host's home | denied |
| `/mnt/c` interop | not applicable, asserted anyway |
| **the host's 0600 control token** | unreadable |
| **the host's control socket** | unreachable |
| capabilities held by the visitor | all four sets `0000000000000000` |
| root filesystem | read-only |
| Docker socket | absent |
| the demo host's own program | not writable |
| relay reachable | yes — the session depends on it |
| 1.1.1.1, github.com, the relay box's ssh, the broker | all unreachable |
| **another visitor's machine, on a port it really is listening on** | unreachable — see below |
| filling the disk | bounded by the tmpfs cap |
| fork bomb | container and box both still standing |

**What that cost, stated plainly.** Docker's default AppArmor profile permits
`umount` and not `mount`, so `unshare --mount` fails at *"cannot change root
filesystem propagation"* under it. The container therefore runs with
`--security-opt apparmor=unconfined` and `--cap-add SYS_ADMIN`, which is what the
mount namespace needs. The visitor never holds either: `setpriv` empties the
bounding set before their shell starts, and `userns-remap` means the root that
does hold them is host uid 100000. That trade is a judgement, it is written down
here, and the alternative — no mount namespace at all — was the other candidate.

Also true and less obvious: **uid separation is what protects the control token**,
not the mount. The headless daemon keeps a 0600 token beside a 0700 state dir and
spawns sessions as the same uid (`daemon.ts:57,111`), so on a machine you own a
session can drive the control socket and grant itself every folder. Here the
demo host is the container's root and the visitor is 1001, and that is the reason
the two rows in bold above pass.

### 7.4 What changed in the product, and what did not

Nothing in `device-auth.ts`. `PAIRING_TTL_MS` is sixty seconds, tokens are
single-use, five wrong answers still kill a code.

- `src/headless/public-host.ts` — the policy: approve a device that redeemed a
  code this host just minted, grant it the playground and nothing else, advertise
  `create` only, end when the visitor leaves. It is a decision object with no
  process in it, so its own tests need no machine.
- `src/headless/demo.ts` — the only program that can turn that on. Not an
  environment variable, because an environment variable can be inherited, set by
  a systemd drop-in or baked into an image; a second entry point cannot be
  arrived at by accident. It is built but deliberately not in the npm package's
  `bin` or `files`.
- `src/main/remote/server.ts` — two additive seams: `offer`, a *ceiling* on what
  a host advertises (it can only remove, never promise), and `onDevicePaired`,
  which fires the moment a code is redeemed.
- `src/main/remote/relay-client.ts` — `onState`, so a headless host can say "I am
  reachable" from an event instead of being asked repeatedly.
- `terminaldeck pair` **no longer asks anybody to press Enter.** The redeem event
  gave it something to wait on, and its own comment said that was the only reason
  a person was standing in for one.
- `src/headless/public-host.test.ts` asserts that neither the desktop's
  `index.ts` nor the ordinary `daemon.ts` can reach this mode, that no
  environment variable switches it on, and — by grepping the whole of `src` —
  that exactly one file turns it on. It also drives a real `RemoteAuth`, a real
  `PairingDesk` and the real `authenticatorFor` end to end: a device that redeems
  the code this host minted comes back approved and gets in on its second
  connection; a guessed code creates nothing; the same code twice is refused.
- The pairing link is built by `relayPairingLink` in `src/shared/pairing-link.ts`
  — the function the desktop's own Pair panel calls — reached over a `demo:link`
  control channel. The broker's helper assembled it by hand first, which was a
  second implementation of a format four programs have to agree on.

`npm run typecheck` is clean and `npx vitest run` is **5420 passed, 4 skipped**.

### 7.5 App Review Information — ready to paste

**Sign-in required:** No.

**Demo account:** leave blank. There is nothing to sign in to, and there is no
credential that would still work by the time anybody read it — a pairing token
lives sixty seconds and one use. That is the point of §6.1, and the URL below
mints a real one at the moment it is tapped.

**Contact:** Asad Iqbal · hello@terminaldeck.dev

**Notes** — paste from here to the end of this block:

> Terminal Deck is a client for a computer you own, like an SSH client: the app
> attaches to terminal sessions running on your own Mac, PC or Linux server. The
> phone draws characters and sends keystrokes; every process runs on the far
> machine.
>
> **So that you can review it without setting up a computer, we run a real Linux
> machine for you.**
>
> On the iPhone or iPad, open https://terminaldeck.dev/review in Safari and tap
> "Start a demo machine", then "Open in Terminal Deck". The app opens and pairs
> itself — nothing to type, no account to make. When the badge under the title
> says Connected, tap "New session", then type `uname -a`. That output is a real
> server in Nuremberg, Germany. The machine is yours alone, it is destroyed when
> you disconnect, and the page works as many times as you like.
>
> Start to finish this takes about twenty seconds.
>
> If you would rather see it before installing anything, the same machine is
> reachable from a browser: the page shows an eight-character code to type into
> https://app.terminaldeck.dev.
>
> Two things about the demo machine that are deliberate, so they are not mistaken
> for faults. Its outbound network is firewalled off except for the connection
> that carries your session, so `git clone`, `npm install`, `curl` and `ping`
> will not reach the internet from it. And pairing codes expire after sixty
> seconds and can be used once — that is the real product behaviour, not a demo
> restriction; the page has a button for a fresh one.
>
> **Guideline 2.5.2** — nothing is downloaded, compiled or executed on the
> device. The app contains a VT100 terminal emulator (SwiftTerm) and a network
> client, and it interprets bytes for display. Every process runs on the user's
> own computer.
>
> **Guideline 4.2** — this is the same category as Termius, Blink and Prompt, all
> of which require a machine the user already owns. What is native here rather
> than a web view: a real terminal emulator, an end-to-end encrypted transport
> (Noise IK over a relay that cannot read the traffic it carries), file transfer,
> and a hardware-keyboard-aware key bar.
>
> **Privacy** — the app collects nothing. No analytics SDK, no crash reporter,
> one third-party package (SwiftTerm). The relay carries ciphertext it cannot
> decrypt.

### 7.6 Still to do before submitting

1. `terminaldeck.dev/privacy` and `terminaldeck.dev/support` are **still 404**
   and are mandatory. Re-checked 2026-08-16 and both still answer 404.
   `terminaldeck.dev/review` **is** published now and answers 200.
2. **Pair a real iPhone.** Largely answered — see §7.8, which ran the whole chain
   twice on a freshly erased iOS 26.5 simulator against the live box. What is
   still outstanding is narrower than it was: physical hardware, and the one tap
   in Safari that turns the page's button into the `terminaldeck://` open. Both
   halves either side of that tap are now proved.
3. **Measure the relay from a US and an Asian egress.** Still an assumption, and
   still the one rejection nobody here can reproduce.
4. Screenshots, description, age rating, privacy label.
5. Record the two-minute video (§2, option C).
6. An uptime check on the demo box that reaches a human. The page fails honestly
   when the box is down — it is hosted elsewhere for exactly that reason — but
   nothing tells us it has happened.

### 7.7 Proved by running it, 2026-08-16

    curl -sS https://178-105-239-176.sslip.io/healthz
      → {"ok":true,"slots":4,"inUse":0,"free":4}

    curl -X POST -H 'Origin: https://terminaldeck.dev' …/allocate
      → {"ok":true,"slot":"…","link":"terminaldeck://pair?v=1&r=wss%3A%2F%2F…
         &h=<26 chars>&k=<43 chars>&t=GT1C-CGQB","code":"GT1C-CGQB", …}

    curl -o /dev/null -w '%{http_code}' https://terminaldeck.dev/review   → 200

    docker exec <container> node /opt/terminaldeck/cli.mjs status
      → "PUBLIC DEMO HOST. This host approves any device that redeems a code it
         just minted, grants it /home/visitor/playground and nothing else, and
         advertises create only…"  and  "Relay  connected  wss://relay.terminaldeck.dev"

    a container with its arrival deadline set to 30 seconds
      → exited after 30s, `--rm` removed it, nothing left behind

    reboot the box, then all of the above again
      → broker up, egress rules reapplied by td-demo-firewall.service,
        allocation works, 22 held / 0 escaped

**Not proved, and it is the one that matters most:** nobody has tapped the link
on an iPhone. Everything up to and including a real container handing back a real
`terminaldeck://pair?…` link over the public HTTPS endpoint has been run; the tap
has not, because this session had no device and no working headless browser to
drive the web client with. Until somebody reads `uname -a` on a phone, §6.8's
definition of done is not met.

*(Answered on 2026-08-16 — see §7.8. Kept above as written, because the shape of
what was missing is the point.)*

**Not run in this session:** no `electron-builder`, no git commit, no deploy of
the marketing site, and nothing on the relay box was changed.

---

## 8. Walked through as the reviewer — 2026-08-16

§7 built it and could not try it. This section is the try: a **freshly erased iOS
26.5 simulator**, so no stored pairing and no keychain entry, driven twice
through the instructions in §7.5 exactly as they are written, against the live
box. Everything below is timed or screenshotted; nothing is inferred.

### 8.1 The walk, and the clock

The harness is `ios/UITests/RealDesktopUITests` unchanged — it stands at the
pairing screen and waits for a `terminaldeck://` link to appear in a file, which
is the same shape as a reviewer standing at the pairing screen waiting for the
page. Nothing in the app, the host or the image was modified to make it pass.

| Step | Clock |
|---|---|
| Reviewer asks the page for a machine (`POST /allocate`) | 0.0 s |
| Container up, on the relay, real pairing link in hand | **2.4 s** |
| Link opened in the app, code submitted | 7 s |
| **Connected — with nobody anywhere to approve it** | **10 s** |
| Session started, live shell drawn | **18 s** |

**Eighteen seconds from tap to a working terminal**, and 18 s again on the second
run after a second erase. The two-minute bar is not close.

What was on the screen, in a session the phone started itself:

    ~/playground $ hostname
    terminaldeck-demo
    ~/playground $ stty size
    26 54
    ~/playground $ sleep 300
    ^C
    ~/playground $

Nothing echoes locally — `TerminalBridge` draws only what arrives through the
sealed channel — so that output was produced by a shell in Nuremberg. `sleep 300`
was a real process and Ctrl-C really killed it.

**The one substitution, said plainly.** The reviewer's *tap in Safari* was not
performed. `idb` on this Mac is broken under Python 3.14 and `osascript` has no
assistive access here, so nothing in this session could tap a button inside the
simulator. What was done instead is the exact call the page's button makes
(`POST /allocate` with the page's `Origin`) and the exact URL open that tapping
"Open in Terminal Deck" produces. Both halves either side of the tap are proved;
the tap is one `<a href>` and it is the only thing left. **This is also a
this-machine limitation rather than a product one** — on a Mac with accessibility
granted, or on hardware, it is a finger.

### 8.2 What the walk found, which is why it was worth doing

Three defects, none of which any test or escape row could have caught, and two of
which a reviewer would have seen in their first ten seconds.

**1. The demo's greeting was unreadable on a phone.** `stty size` above is the
evidence: the phone is **54 columns**, and `motd()` was written in lines of up to
74. So the reviewer's first screen read `running the r` / `eal Terminal Deck
host.` and `so gi` / `t, npm`. Fixed — the lines are held to 44 columns now, with
`public-host.test.ts` asserting the ceiling and asserting it again with a
three-digit lifetime, because the natural way to edit a motd is in an editor
eighty columns wide.

**2. macOS resource-fork files were shipped into the demo and baked into the
image.** `ls -a ~/playground` on "a real Linux machine in Germany" showed
`._README.md` and `._hello.sh`. `tar` on macOS writes an AppleDouble sidecar for
any file carrying an extended attribute, `deploy.sh` tarred the staging directory
from this Mac, and `docker build` baked the result into `/opt/demo-seed`. All 22
escape rows passed the entire time, because nothing about it is a security
question. Fixed in `deploy.sh` with `COPYFILE_DISABLE=1`, a `--exclude '._*'`,
and a `find -delete` on the box so that a machine already contaminated is
cleaned rather than rebuilt from its own junk.

**3. Visitors could reach each other at the IP layer.** Measured with four
containers up: one could open a connection to another's address. Nothing
answered — every listener in a demo container is bound to `127.0.0.1` — but
"nothing was listening" is a fact about that day's process list, not a boundary.
The egress rules could not have stopped it either: container-to-container on one
bridge is bridged rather than routed, and this kernel has no `br_netfilter`, so
`DOCKER-USER` is never consulted. The demo network is now created with
`enable_icc=false`, `deploy.sh` recreates a network that predates the flag rather
than silently leaving it, and `escapes.sh` has a row that stands up a second
container with a **real listener on 0.0.0.0** and proves it cannot be reached.

### 8.3 Attacked again, after all of that

`./demo/deploy.sh --escapes` — **23 held, 0 escaped**, including the new
neighbour row, and with `the relay is reachable` still passing, which is the row
that would break if the network had been cut too far.

Beyond the table:

- **`rm -rf ~`** — the playground is a mount point, so it answers *"Device or
  resource busy"* and survives; everything else in the home goes, and the next
  session the app starts comes up normally in the same container. The host
  process, its control socket and the broker are all untouched.
- **Rate limiter, attacked rather than assumed.** `broker.mjs` keys its limit on
  `x-forwarded-for`'s *first* value, which is spoofable in general. It is not
  spoofable here: Caddy ≥2.7 replaces the header for an untrusted client, and a
  request carrying `X-Forwarded-For: 203.0.113.7` was still refused against the
  real address's bucket. **This holds because of Caddy's default, not because of
  the broker** — adding `trusted_proxies` to the Caddyfile would silently make
  the limiter bypassable.
- **Four at once.** Four simultaneous visitors, four separate containers, four
  separate pairing links; a file written in one is absent in another; the fifth
  caller gets the honest `busy` refusal rather than a queue or a hang.

### 8.4 One thing that is not what its comment claims

`PUBLIC_HOST_OFFER` narrows what the demo advertises to `create`. For `upload`
and `credential` that narrowing is enforced twice — the demo host is built with
no uploads directory and no credential proxy, so the verbs are refused by
`server.ts` even if sent. **For `localhost` it is not enforced at all.**
`server.ts` routes `ports`, `tunnel.open`, `tunnel.close` and `net.*` straight to
the tunnel hub without consulting the offer, so a client that sends the verb it
was never offered is served.

It is worth nothing on this box, and the reason is measured rather than argued:
`demo-shell` unshares the mount and pid namespaces but **not** the network one,
so a visitor's shell already reads the same `/proc/net/tcp` the host process does
and can already reach the container's loopback with `exec 3<>/dev/tcp/...`. The
tunnel hub will also only dial a port something is already serving. So it grants
no reach a visitor does not have, and the container and the egress rules bound
both.

It is still an enforcement gap rather than a design, and the fix belongs in
`server.ts` beside the `create` and `upload` refusals — a host that narrows its
offer should narrow what it *serves*, on every host, not only this one. Left
alone here deliberately: `server.ts` is not this workstream's file, and the
comment in `public-host.ts` that overstated it has been corrected to say exactly
which two of the three are enforced.

### 8.5 Still not done

- **Physical hardware, and the Safari tap** (§7.6 item 2, narrowed).
- **`/privacy` and `/support` are still 404** and are mandatory.
- **`review.html` tells the reviewer the wrong gesture.** Its "Once you are in"
  list says *"Tap the folder to start a session"*, and a reviewer arriving on a
  brand-new machine has no folder to tap — the screen says "No sessions" with a
  **New session** button, which is what §7.5 now says. One word on a page in the
  site repository, which is not this workstream's tree.
- The UI harness fails on a step *after* everything above — the app's Copy Screen
  path, where the software keyboard does not come back up after the key grid has
  been used for Ctrl-C. Reproduced identically on both runs. It is in `ios/` and
  is nothing to do with the demo, but it is a real failing assertion and should
  not be discovered by someone assuming this suite is green.
- **Not run:** no `electron-builder`, no git commit, nothing on the relay box,
  and no change to the marketing site.
