# 0.2.0 — the plan

Asad, 2026-08-16, going to sleep: *"make a proper plan and start building and
start pushing live no more discussion no more questions … you are decision
makers."*

So this document decides. Where he gave a preference it is followed exactly;
where he did not, a decision is made and the reasoning written down so he can
overrule one line rather than re-open a conversation.

---

## 1. The Windows window is wrong, and it is the first thing anyone sees

His screenshots put Claude's Windows window next to ours. Claude's is one
integrated bar. Ours is **three stacked strips**: the OS title bar with "Terminal
Deck" and the minimise/maximise/close buttons, then a native menu bar (File Edit
View Window Help), then our own chrome underneath. It reads as an old Win32 app
wearing a modern app's clothes.

**Fix:** one bar. A frameless window with our own chrome and native window
controls drawn where Windows expects them, and the File/Edit/View menu folded
into the app rather than sitting in an OS strip. macOS already does this — the
traffic lights sit in our own header — so this is Windows catching up to the Mac,
not a new design.

Getting this right is worth more than it sounds: it is the difference between
"this is a real Windows app" and "this is an Electron app" on first launch.

## 2. Machines and Remote become one thing

Two sidebar entries for one idea — *other devices that can reach this machine*.
He wants one. **Decision: keep "Remote", fold Machines into it.** A phone and a
laptop are both just a paired device; the section is about who can reach this
computer, not about what kind of hardware they are.

## 3. One pairing method: a six-digit code

Today there are three ways in — a QR code, a long link, and an eight-character
code — and he reports the **QR does not work at all**.

**Decision, exactly as he asked:**
- **Six digits. Nothing else.** No dashes, no letters, no mixed alphabet.
- **The link goes away entirely**, everywhere: desktop, phone, browser client.
- **The QR goes away** rather than being fixed. A code you type is one thing to
  explain and one thing to keep working; a QR is a second path that must be kept
  alive on four clients, and it is already broken on one.

**The security consequence, and it must be handled rather than waved past.** Six
digits is a million combinations against the current eight characters' trillion.
That is only safe because of what already surrounds it: the code lives 60
seconds, it is single-use and burned on match, and five wrong guesses burn it
too. Those three must be verified as still true after the change, and the
five-guess limiter must be exercised in a test that would fail if someone removed
it. Without the limiter this is a materially weaker product.

**And that argument only covers pairing a phone or a browser**, where the code is
checked *online* by the desktop and the limiter is what makes it safe. PC-to-PC
pairing is a different mechanism with a different exposure: `rendezvous.ts`
derives the Noise **responder static key from the code itself**, deliberately, so
that a hostile relay cannot get in the middle. That design has no rate limiter to
hide behind — a relay can record the handshake and search the code space
*offline*. The file prices it in its own comment: memory-hard scrypt at 36ms and
16MB per guess puts a full 2^40 search at roughly four months of a dedicated rig.
Against 10^6 the same rig finishes in minutes, inside the window where a live
man-in-the-middle is still useful. Six digits would quietly convert a stated
defence into a practical attack.

**Resolved: six digits everywhere, and the cost moved somewhere a human cannot
feel it.** Twelve digits was floated and he rejected it — *"over secured … not a
good feeling for a human"* — and his counter-argument is correct on its own
terms: redeeming a code creates a *pending* device that somebody has to approve
on the other machine, so for an attacker trying to get **in**, the code was never
the only gate. Add the rate limit he asked for and the online path is sound at
six digits.

That leaves exactly one case his argument does not reach: the **offline** one,
where a hostile relay recovers the code from a recorded handshake. No rate limit
and no approval button applies there, because the attacker is not asking anyone
for anything. But the price of that attack is a number this codebase sets, so it
gets set higher:

