# The local-first plan

Two recordings, 2026-08-16: 47 minutes on the macOS app, 11 minutes on the phone.
Transcribed losslessly through GPT-4o (`VIDEO-2-TRANSCRIPT.txt`,
`VIDEO-3-MOBILE-TRANSCRIPT.txt`) and every frame read.

**The rule he set, and it governs everything below:**

> *"make all of these changes in the local macOS application first. Once I check
> them properly — I do all the inspection myself — and I tell you it's good to
> go, then we align everything else to it. This one will be the final."*

So: macOS only. Nothing pushed, nothing tagged, no iOS build, no web deploy,
until he has sat in front of the local app and said so. The iOS list is
recorded here and deliberately not started.

---

## What the frames found that the audio did not

Worth stating separately, because these are worse than described and none of
them were reported as bugs — he never saw them as bugs, he saw them as the app
being slow or odd.

1. **The app thrashes between pages.** ~24 consecutive frames alternating Files
   ⇄ terminal with the cursor motionless, the sidebar highlighting Files while
   the content pane shows a blank terminal. Roughly a minute of the recording.
   Artifacts does the same and re-fetches from scratch each time.
2. **Codex sign-in crashes.** Add-account opens a blank session which prints a
   raw Node `ENOENT` stack trace for a vendored `codex` binary and exits. Twice.
   No error card, no "not installed", no retry — and each attempt leaves an
   orphan session behind, five by the end, names clipped to `Se…`.
3. **The macOS folder picker lists nothing.** Four separate openings, never a
   single row. It is also not modal — the app navigated pages behind it — and
   `Browse…` from the New session dialog opens it *underneath* that dialog.
4. **Session identity is broken**, not untidy: two projects each with a
   "Session 1", two tabs both labelled "Session 1", a sidebar reading
   `Session 1, Session 2, Sess…, Session 4, Session 5` — a truncated name and a
   missing 3 — and a title bar naming a session with no tab.
5. **In dark mode the selected Settings section is invisible** — dark-on-dark,
   a blank gap in the nav. You cannot see where you are.
6. **Terminal text clips.** The Claude banner's right border floats detached,
   and a real error rendered as `✗ Auto-update failed · Run cl…`, cut mid-word.
7. **Ghosts.** Dismissed dialogs leave translucent rectangles painted over the
   content; the picker paints as a solid black void before it draws.
8. **An accidental project — `untitled folder` — is now permanent** in the
   sidebar and the project list.

---

## macOS — grouped by the change, not by the page

### A. Stop it lying and stop it thrashing

- The Files/Artifacts ⇄ terminal ping-pong. One page owns the pane at a time.
- Files must not say *"Nothing to show."* and render a `README.md` header over
  a blank body at the same moment, nor print "Loading…" twice.
- Pages that never resolve: *Reading the transcript…*, *Reading your MCP
  configuration…*, *Reading repository…*, *Reading the changes…*, and Remote's
  two — *Reading the current state…*, *Reading the machines this desktop
  knows…*. Each needs a real terminal state: loaded, empty, or failed-with-why.
- `Model Unknown` / `Permission Unknown` in the composer. Permission never
  resolves at all.
- The Overview Sessions widget vanishes mid-session and never returns.

### B. Sign-in has to work, and fail like a product when it cannot

- **Codex**: detect the missing binary *before* spawning and say so, with the
  install command. Never a stack trace.
- **Gemini**: he cannot add even one login. One must be possible.
- Add-account must not create a session at all until sign-in succeeds, and must
  clean up after itself when it does not.
- **Sign in, not Add** — one button, straight into the flow, not two steps.
- A **`+` that offers many agents** — Grok and the rest — the way Cursor and VS
  Code do, not a hardcoded four.

### C. One subject, one place

Agents, Accounts, Setup and the agent/notification rows currently in General are
one subject scattered across four sections. Group by subject. Notifications all
under Notifications. **Nothing may be dropped in the move** — his explicit worry,
and a fair one.

### D. Cut the words, keep the meaning

