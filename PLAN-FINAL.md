# The plan — 91 review items to a release on every surface

Written 2026-08-18 from `REVIEW-2026-08-17.md` (four recorded parts, 48 minutes).
His instruction: build it, test it on every device, ship it everywhere, decide
everything myself, do not wait for him, do not hold anything back.

## Decisions I am taking, so nothing waits

Recorded here rather than asked, because he is asleep and said to decide.

1. **Later statement wins** where the review contradicts an earlier decision.
   iOS goes to **four tabs** (Copilot · Sessions · Localhost · Settings), not
   three. Driving mode is **rebuilt** around a machine-speed scan, not a paced
   read-along.
2. **Account model C** — separate config dirs, shared `projects/`. Measured to
   work, keeps two accounts running at once, and the app never holds a token.
3. **A device cannot change kind after pairing.** Guest → mine means re-pairing.
   A toggle would make the distinction one tap deep.
4. **The copilot's terminal is not offered over the remote connection.** Full
   control means its chat, tools and consent — not a raw pty.
5. **The Alerts unread badge gets wired** to a real count.
6. **The tab pill lift stays as it is.** He praised the usage pill and asked for
   no change; nothing in the review asks for the tab pill to move.
7. **Ship signed-but-not-notarized on macOS.** Apple's notary service has held
   five submissions since 14 August, including a few-hundred-byte probe. The
   release workflow already handles this explicitly and the download page says
   so. Not a reason to hold a release.

8. **Android is not in this review and does not gate the release.** He reviewed
   macOS, Windows-by-alignment, iOS, the web app and the site — Android is named
   in none of the four recordings, and what he asked to be pushed was *"push to
   iOS, push to TestFlight, push to GitHub."* The Android client is real and was
   proven end to end against the live relay on 14 August, so it is not abandoned;
   it simply gets no UI work this round. If its APK builds clean at ship time it
   rides along on the GitHub release. If it does not, that is said plainly rather
   than holding four other platforms for it.

## Three checks that decide delete-or-build, before anything else

- **Fast mode** — does the CLI support it at all? If not, remove the control
  entirely rather than leave one that cannot act.
- **large-v3** — is bundling it legally allowed? If not, key-only.
- **The model list** — what models actually exist. `Opus 4` reading where `Opus 5`
  should be is a symptom; the list is short and stale.

## The through-line

Three of the four parts say the same thing from three surfaces:
**remote must feel exactly like local — desktop, web and phone.** Today the
desktop's Remote page connects but cannot control, the web app lists localhost
with no way to open anything, and the phone has neither. That is one piece of
work, not three, and it is the largest.

The second through-line is **his audience**: *"mostly non-technical vibe
coders."* It is why file paths and JSON in Advanced are wrong, why the copilot's
settings need edit buttons rather than a list of paths, and why every screen that
says "this is not ready" must also say what to press.

## Waves

**1 · Decide and sweep** — the three checks above; the neutral-naming sweep (no
Claude, Gemini or VS Code named in shared UI, product-wide); the copilot
capability test he asked for after finding it could not drive.

**2 · The desktop, in parallel by file ownership**
- Copilot setup flow trimmed + Settings → Copilot made editable
- Top bar: two stacked usage bars, labels dropped, real model list, effort
  default, connectors hidden when empty
- Chat view: stray box, clipped dropdown, options row removed; attachments open
  the OS picker
- Sessions and windows: open-beside not switch, consistent new-session, the ✕,
  the copilot-folder collision
- Broken pages: Artifacts, Source control, hooks vs CLIs, the phantom session
  list, the token count
- Settings: Help page, Language gone, Advanced in-app, section rename,
  confirm-close and its un-silencing

**2b · Two items held back from wave 2 on purpose** — both live in files wave 2
already had open, and a third agent in a file two others are editing is how the
mass-revert happened on 17 August. They go out with wave 3.
- **Accounts**: "Add" and "Sign in" become one thing called **Add account**,
  opening a small popup with only the sign-in steps rather than the whole Agents
  page. *"It is confusing. Just give me the login, sign-in steps."*
- **AI readiness**: every not-ready row needs an action button that actually
  performs the fix, or a way to dismiss it. *"They should not see something they
  cannot do something about it."* The existing "create README" button is the
  right shape and is not finished.