- **Raise the rendezvous KDF to `N=65536, r=8, p=1`.** Measured on this Mac:
  36.6ms/16MB today, 146.7ms/64MB at the new setting, 293.5ms/128MB one step
  beyond. 147ms is paid **once, while pairing**, where it is invisible; 64MB per
  guess is the half that actually hurts a GPU rig, since memory is what stops one
  card running thousands of guesses at once. 128MB was rejected as the phone
  clients have to run this too now that the link is gone.
  `RENDEZVOUS_SALT` is already versioned for exactly this, so the change is one
  line and two mismatched builds simply fail to find each other rather than
  half-completing a handshake.

  **And the honest arithmetic, because 4× does not cancel 1,100,000×.** At six
  digits and 147ms, the full space is ~41 CPU-hours of memory-hard work. To crack
  inside the code's own sixty seconds an attacker needs on the order of 2,500
  cores holding ~157GB of scrypt state — a real datacenter, rented for one
  minute, to steal one pairing, while also controlling or wiretapping the relay
  at that exact moment. That is a defensible place to land and it is *not* the
  four-month margin the eight-character code had. The comment in `rendezvous.ts`
  must say so in those terms; its current text prices a 2^40 search and would
  become a false statement the moment the code shortens.
- **Rate-limit redemption**, at the host and at the relay, on top of the existing
  five-strikes-and-the-code-dies.
- **Make the approval screen worth approving**: the requesting device's name and
  the channel fingerprint, so an impersonation is something you can *see* rather
  than something you have to reason about. The approval step is load-bearing in
  his argument, so it has to actually carry the weight.

He is also right that PC-to-PC was never "a long code" — it is `H4K9-2FQT`, eight
characters. Six digits is a reduction from it, taken deliberately, with the
compensation written down above rather than assumed.

Also required: the iOS, Android and browser clients must accept six digits, and
the "That code has expired. Show another one." path in his screenshot must stay —
it is correct behaviour and the message is good.

## 4. GitHub is connected wrong

His screenshot of the authorisation page shows **"Full control of private
repositories"** and no way to choose which. Then, after connecting, the app shows
no repositories to pick from.

**Two separate faults:**

**(a) Too much access.** We authorise through the GitHub CLI's own OAuth app,
which asks for everything it needs for `gh`, not what Terminal Deck needs. A user
handing over full control of every private repository to run one folder is wrong,
and it is the kind of thing that stops a careful person installing.
**Decision: our own GitHub App**, requesting only what the product uses, and —
critically — GitHub Apps let the user **choose which repositories** at install
time. That is exactly the screen he expected and did not get.

**(b) Nothing to see afterwards.** Connecting should show the account, which
repositories are shared, and the current folder's repository and branch. Today it
shows almost nothing.

## 5. The four from before, still owed

From `NEXT-UPDATE.md`, unchanged and still queued:

- **"Run Claude" button** on a plain session, and no chat/account controls until
  an agent is running in it.
- **Rename an account** from the dropdown inside a session, not only in Settings.
- **Chat and terminal disagree** — two views of one session showing different
  conversations. Still the most serious item on either list.
- **The stray line at the end of chat view** — "Read from the session transcript
  — prompts and replies only." should not be the last thing on screen.

## 6. Prove it on his Windows PC, not on this Mac

Terminal Deck 0.1.9 is installed on `DESKTOP-DDGMNCV` now. Everything above ships
as an update he installs there, and then it gets **driven on that machine**: the
window chrome, a WSL session, pairing by six digits, GitHub, quit and reopen.

A dozen bugs this week existed only on a clean machine. His PC is the clean
machine.

---

## What is running, and what waits

The recording (`VIDEO-FEEDBACK.md`) roughly tripled the list, so it goes out in
waves — not for ceremony, but because agents editing one working tree in parallel
have to own disjoint files, and several of these want the same ones.

**Wave 1, running:** Windows chrome · six-digit pairing across every client ·
Machines+Remote merged · GitHub App · the four session-view items · Windows
confinement.

**Wave 2, running:** the built-in browser (start page, the behind-the-page
popups, dark empty state, top tab strip with drag) · Overview becomes a live
board of running sessions · Power, Windows session-restore, and the Features
screen.

**Wave 3, waiting on wave 1 to release `pwa/`, `ios/` and the session files:**

- The web client: full width, no phone key-bar on a desktop, localhost as well as
  terminals, and the duplicate folders in "Start in".
- iOS: a real tab bar, the desktop's options brought across, one-finger scroll
  instead of selection, and the connection chip that must stay silent for its
  first five seconds.
- Search becomes Artifacts; the Files page earns its place or loses it.
- A session's name becomes editable.
- Dropdowns close each other, and Options stops duplicating controls that already
  exist elsewhere.
- The long descriptions come out of Settings — his broadest note, and it applies
  well past the page he was looking at.
