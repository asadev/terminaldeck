# Terminal Deck — the whole list

Written 2026-08-14. Everything Asad has asked for, what is already true, what is
left, and how each thing gets *tested* rather than assumed.

Rules that apply to every line below, from
`/Users/apple/ASAD_BUILD_PREFERENCES.md` (read it, it is the spec):

- **7.8** A UI change is not done until it has been rendered and *looked at* —
  whole frame, then zoomed crops. Never "verified" from code.
- **7.9 / 7.10** Events over polling; one scheduler, not many.
- **7.11** Least resistance. The user says it and it is done.
- **No unreachable features.** If it exists, there is a way to click it. This has
  bitten this project five times and `reachable.test.ts` exists because of it.
- **No fake data, ever.** A fixture must say it is a fixture.

---

## A. What Asad asked for

### A1 — Reach (done, mostly)
| # | Requirement | State |
|---|---|---|
| A1.1 | Remote access with **no Tailscale, no VPN** | ✅ relay live |
| A1.2 | **No online/offline toggle** — it just works | ✅ by design |
| A1.3 | Relay must not be able to read sessions | ✅ Noise IK, test asserts it |
| A1.4 | Paired devices last **forever**, until revoked | ✅ no expiry exists |
| A1.5 | Stays connected across sleep, network change, restart | ✅ Android: wifi+data killed, re-attached, fresh conn id, no leaked channel |

### A2 — Platforms
| # | Requirement | State |
|---|---|---|
| A2.1 | macOS | ✅ **0.1.8**, self-updated 0.1.4→0.1.5→0.1.6 through its own updater. Relay dialled at launch, verified `ESTABLISHED` to 178.105.248.86. **Ad-hoc signed** — Gatekeeper rejects it for anyone but Asad; Developer ID cert is the one thing needing his sign-in (`SIGNING-HANDOFF.md`) |
| A2.2 | Windows | ✅ **0.1.8 installed and launched on `desktop-ddgmncv`**. Remote session over the LIVE relay answered `DESKTOP-DDGMNCV`, with **no manual start**. Both former gaps closed: in-app update installs itself (`quitAndInstall(true, true)` — the default omits `/S` and an assisted installer then sits waiting for a click), and the localhost tunnel now resolves the loopback family by connecting, so IPv6-only dev servers work |
| A2.3 | iOS | ✅ TestFlight **build 3** (0.1.4, `2608140303`) VALID. **Proven against the REAL packaged desktop over the live relay** — see W10 |
| A2.4 | Android | ✅ verified vs REAL desktop over LIVE relay; signed release APK built |
| A2.5 | Windows download on the website | ✅ terminaldeck.dev live at **0.1.8**. All three redirects verified 200 — `/download/mac` → `terminaldeck-0.1.8-arm64.dmg`, `/download/windows` → `-x64-setup.exe`, `/download/windows-portable` → `-x64-portable.exe`. Hero CTA flips to Windows on a Windows UA. Note the macOS download is unsigned until the Developer ID cert exists, so a stranger is stopped by Gatekeeper |