**3 · Remote, everywhere** — folder approval as a real step-by-step flow before
anything is reachable, remote sessions in the sidebar, remote localhost with the
machine's icon, and the same on web and phone.

**4 · The browser** — bottom chrome gone, profiles and saved passwords, the
sign-in flows that get stuck, and confirming the driver is genuinely code-driven
rather than screenshot-driven.

**5 · Driving mode, rebuilt** — machine-speed scan across every session, the
intelligence UI, one combined answer at the end, the interactive toggle, and the
layout rule he stated twice: no split on its own page, side panel only when it is
elsewhere.

**6 · iOS** — four tabs, swipe actions, remote parity, copy fixes, refresh and
reconnect earning their place or going.

**7 · Web app and website** — remote parity, localhost driving, the copilot, and
the wasted header.

**8 · Verify and ship** — full suite, typecheck, packaged builds opened and
walked on macOS and Windows, the simulator driven, the web app and site checked,
then tag, release, and upload to TestFlight.

## Owed, handed back by agents that finished — do not lose these

**From driving mode (landed 2026-08-18): all five closed 2026-08-18, later the
same night.** Every one was proven against the running app rather than against a
test, through the copilot's own loopback MCP endpoint with a person clicking the
consent dialog, and looked at in both themes.

1. ~~**A copilot setting never reached the open window.**~~ `prefs:changed` and
   `settings:changed` in `live-push.ts`, pushed by `DeckSurface.applyToWindow`
   and taken by `useAppSettings`. **Proven:** asked for the light theme,
   `state.json` said `"light"` **and the window went light with no reload**;
   `appliedToWindow` now reads *"in-the-open-window… It is on screen now"*, and
   it is measured rather than asserted — a host with no window still says "next
   started", which `settings-write-visibility.test.ts` pins from both sides.
2. ~~**`copilot.interactive` has no Settings row.**~~ *While it works → "Show me
   what it is looking at"*, in `CopilotSection`. The key is pinned against
   `tour-tool.ts`'s `INTERACTIVE_KEY` by a test, because the two sit on opposite
   sides of a bridge that carries `unknown` and a rename would otherwise be a
   switch that moves and changes nothing.
3. ~~**A ghost row in the sidebar.**~~ `PtyManager.kill` now announces
   `session:removed` the moment it drops a session, `App.tsx` takes the row away,
   and the account switch opts out with `RemovalReason.replaced` so a swap cannot
   lose its own tab. **Proven:** *"Copilot sessions → Session 1"* was in the rail,
   `sessions_stop` ran, the row and the tab both went, no reload.
4. ~~**`where.ts` cannot name the session behind a conversation.**~~ `ChatView`'s
   root carries `data-chat-session`, and only when it knows which pty it acts on
   — a folder with two live sessions still answers `pane: chat` with no name,
   which is a real ambiguity rather than a missing capability. **Proven:**
   `app.where` returned `pane: "chat"` with the session's own id.
5. ~~**Scraping does not show itself.**~~ Not painted over the page, which cannot
   be painted on, and not a screenshot animation pretending to be live. A
   `BrowserWatch` panel in the rail's column carries the drive's own present-tense
   step and the app's own action log: the URL, **the element the driver
   resolved** (its label, not the selector it was asked for) and how much text it
   took. **Proven:** open → read → click on a real page produced *"Terminal Deck
   harness"*, *"124 characters · 11 elements"*, *"Show sidebar"*.

Two things found while proving those, both fixed here:

- **`browser.open` left the drive reporting no URL at all.** `setStep('')` only
  publishes when the step changes, and after an open it usually has not — so the
  last status anyone saw was taken before the navigation. Both readers of it (the
  banner over the page, the panel beside it) said "no page open" over a loaded
  page. It publishes once the page settles now.
- **A drive does not end when a scrape does.** `browser-driver.ts` only releases
  the tab when the tab is *closed*, so the panel would have sat over the rail —
  the only way to reach every session in the app — from the first `browser.open`
  until somebody thought to close the browser tab. It wears the driving panel's
  own fold dot; putting it away is keyed to that tab, so the next errand brings
  it back without anything having to expire.

**From the website (landed 2026-08-18, committed):** nothing owed.

## The bar

Nothing is reported done because a test passes. Every visual item is looked at,
in both themes, on the surface it belongs to. Every "it cannot do X" is proven
against the real thing, not a stand-in — the iOS harness advertises capabilities
it does not implement, and that has already produced one false verification.
