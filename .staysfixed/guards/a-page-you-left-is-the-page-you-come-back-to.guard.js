/**
 * "If this link is loaded, page is loaded, I go to session. If I come back, this is all
 * gone, so it refreshes."
 */
export default {
  name: 'leaving a page or a session and coming back finds it exactly where it was left',

  fixed: '2026-08-26',

  because:
    'Switching away unmounted the view holding the page instead of hiding it, so coming back mounted a new one and the '
    + 'site loaded again from scratch — scroll position, half-typed form, anything signed into, gone. The same shape hit '
    + 'the terminals from the other end: leaving a session on a paired machine detached from that machine, so coming '
    + 'back re-attached and the whole afternoon’s scrollback was sent again and *watched* scrolling past. He filmed the '
    + 'browser half on 2026-08-20 — *"if I go to session and come back, it will be always clean"* — and reported the '
    + 'identical thing on the phone six days later: *"coming back it refreshing the page every time I am coming, it '
    + 'should stay as it is."* Three separate mechanisms hold it up now, in three different files, and a new pane in '
    + 'this window is mounted by whoever adds it — which is how every one of these arrived in the first place.',

  link: 'review-2026-08-20 S3, review-2026-08-26-evening D2; asks-audit-2026-08-28 BRO-034, IOS-039, DES-092',

  async run({ expect, page, project }) {
    const path = await import('node:path');
    const fsp = await import('node:fs/promises');
    const { pathToFileURL } = await import('node:url');

    /**
     * A reading off the window, or nothing at all — never a throw.
     *
     * A guard that explodes on an unexpected answer stops at the line it exploded on, and
     * everything it had not asked yet goes unasked: the phone half of this one is last. So a
     * read that comes back wrong fails a named check instead.
     *
     * @param {string} said
     * @param {unknown} whenUnreadable
     */
    const parsed = (said, whenUnreadable) => {
      try {
        return JSON.parse(said);
      } catch {
        return whenUnreadable;
      }
    };

    /**
     * Every rule in the running app that hides a pane while it is not in front.
     *
     * Read out of the stylesheets the app has actually loaded rather than out of the source,
     * because what ships is one bundle: a rule deleted from one sheet while a component still
     * writes the attribute is only visible in the build, and the build is what a person opens.
     */
    const hiders = parsed(String(await page.evaluate(
      '(()=>{const found={};for(const sheet of document.styleSheets){let rules;'
      + 'try{rules=sheet.cssRules}catch(e){continue}'
      + 'for(const rule of rules){const sel=(rule.selectorText||"").trim();'
      + 'if(!/\\[data-visible=.false.\\]/.test(sel))continue;'
      + 'found[sel.replace(/\\[data-visible=.false.\\]/,"")]=rule.style.display}}'
      + 'return JSON.stringify(found)})()',
    )), {});

    await expect('every surface that has to outlive a trip away is hidden rather than unmounted', async () => {
      /*
       * Five families, one arrangement, and each of them is here because unmounting it costs
       * something different: a browser page is a native view the main process CLOSES on
       * unmount; a session on a paired machine is a detach and a replay off another computer;
       * a shell on a server is an SSH channel with nothing anywhere keeping what it printed;
       * a local terminal is a redraw from the main process's scrollback; the copilot is a
       * login somebody may be halfway through.
       *
       * The rules are the right place to ask. They are what goes with the arrangement — when
       * a pane is put back inside the view that draws one thing, its `[data-visible]` rule is
       * the first thing deleted, because nothing sets the attribute any more.
       */
      const families = ['.bw', '.terminal-host', '.remote-pane', '.server-pane', '.copilot-page'];
      return families.every((name) => hiders[name] === 'none');
    });

    /**
     * The module that decides what a terminal shows while it is being filled in, loaded and
     * RUN rather than read.
     *
     * It has no imports at all, which is why Node can take it straight off the tree. Running
     * it is the only honest way to ask this: the rule is an ORDER — scrolled to the bottom
     * first, then shown — and reading the source for the two calls would pass on a build that
     * had swapped them, which is exactly the bug he filmed ("it will start from the beginning
     * and scroll the full page").
     */
    const backfill = await import(
      pathToFileURL(path.join(project.paths.root, 'src/renderer/components/terminal-backfill.ts')).href
    );

    /** A terminal and its element, reduced to what this module touches, with a diary. */
    const fake = () => {
      /** @type {string[]} */
      const events = [];
      let written = '';
      const surface = {
        style: {
          _opacity: '',
          get opacity() { return this._opacity; },
          set opacity(value) { this._opacity = value; events.push(`opacity=${value === '' ? 'shown' : value}`); },
        },
      };
      const term = {
        write(data, done) {
          written += data;
          events.push('write');
          // xterm calls this back when it has PARSED the bytes, not when it has queued them,
          // and the whole file exists because those are seconds apart on a real backlog.
          if (done) done();
        },
        scrollToBottom() { events.push('scrollToBottom'); },
      };
      return { term, surface, events, read: () => written };
    };

    await expect('a terminal being filled in is held blank while the backlog arrives', async () => {
      // The held chunks must not reach the terminal one at a time — that is the scrolling
      // history, and it is what he was watching.
      const one = fake();
      const hold = backfill.holdUntilFilled(one.term, one.surface);
      hold.push('an hour of output ');
      hold.push('and the last line');
      const heldBlank = one.surface.style.opacity === '0' && one.read() === '';
      hold.stop();
      return heldBlank;
    });

    await expect('and it is shown once, already scrolled to the bottom rather than scrolling there', async () => {
      // The order is the assertion. `scrollToBottom` after the reveal is the same picture the
      // fix removed — the viewport travelling down the backlog in front of somebody — and it
      // reads as an innocent pair of lines in either order.
      const one = fake();
      const hold = backfill.holdUntilFilled(one.term, one.surface);
      hold.push('an hour of output ');
      hold.release('everything older than that ');
      hold.stop();
      const shown = one.events.indexOf('opacity=shown');
      const bottom = one.events.indexOf('scrollToBottom');
      return shown > 0 && bottom > 0 && bottom < shown
        // The older bytes first. A caller with a backlog holds the OLDER half, and the two
        // halves written the other way round would leave the session's history under its
        // latest output.
        && one.read() === 'everything older than that an hour of output ';
    });

    await expect('and the hold can only ever delay a terminal, never hide one', async () => {
      // The backstop, which is the reason this file is allowed to hide anything at all. A read
      // that never comes back would otherwise leave a permanently blank terminal — a worse bug
      // than the one being fixed, and one nobody would connect to a fix for scrolling.
      const one = fake();
      const hold = backfill.holdUntilFilled(one.term, one.surface, { limit: 20 });
      await page.wait(400);
      const revealed = one.surface.style.opacity === '';
      hold.stop();
      return revealed;
    });

    /**
     * What this window is holding right now: every page, with the address it is showing, and
     * every terminal. Read before anything is clicked.
     *
     * The address comes off the field rather than off a title, because the field is what he
     * was pointing at — *"if this link is loaded"* — and a title survives a remount that
     * threw the page away.
     */
    const holdings = async () => {
      const said = parsed(String(await page.evaluate(
        '(()=>{const pages=[...document.querySelectorAll(".bw")].map(el=>{'
        + 'const field=el.querySelector(".bw-address input");'
        + 'return String(field?field.value:"")});'
        + 'return JSON.stringify({pages,terminals:document.querySelectorAll(".terminal-host").length,'
        + 'active:(document.querySelector("[data-strip-tab][data-active]")||{getAttribute:()=>null})'
        + '.getAttribute("data-tab-id")})})()',
      )), null);
      // The shape is checked, not assumed. An answer that parses but is not this answer would
      // otherwise be read field by field and throw on the first missing one.
      return said !== null && Array.isArray(said.pages) && typeof said.terminals === 'number' ? said : null;
    };

    /*
     * A tab is put in the frame FIRST, and the order is not tidiness.
     *
     * Guards share one running app and read whatever the guard before them left on screen. If
     * that is a sidebar view, a build with the bug in it has already thrown every page away —
     * so the reading below would find nothing, find nothing again after the trip, and report
     * green having watched the defect happen. Selecting a tab that is already open clears the
     * view and puts a real one in the frame, which is the state every build mounts its pages
     * in. Nothing is opened, nothing is closed: this is a row that was already there.
     */
    await page.evaluate(
      "(()=>{const row=document.querySelector('.sb-row.sb-open .sb-row-main');"
      + 'if(row)row.click();return Boolean(row)})()',
    );
    await page.wait(600);
    const before = await holdings();

    /*
     * The trip he filmed, and the only one of it a guard may take. Opening a sidebar view is a
     * navigation and changes nothing — no session is started, nothing is typed, nothing is
     * closed. Splitting the window, starting a swarm and opening a session on another machine
     * are the other triggers and all three are changes to the product; they are covered by the
     * mount site, which is `a-page-outlives-whatever-takes-the-frame`.
     */
    const wentToFiles = Boolean(await page.evaluate(
      "(()=>{const b=[...document.querySelectorAll('button.sb-nav')]"
      + ".find(e=>((e.querySelector('.sb-label')||{}).textContent||'').trim()==='Files');"
      + 'if(b)b.click();return Boolean(b)})()',
    ));
    await page.wait(700);
    const away = await holdings();

    // Back to whatever was in front, so the guard after this one reads the window it would
    // have read anyway. Nothing is opened and nothing is closed: this is the same tab.
    if (before !== null && before.active) {
      await page.evaluate(
        '(()=>{const t=document.querySelector('
        + JSON.stringify(`[data-strip-tab][data-tab-id="${String(before.active).replace(/"/g, '\\"')}"]`)
        + ');if(t)t.click();return Boolean(t)})()',
      );
      await page.wait(500);
    }
    const back = await holdings();

    await expect('the sidebar view really did take the frame, so the trip was a trip', async () => {
      // Without this the three comparisons below are three readings of one unchanged window,
      // which would pass for ever while checking nothing — and a window that cannot say what
      // it is holding is a window none of them can be asked of.
      return wentToFiles && before !== null && away !== null && back !== null;
    });

    if (before !== null && away !== null && back !== null && before.pages.length > 0) {
      await expect('every page still exists while a sidebar view has the frame', async () => {
        // The defect exactly: `mainView` drew Files, and every `BrowserWorkspace` in the window
        // was unmounted with the branch that used to hold them — which closes the native view
        // in the main process for real.
        return away.pages.length === before.pages.length;
      });

      await expect('and every one of them is still on the address it was on', async () => {
        // A page that came back blank had a mount and an empty address bar, which is the state
        // a fresh `WebContentsView` is in. Compared in order: the strip's order does not move
        // for a navigation.
        return away.pages.every((url, at) => url === before.pages[at])
          && back.pages.every((url, at) => url === before.pages[at]);
      });
    }

    if (before !== null && away !== null && back !== null && before.terminals > 0) {
      await expect('every terminal is still mounted too, whichever page has the frame', async () => {
        // The other half of the same sentence, and the one that costs a round trip to another
        // computer when it breaks. A terminal that survives the trip has nothing to replay.
        return away.terminals === before.terminals && back.terminals === before.terminals;
      });
    }

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter here. Every rule below is written down in prose directly above the
     * line that implements it — his own words, in the source — so a plain search for the rule
     * finds the paragraph explaining it and passes on a client that stopped obeying it. Three
     * iOS tests on this project have already failed on their own comments, from the other
     * direction.
     *
     * @param {string} rel
     */
    const code = async (rel) => {
      const raw = await fsp.readFile(path.join(project.paths.root, rel), 'utf8');
      return raw
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/^[ \t]*\/\/.*$/gm, ' ')
        .replace(/\s+/g, ' ');
    };

    await expect('the phone does not let go the moment a screen goes, and lets go half a minute later', async () => {
      // The phone cannot hide a terminal the way the desktop does — the screen is genuinely
      // gone — so its version of "it never went away" is a delay: the detach is deferred, and
      // the number is the length of an ordinary glance at another session. Both halves are
      // asked for, because a grace with no timer behind it is a leak and a timer with no grace
      // is the bug.
      const swift = await code('ios/TerminalDeck/App/HostLink.swift');
      return /static let leaveGrace: TimeInterval = 30\b/.test(swift)
        && /leaving\[id\] = Task \{[^{}]*Task\.sleep\(for: \.seconds\(Self\.leaveGrace\)\)/.test(swift);
    });

    await expect('and coming straight back on the phone costs nothing at all', async () => {
      // The load-bearing line of the phone half: cancelling the pending detach is the FIRST
      // thing an appearing screen does, so the detach never left, so there is no attach to
      // answer, no `attached` frame, no reset and no replay. Cancelling it later in the
      // function would still send the wipe.
      const swift = await code('ios/TerminalDeck/App/HostLink.swift');
      return /func attach\(_ id: String\) \{ leaving\.removeValue\(forKey: id\)\?\.cancel\(\)/.test(swift);
    });

    /*
     * WHAT THIS GUARD CANNOT REACH, said here rather than left to be assumed.
     *
     * The write-up asks for a page scrolled and typed into, left and returned to, with no
     * fresh network request for it. Every one of those is a change to a page somebody has
     * open — typing into a stranger's form, scrolling their reading, reloading their site —
     * and a guard that does any of it has changed the thing it is watching. So what is
     * measured is the arrangement that makes all of it true: the mount survives, the address
     * survives, the hold reveals at the bottom.
     *
     * The phone leg is a phone. Both halves above are a reading of the iOS client's rules, and
     * a rule that reads correctly and behaves otherwise is exactly the shape this bug arrived
     * in twice — the desktop was fixed on 2026-08-20 and the identical report came back off a
     * phone on 2026-08-26. Watching it needs the app on a device, leaving a session and coming
     * back inside thirty seconds.
     */
  },
};