### A3 — Features
| # | Requirement | State |
|---|---|---|
| A3.1 | Attach to a running session from the phone, with scrollback | ✅ proven on real hardware path (Android) |
| A3.2 | Start / resume sessions from the phone | ✅ iOS: real `claude` PTY started from the phone, typed into, resumed with replay. Android needs 3 literals. |
| A3.3 | **Localhost tunnel** — see the Mac's dev server on the phone | ✅ raw TCP tunnel, hot reload proven |
| A3.4 | Tunnel must be seamless: tap a port, no typing | ✅ ports self-populate, tap is the consent |
| A3.5 | npm name claimed | ✅ `terminaldeck@0.0.1` |
| A3.8 | **Clipboard both ways** — phone→terminal and terminal→phone | ✅ **BOTH PLATFORMS, both ways, read from outside the app.** iOS: `xcrun simctl pbpaste`. **Android copy-out proven 2026-08-14 10:00** against the packaged 0.1.6 desktop over the live relay: a sentinel was written to the *device* clipboard from the host first (`TD-SENTINEL-3096630044`, read back to prove the reader works), the Mac's zsh printed `TD-COPYOUT-1795431617-11708-Asads-MacBook-Pro-21.local` — the `11708` is the Mac's own `$RANDOM` and the phone only ever typed the literal `$RANDOM`/`$(hostname)` — and after Copy Screen the host read **367 bytes** back off the device clipboard containing it, sentinel gone |
| A3.9 | **Send files/photos/videos from the phone into the terminal**, with progress, landing at a real path | ✅ **ANDROID PROVEN end to end 2026-08-14 10:14**, phone → live relay → packaged **0.1.6** desktop. 6,291,456 bytes landed at `/Users/apple/Downloads/Terminal Deck/td-upload-1103129917.bin`, **SHA-256 identical on both sides** (`f2af01a6…b4e9f9`, `sha256sum` in the guest vs `shasum -a 256` on the Mac). Progress is real: the Mac's `.part` grew monotonically 0 → 6 MB in steps that are **every one a multiple of 24576** (`MAX_UPLOAD_CHUNK_BYTES`), and the frame where the phone said "840 KB of 6.0 MB" is the second the Mac had written **exactly 860,160 bytes = 840 KB** — the bar counts what the Mac acknowledged, and lags it. A second file was sent with `shasum -a 256 ` already typed, so the pasted path completed the command: the Mac answered `e7bf1a35…d75c3b`, matching. **iOS half still UNPROVEN against the real desktop** — see W14 |
| A3.7 | **Multi-host**: one phone paired to many machines at once (several Macs *and* Windows), sessions separate, switch between them | ✅ both platforms. Pairing adds, never replaces. Routing proven from the hosts' own `/input`: `echo TD-WORKPC-MARKER` with the PC selected arrived at the PC as 21 bytes and at the Mac as **nothing** |
| A3.6 | **Inspect mode on iOS** — tap an element in the tunnelled page, type the change, send it to the agent — exactly as the desktop browser does | ✅ proven end to end. Tapping `Pay now` delivered 120 bytes, one line, no CR/LF, to the host's real PTY. `oneLine`/`composeSend` transcribed from `CapturePanel.tsx` — including JavaScript's whitespace set rather than Foundation's, which differ by U+0085 and U+FEFF |

### A4 — Design (NEW, 2026-08-14)
| # | Requirement |
|---|---|
| A4.1 | **Apple design language** — Apple HIG, materials, type scale, spacing, icons |
| A4.2 | **Liquid glass** surfaces where Apple uses them |
| A4.3 | **Sidebar like Claude / ChatGPT** — single quiet rail, not many bars |
| A4.4 | **Settings button bottom-left** that opens a full settings page |
| A4.5 | **Far fewer separators and panels.** Folded, calm, not boxed-in everywhere |
| A4.6 | Simple colour palette, Claude-like. Real dark **and** light mode |
| A4.7 | Must feel **premium and expensive** |
| A4.8 | Every feature reachable by clicking. No orphan features |

### A5 — Process
| # | Requirement |
|---|---|
| A5.1 | Test everything in **both** simulators, not just code |
| A5.2 | Screenshots for every feature; look at them |
| A5.3 | No backend errors anywhere |
| A5.4 | Maximum parallelism on unrelated work |
| A5.5 | Do not stop to ask; finish the list |
| A5.6 | Final verification pass over everything at the end |

---

## B. Work streams (parallel-safe)

Grouped so two streams never touch the same files.

**W1 — Design system + shell** `src/renderer/**` (excluding remote/)
Apple HIG pass, liquid glass, palette, dark/light, sidebar rebuild, settings page.
The largest stream. Everything in A4.

**W2 — Reachability audit** `src/renderer/**` (read), tests
Every feature has a control. Extends `reachable.test.ts` from "module is imported"
to "feature has a way in". A4.8.

**W3 — Localhost tunnel** ✅ DONE
Raw TCP tunnel rather than an HTTP proxy, so WebSockets and hot reload survive
untouched. Verified on the Simulator against a real dev server: a file saved on
the Mac reloaded the page on the phone with nobody touching it.
Open: Vite 7.3.6 refuses the HMR socket when an `Origin` header is present —
reproduces over direct loopback, so it is Vite's policy, not ours.

**W13 — Clipboard both ways** ✅ iOS DONE / Android copy-out open
A3.8. Paste-in works on both. **iOS copy-out is now proven, and not by the app's
own word for it:** `RealDesktopUITests` mints a marker, has the *Mac's* shell
print it, taps Copy Screen, and holds still while the host runs
`xcrun simctl pbpaste` against the Simulator's own pasteboard. A sentinel is
written there first, so "the marker is on the clipboard" cannot be true by
accident. The 423 bytes that came back were the real desktop's screen —
`Asads-MacBook-Pro-21`, `stty size` → `32 60`, `TD-COPYOUT-721075`.