- **Accounts belong to a provider, not to Claude.** Added 06:0x, from him:
  adding an account always sends him to a Claude login, so his ChatGPT and Gemini
  logins have nowhere to go. Adding an account must first ask *which* — Claude,
  ChatGPT/Codex, Gemini — and then run that one's sign-in. And in the session
  dropdown, the connected account should carry **that provider's logo**, so the
  answer to "what am I talking to right now" is visible without opening anything.

  The plumbing is half-present: `src/main/providers.ts` already treats `claude`,
  `codex`, `gemini` and `shell` as first-class provider ids. What is Claude-only
  is the *account* concept — an account is implemented as "point Claude at a
  different config directory", which is why the Accounts screen carries a
  paragraph admitting exactly that. Each CLI has its own equivalent, so the work
  is a per-provider account strategy rather than a new idea: find each one's
  config-directory or profile mechanism, verify it genuinely isolates two logins
  (the way Claude's was verified), and refuse to offer multi-account for any
  provider where it does not — an account switcher that silently shares one login
  is worse than not offering it.

## Order

1. Windows chrome — most visible, self-contained.
2. Six-digit pairing — touches every client, so it goes early and settles.
3. Remote/Machines merge — small, and it moves what pairing lives in.
4. GitHub App — the largest single piece.
5. The four from before.
6. Ship, install on his PC, drive it there.

## 7. Found in his screen recording, not in his list

Watching the recording turned up four things he did not mention, three of which
are defects:

- **The web client lists every folder twice.** `app.terminaldeck.dev`, paired to
  his Windows PC, offers `/home/asad/ClaudeImza` and `/home/asad/ClaudeImzacrm`
  under "Start in" — and then offers both again. Almost certainly the folder list
  being concatenated from two sources, or a re-render appending rather than
  replacing.
- **Raw git stderr is leaking into the UI.** The Overview page's Git widget
  prints `fatal: not a git repository (or any of the parent directories): .git`.
  That is a command's error text, not a sentence written for a person. The
  GitHub page next to it gets the same situation right — "This folder is not a
  git repository. Run `git init` in a terminal, then refresh." Make the widget
  say that.
- **Tailscale still has a card of its own on the Remote screen**, titled "Direct
  on your tailnet", sitting level with the relay and marked "Ready". He has
  objected to Tailscale's prominence twice. It is a legitimate optional path, so
  it is not deleted — it moves under Advanced, and the relay is the only thing
  the main screen talks about.
- The stray chat line is confirmed exactly as reported — the recording catches it
  selected, with a tooltip showing the `.jsonl` transcript path behind it.

## 8. What 0.2.0 can actually be released as

Two facts settled while the build ran, both of which shape the release rather
than the code.

**macOS cannot be notarized, still.** Checked again at 05:52: the 330-byte probe
submitted at 00:25 is *In Progress* five and a half hours later, and a submission
from the 14th has been pending thirty-one hours. Four stuck submissions across
two different auth paths is an account-level hold at Apple, not anything about
our artifact. Only Asad can clear it — Apple Developer Support, Team ID
`6U4VNX5W87`, submission `24b316a6-3d88-4035-9a2f-d04332926ff3`.

**0.1.9's macOS build went out unsigned**, which is why a stranger downloading it
is told the app "is damaged and can't be opened" — Gatekeeper's wording for an
unsigned quarantined bundle, and it reads like a corrupt download. Signing works
locally; it is only notarization that is stuck. So 0.2.0's macOS build gets
**signed with the Developer ID even though it cannot be notarized**: the warning
becomes "Apple cannot check it for malicious software", which a right-click →
Open gets past, instead of a dead end that looks like a broken file. The release
notes have to say that plainly. The CI signing step currently *fails* when
stapling fails, so it needs a signed-but-not-notarized mode before it can run at
all.

**Windows is unaffected** by any of this and is the platform he is actually
blocked on, so it is the one 0.2.0 is really for.

**One thing only he can unblock:** `.github/workflows/release.yml` cannot be
pushed — no logged-in account carries the `workflow` scope. One command fixes it:
`gh auth refresh -h github.com -s workflow`. Everything else commits and pushes
without him.

## Not in 0.2.0

App Store submission (the listing is empty and he should live with the app
first), Instagram profile (needs an Instagram login), the Facebook username
(Meta removed the API), and the daemon split that would let sessions survive
quitting the window — that one is big enough to deserve its own release.
