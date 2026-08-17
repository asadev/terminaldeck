# Cross-agent hand-offs, 0.2.0

Twelve agents built in one working tree with disjoint file sets, which is what
made them safe to run at once and also means every change that crossed a
boundary had to be *described* rather than made. This is that list. Anything
still unticked when the waves finish is applied in the integration pass, before
the suite is run.

Ticked items were applied directly by me because no agent held the file.

---

## Applied

- [x] **`src/renderer/settings/settings-schema.ts`** — `browser.startUrl` default
      was `http://localhost:3000`, so the first browser tab on a fresh install
      navigated somewhere nothing was listening and landed on Chromium's red
      error page. That is the screenshot Asad sent. Now empty, which is what
      makes the start page reachable.
- [x] **`src/renderer/components/GitPanel.tsx`** — render `status.message` before
      the four generic constants, now that `git.ts` returns written prose instead
      of git's stderr. Also fixes a repo refused for *dubious ownership* being
      told "This folder is not a git repository", which is false and names no way
      out.

## Owed, waiting on the file's owner to finish

- [ ] **`src/main/transcript.ts` — `encodeProjectPath` is wrong for every WSL
      path.** The most important item here. It calls `path.resolve`, so on a
      Windows host `/home/asad/ClaudeImza` becomes `C:\home\asad\ClaudeImza` and
      encodes to `C--home-asad-ClaudeImza`, while the Linux agent that wrote the
      transcript encoded `-home-asad-ClaudeImza`. Nothing matches.
      This is not only a restore bug — **chat view and cost read the same encoded
      directory**, which makes it a live candidate for the "chat and terminal show
      different conversations" fault, at least on Windows. The proper fix is
      posix encoding when the path is a Linux path, plus reading through
      `\\wsl.localhost\<distro>\home\<user>\.claude\projects\<encoded>` so
      "genuinely nothing" is distinguishable from "cannot see". Needs the distro
      and home from `WslLink`. *Owner: session-view agent.*
- [ ] **`src/main/fs-tree.ts`** — same root cause, different symptom: the app log
      on his PC shows `fs:list failed ENOENT: realpath 'C:\home\asad\ClaudeImzacrm'`.
      This is almost certainly his *"Files — I don't see any files here"* on
      Windows. Route through `statablePath`. *Owner: artifacts agent.*
- [ ] **`src/renderer/shell/PanelView.tsx`** — Overview is gated behind
      `if (!projectPath) return <NeedsProject/>`, but the new session board needs
      no project; "which agent needs me" is not a per-folder question. Move
      `case 'overview'` above that check, beside `hooks`/`mcp`/`machines`.
      *Owner: session-view agent.*
- [ ] **`src/renderer/shell/Sidebar.tsx`** — three lines to make sidebar rows a
      drag source for the new top tab strip, using the `startTabDrag` contract in
      `shell/workspace-tabs.ts`. Without it the strip works but nothing can be
      dragged *into* it. *Owner: remote-merge agent.*
- [ ] **`src/main/index.ts` + `src/preload/index.ts`** — a `session:screen`
      invoke channel exposing `PtyManager.screen(id)`, the settled emulator
      viewport. It already exists and is consumed only inside
      `agent-controls.ts`. With it the session board gains a true "last line the
      agent wrote" in ~15 lines. Without it that line stays off the card, because
      the PTY stream tail is *not* the screen — agent CLIs repaint with cursor
      moves — and using it would put a false line on the screen people use to
      decide where to spend the next hour. *Owner: windows-chrome agent.*
- [~] **`src/renderer/App.tsx`** — `onNewSession` into the `dashboard={{…}}`
      object, so the board's empty state offers a button rather than naming the
      ⌘T chord. **Deliberately deferred.** The board does not declare the prop,
      so this is a context-type change plus a button plus tests, for a screen
      that is already correct — naming the chord teaches the shortcut, which is
      arguably the better empty state anyway. Not worth spending release time on
      while real defects are open. `newSession` already exists at
      `App.tsx:615` if it is picked up later.
- [ ] **`src/main/index.ts:866`** — `void wsl.refresh()` is unawaited; a latent
      race flagged in passing. Confirm whether anything reads the result before
      it resolves. *Owner: windows-chrome agent.*

## Owed by the copilot UI pass (2026-08-17)

- [ ] **The copilot session is not launched with `--mcp-config`, so the copilot
      itself cannot reach its own tools.** `deck-control` is wired at boot now
      and is genuinely live — proven end to end against the running app: a real
      MCP `tools/call` over the loopback socket raised a real confirmation, the
      dialog blocked it, Refuse came back as
      `settings.write was not approved` with the preferences unchanged, and
      Allow wrote the change after taking a last-good snapshot. `index.ts`
      writes `<userData>/copilot/deck-control.json` on every start and
      `mcpConfigFor` produces exactly the file the CLI wants.

      What is missing is the last link: `copilot-session.ts` calls
      `startSession` with no way to add `--mcp-config <path> --strict-mcp-config`
      to the spawn, because `CreateSessionInput` has no argv field — and it must
      not grow one, since that object crosses the preload bridge from the
      renderer and an argv field on it would let page code inject CLI flags.
      The shape that works is a fourth argument on `startSession` (main-process
      callers only), appended to `wanted` in `host-core.ts` just before
      `confineSpawn`. `deckControl.configPath` is already returned from
      `registerDeckControlIpc` and is what has to be passed. *Owner: whoever
      holds `host-core.ts` — not taken here because that file is core and was
      being edited concurrently.*

      Until it lands: everything in the copilot UI works and the copilot answers
      as an ordinary Claude session, but asking it *"which of my sessions is
      stuck"* gets a model with no `sessions.list` to call.