Why the host has to be the witness, so nobody re-derives it: the runner *cannot*
read the pasteboard. `UIPasteboard.general.string` across apps raises the system
consent alert and blocks the calling thread until it is answered — the same
thread that would have to tap Allow — so the run stops dead. `changeCount` is
readable without consent but only says *something* changed, not what.

**Android copy-out is now proven too** — same evidence shape, different witness.
`TD-SENTINEL-3096630044` was written to the *device* clipboard from the host and
read back, so the reader was known good before anything was claimed. The Mac's
zsh then printed `TD-COPYOUT-1795431617-11708-Asads-MacBook-Pro-21.local`; the
phone typed the literal `$RANDOM` and `$(hostname)`, so the `11708` and the
hostname exist only because the Mac expanded them. Copy Screen, then **367 bytes
read back off the device clipboard from the host**, marker present, sentinel
gone. The phone's own IME clipboard chip showed the same both times.

**How to read an Android device's clipboard from the host — two dead ends and
the way that works.** Do not re-derive this:
- `adb shell service call clipboard 4 …` → `Parcel(00000000 00000000)`, i.e.
  null, *even immediately after a copy that visibly succeeded*. Android 10+
  refuses clipboard reads to anything that is not the focused app or the default
  IME, and `com.android.shell` is neither. Transaction 4 **is** `getPrimaryClip`
  on API 31 (7 is `addPrimaryClipChangedListener` — it throws an NPE from
  `service call`, which is how the numbering was pinned down). Careful: **3 is
  `clearPrimaryClip`**, so probing transaction numbers blindly wipes the thing
  you are measuring.
- `adb shell dumpsys clipboard` prints **nothing** on API 31.
- ✅ **The emulator's own gRPC control service.** `EmulatorController.getClipboard`
  / `setClipboard` (message `ClipData { string text = 1; }`) at the port and
  bearer token in `~/Library/Caches/TemporaryItems/avd/running/pid_*.ini`
  (`grpc.port`, `grpc.token`). Node's built-in `http2` speaks it in ~80 lines
  with a hand-rolled 5-byte gRPC frame — no protobuf toolchain needed. It both
  seeds the sentinel and reads the result, entirely outside the app.
  (`scratchpad/android-lane/emu-clip.mjs`.)
- The emulator's *host* clipboard sharing turned out to be one-way in practice:
  guest→host reached `pbpaste` on the Mac, host→`pbcopy`→guest did not. Useful as
  corroboration, useless as the seeding mechanism.

Watch `MAX_INPUT_BYTES` (16 KiB) and keep bracketed paste, or a multi-line paste
submits early to a coding CLI — the same hazard `composeSend` guards against.

**W14 — File / photo / video transfer** ✅ **ANDROID PROVEN** / iOS unproven
A3.9. Chunked over the sealed channel, progress from acked chunks, lands at a
real path which is then typed into the terminal.

**Android, against the packaged 0.1.6 desktop over the live relay, 2026-08-14:**
6 MB of `/dev/urandom` picked in the system picker → landed at
`~/Downloads/Terminal Deck/td-upload-1103129917.bin`, **SHA-256 identical**
(`f2af01a6…b4e9f9`) computed with `sha256sum` in the guest and `shasum -a 256` on
the Mac. Two things worth keeping:
- **The progress is not a timer.** A 0.2 s sampler on the landing folder caught
  345 samples, monotonic, and **every growth step is a multiple of 24576** —
  `MAX_UPLOAD_CHUNK_BYTES`, one chunk. The frame where the phone read
  "840 KB of 6.0 MB" is the second the Mac had written exactly **860,160 bytes**,
  which is 840 KB: the bar counts acknowledged bytes and therefore *lags* the
  wire rather than leading it.
- **The path is usable, proven by using it.** `shasum -a 256 ` was typed at the
  prompt *before* a second upload, so the pasted path completed the command;
  Enter, and the Mac answered `e7bf1a35…d75c3b` — matching the host — with the
  space in `Terminal Deck` surviving because `shellQuoted` single-quotes it.
