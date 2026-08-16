# iOS client

A native phone client for the desktop app: a list of the sessions running on the
Mac, and a real terminal attached to one of them. It is the same job the PWA in
`../pwa` does, done with a native VT100 emulator, a native keyboard accessory and
a native navigation stack.

It reaches the Mac two ways. Through a **rendezvous relay** (`../relay`), where
every byte is sealed end to end with the Noise IK channel from
`../src/shared/sealed.ts` and the relay carries ciphertext it cannot read; or
**directly** to the desktop's own listener on a tailnet, where the tunnel is the
privacy and there is nothing in the middle to seal against. Which one a phone is
using is on the pairing screen and in the settings menu, because "who can read
this session" is not a detail.

## Status

| Piece | State |
|---|---|
| Xcode project, SwiftTerm wired in, builds and runs on the Simulator | done |
| Session list, terminal screen, navigation, deep link | done |
| Wire types and codec, ported from `src/main/remote/protocol.ts` | done |
| **Sealed channel** — Noise IK in CryptoKit, byte-compatible with `sealed.ts` | done; proved against vectors generated from the Node implementation |
| **Pairing** — QR or pasted link, Keychain, the pending-approval wait | done |
| **Relay transport** — guest socket, handshake as initiator, sealed protocol | done; run against the real relay and a stand-in desktop |
| Direct (tailnet) transport | written; **not run against a desktop** — see below |
| Session list with live status, attach + replay, resume, new session | done |
| Key bar + key grid, copy/paste, automatic reconnect | done |
| `StubTransport` | **deleted** — the real one works |
| Release pipeline, icon, signing | done; `preflight.sh` passes every check |
| TestFlight | **live** — 0.1.8 build `2608151610`, VALID, on the internal group |
| App Store submission | **not started** and not close — a reviewer has no machine to pair with, see [`APPSTORE.md`](../APPSTORE.md) |

### What has actually been run, and against what

Worth being precise, because "compiled" and "works" are different claims:

- **The sealed channel** is checked against `Tests/Fixtures/sealed-vectors.json`,
  which `Harness/run.sh vectors` generates by running `src/shared/sealed.ts`
  itself. The Swift side reproduces Node's handshake message byte for byte,
  derives the same channel binding, opens what Node sealed, and produces
  identical ciphertext under the same counter.
- **The wire framing around it** is checked separately, by `Tests/RelayWireTests`,
  and the separation is the point. `sealed.ts` produces 80- and 48-byte Noise
  messages; `src/shared/relay-wire.ts` puts a version byte in front of each, so a
  relay carries **81 out and 49 back**. This app had the first file ported
  faithfully and the second one missing entirely — a handshake correct to the byte
  and one byte short on the wire, which a desktop answers by closing the channel
  in silence so that a hostile relay learns nothing from a refusal. Every test
  passed throughout, because the stand-in host skipped the same byte. It no longer
  does: it imports `withSealedVersion` / `readSealedHandshake` from the desktop
  rather than re-deriving them, and its `--selftest` asserts the two byte counts
  on a live socket.
- **The relay transport** has been driven from the Simulator against
  `Harness/run.sh host`: the real relay from `relay/src/rendezvous.ts`, a
  stand-in desktop that answers the handshake with the real `respondToHandshake`
  behind the real framing, and sessions that are real `node-pty` shells. Pairing, the approval wait,
  attach with scrollback replay, typing, resize, Ctrl-C, creating a session and
  reconnecting after the far end disappeared have all been done on a device
  screen rather than argued from the source.
- **File transfer and the clipboard have been proved against a real host on the
  live relay**, which is the claim that had never been made for iOS before
  2026-08-15 — Android made it a day earlier and this was the unproven half.
  `Harness/live-transfer.sh` runs it; two consecutive runs from an erased
  Simulator, each with fresh randomness, gave:
  - a **6,752,593-byte** photo picked in `PHPickerViewController`, across
    `wss://relay.terminaldeck.dev`, landing at
    `…/Downloads/Terminal Deck/td-proof.png` with SHA-256
    `04fdd4e6…c3b484a9` — **identical** to the source, hashed by `shasum -a 256`
    on the Mac and independently by CryptoKit inside the Simulator, and gated a
    third time by `uploads.ts`, which deletes rather than renames anything whose
    digest does not match what the phone claimed;
  - the same for a **video** — `live-transfer.sh --media td-proof.mp4`, an
    8,102,371-byte H.264 clip of noise, landing with SHA-256
    `a28885f9…eac94b53`, identical. Same code path as the photo
    (`preferredAssetRepresentationMode = .current`, so nothing is transcoded on
    the phone), and worth running because "photos and videos" is two claims;
  - progress that was **real**: 163 samples of the `.part` file on the Mac, 62
    distinct sizes, only ever growing, every one a whole number of 24,576-byte
    slices except the last, which was the file's exact length;
  - the clipboard **inwards** — a command put on the device pasteboard with
    `simctl pbcopy`, pasted, run, and read back out of the file it wrote in the
    granted folder;
  - the clipboard **outwards** — Copy Screen replacing that pasteboard with
    terminal text carrying a value the host's own shell minted from `$RANDOM`,
    read with `simctl pbpaste`, which needs no consent and has nothing from the
    test process in the loop.
