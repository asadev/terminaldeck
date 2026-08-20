# 0.2.0 — testing every feature, on real hardware

Asad: *"once everything is done then do a proper testing of every single thing,
every single feature, all of it should be properly working."*

So this is the checklist, and it is written to be executed rather than admired.
Two rules govern it, both learned the hard way in this project:

- **Rendered and looked at, or it is not tested.** Reading the code and
  concluding the UI is fine has been wrong here before. Every UI line below ends
  in a screenshot of the real app.
- **On the machine it ships to, not the one it was built on.** A dozen bugs this
  week existed only on a clean Windows box. His PC is `DESKTOP-DDGMNCV`,
  reachable over `ssh imza-pc`, and Terminal Deck is installed and running on it
  now — so 0.2.0 reaches it as a real self-update, the way a stranger would get
  it.

Anything that cannot be tested gets written down as untested. Nothing gets
reported as working because it looks like it should.

---

## 0. Gates before anything is installed anywhere

- [ ] `npm run typecheck` clean
- [ ] `npm test` — full suite green, with the count recorded (it was 5,088)
- [ ] No test weakened to make it pass. Any assertion that changed, changed
      because the intended behaviour changed, and the diff says which.
- [ ] The four pairing invariants still hold and are still pinned: a code dies at
      60s, is single-use, five wrong guesses kill it, and redeeming one only
      creates a device a human must approve.

## 1. macOS — the app itself

Build, launch, and drive it. Screenshot each screen; look at the whole frame,
then zoom the region that changed.

- [ ] **Window chrome** unchanged and still correct (traffic lights inside our
      own header — this is the platform the Windows work must not have broken)
- [ ] **Overview** is the new live session board: a real running session appears,
      shows what it is doing, marks *waiting for you* when it stops, and clicking
      it opens that session. Nothing on it is a decorative progress bar.
- [ ] Git widget on Overview shows a written sentence, not `fatal: not a git
      repository...`
- [ ] **Files** opens with the tree populated and a file already shown
- [ ] **Artifacts** replaces Search in the sidebar, and lists real things
- [ ] **Source control** shows a repo's actual state
- [ ] **GitHub**: connect, and afterwards see the account, the repositories that
      were shared, and this folder's repo and branch. Check what the consent
      screen asks for — it must no longer be "full control of private
      repositories"
- [ ] **Remote** is one section. Machines is gone as a separate entry and nothing
      it could do was lost
- [ ] No "Direct on your tailnet" card anywhere
- [ ] Settings pages read short. No paragraph where a line does
- [ ] Two dropdowns cannot be open at once
- [ ] A session's name can be renamed
- [ ] A plain shell session shows **Run Claude** and no chat/account controls;
      pressing it starts Claude; the chat toggle and account picker then appear
- [ ] An account can be renamed from inside the session dropdown
- [ ] Chat view and terminal view show **the same conversation** — the one real
      bug on the old list. Reproduce the old failure deliberately before trusting
      the fix
- [ ] Nothing is appended after the last chat message
- [ ] Adding an account asks **which provider**, and signs into that one
- [ ] The session dropdown shows the provider's logo next to the account
- [ ] Asking for a `shell` session gives a shell, not Claude
- [ ] Built-in browser: a new tab opens on a start page listing live localhost
      ports, not a red error; popups and the session flyout render **in front**
      of page content; an empty page is dark in dark mode; the top tab strip
      works and things can be dragged between it and the side panel
- [ ] Power: a remote session survives the lid closing and does not drop after a
      few seconds
- [ ] Quit and reopen — sessions come back

## 2. Windows — on `DESKTOP-DDGMNCV`, as a self-update

This is the platform he is blocked on and the one 0.2.0 is really for.

- [ ] The update is offered in-app and installs
- [ ] **One title bar.** Not three. Native minimise/maximise/close in the
      top-right where Windows puts them; no File/Edit/View strip
- [ ] The window can be dragged by its header, and every control in that header
      still clicks
- [ ] Every keyboard shortcut the old menu provided still works — **Ctrl+C in a
      terminal above all**
- [ ] A WSL session starts in a `/home/...` folder and runs
- [ ] "Pick up where you left off" works here, not just on the Mac
- [ ] Pairing by six digits, both directions
- [ ] GitHub connect
- [ ] Confinement: whatever the honest answer is, the app states it correctly —
      and if it claims a boundary, the boundary is proved on this machine

## 3. The clients

**Web (`app.terminaldeck.dev`)** — from a desktop browser, paired to the Windows PC:
- [ ] Full width, not a narrow column
- [ ] No on-screen ESC/Tab key bar where there is a real keyboard
- [ ] The "Start in" folder list has **no duplicates** (it listed every folder
      twice)
- [ ] localhost as well as terminals
- [ ] A terminal session actually runs, types, and reconnects

**iOS** — simulator first, then his real phone via TestFlight:
- [ ] A real tab bar / pill navigation, not the current bare list
- [ ] Six-digit pairing, numeric keypad, auto-submit on the sixth digit
- [ ] **One finger scrolls** the terminal; it does not select. Selection is
      long-press and drag
- [ ] The connection chip stays silent for the first five seconds and on drops
      shorter than five seconds; it appears only when a drop outlasts that
- [ ] No pairing link and no QR anywhere

**Android**:
- [ ] Six-digit pairing and a working session

## 4. The seams — where this project's bugs actually live

Sections passing individually has never been sufficient here.

- [ ] Mac ↔ Windows pairing, both directions
- [ ] Phone → Mac and phone → Windows, over the relay, on a different network
- [ ] A session started on the desktop is visible and usable from the phone
- [ ] Kill the network mid-session and bring it back
- [ ] Quit the desktop app while a phone is attached — the phone must say
      something true
- [ ] Two devices paired at once
- [ ] Every page visited in one pass, looking at spacing and transitions between
      them, not only at each page alone

## 5. Release

- [ ] Version bumped, CHANGELOG written
- [ ] Tag pushed, CI green on both runners
- [ ] Windows installer downloaded **from the release page** and installed on a
      machine that has never had it
- [ ] macOS: signed; and while notarization is refused at Apple, the release
      notes say so and give the System Settings → Privacy & Security →
      Open Anyway step (NOT right-click → Open, removed in macOS 15)
- [ ] The in-app updater offers it to the running copy on his PC