Every row is 1–2 lines with an ⓘ for the rest. Vibeyard's entire Preferences is
8 sections, one screen, no descriptions; ours is 13 sections with two lines of
prose under every row. That comparison is the target.
Shortcuts becomes a popup, Help links to the website, About stops scrolling.

### E. The chrome

- Tab strip on top; the **Terminal/Chat/Split bar moves below it**, so it is
  absent inside a browser tab where it means nothing.
- New-session and new-window buttons **next to each tab**.
- Session rename by **double-click**, no pencil. The pin moves to where the
  pencil was and gets a better glyph.
- Session names must not lose to account chips — never `S…`.
- Folder chip becomes a title unless it can genuinely add a folder to a session.
- Login shows the **email**, not "Default".
- "Continue the last conversation" must say **which**, with a picker.

### F. The browser

- Inspection: a popup **anchored at the click**, carrying a **session picker
  that sticks per window** and stays greyed until chosen — his mobile sheet
  already does this and is the reference.
- Highlight becomes a **1px outline**, not the opaque blue fill that hides the
  element.
- Flow recording actually records; clicking must not throw the panel back to
  Element.
- Screenshot pops up with a preview, the path, and a box to send to an agent.
- Only one instruction strip on screen at a time.
- The port list must not be eight of our own ports labelled "Terminal", and
  clicking one must not land on **`that is not how to ask`**.
- Icons get labels or tooltips.

### G. Overview and Remote

- **One** cost figure, not two. See "The cost figures, settled" below.
- Context window must say whose.
- Remote shows nothing until a device is connected; the tailnet card goes;
  the fingerprint is printed once, if at all; one turn-on, not two.

### H. Appearance

- Dark mode goes **flat** — the sidebar and header are gradients today, light
  mode is flat, so this is a dark-only regression.
- The selected nav item must be visible in dark mode.
- Terminal font gets a real control, or the row and its stray `❯ npm run dev`
  specimen go.
- **Real provider logos in their real colours.**

---

## iOS — recorded, not started

Four pills (Sessions · Localhost · Machines · Settings) · Machines moves inside
Settings · the pill hides inside a session and inside localhost · localhost
stops animating like a browser and gets folding, categories and renameable
ports · start/stop a server from the phone · one-finger scroll still selects ·
the back button beside refresh does nothing · **notification spam on every
return to the list** · **GitHub sign-in needs many clicks and never completes —
Done returns to the code screen** · swipe actions on rows · flow and
screenshot-to-agent in the mobile WebView · possibly chat per session.

---

## Found in the Settings frames after the first pass missed them

The scene-change extraction skipped tab switches inside the Settings modal, so
these were invisible until the walkthrough was re-extracted at a fixed interval.
Several answer complaints he made without knowing the cause.

1. **Codex is reported three contradictory ways in three panes.** Agents shows a
   green **Ready** badge beside `version not reported`; Setup says its hooks are
   `All hooks installed`; Accounts shows the raw `codex … ENOENT`. The green
   badge is *why* he says the app never tells him Codex is installed — it tells
   him the opposite of the truth.
2. **Power's own copy refutes its own switch.** "Keep running with the lid
   closed" is ON, and twenty pixels below it: *"Closing the lid or choosing
   Sleep still does."* Then a second box disclaims the setting entirely — "this
   was already on before the app started… something else may have set it."
   His bug report was already printed in the pane.
3. **Agents → "Check again" hangs forever** — skeleton bars replace the list and
   never resolve; still spinning 24s later when he gave up. It also destroys the
   information it had.
4. **Adding a Gemini account is impossible, not limited.** The radio is
   *disabled*. The badge says "One login only"; the UI delivers zero.
5. **A raw Electron IPC error is rendered at the user**: `Error invoking remote
   method 'profiles:create': ProfileError: a claude account called "…" already
   exists`.
6. **Two account rows with identical titles** after adding Codex, separable only
   by an icon and a `-2` path suffix.