- **The direct transport has not.** `DirectCarrier` speaks the same protocol over
  plain text frames to `WS_PATH` on the desktop's listener, and that path has
  never been exercised from this app. It is the shape the PWA uses and it is
  transcribed from `pwa/src/connection.ts`, which is exactly the claim the relay
  transport carried before someone pointed it at a socket and found two bugs.

## Navigation, and the connection indicator

Three things from the screen recording of 2026-08-16, all of them his and two of
them asked for twice.

**A bottom tab bar.** *"we need to give a proper menu … maybe we can have some
tab bar, and down here like a pill."* **Sessions**, **Machines**, **Settings** —
and no fourth, because there is no fourth thing this app can do. The desktop's
sidebar has ten entries and most of them are a file tree, a diff or a search box;
a tab leading to any of those on a phone would lead to a placeholder, which is
the complaint rather than the fix. What moved is everything that was buried in
the session list's `…`: pair, rename, forget and which endpoint a machine is, to
Machines; the GitHub account, the alert switches and the terminal's text size, to
Settings. Nothing is in two places. That menu now holds Refresh and Reconnect,
which are the only two things in it that act on the list. `DeckTabs.swift`.

**The connection is only mentioned when it is in the way.** *"when we just open
the application, it shows connecting … let it give a few seconds; after five
seconds if it is still not connected, then show … no need to show connected all
the time … if it gets disconnected for more than five seconds, then start showing
connecting … less than five seconds, let's not show anything."* Implemented as a
state machine rather than as timers in views, because the rule had to hold in
three places at once — the pill, the warning bar and the empty state — and one of
each per screen is how a rule ends up almost-implemented three different ways.
`ConnectionGrace` is the rule (pure, takes the instant as a parameter),
`ConnectionNotice` holds one against a real clock, and there is one per machine on
`HostLink` so an outage that started a minute ago does not get a fresh five
seconds of silence every time somebody navigates back to the list. All four of his
cases are pinned in `Tests/ConnectionGraceTests.swift` with a fake clock and no
sleeping.

The pill's accessibility element stays on screen when the pill does not. The
state is still true when it is not being shouted about, and VoiceOver asking for
it is somebody asking a question the screen has deliberately stopped answering
out loud — `Tests/ConnectionPillTests.swift` hosts the real view and walks the
real accessibility tree to check both halves.

**One finger scrolls; selecting is a long press.** Asked for a second time, and
most of it was already built — see *Gestures in the terminal* in
[`../IOS-DESIGN.md`](../IOS-DESIGN.md). What was missing was that the gestures
were *attached* rather than *related*: the delegate said yes to every pair, so
the refusals in `DeckTerminalView` only covered the case where the scroll had not
started yet. The scroll and the two selection gestures are now declared exclusive,
the scroll is declared to wait for the selection drag to fail, and the scroll view's
own pan is limited to one finger. `TerminalGesturesTests` asks the delegate each
of those three questions directly.

## What the phone can do beyond attaching to a session

The four things below were added on 2026-08-15, after the design pass, because
"it is on very basic stages" was the accurate description of a client that could
attach to a session and do nothing else with it.

**Find in the scrollback.** The actions menu → *Find in output*. A bar floats
over the terminal — it does not push it, because taking rows off a session is a
`resize` on the wire and a repaint on the far end. Typing searches **backwards
from the bottom**, so the first match is the newest one, which on a terminal is
almost always the interesting one; `↑` walks further back and `↓` comes forwards.
The counter is counted from the top of the buffer. The search is SwiftTerm's own,
against the real emulator buffer, so it finds what scrolled away rather than what
is on screen. `TerminalFind.swift`, `FindBar.swift`, `Tests/FindTests.swift`.

**Alerts.** The phone says when a machine needs somebody: a session that stops
and waits makes a sound, a session that finishes arrives quietly, and tapping
either opens that session on that machine. It is computed on the phone from the
`status` and `exit` frames the desktop already sends — no new wire verb, nothing
the desktop has to be taught.

What it cannot do is on the screen, in the app, in those words: **there is no
push service in this product**, so an alert can only be raised while the app is
running — in front of you, or in the ~30 s `beginBackgroundTask` window after the
phone goes in a pocket. Anything that happened while it was asleep is caught up
on the next connection and shown as one line at the top of the session list
("While you were away: 1 session needs you, 1 finished") rather than as four
banners about things that are already over. `SessionAlerts.swift`,
`AlertCenter.swift`, `BackgroundGrace.swift`, `AlertsView.swift`.

**Text size.** Pinch the terminal, or the two items in the actions menu. It is
not a zoom: the column count *is* the font, so a smaller face means more columns
and a `resize` the far end reflows to — which is the point, because an agent's
eighty-column table wraps into nonsense at fifty. Nine to twenty-two points,
whole points, one setting for the phone. `TextSize.swift`.