- **The permission rule holds at runtime, not just in the source.** `dumpsys
  package` during the run: requested = `INTERNET` + `CAMERA` only, and
  `CAMERA: granted=false`. The whole feature ran with no media permission held,
  no prompt shown, and the picker in `com.google.android.documentsui` — another
  process. On API 31 `PickVisualMedia` falls back to a mime-filtered
  `OpenDocument`, which keeps the same property.

**iOS is UNPROVEN against the real desktop.** `ios/UITests/ClipboardAndTransferUITests.swift`
exists and is written well, but it points at `scripts/remote-host.ts` — the
stand-in, and *the stand-in is not the product* (section E). An `IMG_1277.png`
(227,278 bytes, 09:02) is sitting in the real desktop's uploads folder and
something put it there, but nothing on this machine attributes it, so it is not
evidence. What is missing is one run of the Simulator against
`/Applications/Terminal Deck.app` with a `shasum` on both ends.

**Approval note, since Asad asked:** iOS `PHPickerViewController` and
`UIDocumentPicker` run out of process — no permission prompt, no
`NSPhotoLibraryUsageDescription`, no extra review. Android `PickVisualMedia`
needs no runtime permission. The OLD `UIImagePickerController` is what triggers
privacy scrutiny. **Using the modern pickers is the constraint that keeps this
free of approvals** — it is a design rule, not a preference.

**W12 — Multi-host** `ios/`, `android/`
A3.7. The relay is already multi-tenant and the protocol is OS-agnostic — a phone
cannot tell a Mac from a Windows PC. Only the phone's *storage* is single-host.
Make the credential store a collection keyed by hostId, add a switcher, scope
sessions per host. **The failure to avoid: pairing a second machine silently
replacing the first.**

**W11 — iOS inspect mode** `ios/`
A3.6. Mirror `CapturePanel.tsx` exactly: capture `{selector, tag, label, url,
attributes, context}` on tap, sheet for the instruction, then `composeSend`.
**Must reuse the one-line rule** — a newline into a coding CLI submits the prompt
early, and an ESC repaints the terminal it lands in. Both platforms must hand the
agent identical strings.

**W4 — Session create from phone** ✅ DONE (iOS + desktop)
Verb `create`, capability `create`, `PROTOCOL_VERSION` unchanged. `cwd` is
allowlisted server-side — a phone may only name a folder the desktop already
offers. Backed by the *same* `startSession()` the desktop's own button calls, so
there is no remote-only spawn path.
Open: Android needs 3 literals (handed over). **And a phone-created session does
not appear in the desktop UI** — main broadcasts `session:created`, preload
exposes `onSessionCreated`, the renderer needs one `useEffect` (handed to the
design agent, with the note that it must NOT steal the focused tab).

**W5 — Mac package + visual QA** `electron-builder.yml`, screenshots
A2.1, A5.2. Repack, install, drive, screenshot every screen.

**W6 — iOS TestFlight build 2** `ios/`, `scripts/ios/`
A2.3.

**W7 — Android install + verify** ✅ DONE
Full chain proven against the live relay and the real desktop. Signed release APK
at `android/app/build/outputs/apk/release/app-release.apk`. Fixed: debug and
release were indistinguishable in the deep-link chooser.
Not tested: QR decode — an emulator has no camera.

**W8 — Windows** `.github/workflows`, his PC over Tailscale
A2.2, A2.5.

**W9 — Website** separate private repo
A2.5 plus whatever A4 changes about how the product is described.

**W10 — End-to-end proof** ✅ **BOTH HALVES DONE**
A5.6. Android was proven earlier. iOS is now proven too: Simulator → live
`relay.terminaldeck.dev` → the packaged **0.1.6** desktop, paired the way a user
pairs (Settings → Remote → Pair a device, QR decoded with Vision, Approve at the
Mac). Evidence read on the Mac, not the phone:

| Claim | Evidence |
|---|---|
| `hostname` | phone showed `Asads-MacBook-Pro-21.local`; nothing echoes locally — `TerminalBridge` draws only what arrives through `feed` |
| resize on the Mac's OWN pty | phone `stty size` → `32 60`; Mac `stty -f /dev/ttys0NN size` → `32 60` |
| a real `sleep 300`, really interrupted | the Mac's own `ps` saw `/bin/sleep 300` on the session's pty three separate runs (24 s, 29 s, 31 s), each vanishing on Ctrl-C |
| no leaked channel | relay `guests` 0→1→0 every attach/detach |
| pairing lasts (A1.4) | every later run came up "already paired", Connected in ~26 s, no new code |