7. **The three yellow Browser warnings are word-for-word identical** except the
   browser name — Chrome, Edge, Brave — with one shared remedy (grant Full Disk
   Access once). Edge and Brave are probably not even installed and warn anyway.
   Meanwhile "Chrome (14 profiles)" is advertised in a **disabled** segment while
   the only real profile picker is a bare `Default` dropdown 300px below.
8. **The Start page field saves on every keystroke** — footer reads "Saved."
   while the value is the fragment `google.c`.
9. **Setup admits the duplication in its own copy**: "the same three rows used to
   be drawn here as well, under a second heading." GitHub Copilot appears twice
   on that page with conflicting statuses — `Not found` and `Not supported`.
10. **`0 of 10 installed · 10 out of date`** — an impossible pair, above prose
    saying the opposite.
11. **One sound setting, two panes, opposite states**: General's "Play sound when
    session finishes work" is OFF while Notifications' row is ON.
12. **"Check for updates" is dead** in a 0.2.0 build, and the pane explains why by
    naming Squirrel.Mac.
13. **A malformed backup file is written to disk**: `hook-backups/gemini-.gemini-settings.json.bak`.
14. **Advanced → Debug trace is badged `not created yet`** and still offers live
    Copy and Reveal for a file that does not exist; path rows mix "Open" and
    "Reveal" for the same action.
15. **Features headlines "Nothing is downloaded"** above seven installed rows with
    Uninstall buttons, and says "Everything is installed" while one item is not.
    Installed rows get a toggle *and* Uninstall; available rows get Install only —
    so "off" and "uninstalled" are different states with nothing explaining the
    difference.

**Help** opens on *Troubleshooting*, four levels deep (modal → nav → sub-nav →
article), and its default article is a PATH-debugging manual full of
`/opt/homebrew/bin` and `~/.nvm`. The first thing Help says to a new user is why
their CLI is broken.

**Shortcuts** is 32 rows over ~2.5 screens, and its own subtitle admits they
cannot be changed — so it is a document occupying a settings tab. `Esc` and `⌘D`
are each bound to two different things.

---

## The cost figures — removed entirely (2026-08-17, final)

**This supersedes the section below it.** After reading the analysis, Asad closed
the whole feature rather than keeping the half that was computable:

> *"Let's not show any kind of price, any kind of cost, because people are using
> subscription and we are showing API price. So if we cannot show the both,
> let's not show any of them completely. Close this."*

He is right, and the reasoning is worth keeping: an "API equivalent" figure is
still a dollar amount shown to somebody who was billed a flat fee. Labelling it
does not fix it — the number tells a subscription user they spent money they did
not spend. One figure misleads, the other cannot be computed, so there is no
honest pair and no honest single.

**Gone:** every dollar figure in the UI, `formatUsd` and its three renderer
copies, `aggregateCost`, all per-model rates, the cache multipliers, the whole
subscription block, and any IPC field that existed to carry a cost across.

**Kept, because these are facts and not prices:** token counts, cache hit rate,
and the context window — which must still name whose window it is.

Removing the rate table also deletes the dated Sonnet 5 bug described below;
there is nothing left to over-charge with.

---

## The cost figures, first analysis (2026-08-17, superseded above)

Asad, on the Overview tile reading `$100–200` subscription and `$2` API:

> *"both are not actually accurate… if we cannot reliably get this thing done
> then we don't need to have it. We don't keep anything which is not credible,
> which is not accurate."*

Checked against Anthropic's live pricing — `platform.claude.com/docs/en/about-claude/pricing`
and `claude.com/pricing`, both read 2026-08-17. Three findings, and they point
in different directions:

**The API figure is correct.** The `MODELS` table matches the published one
exactly: Opus 5 $5/$25 with cache read $0.50 and 1h write $10, Fable/Mythos
$10/$50, Haiku 4.5 $1/$5, and the 0.1 / 1.25 / 2 cache multipliers. `$2` for a
million tokens is real arithmetic, not a bug — a warm agent session is ~90%
cache hits at 0.1× base, so a million mostly-cached tokens genuinely costs a
couple of dollars. It reads as fake only because nothing on screen explains the
cache discount. **Keep the number, make it explain itself:** cache hit rate
beside it, a per-category breakdown, the models it was priced from, the date the
rates were verified, and the word "equivalent" rather than "spent".