**Share the output.** The actions menu → *Share output* writes the **whole
buffer** — scrollback included — to a `.txt` named after the session and hands it
to the system share sheet. Deliberately not the same thing as Copy, which takes
the screen or a selection: the reason to send somebody a session is usually the
error that has already scrolled off the top. `ShareOutput.swift`.

## Build and run

The project file is generated, so start there:

```sh
brew install xcodegen          # once
cd ios
xcodegen generate              # writes TerminalDeck.xcodeproj
open TerminalDeck.xcodeproj
```

From the command line, against a simulator that exists on this machine
(`xcrun simctl list devices available`):

```sh
xcodebuild \
  -project TerminalDeck.xcodeproj \
  -scheme TerminalDeck \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  build
```

Swap `build` for `test` to run the tests. The UI tests need a desktop to talk
to and skip themselves when there is not one — see [Running it against a real
desktop](#running-it-against-a-real-desktop). Then:

```sh
xcrun simctl boot 'iPhone 17'
open -a Simulator
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/TerminalDeck.app
xcrun simctl launch booted dev.terminaldeck.ios
xcrun simctl io booted screenshot shot.png
```

### One-time: the Metal toolchain

Xcode 26 does not ship the Metal compiler. SwiftTerm has an optional Metal
renderer and its package declares `Shaders.metal` as a resource, so the build
stops with `cannot execute tool 'metal'` until you run:

```sh
xcodebuild -downloadComponent MetalToolchain      # ~690 MB, once per machine
```

### The app icon

Generated, not drawn, and not stored twice:

```sh
node scripts/ios/icon.mjs      # writes TerminalDeck/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

The artwork is `build/art/icon.mjs` — the same vector description the desktop
icon is rasterised from. The iOS script imports its renderer and changes only
the frame, because iOS wants a full-bleed square it can mask itself where macOS
wants a rounded tile with the shape baked in, and because App Store Connect
rejects an icon carrying an alpha channel even when every pixel of it is opaque.
The file it produces is committed; `preflight.sh` re-renders it and fails if the
committed bytes have drifted from the art.

## Running it against a real desktop

The desktop app has no relay transport yet — `src/main/remote/server.ts` speaks
this protocol over a tailnet socket and its own comments describe a relay client
as future work. So `Harness/` contains the other end: the **real** relay, the
**real** sealed channel and the **real** protocol parser, imported rather than
reimplemented, wrapped in the smallest stand-in desktop that can serve them.

```sh
ios/Harness/run.sh host --approve-after 6000 --log-input
```

It prints a six-digit pairing code, writes it to `ios/Harness/.build/pairing.txt`
and sits in the rendezvous slot that code names. Type it into the app's pairing
field, which is the only way in the product has:

```sh
cat ios/Harness/.build/pairing.txt   # six digits — type them into the Simulator
```

A control server on the next port up stands in for the human at the Mac, because
approval is deliberately not something software can do for itself:

```sh
curl 127.0.0.1:8788/state     # host id, devices, sessions
curl 127.0.0.1:8788/approve   # be the human
curl 127.0.0.1:8788/pair      # mint another pairing code
```

`run.sh host --selftest` runs the whole flow with a Node guest instead of the
phone — handshake, pairing, refusal, approval, attach, replay, a keystroke into
a real shell — and is the thing to run first when the app cannot connect: it
says whether the harness or the client is wrong.

The sessions it serves are real shells. Typing `rm` into one from the phone will
do what `rm` does.

### Against a real host, on the live relay — one command

Everything above is a stand-in, and a stand-in can share a bug with its client
and agree with it forever — which is how an 81-versus-80 byte error survived a
day and how Electron's missing ChaCha survived weeks. So the transfer and
clipboard proof uses no stand-in at all:

```sh
ios/Harness/live-transfer.sh            # or --device "iPhone 17 Pro Max"
```

It starts the product's own headless host (`out/headless/host.mjs` — the same
`registerRemoteIpc`, `PtyManager`, `uploads.ts` and sealed channel the window
build links) under its own `HOME`, waits until it is on
`wss://relay.terminaldeck.dev`, erases and boots a Simulator, drives
`UITests/LiveTransferUITests`, and then reads the evidence off the Mac:

- `shasum -a 256` over the photo before it goes into the library and over the
  file that lands in the host's uploads folder;
- the partial file's growth, sampled while it is being written;
- the file the pasted command wrote, and `xcrun simctl pbpaste` against the
  Simulator's own pasteboard.

The headless host rather than `/Applications/Terminal Deck.app` for two reasons:
its pairing can be driven end to end (`Harness/live-desktop.ts` sends the same
`machines:code` and `remote:device:approve` the CLI sends), and it cannot
disturb the desktop app's own state or relay identity.

**Send File is the one branch this does not cover.** `DocumentPicker` in
`Transfer/FilePickers.swift` has not been driven against a live host: the Files
browser is out of process like the photo picker, but unlike the photo picker
there is no `simctl` verb that puts a file where it can be chosen, and the app
deliberately declares neither `UIFileSharingEnabled` nor
`LSSupportsOpeningDocumentsInPlace` — adding them to make a test easier would be
changing the product to suit the harness. Everything after the picker callback
is shared with the photo path and is covered: staging, `FileUpload`, the window,
the digest, `uploads.ts`.

### The UI tests

`UITests/` covers what a unit test cannot: that the connection indicator says a
true thing, that a key on the key bar reaches a shell, that copy and paste
are wired to the session, and that New Session appears only because the far end
offered it. They need the harness and a phone that is already paired with it:

```sh
ios/Harness/run.sh host --approve-after 6000 --log-input &
cat ios/Harness/.build/pairing.txt   # type the six digits into the Simulator
xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath ios/build/DerivedData \
  -clonedSourcePackagesDirPath ios/build/SourcePackages \
  -only-testing:TerminalDeckUITests
```

The derived-data flags are not decoration: leaving them off builds SwiftTerm
again into Xcode's own directory, which is five minutes of a machine that has
already compiled it.

Without a paired app every case skips rather than fails. A test that goes red
because a server is not running on someone's laptop is a test that gets deleted
in a week.

Pairing happens outside the test on purpose: the code is minted at run time and
has to cross from the host machine into the Simulator.

This used to be `xcrun simctl openurl` with a `terminaldeck://pair?…` link — the
door a scanned QR code came through — and it dragged a SpringBoard alert with it:
**"Open in 'Terminal Deck'?"**, which nothing in the app's own code could dismiss
and which a helper had to find and tap. Every one of those problems is gone with
the link. There is one way into this app now and it is six digits in a field, so
the tests type six digits: `LiveTransferUITests` reads them from `TD_CODE_FILE`
(the harness writes it once the phone says it is at the pairing screen), and the
rest ask the harness's control server for one.

`TEST_RUNNER_…` injection is how the run-time values reach the runner, and the
*form* matters more than anything else on this page. Measured on Xcode 26.6 with
iOS 26.5, changing nothing but where the assignment sits:

```sh
xcodebuild test … TEST_RUNNER_TD_READY_FILE=/tmp/probe   # after: DOES NOT WORK
TEST_RUNNER_TD_READY_FILE=/tmp/probe xcodebuild test …   # before: works
```

The first is parsed as a build setting, is echoed under "Build settings from
command line" at the top of the log, never reaches the runner's
`ProcessInfo.processInfo.environment`, and every case skips while the run ends
`** TEST SUCCEEDED **`. That is a green run in which nothing was tested, which is
the worst thing this suite can produce — and it is why `live-transfer.sh` exists
as one command rather than as a recipe to be retyped.

#### `FindShareAndAlertsUITests` pairs itself

It asks the harness's control server for a code and types it, the way
`KeyBarUITests` does — which is now what every file in the target does.
So the whole of find, text size, share and the alerts screen is one command:

```sh
ios/Harness/run.sh host --approve-after 3000 &
xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath ios/build/DerivedData \
  -only-testing:TerminalDeckUITests/FindShareAndAlertsUITests
```

Use `id=<UDID>` rather than `name=iPhone 17` if two runtimes are installed:
`name=` picks one of the two devices with that name and it is not necessarily
the one you booted, installed to and are screenshotting. That cost an hour once.

One case in it is **opt-in**, because it spends the system notification prompt,
which can be answered exactly once per install:

```sh
TEST_RUNNER_TD_SPEND_NOTIFICATION_PERMISSION=1 xcodebuild test … \
  -only-testing:TerminalDeckUITests/FindShareAndAlertsUITests/testASessionEndingRaisesARealNotification
```

It grants permission, starts `sleep 6; exit` in a session, leaves that screen,
and waits for the banner. Run on 2026-08-15 it passed: **"build — Finished on
RLCKG3."** over the session list, which is the whole chain — a pty exiting on the
machine, a `status` frame across the sealed relay, a transition noticed on the
phone, and iOS drawing it.

## The pairing code

Two shapes, because there are two ways to reach a Mac. `Transport/PairingCode.swift`
is the only thing that reads either.

```
terminaldeck://pair?v=1&r=<relay ws url>&h=<26-char host id>&k=<base64url static key>&t=<token>
https://mac.tailnet.ts.net/#t=<token>
```

The relay shape carries the Mac's static X25519 public key, and that is what
makes the handshake IK rather than trust-on-first-use: without `k` the relay
could answer in the Mac's place and nothing would notice. The `https` shape is
the one `pwa/src/pair.ts` already reads, token in the fragment so it cannot land
in an access log, and it produces a direct connection with no sealed channel.

**The desktop does not emit the relay shape yet.** It is defined here, by the
client that consumes it, and the format is the obvious encoding of what the
handshake needs — but when the desktop grows a relay client, this is the thing
to agree on first, and if it picks a different spelling then this file changes
rather than both being supported.

## Shipping it: TestFlight

### The state of it

The whole path runs unattended, from a checkout to a build a phone can install.
`scripts/ios/preflight.sh` passes every check: the Release configuration
archives for a real arm64 device, the icon compiles in, the Info.plist comes out
saying what it should, exactly one distribution identity is visible and its
keychain is unlocked, the release notes exist and fit, and the App Store Connect
key and issuer id are both on disk.

### The signing key was lost once, and what replaced it

Worth the paragraphs, because the symptom points at the wrong thing and it cost
an afternoon on 2026-08-15.

```
CodeSign … TerminalDeck.app: errSecInternalComponent
```

The unsigned archive immediately before it succeeds, so nothing in the bundle is
the problem. `errSecInternalComponent` from `codesign` means the keychain would
not hand over the signing key to a process that cannot put a prompt on screen.
It has two causes and they look identical: **two identities with the same name**,
or **the keychain is locked**. This time it was the second.

The keychain holding the Apple Distribution identity had been created with
`security set-keychain-settings -lut 21600`, which locks it on sleep. It slept.
And the password recorded for it in
`~/ClaudeAsad/credentials/.terminaldeck-keychain-pw` **did not open it** — not a
whitespace problem, not a quoting problem; four spellings were tried and all
four were refused. The private key inside is therefore unreachable and stays
that way, because a keychain password cannot be recovered or reset from inside.

The fix was to stop trying and rebuild the material, which is entirely doable
without Apple's help beyond the API key already on disk:

1. A new key pair and CSR, then `POST /v1/certificates` with
   `certificateType: DISTRIBUTION` — **this one Apple's API will do**. (Only
   `DEVELOPER_ID_APPLICATION` is refused with *"can only be performed by the
   Account Holder"*; do not confuse the two, see `SIGNING-HANDOFF.md`.) New
   certificate `MPD2XX32V2`, valid to 2027-08-15. Nothing was revoked — the
   account was not at its certificate limit, and revoking would have broken the
   other apps that share this team.
2. A p12 of certificate + key + the WWDR G3 intermediate, imported into a new
   `terminaldeck-ios.keychain-db` whose password is recorded in
   `~/ClaudeAsad/credentials/.terminaldeck-ios-keychain-pw`, with
   `set-key-partition-list` so `codesign` never needs a dialog — and created with
   a **plain `security set-keychain-settings`**, no `-l` and no `-t`, so it can
   never lock itself the way its predecessor did.
3. A provisioning profile is a *snapshot* of the certificates that existed when
   it was made, so the existing one did not contain the new certificate and had
   to be rebuilt. `Terminal Deck iOS App Store` was deleted and recreated with
   every distribution certificate on the account, keeping the same name so
   nothing in `project.yml` changed.

`preflight.sh` now unlocks that keychain from the recorded password before
anything is built, and fails loudly if the password does not open it — which
turns this whole afternoon into one red line in five seconds.

**Do not check for a locked keychain by signing something, or with
`security show-keychain-info`.** Both raise a SecurityAgent dialog and block
forever, and the dialog *outlives the process that raised it* — killing
`codesign` leaves the window up. A first attempt at this check hung for two
minutes and stacked three modal prompts on the user's desktop. `unlock-keychain
-p` is the only one of these that never raises UI: it unlocks, or it says the
passphrase is wrong, immediately.

The old `terminaldeck.keychain-db` is left on disk, out of the search list. It
still holds the Developer ID Application certificate for the **macOS** lane —
whose private key *is* recoverable, from `~/private_keys/developer-id/`, so that
lane can be rebuilt the same way when someone needs it.

Three things used to be blocked. None of them is now, and the history is kept
because each one has a trap in it that will be met again:

1. ~~The App Store Connect issuer id is not known.~~ **Resolved** —
   `33807517-81cb-4d1e-8263-787b34fe2cc2`, recorded in
   `~/ClaudeAsad/credentials/apple-appstore.md`.
2. ~~There is no provisioning profile for `dev.terminaldeck.ios`.~~ **Resolved** —
   the App ID (`72M8V8LV2M`) and the *App Store* profile were created through the
   API. Note that `-allowProvisioningUpdates` asks for a **development** profile,
   which needs a registered device and is not what TestFlight wants; the App
   Store profile needs none and was made directly.
3. ~~The export declaration is a filing.~~ **Resolved, and it was not a filing** —
   see [Export compliance](#export-compliance). The key was removed and the
   question is answered in App Store Connect.

**The app is on TestFlight.** App record `6801251458`, bundle
`dev.terminaldeck.ios`. Four builds delivered; the current one is **0.1.8, build
`2608151610`**, processed VALID, export compliance answered, notes filed, and
attached to the internal group — so it is installable now, with no Beta App
Review in the way.

Getting onto the **App Store** is a different question with a real obstacle in
it, and it is written down in [`APPSTORE.md`](../APPSTORE.md) rather than here.

Two traps worth keeping, because both cost hours:

- **Duplicate signing identities are invisible and fatal.** Two certificates
  named `Apple Distribution: Asad Iqbal` existed — one in a locked
  `imatch-ship.keychain-db` from another product. `codesign` cannot choose
  between identically-named identities and reports `errSecInternalComponent`,
  which reads exactly like a locked keychain and is not one. The fix was a
  dedicated `terminaldeck.keychain-db` holding exactly one identity, with
  `imatch-ship` out of the search list. Check `security find-identity -v -p
  codesigning` returns **one** distribution identity before debugging anything
  else.
- **App Store Connect's styled checkboxes swallow synthetic clicks.** Automating
  that questionnaire needs a real mouse click at the control's pixel
  coordinates; `.check()` and clicking the label both silently do nothing, and
  the form then advances with the wrong answers.

### Runbook

**Step 1 — get the issuer id (Asad, in a browser, once and forever).**

Open <https://appstoreconnect.apple.com/access/integrations/api> — the path
through the UI is *Users and Access* > *Integrations* > *App Store Connect API*.
Above the table of keys is a line reading **Issuer ID** followed by a UUID like
`69a6de70-1234-47e3-e053-5b8c7c11a4d1`. That is the whole errand. It is not the
Key ID — that is the ten-character code in the table itself, and it is already
known.

While that page is open, check the **role** on key `999LNRXQS2`. Creating App
IDs, certificates and provisioning profiles needs *App Manager* or *Admin*. A
key issued with a lower role can be replaced but not promoted.

**Step 2 — put it where the scripts look.**

```sh
export ASC_ISSUER_ID=<the-uuid>
# or, so it survives the terminal:
echo '<the-uuid>' > ~/private_keys/issuer_id.txt && chmod 600 ~/private_keys/issuer_id.txt
```

It is read from `$ASC_ISSUER_ID`, from `$ASC_ISSUER_ID_FILE`, or from
`issuer_id.txt` next to the private key. It is never written into this
repository and there is no default.

**Step 3 — register the App ID by signing something.**

```sh
scripts/ios/preflight.sh
```

With an issuer id set, the distribution-signing check stops being a check and
starts being the thing that does the work: `xcodebuild -allowProvisioningUpdates`
registers `dev.terminaldeck.ios` in the developer account and creates the
profile it needs. This is a genuine side effect on Apple's servers and it is
called out here because a script named *preflight* creating things is
surprising — but signing for distribution *is* creating them, the first time.
It is idempotent afterwards.

**Step 4 — create the app record (Asad, in a browser, once).**

A build cannot be uploaded to an app that does not exist, and no API key creates
one. <https://appstoreconnect.apple.com/apps> > **+** > **New App**:

| Field | Value |
|---|---|
| Platform | iOS |
| Name | Terminal Deck |
| Primary language | English (U.S.) |
| Bundle ID | `dev.terminaldeck.ios` — in the dropdown only after step 3 |
| SKU | `terminaldeck-ios` (private to you; any stable string) |
| User access | Full Access |

**Step 5 — say what changed.**

Edit `ios/WhatToTest.md`. It is the text TestFlight shows the tester as *What to
Test*, and both `preflight.sh` and `testflight.mjs` refuse to go on without it.

That refusal is not fussiness. Builds 1, 2 and 3 all went up with this field
empty — `betaBuildLocalizations` was an empty list for every one of them — and
the result was exactly what you would predict: the tester installed build 3,
could not tell it apart from build 2, and concluded the release had not
happened. A build nobody can verify is not a shipped build.

Write it for somebody holding a phone: name the screen, name what changed on it,
name what to look at. 4000 characters is the ceiling App Store Connect stores.

**Step 6 — release.**

```sh
scripts/ios/release.sh
```

Archive, export, validate, upload — four steps, four logs under
`ios/build/release/`, each one able to fail on its own without taking the others
with it. Roughly three minutes, most of it SwiftTerm compiling.

**Step 7 — TestFlight.**

```sh
node scripts/ios/testflight.mjs <build number>
```

Waits for processing to reach a terminal state and exits non-zero on INVALID,
answers export compliance over the API, uploads the notes from step 5, and
attaches the build to the internal group. No browser, and nothing left half
done: a build that has been through this is installable on a paired phone
minutes later, because an internal group needs no Beta App Review.

Processing itself takes 5–15 minutes. The first build of a *new app* also wants
the export compliance answer acknowledged once in the App Store Connect UI —
Apple asks anyway, and the answer is the one written down below.

### Environment

Everything the pipeline needs, and nothing hardcoded that shouldn't be:

| Variable | Default | Notes |
|---|---|---|
| `ASC_ISSUER_ID` | *none — required* | The UUID from step 1. |
| `ASC_ISSUER_ID_FILE` | `~/private_keys/issuer_id.txt` | Alternative to the above. |
| `ASC_KEY_ID` | `999LNRXQS2` | Not a secret; it names the key file. |
| `ASC_KEY_PATH` | `~/private_keys/AuthKey_$ASC_KEY_ID.p8` | The secret. Never in the repo. |
| `TD_IOS_MARKETING_VERSION` | `package.json`'s `version` | One product, one version. |
| `TD_IOS_BUILD` | `yymmddHHMM`, UTC | See below. |
| `TD_IOS_SIGN_STYLE` | `automatic` | `manual` needs `TD_IOS_PROFILE`. |
| `TD_IOS_KEYCHAIN_PW_FILE` | `~/ClaudeAsad/credentials/.terminaldeck-ios-keychain-pw` | Unlocks the keychain holding the signing key. Ignored when the identity lives in the login keychain. |
| `TD_TESTFLIGHT_NOTES` | `ios/WhatToTest.md` | The *What to Test* text. |
| `TD_TESTFLIGHT_LOCALE` | `en-GB` | The app's primary language, read off the app record — **not** `en-US`. Notes filed against a locale the app does not have are stored and shown to nobody. |
| `TD_TESTFLIGHT_GROUP` | the `Internal` group | Internal groups need no Beta App Review. |
| `TD_ASC_APP_ID` | `6801251458` | The app record. |

`release.sh --no-upload` stops with an `.ipa` on disk; `--no-validate` skips the
pre-upload check; `--skip-preflight` skips the checks it runs first.

### Decisions worth knowing about the release

**iPhone only, and it is not a close call.** A device family can be added to a
shipped app whenever the layout is ready for it, and cannot be taken away — App
Store Connect rejects a build that drops a family an earlier build supported.
The iPad layout here is adaptive because SwiftUI made it so, not because anyone
has run a terminal on a 13-inch canvas and liked it. Shipping universal on day
one would buy an iPad screenshot set, iPad review, and iPad bug reports, with no
way back. `TARGETED_DEVICE_FAMILY` is `1` and widening it later is a one-line
change.

**The build number is the clock.** `CURRENT_PROJECT_VERSION` is `yymmddHHMM` in
UTC, stamped on the xcodebuild command line rather than committed. App Store
Connect refuses a build number it has already seen — after the upload, which is
the expensive place to find out — so the only real requirement is that it always
goes up. A git commit count goes backwards on a rebase, a counter in a file is
state one machine has and the next does not, and a bare timestamp is monotonic
with no coordination at all, reads as a date in a crash report, and fits in the
unsigned 32-bit field Apple stores it in until 2042. `manageAppVersionAndBuildNumber`
is `false` in `ExportOptions.plist` for the same reason: Xcode's default is to
silently renumber the build during export, which is helpful for a human clicking
*Distribute* and a disaster for a script that has already logged what it built.

**The marketing version comes from `package.json`.** The desktop app and the
phone app are one product with one version number. `preflight.sh` fails if
`project.yml` and `package.json` disagree.

**One icon file, not ten.** The asset catalogue holds a single 1024px image and
`actool` derives every size the phone draws. The desktop icon rasterises each
size natively so the 16px one can drop detail that turns to mud — but the
smallest icon iOS asks for is 40px, above the size where the artwork switches
compositions, so there is no iOS size that wants different art.

### Export compliance

**`ITSAppUsesNonExemptEncryption` is not in `Support/Info.plist` at all**, and
that is deliberate. The question is answered in App Store Connect instead, where
the full questionnaire lives. Getting here cost a rejected upload, so the
reasoning is written down.

**The key does not mean "does this app encrypt".** It means "does this app use
encryption that is **not exempt**". Those are different questions and the
difference is the whole story:

- `false` — no encryption at all, **or** encryption that qualifies for the
  exemption under 15 CFR 740.17.
- `true` — encryption that needs a compliance code or a CCATS ruling.

An earlier version of this file set it to `true`, reasoning that the sealed
channel is real cryptography beyond what the OS performs. That reasoning is
sound about the *app* and wrong about the *key*: it conflated "uses encryption"
with "uses non-exempt encryption".

`true` makes `altool` demand `ITSEncryptionExportComplianceCode`, and the upload
fails with **90592**, *"The export compliance key value [] in the app's
Info.plist doesn't match the key value of the app's export compliance
documentation"* — the `[]` being the code that does not exist.

Meanwhile App Store Connect's own three-step questionnaire was completed
honestly for this app: the app purpose, then **"standard encryption algorithms
in addition to the encryption within Apple's operating system" — yes**,
proprietary algorithms — no, and distribution in France — no. Apple's answer to
that combination was verbatim: *"Based on your answers, you don't need to upload
any documents."* No documents means no code, and no code means `true` can never
be satisfied. The two states contradict each other.

Removing the key resolves it: the upload proceeds, and the declaration is made
in the console against the real questionnaire rather than guessed at build time.
**Upload succeeded on the first attempt after the key came out.**

Recorded so nobody re-derives it:

- The classification is **ECCN 5D992.c**, mass market, self-classified under
  740.17(b)(1). Every primitive is a published standard — X25519 (RFC 7748),
  ChaCha20-Poly1305 (RFC 8439), HKDF-SHA256 (RFC 5869), SHA-256 (FIPS 180-4) —
  and all of them are reached through CryptoKit rather than implemented here.
- `ExportCompliance.pdf` in this directory states all of that. Apple did not
  require it; it is kept as the written record behind the answers given.
- **France is answered "no"**, which means the app is not distributed there.
  That is a market exclusion, not merely a form avoided, and it is reversible
  once a French declaration is filed.
- Any annual self-classification report obligation is due by **1 February** for
  the preceding calendar year, so it never blocks a release. Sources disagree on
  whether mass-market 5D992.c even carries it; worth a definitive answer before
  February 2027.

Two things that still do not cross the line, so that the trigger stays sharp:
holding a credential in the Keychain (the Keychain is the operating system), and
the desktop's scrypt hashing of device credentials (authentication, and a
different binary in any case).

### Not done, and known

- **`NSLocalNetworkUsageDescription` and `NSCameraUsageDescription` are now
  present**, and both describe something the app really does: a pairing code can
  name a relay on a LAN, and the camera is opened once to read a QR code.
  `NSBonjourServices` is still absent because nothing here discovers anything —
  an address always comes from a code a person scanned or pasted.
- **`ws://` is allowed to work, and that is App Transport Security's doing, not
  ours.** No ATS exception is declared anywhere in this bundle; a plaintext
  WebSocket to a relay on `127.0.0.1` connects because ATS does not police the
  `ws`/`wss` scheme the way it polices `http`. A pairing code pointing at a
  public relay should say `wss`, and the pairing screen shows the endpoint so a
  person can see which they got.
- **Paste raises the system's Allow Paste prompt.** `UIPasteboard.general.string`
  is a read of another app's clipboard, and iOS asks about it once per paste.
  That is correct behaviour rather than a bug, and it is the price of a Paste
  button that works from anywhere; `UIPasteControl` is the way to avoid the
  prompt and is a later change, because it is a system-drawn button and the
  key grid draws its own.
- **The direct (tailnet) carrier has never run against the desktop.** See the
  status section.
- **Internal TestFlight only, for now.** External testing needs Beta App Review,
  and the export filing above has to be done first either way.
- **The Liquid Glass icon format** (Icon Composer, `.icon`) is a later upgrade;
  a 1024px PNG is still what iOS 26 accepts and masks.

## Layout

| Path | Owns |
|---|---|
| `TerminalDeck/Protocol/` | the wire language: types, codec, backoff. No UIKit, no SwiftUI. |
| `TerminalDeck/Crypto/` | the sealed channel — a port of `src/shared/sealed.ts`, and the only cryptography in the app |
| `TerminalDeck/Transport/` | the seam and what is under it: carriers, the protocol state machine, pairing codes, the Keychain |
| `TerminalDeck/Terminal/` | SwiftTerm, the two directions data moves through it, the key bar and grid, and the gesture reconciliation |
| `TerminalDeck/Screens/` | pairing, the approval wait, the session list, the terminal |
| `TerminalDeck/App/` | composition root, navigation, the model every screen reads, the network watcher |
| `TerminalDeck/Assets.xcassets/` | the app icon, generated — see above |
| `Support/Info.plist` | what the bundle claims about itself, including the export declaration |
| `Tests/` | everything that needs no server: crypto vectors, wire, pairing codes, Keychain, the transport state machine |
| `UITests/` | everything that needs a finger and a real desktop |
| `Harness/` | the Node side: the crypto fixtures, and a relay + stand-in desktop to run against |
| `../scripts/ios/` | the release pipeline: `preflight.sh`, `release.sh`, `ExportOptions.plist`, `icon.mjs` |

`Transport.swift` is the seam: everything above it talks to a `Transport` and
nothing else. `Carrier.swift` is the seam under *that* — the protocol state
machine in `LiveTransport` does not know whether it is riding a sealed relay
socket or a plain tailnet one, which is what kept adding the second one from
being a second copy of the first.

## Decisions worth knowing

**Deployment target iOS 17.** SwiftTerm needs only 14. What pins 17 is
`@Observable`, `NavigationStack` and `ContentUnavailableView`. Going to 18 would
buy nothing and would drop the iPhone XS/XR generation.

**Swift 5 language mode.** SwiftTerm is a UIKit library with no `Sendable`
annotations and its own manifest declares `swiftLanguageVersions: [.v5]`.
Compiling this app in Swift 6 mode turns every touch of a `TerminalView` from a
callback into a concurrency error inside someone else's library. The compiler is
still 6.x; only the language mode is 5, and the one place it matters carries a
`@preconcurrency` conformance rather than a suppression.

**The project file is generated, not committed.** A `.pbxproj` is the one file in
an Xcode repo that two people cannot edit at once. `project.yml` is 60 readable
lines instead.

**The wire types are a copy, and that is a cost.** The PWA imports
`src/main/remote/protocol.ts` directly so there is no second copy to drift.
Swift cannot, so `Protocol/WireProtocol.swift` is the copy — it changes only when
`protocol.ts` changes, in the same commit, with the same values.

**Four-space indent.** The repo's style rules are about the TypeScript; Swift
follows Swift.

## What is faked, precisely

Nothing, in the app. `StubTransport` and `InMemoryCredentialStore` are both
gone: the transport talks to a socket and the credential lives in the Keychain
behind `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — after first unlock so
a background reconnect works with the phone in a pocket, this-device-only so a
credential that grants a shell does not sync to every device on the account.

Two things outside the app are stand-ins, and both say so:

- **`Harness/host-standin.ts`** is a desktop, because the real one has no relay
  client yet. It imports the real relay, the real sealed channel and the real
  protocol parser; what it invents is the host side of the envelope and the
  `create` verb.
- **`create` itself.** Protocol v1 has no way to start a session and
  `parseClientMessage` closes the socket on a verb it does not know. So the New
  Session button appears only when the far end advertises `create` in
  `welcome.capabilities` — which the harness does and no shipping desktop does.
  Against a real Mac the button is absent rather than disabled, because a button
  that cannot work is a smaller lie, not an honest one.