One honest limit kept rather than glossed: the 20 s background **did not sever
the socket** (`guests` stayed 1), so that step proves continuity and replay, not
a hard drop — a hard drop *is* proven by app termination between runs.

### The "no green exit" was wrong — corrected 2026-08-14

`RealDesktopUITests` **passes.** Three runs — 280 s / 300 s / 299 s, 0 failures,
all screenshots. It was never hung. What was recorded as a hang is **two
back-to-back 60-second XCUITest timeouts inside one `typeText`**, the first one
after `app.activate()`; each ends with `App animations complete notification not
received, will attempt to continue`, and the test then completes normally. Every
interaction *before* the background cycle is fast, the Copy Screen tap included
— the whole clipboard step is 5.6 s — so the old note blaming that tap was wrong
as well. The earlier run was killed one second into the first timeout:
`** BUILD INTERRUPTED **` sits in the log at exactly `t = 143.09s`, and it would
have cleared at `t ≈ 263s`.

**The mechanism, from the app's own log inside the simulator** (`log show
--predicate 'subsystem CONTAINS "XCTest"'`):

    Received request to notify when the main run loop is idle
    Idle notifier run loop observer fired
    Sending main run loop idle reply
    Received request to notify when animations are idle      ← never answered

The run-loop half answers in the same millisecond. The animations half is asked
and never answered. Throughout, the app is at **0.0 % CPU** with its main thread
parked in `mach_msg2_trap` — nothing is animating; something is merely still
*counted* as animating across the suspend.

**`StatusDot` is not the cause, and the hypothesis is dead.** A throwaway
SwiftUI app containing nothing but that `.repeatForever` reaches idle in
**0.33 s per interaction — identical to the same app with no animation at all**,
and identical again after a 20 s background cycle (4 animation variants × ±
background, `mode` asserted on screen so the runs cannot be the same build). The
background cycle alone does not stall it either. And at the stall in the real
app the dot is amber `waiting`, so the animating branch is not even selected.
Nothing was changed in `StatusDot`; there was nothing to change.

The remaining suspect is SwiftTerm's caret — `TerminalOptions` defaults to
`.blinkBlock`, `iOSCaretView` blinks it with
`UIView.animate(options: [.autoreverse, .repeat])` re-armed from its own
completion handler, and `CaretView.foreground()` re-arms it again on
`willEnterForegroundNotification`, which is exactly the trigger moment. That
attribution is **UNPROVEN**. The 120 s is paid once per run and everything after
it is correct, so it is documented rather than designed around.

**Do not "fix" this by making the dot worse.** The one `.repeatForever` in the
app is the right way to draw a living indicator and it costs XCUITest nothing.

---

## B2. Why Asad's iPhone showed old content and said "connected" — diagnosed 2026-08-14

His report: *"i am seeing the same this session in my ios app but i dont see same
last messages ... app is showing older ones and says connected too."*

Measured, not guessed:

| Check | Result |
|---|---|
| `/Applications/Terminal Deck.app` | 0.1.3, bundle mtime 14 Aug 03:56 |
| Cipher fix present in shipped bundle | ✅ `@noble/ciphers` is inside `app.asar` |
| Relay, right now | `{"ok":true,"hosts":1,"guests":0}` — one host, **no phone attached**. Do NOT read that host as his Mac: several harness stand-ins are running and at least one dials the live relay. Attributing it needs more than `/healthz`. |
| Desktop identity | exists — `remote/relay-identity.json`, hostId `59GLH9L6GQUB54CNG682FV78ZX` (public; it goes in the QR) |
| Paired devices on the Mac | **2**, both named "iPhone" — he re-paired, which matches "my connection is fresh" |
| Relay while he reported "connected" | `guests:0` sustained 40 s; iPhone offline on the tailnet |
| TestFlight build 2 uploaded | 13 Aug 21:26 |
| Commits to `ios/` since build 2 | **2**, including `9728d2b` "Make remote access actually work, on every platform" (02:48) |

So the desktop side is healthy and waiting. **His phone runs a build that predates
the fix**, cannot complete the handshake, and then does the genuinely bad thing:
renders a cached buffer behind a "connected" badge.

### The bigger one, found straight after: the Mac never dials the relay

`lsof -nP -i@178.105.248.86` returns **nothing**. No process on this machine holds
a connection to the relay. The running Terminal Deck's only established
connections go to the Anthropic API. Killing the 3h23m orphaned harness stand-in
that *was* dialling production left `hosts:1` unchanged, so that host is remote —
plausibly the Windows PC.

**So his phone has had nothing to attach to.** A new iOS build alone would not
have fixed it, and **A1.1/A1.2 are not true today** whatever the tests say.

`relayEnabled()` is documented "on by default", so this is a defect, not a
setting — unless remote access is secretly opt-in through persisted config, which
would violate A1.2 outright. Handed to the Mac package agent with four candidate
causes, the last being another silent catch of the kind that hid the BoringSSL
throw all night.

The distinguishing test, since `hosts:N` proves nothing on its own: launching the
packaged app must make an established connection to `178.105.248.86` appear, and
quitting it must make the relay's host count fall.

Two further defects, both handed to the iOS lane:
1. ~~**The badge lies.**~~ ✅ **FIXED, and the mechanism matched the measurement.**
   `resume()` was a no-op while `.online` — nothing tells a socket that a carrier
   NAT reclaimed it in a pocket — and `realign()` then pushed the first check a
   full interval out. That is **25 s + 10 s of grace showing "Connected" against
   nothing**, which is exactly the dead window observed on the relay. Resuming now
   doubts the channel, the pill reads "Checking", and it probes immediately; any
   sealed frame restores it. Seven new tests. The probe's own second, more
   trigger-happy deadline was removed.
2. ~~**Build 3.**~~ ✅ **TestFlight 0.1.4 build `2608140303` is VALID**, compliance
   answered, attached to Internal, testable now. Both traps avoided:
   `ITSAppUsesNonExemptEncryption` still absent, one distribution identity.

### Battery, measured rather than remembered
`scripts/keepalive-cost.ts` runs the shipping wire code. **The inherited numbers
were wrong in three places of four**: ping and pong are both 12 bytes of JSON →
52 out / 48 in (a client masks, costing 4), 100 bytes per host per tick, three
machines = **43.2 kB/hour**, not ~53. The finding that matters: **radio wake-ups
do not grow with host count** — 144/hour at one machine and at five, against 720
unshared. Keep the shared ticker. A battery *percentage* is deliberately not
quoted: a Simulator has no cellular radio, so any figure would be invented.

One more thing this explains: it was never going to mirror *this* conversation.
This session runs in Terminal.app, not inside Terminal Deck. The phone can only
ever show Terminal Deck's own sessions.

---

## B3. Notifications — the "Sent." lie, closed. And the last unproven claim, proven. (2026-08-14)

`SIGNING-HANDOFF.md` §1 diagnosed it: `Notification.permission` is **always
`granted`** in an Electron renderer, so the settings pane read a permission it
had not checked, enabled the Test button on it, printed **"Sent."** for a
delivery it had not confirmed, and blamed a Focus mode — the one cause that had
been checked and ruled out. Fixed in `72b1015`.

**What the app says now**, in its own words on screen:

| Case | Note |
|---|---|
| The OS recorded it | *"macOS recorded a banner at 10:25:14. Notifications are working."* |
| The OS has no record | *"macOS has no record of showing it. Authorisation is most likely still pending or has been refused — the app cannot read which. If it is asking permission, the request arrives as a banner in the corner and Allow is hidden under its Options button."* + **Open notification settings** |
| The app cannot ask | *"The banner was handed to macOS. Whether a banner actually appears is decided by macOS, and the app cannot read that. If nothing appeared, check there."* |
| A preference switched on | fires a banner **then**, while the user is on the pane, because macOS asks with a banner exactly once |

There is no "Sent." branch left, and `deliveryCopy` is a pure function with a
test asserting the word *Focus* never appears and *Options* always does.

**Two facts that had to be measured, and that a plausible implementation gets
backwards.** Both are in `src/main/os-notifications.ts` with the numbers:

1. **macOS records a banner when it *leaves* the screen, not when it appears.**
   Polled once a second against a banner that was plainly on screen the whole
   time: `t+1s…t+5s → 0 rows`, `t+6s → 1 row`. A 2.4-second probe would have
   reported "no record of it" for every banner that worked perfectly — a false
   alarm, the same disease as the false success, pointing the other way. The
   probe runs 9.5s, and the proof banner is only closed *after* the answer,
   because closing at six seconds raced the row.
2. **The store lower-cases the bundle id.** `Info.plist` says
   `com.github.Electron`; `app.identifier` says `com.github.electron`. SQLite
   `=` is case-sensitive, so an exact match found nothing for notifications
   that had arrived.

**The unproven row in §1 is now proven** — a real session, not a Test button:
plain-shell session in the packaged renderer, `sh /tmp/td-proof.sh` typed in,
Enter, app backgrounded (`frontmost` = Terminal, asserted before and after),
script sleeps 15s and then asks `Do you want to continue? (y/n)`.

    Enter          10:22:41
    banner         10:22:58   screenshot: "terminaldeck / terminaldeck needs your input"
    macOS's store  10:22:57   com.github.electron

Repeated, same shape: Enter 10:21:47 → recorded 10:22:02. The evidence is the
OS's own `group.com.apple.usernoted/db2/db`, not the app's word.

That screenshot is also what caught the last bug: **the banner said the same
word twice.** A tab keeps the folder name until the conversation has a title,
so the common case read *"terminaldeck / terminaldeck needs your input"*.

**UNPROVEN, and left that way deliberately:** `completed` never fires for a
plain shell — `classify()` cannot produce it, it comes only from the agent
hook server (`hooks.ts`, `Stop` → `completed`). The `input` half of the policy
is now proven end to end; the `completed` half is proven only by unit test.

**Caveat on the identity:** this ran under `electron-vite`'s bundle
(`com.github.electron`), in an isolated `--user-data-dir`, so it could not
disturb the shipping app or the Android lane's live relay session. The OS layer
for `dev.terminaldeck.app` was already proven in §1. Both halves are proven;
they were proven under two different bundle ids.

---

## C. Testing matrix

Nothing is ticked on this list without the evidence named.

| Thing | Evidence required |
|---|---|
| Any UI change | Screenshot, read by me, whole frame + zoom crop, light AND dark |
| Any feature | A click path from a cold start, driven, screenshotted |
| Desktop crypto | Runs under Electron's own Node, not plain Node |
| iOS | `xcodebuild test` + Simulator screenshot of the working feature |
| Android | `testDebugUnitTest` + emulator screenshot |
| Relay | Against **relay.terminaldeck.dev**, not loopback |
| Windows | Installed and launched on `desktop-ddgmncv` |
| No backend errors | Main-process log clean across a full session |
| Reachability | `reachable.test.ts` green with no new allowlist entries |

---

## D. Order

1. **Now, parallel:** W1 (design), W2 (reachability), W3 (tunnel, running), W5 (repack)
2. **Then:** W4 (create), W6 (TestFlight 2), W7 (Android on device)
3. **Then:** W8 (Windows), W9 (website)
4. **Last:** W10 — full chain, every platform, final sweep

---

## E. Known traps — do not re-learn these

- **`Notification.permission` is a lie in a renderer.** Always `granted`;
  Chromium never asks the OS. It means "constructing one will not throw", not
  "the user will see it". Never gate a control on it and never report success
  from it. `canNotify`'s comment carries the argument and a test pins it.
- **macOS records a banner ~6s after posting it, when it leaves the screen** —
  and lower-cases the bundle id in the store. A short poll or an exact match
  both report "never arrived" for banners that arrived. Measured; see
  `os-notifications.ts`.
- **Chromium swallows CGEvent clicks here, but not CDP input.** Launch with
  `--remote-debugging-port` and use `Input.dispatchMouseEvent` — it drives the
  real renderer. Native UI (Notification Center, its `Options ⌄` menu) *does*
  take CGEvent clicks, and real-cursor hover is what reveals `Options` at all.
  One gotcha: a CDP Enter needs `keyDown` carrying `text` and then `keyUp` — add
  a `char` event as well and the shell receives **two** newlines, which a `read`
  answers instantly.
- **A backgrounded renderer's DOM goes stale** (xterm paints in rAF, which
  Chromium throttles). Do not read session state out of `innerText` while the
  window is in the background — the status the notifier acts on comes from the
  main process and is correct while the DOM is minutes behind.
- **Electron is BoringSSL.** No ChaCha. Test crypto under Electron or it is untested.
- **Duplicate signing identities** produce `errSecInternalComponent`, which looks
  like a locked keychain and is not. One identity, one keychain.
- **`open <path>/Terminal Deck.app` launches the /Applications copy**, not yours —
  same bundle id. Run the binary directly.
- **Apple and npm styled controls swallow synthetic clicks.** Real pixel clicks.
- **Don't build while a dev server serves** — it clobbers `out/`.
- **electron-builder walks excluded dirs**; `ios/` and `android/` are named exclusions.
- **The stand-in is not the product.** Both phone stand-ins shared a bug with their
  clients and hid an 81-vs-80 byte error for a day.
- **A stalled XCUITest is not a hung one — read the timeout before killing it.**
  `RealDesktopUITests` was written off as having "no green exit" because one
  `typeText` after `app.activate()` sits through **two 60-second** animation
  timeouts. It prints `App animations complete notification not received, will
  attempt to continue` twice and passes. It was killed inside that window. Before calling a
  UI test hung: `sample` the app (0 % CPU parked in `mach_msg2_trap` means it is
  not the app), and read `log show --predicate 'subsystem CONTAINS "XCTest"'`
  *inside the simulator*, which names which half of the idle check went
  unanswered.
- **A pairing link handed to `adb shell` must be quoted for the *device's* shell
  as well.** `adb shell am start -d "$LINK"` looks right and silently does
  nothing useful: adb hands the whole command to `sh` on the phone, and the `&`
  between `terminaldeck://pair?v=1&r=…&h=…&t=…` backgrounds it. Write
  `adb shell "am start -a android.intent.action.VIEW -d '$LINK'"`. One 60-second
  pairing window was burned on this.