- [ ] **`src/main/remote/copilot-grants.ts` is still an orphan**, and
      deliberately: `COPILOT-DESIGN.md` phases remote copilot access last, as the
      highest-stakes surface in the product. It is listed here so nobody reads
      the `reachable.test.ts` failure as an accident. Wiring it is a decision to
      start phase 4, not a tidy-up.

## Found after wave 1 reported

- [x] **The Tailscale row.** Checked rather than trusted the wording of the
      report: `RemoteSection.tsx` has no `tailnet`/`Tailscale`/`direct`
      reference left, so the card he asked to remove is genuinely gone. What
      survived was the Settings **section blurb** — "Reach these sessions from a
      phone, over your own tailnet" — which named an optional extra as if it were
      the requirement, on a screen reached by people who have never heard of
      Tailscale. Rewritten to "Reach these sessions from a phone or another
      computer", which is also true of the merge.
- [ ] **`src/main/pty-manager.ts` — expose `IPty.process`.** The session-view
      agent drove a real pty to find the robust "is an agent running here"
      signal and found it: the process title goes `zsh` → `2.1.233` (Claude Code
      sets its title to its version) → `zsh` after `/exit`. It could not use it
      because `PtyManager` is outside its file set, so it fell back to reading
      the emulator viewport for banner text. The screen read works and is
      hysteresis-guarded, but the process title is the fact rather than the
      inference. One accessor. Nobody owns this file.
- [ ] **GitHub App registration — Asad only.** `github-app.ts` ships with
      `GITHUB_APP = { clientId: null, slug: null }` and is deliberately inert.
      Per-repository choice is impossible without a real registration, because
      OAuth apps have no per-repo scope — this is a GitHub platform limit, not a
      shortcut taken here. Steps for him are in that agent's report.

## Held out of the push

- [ ] **`.github/workflows/release.yml`** — committed nowhere, sitting in the
      working tree. GitHub refuses a workflow file pushed by a token without the
      `workflow` scope, and no account here has it (checked live against the API:
      `admin:public_key, gist, read:org, repo`). One command grants it:
      `gh auth refresh -h github.com -s workflow`, approved for **asadev** —
      which `gh` still labels `imzapremium`, its pre-rename name.

      Two things ride on that file, and both fail *quietly* without it:
      - the macOS signing step, so a tag would build an unsigned dmg again and
        every download would say the app "is damaged";
      - the step that compiles `tdconfine.exe`, without which
        `extraResources: native/win-confine/tdconfine.exe` matches nothing, the
        installer ships no launcher, and electron-builder says nothing at all.
        Confinement then reports itself unavailable — honestly, but forever.

      The repo variable `TD_MAC_SIGNED_ONLY=true` is already set, so the signing
      step will produce a signed-but-not-notarized build while Apple's hold
      lasts, and flip back by changing that variable alone.

## Found by Asad testing the local build — both confirmed in code

- [ ] **Nothing can be dragged into the tab strip.** The strip renders and accepts
      drops; the sidebar was never made a drag *source*. `Sidebar.tsx` has no
      `draggable` and never calls `startTabDrag` — confirmed by grep, so this is
      unfinished wiring rather than a bug. The contract it must use is already
      written and tested in `shell/workspace-tabs.ts` (`TAB_DRAG_MIME`,
      `startTabDrag`), and the strip's drop side is done. Three lines, blocked
      only because `Sidebar.tsx` was owned by another agent at the time — and
      then not closed, which is why he found it.

- [ ] **Remote belongs in the sidebar, where Machines was — not inside Settings.**
      His words: *"the remote page I asked you to keep it in the side panel, same
      as machines we had before, at the same placement — I want remote, not
      inside that settings."*

      This is a decision of mine that was wrong, not a missed instruction. He
      asked for Machines and Remote to be *one* thing; I merged them into
      Settings → Remote and deleted the rail entry. But pairing a device is
      something you **do**, not something you configure once — which is why
      Machines was in the rail to begin with. `remote` is not in `panels.ts` at
      all today.

      The move: add `remote` to `PanelId` and `PANELS` (in the `foot` group,
      where `machines` sat, beside Alerts), render it from `PanelView.tsx`, and
      leave Settings → Remote as the *settings* about remote access if anything
      genuinely settings-shaped remains — the pairing UI, device list and machine
      sessions go to the panel. One live pairing code is minted by one desk in
      the main process, so exactly one screen may show it: whichever surface
      keeps the code, the other must not mint a second.

## Coupling to preserve, not a task

- `src/renderer/dashboard/useBoard.ts` imports `useTranscriptChanges` from
  `../chat/usage/useUsage` deliberately: the `cost:watch` refcount lives there,
  and a second tally over that channel would let one unmount kill the other
  subscriber's watcher. If that module moves, this import follows it.