**The subscription figure goes.** Two independent reasons, either sufficient:

1. What it shows *is* the package price — `SUBSCRIPTION_PLANS` × `billingMonths`
   is the plan's own fee for the span the work covers. That is the thing he said
   he does not want.
2. His proposed replacement — API cost ÷ the plan multiplier, so Max 5× is a
   fifth of API — has no published basis. The 5×/20× in those names is a
   multiple of **the Pro plan's usage allowance**, not a discount against API
   rates, and **Anthropic publishes no token allowance and no per-token value
   for any subscription plan.** Both pages were checked. There is no conversion
   to compute, so any such figure would be invented.

His own rule decides it. The figure is deleted and the argument is left in the
code so nobody re-runs it.

**A dated bug, found only by verifying.** The table time-boxes Sonnet 5's
$2/$10 as introductory pricing reverting to $3/$15 on 2026-09-01. Anthropic has
since cancelled that increase — $2/$10 is now the standard price. Left alone,
this app starts over-charging Sonnet 5 by 50% in two weeks. Also: Opus 4.5 is
flagged `legacy` but is in the current published table.

---

## The chrome, as specified 2026-08-17

Supersedes the two tab-strip lines in §E above where they conflict.

- **Chrome-shaped tabs** — the active tab visually continuous with the pane
  under it, the way Chrome draws it. Detached floating pills today.
- **No `+` in the strip.** After the last tab, two icons: **terminal** and
  **globe**. Globe opens a browser tab on the start page; terminal opens the
  new-session popup.
- **No quick-open path at all.** The sidebar's New session button opens the
  dialog, always — *"we don't want this quick window at all"*. The chevron half
  added earlier is removed. "Remember these choices for this project" covers the
  repeat case. Sidebar keeps two actions: Browser and New session.
- **No fold-away arrow inside a tab** — tabs are not pushed back down from
  there any more. The sidebar's promote toggle stays; that is the other
  direction.
- **The `×` on a tab closes the view only.** The session keeps running and stays
  in the side panel. Only the side panel's `×` ends a session. Two `×` glyphs
  that mean different things is how someone loses work, so they must not look
  alike.
- **Alerts stops being a rail item** — a small icon beside Settings that opens
  notifications.

## The account chip, as specified 2026-08-17

- It says **"Default"**, which is the internal profile key leaking to the
  surface. Show the **email** — the identity the session is actually running as.
  Where no email exists, say something true and specific; never the word
  "Default" dressed as an identity.
- **The account name is renameable.** Collisions handled in the UI, not as a raw
  `profiles:create` IPC string at the user (see item 5 above).
- **The session name is renameable from inside the terminal**, by double-click —
  the same idiom already decided for the sidebar, one implementation and two
  entry points.
- The selected account must be unmistakably marked.
- **A usage-window bar beside the account** — *"for Claude we have a five hour
  window… how much limit is completed, how much is left, with the time of
  renewal."* Gated on the same test the cost figures just failed: build it only
  if a real reset time **and** a real consumed fraction can both be read
  locally. A bar implies a measured fraction; an estimated one is worse than
  none. If only part is knowable, show only that part. If none is, build
  nothing and report what was checked.

## Per-pane chrome, and the controls that belong in it (2026-08-17)

The largest remaining piece, and it is one change wearing three hats.

### The problem he found

> *"In a split view, it can be from two different projects, two different
> folders, two different accounts. The accounts and other things related to it
> are always above the view, not inside the view. So it can be showing something
> for one of them or maybe the other one — it can be a confusion, which one it
> is showing right now."*

He is right and it is a correctness bug, not a layout preference. Window-level
chrome describing a pane-level fact is ambiguous the moment the panes differ,
and the account chip is exactly such a fact. The fix is **chrome ownership moves
from the window to the pane**.

### The shape he asked for

- The **primary pane** keeps the ordinary background — no container, chrome
  reading as part of the window.