- **`adb shell input text` drops characters on a loaded machine.** `echo TD-…`
  arrived as `ech`. Type in short chunks with a second between them and read the
  result off a screenshot before pressing Enter — and expect to fix up a stray
  character with `input keyevent 67` rather than trusting the send.
- **The Android guest reboots when the Mac is loaded**, and it looks like the
  emulator has died: `service call ... Broken pipe`, then `Can't find service:
  input`. It is `system_server` restarting. Wait for `sys.boot_completed=1` *and*
  the launcher, ~2 minutes. Nothing is lost — pairing, the desktop's sessions and
  the scrollback all come back on reattach, which is itself A1.5 evidence.
- **Never generate synthetic CPU load to reproduce a timing test.** An agent
  chasing the `layout.test.ts` timing flake ran
  `for i in 1..12; do (while :; do :; done) & done` — twelve spinning shells per
  invocation, ~48 of them — then stalled before cleaning up. Load average hit
  **836 on 8 cores**, which starved and killed four agents at once and made the
  very test it was investigating fail (3092 ms against a 2000 ms budget). The
  "flake" was self-inflicted: unloaded, it passes 71/71 three runs in a row.
  A busy loop is unkillable by the thing that spawned it once that thing dies.
  To test behaviour under load, **inject a fake clock or raise the budget** —
  never load the real machine. If load must be simulated, bound it
  (`timeout 30 …`) so it dies on its own.


