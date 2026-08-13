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
| A2.1 | macOS | ✅ ships; ⚠️ current build predates today's fixes |
| A2.2 | Windows | ⚠️ built, **never launched on his PC** |
| A2.3 | iOS | ✅ TestFlight build 2 VALID (2608132126); ⚠️ never tested vs the real desktop |
| A2.4 | Android | ✅ verified vs REAL desktop over LIVE relay; signed release APK built |
| A2.5 | Windows download on the website | ❌ |

### A3 — Features
| # | Requirement | State |
|---|---|---|
| A3.1 | Attach to a running session from the phone, with scrollback | ✅ proven on real hardware path (Android) |
| A3.2 | Start / resume sessions from the phone | ✅ iOS: real `claude` PTY started from the phone, typed into, resumed with replay. Android needs 3 literals. |
| A3.3 | **Localhost tunnel** — see the Mac's dev server on the phone | ✅ raw TCP tunnel, hot reload proven |
| A3.4 | Tunnel must be seamless: tap a port, no typing | ✅ ports self-populate, tap is the consent |
| A3.5 | npm name claimed | ✅ `terminaldeck@0.0.1` |
| A3.8 | **Clipboard both ways** — phone→terminal and terminal→phone | ⚠️ paste-in verified; copy-out unverified |
| A3.9 | **Send files/photos/videos from the phone into the terminal**, with progress, landing at a real path | ❌ NEW — no extra approvals needed if built with modern pickers |
| A3.7 | **Multi-host**: one phone paired to many machines at once (several Macs *and* Windows), sessions separate, switch between them | ❌ NEW 2026-08-14 — no blocker found |
| A3.6 | **Inspect mode on iOS** — tap an element in the tunnelled page, type the change, send it to the agent — exactly as the desktop browser does | ❌ NEW 2026-08-14 |

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

**W13 — Clipboard both ways** `ios/`, `android/`
A3.8. Paste-in works. Copy-out is unverified on both. Watch `MAX_INPUT_BYTES`
(16 KiB) and keep bracketed paste, or a multi-line paste submits early to a
coding CLI — the same hazard `composeSend` guards against.

**W14 — File / photo / video transfer** `ios/`, `android/`, `src/main/remote/`
A3.9. Chunked over the sealed channel, progress from acked chunks, lands at a
real path which is then typed into the terminal.
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

**W10 — End-to-end proof** everything
A5.6. **Android half is DONE.** Remaining: iOS against the REAL desktop over the
live relay — so far it has only met its own stand-in host. Then a final sweep.

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