- The **secondary pane** is visually **a box**: contained, distinct, obviously a
  second thing rather than a continuation of the first.
- **Each pane carries its own bar above its own content**, holding that pane's
  account and its related controls.

### What goes in that bar

He also reversed an earlier removal, and the reversal is narrower than it looks:

> *"Last time I asked you to remove things, but I only asked to remove the
> Options button, which was showing all the other settings we already have with
> the other buttons. So let's bring them back — select model, select effort. But
> this time we will not bring them inside the chat box. We will bring all those
> settings next to this drop-down of selected account. So it will work for
> terminal view also, it will work for chat view also — it will not be part of
> the chat view only."*

So the bar holds, per pane: **account · model · effort · usage**. The point is
that these stop being chat-view furniture and become session chrome, which is
what makes them meaningful over a terminal.

Plus: *"and also bring that usage bar."* Built from `plan-limit.ts`'s live
reading and the Codex rollout files — the two sources that are actually
accurate — and explicitly "not reported" the rest of the time. The
`~/.claude.json` cache is **not** usable; it was measured 21.3 hours stale and
does not refresh.

### A latent defect this work uncovered, and it belongs to the same pass

**A browser page cannot be shown in a pane at all.** Found while making the
globe opener promote its tab: with the window split, a page opened from the
globe arrives unselected and stays behind the split. The obvious fix — the
`showInFocusedPane` line `newSessionIn` already uses — does select it and
**silently destroys the split**, because a pane holding a non-session id is a
dead pane and `pruneClosedSessions` collapses the layout on the next render.
Reproduced live, backed out, and pinned with a test so nobody retries it
casually.

`selectTab` returning early for a non-session id is the symptom; the cause is
that the pane model only understands sessions. Since the per-pane chrome work
is already opening up how a pane owns its own identity, this is the pass that
should fix it — a split holding a terminal on one side and a localhost page on
the other is an obviously wanted arrangement.

### And the click must do something

> *"It should actually work — change the efforts and models for terminal also,
> when we click another one, just by clicking rather than sending a command."*

The objection is to *him* typing the slash command, not to one being sent. The
app writes it — carefully, because writing into a pty someone is using can
corrupt their input, and a picker that shows what it asked for rather than what
is true is the lie this app keeps catching.

**Sequenced deliberately:** the mechanism (pty write, usage state over IPC) is
being built first while the chrome files are contended; the per-pane layout
follows and should then be layout only.

## Tab pills, round three (2026-08-17)

Queued behind the width/auto-add agent, which owns `WorkspaceTabStrip.*`.

- **Brighter pills.** *"Make the selected tab pill up there, selected and other
  tabs' pill, a little bit more white."* Both states lift — the rebuild left the
  selected tab on `--bg-primary` and unselected tabs with no fill at all, and
  the result reads too dim. Keep the Chrome join intact: whatever the selected
  tab becomes, the pane beneath it has to follow, or the seam he asked for comes
  back apart.
- **The ✕ goes to the far right edge, inside the pill** — *"not next to the
  text, it should be just at the end of the pill inside."* So the label takes
  the free space and the close button pins to the trailing edge, rather than
  trailing the text at whatever width the title happens to be.

## Follow-up pass — after the tab-strip agent lands

Both touch files that agent currently owns, so they are deliberately queued
rather than run alongside it.

- **Notifications is a popup, not a page.** *"Notifications should be a pop-up
  just like settings, not a full page."* So Alerts stops being a `PanelId`
  destination entirely, not merely a rail item that moved. Every existing route
  to it — dashboard, alert actions, command palette — must open the popup
  instead; no dead routes left behind. Reuse the Settings modal shell rather
  than writing a second one.
- **Light mode: the in-session chrome must match the terminal.** The band inside
  the session window carrying the account chip and the Terminal/Chat/Split
  control is pure white in light mode while the terminal body beneath it is a
  soft grey. Dark mode already matches, and he likes it there — this is a
  light-mode-only regression, the same shape as the flat/gradient one in §H.
  **The top header carrying the window tabs stays visually distinct — he
  explicitly does not want that changed.**
