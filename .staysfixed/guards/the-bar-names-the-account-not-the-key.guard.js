/**
 * *"It is saying default, so never default."* Said at 11:30 into the recording,
 * still on screen at 24:00 of the same recording.
 */
export default {
  name: 'the account on a session bar is the login that is signed in, and is never the word Default',

  fixed: '2026-08-21',

  because:
    'The account shown for a session on one of his own machines came off a wire message carrying an id, a name and a '
    + 'colour — no address, no sign-in state — so the chip had nothing to print but the name, and for the machine\'s own '
    + 'install that name is the key `systemProfileId` mints: `Default`, `Default (Codex CLI)`, `Default (Gemini CLI)`. '
    + 'It is a statement about precedence, not about whose account it is, and it landed on the one control whose entire '
    + 'job is saying which login a session is running as — while the agent\'s own welcome banner three lines below named '
    + 'the real person. *"Whatever is actual account should be visible here, never default."* Underneath that, four '
    + 'surfaces resolved the account by four different routes — the top bar, the chip after a switch, the usage bar, and '
    + 'the limit message the agent prints itself under whatever config directory it was launched with — so they could '
    + 'disagree at the same moment: *"all of them are not about one logged in account… they should be all aligned."* '
    + 'The repair is one ladder, in one file, with no rung that prints a generated name and no rung that invents an '
    + 'address — plus a wire that finally carries the fact. It came back twice inside one recording.',

  link: 'review-2026-08-21 T34 and T72; mine-workdir/days/2026-08-21.md line 225',

  async run({ expect, page, read, project, cannotRunHere }) {
    /**
     * The naming ladder, the wire it is fed by, and the usage bar's own reader —
     * loaded and driven rather than read.
     *
     * Every function here is pure: `accounts.ts` is the rules the window draws
     * from, `machine-account.ts` is the reader that turns a frame into a row,
     * and `protocol.ts` is the wire itself. Bundled in memory and imported as a
     * data URL, so nothing is written to disk, no machine is asked anything, and
     * no account's CLI is spawned.
     */
    const ladder = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents:
              "export { accountIdentity, profileLoginLabel, accountRail } from './src/renderer/accounts'\n"
              + "export { readAccount, signInOf } from './src/renderer/machines/machine-account'\n"
              + "export { reportedAccount } from './src/renderer/shell/usage-bar-model'\n"
              + "export { serialize, parseServerMessage } from './src/main/remote/protocol'\n",
            resolveDir: project.paths.root,
            loader: 'ts',
          },
          bundle: true,
          format: 'esm',
          platform: 'node',
          write: false,
          logLevel: 'silent',
        });
        const bytes = Buffer.from(built.outputFiles[0].text).toString('base64');
        return await import(`data:text/javascript;base64,${bytes}`);
      } catch {
        // Null rather than a throw, so the claim below fails as its own sentence
        // rather than as a stack trace nobody reads.
        return null;
      }
    })();

    await expect('the naming ladder and the wire under it could really be loaded and asked', async () => {
      // Everything after this asserts what a function answered, and an assertion
      // against a module that did not load is the one failure this whole tool
      // exists to prevent.
      return ladder !== null
        && typeof ladder.accountIdentity === 'function'
        && typeof ladder.readAccount === 'function'
        && typeof ladder.parseServerMessage === 'function';
    });

    /** The three keys `systemProfileId` mints, which are what he filmed. */
    const KEYS = ['Default', 'Default (Codex CLI)', 'Default (Gemini CLI)'];

    /* ─────────────────────────────────── the fact the wire never used to carry -- */

    /** One `account.state` frame, as a machine sends it. @param {unknown} current */
    const overTheWire = (current) => {
      const said = ladder.parseServerMessage(
        ladder.serialize({ t: 'account.state', rid: 'r1', id: 's1', current, accounts: [] }),
      );
      return said.ok === true ? said.message.current : null;
    };

    await expect('a machine can now say which login a session is running as, and the address survives the trip', async () => {
      // The root cause in one line. The note where a remote chip should have been
      // said, correctly at the time, that *"which account an agent on another
      // machine was spawned under is not a fact any frame on the wire carries"*.
      // Until it did, the chip could not have told the truth even if it had
      // wanted to.
      const row = overTheWire({
        id: 'system', name: 'Default', provider: 'claude', color: null, system: true,
        signIn: { state: 'signed-in', account: 'asad@example.com', plan: 'max', detail: 'Signed in as asad@example.com' },
      });
      return row !== null && row.signIn?.state === 'signed-in' && row.signIn?.account === 'asad@example.com';
    });

    await expect('and a machine that says nothing arrives as nothing, never as a composed answer', async () => {
      // *That build does not report this* and *that machine could not tell* are
      // two different facts with two different remedies, and only one of them is
      // fixed by logging in again. Inventing the second from the first is how a
      // build that reports nothing comes to look like a login nobody can read.
      const row = overTheWire({ id: 'system', name: 'Default', provider: 'claude', color: null, system: true });
      return row !== null && row.signIn === undefined && ladder.readAccount(row).signIn === null;
    });

    /* ─────────────────────────────── wire to chip, the whole way across -- */

    /** The chip's label for a row exactly as it came off a frame. @param {unknown} current */
    const chip = (current) => {
      const row = ladder.readAccount(overTheWire(current));
      return ladder.accountIdentity(row, ladder.signInOf(row));
    };

    await expect('a signed-in login is drawn as its address, and marked as a fact rather than a state', async () => {
      // The ask, end to end: the frame, the reader, the ladder, the label. And
      // `verified` is what lets the chip draw it as an identity — nothing here
      // ever sets it for a string this app composed.
      const said = chip({
        id: 'system', name: 'Default', provider: 'claude', system: true,
        signIn: { state: 'signed-in', account: 'asad@example.com', plan: 'max', detail: 'Signed in as asad@example.com' },
      });
      return said.label === 'asad@example.com' && said.verified === true;
    });

    await expect('the machine\'s own install is never called by the key, in any of the four states it can be in', async () => {
      // Four states, because each one used to reach the chip by its own route and
      // three of them are indistinguishable from "not read yet" unless they are
      // named. `unknown` is a machine whose build predates the sign-in field —
      // which is every machine that ever had this bug — and it is the state that
      // must fall to a sentence rather than to the slug.
      const rows = [
        { id: 'system', name: 'Default', provider: 'claude', system: true },
        { id: 'system', name: 'Default', provider: 'claude', system: true, signIn: { state: 'signed-out', detail: 'Not signed in.' } },
        { id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex', system: true, signIn: { state: 'signed-in', account: null, plan: 'ChatGPT', detail: 'Logged in using ChatGPT.' } },
        { id: 'system:gemini', name: 'Default (Gemini CLI)', provider: 'gemini', system: true, signIn: { state: 'unknown', detail: 'Could not be read.' } },
      ];
      return rows.every((row) => {
        const said = chip(row);
        return said.label.trim() !== '' && KEYS.includes(said.label) === false;
      });
    });

    await expect('and the shape of the id alone is enough to refuse it, before any list has arrived', async () => {
      /*
       * The second rung of "is this name generated", and it covers most of a
       * session's first second: the chip is drawn before the account list lands,
       * so for that moment the id is the only thing saying which kind of name
       * this is. `system`, `system:codex`, `system:gemini` are minted by
       * `profiles.ts` for the installs and never for an account anybody added.
       *
       * FOUND WHILE WRITING THIS AND DELIBERATELY NOT FIXED — Terminal Deck is
       * the thing being watched here, not the thing being repaired. The rung is
       * reached with `??`, so it only fires while the flag is *absent*. A row
       * that has been through `readAccount` never is: that reader spells it
       * `value.system === true`, so a far machine whose build predates
       * `AccountWire.system` decodes to an explicit `false`, and the chip prints
       * `Default (Gemini CLI)` again — the filmed defect, reachable today from
       * an older paired machine. The phone does not have the hole: its
       * `isGeneratedAccount` is `account.system || isGeneratedAccountId(...)`,
       * an `or` rather than a fallback, and its comment says in as many words
       * that trusting the flag alone would print the slug he filmed. This claim
       * is written against the rung as it stands, so it holds today and reports
       * the day the rung itself goes.
       */
      const said = ladder.accountIdentity(
        { id: 'system:gemini', name: 'Default (Gemini CLI)' },
        { state: 'unknown', account: null, plan: null, detail: 'Could not be read.', command: '' },
      );
      return KEYS.includes(said.label) === false;
    });

    await expect('a name a person actually chose is printed, which is the whole reason the rung exists', async () => {
      // The other direction, and it is not a formality: a ladder that suppressed
      // every name would have "fixed" the complaint by telling him nothing at
      // all about the account he named himself.
      const said = chip({ id: 'p1', name: 'Client work', provider: 'claude', system: false });
      return said.label === 'Client work';
    });

    await expect('an expired login does not keep printing the address it used to have', async () => {
      // `claude auth status --json` answers `{"loggedIn": false, "email": "…"}`
      // for a login that has expired, so the address outlives the session it
      // belonged to. Printed on the chip it says a session is running as an
      // account that cannot start one — worse than the key, because it is
      // confidently wrong rather than merely useless.
      const said = chip({
        id: 'p1', name: 'Client work', provider: 'claude', system: false,
        signIn: { state: 'signed-out', account: 'old@example.com', plan: null, detail: 'That login has expired.' },
      });
      return said.label.includes('old@example.com') === false && said.verified === false;
    });

    await expect('the rows of the menu underneath it climb the same ladder', async () => {
      // The defect he filmed *after* the chip was fixed: the chip printed the
      // address and the sheet one line below it still listed three rows called
      // Default. One rule, two entry points — a list needs a caption that tells
      // rows apart rather than a state two of them share.
      const signedIn = { state: 'signed-in', account: 'asad@example.com', plan: 'max', detail: 'd', command: '' };
      return ladder.profileLoginLabel({ id: 'system', name: 'Default', provider: 'claude', system: true }, signedIn) === 'asad@example.com'
        && KEYS.includes(ladder.profileLoginLabel({ id: 'system', name: 'Default', provider: 'claude', system: true }, undefined)) === false
        && ladder.profileLoginLabel({ id: 'p1', name: 'Client work', provider: 'claude', system: false }, undefined) === 'Client work';
    });

    await expect('the rail beside it says the address only where a hover asks for it', async () => {
      // *"in our old versions it was showing emails. Now it's not showing, which
      // is good. Make sure we will not show them again."* A hover is a thing you
      // ask for; a row is a thing you are shown. Both halves come off one rung so
      // the caption and the sentence can never describe different logins — and
      // the caption for an install is nothing, never the key.
      const rail = ladder.accountRail(
        { id: 'system', name: 'Default', provider: 'claude', system: true },
        { state: 'signed-in', account: 'asad@example.com', plan: 'max', detail: 'd', command: '' },
      );
      return rail.short === null && String(rail.note).includes('asad@example.com');
    });

    /* ───────────────────────── the usage bar, which is the surface that disagreed -- */

    await expect('the usage bar names the account the reading it is drawing came from', async () => {
      // His second sentence, and the harder half: *"usage limit bar and sometimes
      // a popup about a limit… they are talking about different account."* The
      // bar takes the account off the **reading**, so the figure and the name
      // beside it are one answer rather than two questions asked of two places.
      const said = ladder.reportedAccount({
        account: { id: 'p2', name: 'Work' },
        readings: [{ id: 'five-hour', account: { id: 'p3', name: 'Other' } }],
      });
      return said?.id === 'p3';
    });

    await expect('and a reading that names nobody leaves the bar silent rather than half-named', async () => {
      // The state the bar is in most of the time. An empty label is drawn as an
      // empty element and joined into a hover reading "Claude Code · " with
      // nothing after the separator, which is the half-answer this was moved here
      // to stop giving.
      return ladder.reportedAccount(null) === null
        && ladder.reportedAccount({ account: { id: null, name: null }, readings: [] }) === null;
    });

    /* ───────────────────────────────── four surfaces, one ladder, no second copy -- */

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Every one of these files argues about the word "Default" at length — the
     * chip's header quotes him on it — so a plain search finds the paragraph
     * explaining the fix and reads it as the fix being broken. Three tests on
     * this project have already failed exactly that way, on their own comments.
     *
     * @param {string} rel
     */
    const code = async (rel) => String(await read(rel))
      .replace(/\/\*[\s\S]*?\*\//g, ' ')
      .replace(/^[ \t]*\/\/.*$/gm, ' ')
      .replace(/\s+/g, ' ');

    /** The four screens that name an account, and the rung each one is entitled to. */
    const surfaces = [
      { file: 'src/renderer/shell/AccountChip.tsx', rung: /accountIdentity\(/, floor: 6000 },
      { file: 'src/renderer/machines/MachineAccountChip.tsx', rung: /accountIdentity\(/, floor: 1500 },
      { file: 'src/renderer/shell/UsageBar.tsx', rung: /accountIdentity\(/, floor: 6000 },
      { file: 'src/renderer/shell/Sidebar.tsx', rung: /accountRail\(/, floor: 8000 },
    ];
    const read4 = await Promise.all(surfaces.map(async (s) => ({ ...s, code: await code(s.file) })));

    await expect('all four screens that name an account were really read', async () => {
      // The hole the two claims below cannot notice about themselves: a file that
      // moved reads as a short string, and a short string calls no ladder and
      // contains no slug.
      return read4.every((s) => s.code.length > s.floor);
    });

    await expect('every one of them asks the same file what a login is called', async () => {
      // Four surfaces, four routes, one moment where they disagreed — that is
      // the complaint. A screen that resolves the account for itself is a fifth
      // route, and it will be right until the day it is not.
      return read4.every((s) => s.rung.test(s.code));
    });

    await expect('and not one of them can compose the word itself', async () => {
      // The strongest form of the claim available without a paired machine: the
      // key is not a string any of these four files holds, so none of them can
      // print it however the ladder is fed. Asked of `accounts.ts` too — the
      // ladder must not be able to fall back to it either.
      const spelt = /['"`]Default/;
      const rules = await code('src/renderer/accounts.ts');
      return read4.every((s) => spelt.test(s.code) === false) && spelt.test(rules) === false;
    });

    /* ─────────────────────────────────────────── and the phone's copy of it -- */

    const swift = String(await read('ios/TerminalDeck/Protocol/AccountNaming.swift'))
      .replace(/\/\*[\s\S]*?\*\//g, ' ')
      .replace(/(^|[^:])\/\/[^\n]*/g, '$1')
      .replace(/\s+/g, ' ');

    await expect('the phone names a login by the same three rungs, and cannot say the key either', async () => {
      // He filmed this on the phone too, five days later, with the same word on
      // the same kind of sheet. The phone and the desktop are fed by one machine
      // and the one thing that must never happen is the two of them naming one
      // login differently — so this is a port of `profileLoginLabel`, and the
      // rung that must never be copied wrong is the first: gated on the sign-in
      // *state*, not on an address being present, because an expired login still
      // carries one.
      return swift.length > 800
        && /signIn\.state == WireSignIn\.signedIn/.test(swift)
        && /isGeneratedAccount\(account\)/.test(swift)
        && /['"`]Default/.test(swift) === false;
    });

    /* ────────────────────────────────────────── asked of the running app -- */

    await expect('the engine still marks its own install as its own, which the whole ladder turns on', async () => {
      // The rung that decides "generated or chosen" reads this flag first, and
      // the id only has to carry it in the first second of a session. Drop it
      // from the snapshot and every surface above starts reading `Default` as a
      // name somebody typed — the entire defect, restored, from one field.
      const said = String(await page.evaluate(
        "(async()=>{try{const s=await window.deck.listProfiles();"
        + "const rows=(s&&Array.isArray(s.profiles))?s.profiles:null;if(rows===null)return 'NO LIST';"
        + "const own=rows.filter(r=>r&&(r.id==='system'||String(r.id||'').startsWith('system:')));"
        + "if(own.length===0)return 'NO OWN INSTALL';"
        + "return own.every(r=>r.system===true)?'FLAGGED':'UNFLAGGED'}"
        + "catch(e){return 'REJECTED '+String(e&&e.message||e)}})()",
      ));
      return said === 'FLAGGED';
    });

    await expect('and the doors that carry a far machine\'s login are still on the bridge', async () => {
      // The chip over a remote session has exactly two roads: the account this
      // session is on, and the list to choose from. A missing name is rejected
      // silently, and the chip then draws itself back and explains — which is
      // indistinguishable from a machine that has no accounts.
      const missing = String(await page.evaluate(
        "['readMachineAccount','readMachineLogins','listProfiles','profileSignIn']"
        + ".filter(n=>typeof window.deck?.[n]!=='function').join(', ')",
      ));
      return missing === '';
    });

    /** What is on screen right now, and what this install can reach. */
    const here = JSON.parse(String(await page.evaluate(
      "(async()=>{const chips=[...document.querySelectorAll('.account-chip-name')]"
      + ".map(n=>(n.textContent||'').trim()).filter(t=>t!=='');"
      + "let machines=-1;try{const v=await window.deck.listMachines();"
      + "machines=((v&&v.machines)||[]).length}catch(e){machines=-1}"
      + "return JSON.stringify({chips,machines})})()",
    )));

    await expect('no account chip drawn in this window is printing the key', async () => {
      // Read off `.account-chip-name`, which is the element that carried the word
      // in his recording — the local chip and the remote one share it, because
      // they share the stylesheet on purpose. Zero chips is the ordinary state of
      // a window with no session in front, which is exactly why this claim is a
      // companion to the rules above and not the proof; see the note below.
      return here.chips.every((text) => KEYS.includes(text) === false);
    });

    // ── and here is what this guard cannot do, said out loud ──────────────
    //
    // The proof he would recognise is a photograph: a session running on one of
    // his own machines, the chip on its bar reading the same address the agent's
    // own welcome banner prints three lines below it, and the tooltip, the
    // dropdown and the usage bar all naming that same one. That needs a **paired
    // second machine with a real signed-in account**, and a guard may not pair a
    // machine or sign an account in to make one — that is the product changing
    // under the thing watching it.
    //
    // NOT PROVED rather than failed. What is proved above is the whole mechanism
    // underneath the photograph: the wire carries the login, the reader keeps it,
    // the ladder never falls to the key in any of its states, four surfaces climb
    // that one ladder and none of them can spell the word. What is missing is a
    // far end to say it about — and failing here would print "a bug that was
    // already fixed is back" about a chip nobody drew, on a defect he condemned
    // by name and found still uncorrected thirteen minutes later.
    if (here.machines <= 0 || here.chips.length === 0) {
      cannotRunHere(
        'this install has '
        + (here.machines <= 0 ? 'no machine paired' : `${here.machines} machine(s) paired`)
        + ' and '
        + (here.chips.length === 0 ? 'no account chip on screen' : `${here.chips.length} account chip(s) on screen`)
        + ', so the chip he filmed cannot be drawn here at all. Pair a machine, sign an account in on it and open a '
        + 'session on it from the machine running this check, and the on-screen half becomes answerable.',
      );
    }
  },
};