---

## F. Rule 7.12 — added 2026-08-14

**Never hand something back as blocked after one approach.** Change the angle:
different tool, different search, different layer, different environment,
different identity. Non-TTY output is often redacted — a pty reveals it.
Styled controls swallow synthetic clicks — use real pixel clicks. When you do
escalate, say what you tried and why each failed.

Earned the hard way in one night: the issuer ID *was* in the Imza folder
(`apps/eas.json`); the App Store record *could* be created, just not by the API;
npm's auth URL *was* recoverable, just not without a pty.


---

## G. Keep the lanes full — added 2026-08-14 after stalling

Asad: *"make sure its not happening again you need to keep going."*

The list stopped moving twice tonight, and both times for the same reason: work
was correctly queued behind a busy file lane, the lane freed, and nobody
relaunched. Queuing is not progress.

**The rule: whenever an agent finishes, immediately start the next queued stream
in that lane.** Do not batch it, do not wait for a natural pause, do not wait to
report first. Report *after* launching.

Lanes, so two agents never share files:

| Lane | Owns |
|---|---|
| renderer | `src/renderer/**` |
| main | `src/main/**`, `src/shared/**` |
| ios | `ios/` |
| android | `android/` |
| infra | `relay/`, `.github/`, release, website |
| verify | read-only; may run anywhere |

A verification agent never edits, so it can always run alongside the others.
If every lane is genuinely busy, say which and when each frees — never just go
quiet.
