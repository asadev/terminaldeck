/**
 * One bar, three phrases reading "This machine", each about a different
 * computer — *"I don't know what to trust."*
 */
export default {
  name: 'the browser bar carries exactly one machine label, and it names a machine',

  fixed: '2026-08-21',

  because:
    'He had asked for the bar to always tell the truth about where a page runs: *"we always need a truth. So we will '
    + 'not know the truth if we remove from inside where it is exactly running."* The fix for that added a mark inside '
    + 'the address field — and drew it when there was no page at all, so after choosing another machine the bar asserted '
    + 'two different machines at once, one of them about a page that did not exist: *"Why it is saying this machine? '
    + 'Since I click on Office PC, it is showing this machine still."* It vanished the moment a real page loaded, which '
    + 'is exactly why it survived: the bar is only wrong while there is nothing on it to check it against. Underneath '
    + 'that, three separate controls each invented their own phrase for the computer in front of him, and "This machine" '
    + 'ended up on one bar three times for three different computers — *"So it is showing both, selected one and this '
    + 'one. So I don\'t know what to trust."* The repair is a name everywhere and a mark only where there is a genuine '
    + 'disagreement to report. Six mentions in three days, over three separate reviews.',

  link: 'asks-audit-2026-08-28 BRO-037 / DES-109; review-2026-08-21 T56 and T57; review-2026-08-20 STILL-WRONG E13',

  async run({ expect, page, project, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /* ─────────────────────────────────────────────────────────────────────
       What this computer calls itself, asked of the engine.

       This is the root of the whole complaint and it is answerable with nothing
       on screen. Every control on that bar takes its word for this computer from
       one field; when the field is empty each of them falls back to the phrase,
       and the phrase is what cannot be resolved by reading it.
       ───────────────────────────────────────────────────────────────────── */
    const view = JSON.parse(String(await page.evaluate(
      '(async()=>{try{const v=await window.deck.listMachines();'
      + 'return JSON.stringify({ok:Boolean(v),here:String((v&&v.here)||""),'
      + 'machines:((v&&v.machines)||[]).map(m=>String(m.name||""))})}'
      + 'catch(e){return JSON.stringify({ok:false,here:"",machines:[]})}})()',
    )));

    await expect('the engine answers with a name for the computer this window is on', async () => {
      // Empty is the state a build whose preload predates the field is in, and
      // every reader falls back to its own phrase there — which puts "This
      // machine" back on the bar for everybody, in one deletion.
      return view.ok === true && view.here.trim() !== '';
    });

    await expect('and that name is a machine\'s name, not the phrase that started this', async () => {
      return /^this (machine|mac|pc|computer)$/i.test(view.here.trim()) === false;
    });

    /* ─────────────────────────────────────────────────────────────────────
       The rule the move would have exercised, read where it lives.

       Read BEFORE the bar rather than after it, and only because of where this
       guard can stop. The half below needs a browser on screen and an install
       with nothing open in it has none; this half needs nothing but the files,
       so it can be answered on any computer. Written after the stop it would
       simply never be read, and the one part of this that always runs would run
       nowhere.
       ───────────────────────────────────────────────────────────────────── */

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter. The rule below is written down in prose directly above
     * the line that implements it — his own words, in the source — so a plain
     * search for it finds the paragraph explaining it and passes on a build that
     * stopped obeying it. Three tests on this project have already failed from
     * the other direction, on their own comments. Flattening the whitespace
     * afterwards is what keeps a reformat from reading as a regression.
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

    await expect('the mark is refused outright when there is no page to attribute', async () => {
      // The one line that was missing, and the whole of the fix. Three of the
      // four states were already written down — in a comment over the JSX that
      // computed them, which is where the fourth was missing from.
      const rule = await code('src/renderer/browser/served-mark.ts');
      return /if \(input\.picked === '' \|\| input\.blank\) return null/.test(rule);
    });

    await expect('and when the picker already names the page\'s machine, the field adds nothing', async () => {
      // The other direction, and it is the same sentence of his: *"why do we show
      // inside the link bar also local? … It doesn't make any sense to keep in
      // both side the same thing."* The mark is the remainder — what is true,
      // less what the control beside it has already said.
      const rule = await code('src/renderer/browser/served-mark.ts');
      return /if \(!served\.agrees\) return served\.port === null \? served\.name : `\$\{served\.name\}:\$\{served\.port\}`/.test(rule)
        && /if \(served\.port === null \|\| served\.sameNumber\) return ''/.test(rule);
    });

    await expect('the picker names this computer instead of pointing at it', async () => {
      // `machineChoices` deliberately has no row for this computer — the picker
      // draws it first, itself, wearing the same name the rest of the app uses.
      // A label computed from anything but that name is how one bar came to carry
      // three phrases for three computers.
      const picker = await code('src/renderer/browser/MachinePicker.tsx');
      return /const label = current === null \? here : current\.name/.test(picker)
        // And the phrase is not anywhere in what it draws. Read with the
        // comments stripped, so the paragraph explaining the defect does not
        // itself read as the defect.
        && /this machine/i.test(picker) === false;
    });

    /* ─────────────────────────────────────────────────────────────────────
       And the bar itself, with no page on it — which is the only state the
       defect was ever visible in.
       ───────────────────────────────────────────────────────────────────── */

    /**
     * A blank browser window, opened here and closed again in the `finally`.
     *
     * Opened rather than assumed: guards share one running app and read whatever
     * the guard before them left on screen, and the bug lives specifically in a
     * tab that has been nowhere. Nothing is navigated — a tab with no page is
     * the condition being tested, not a shortcut around one.
     */
    const made = String(await page.evaluate(
      '(async()=>{try{const one=await window.deck.browserCreate("");'
      + 'return typeof one==="string"?one:((one&&(one.id||one.windowId))||"")}'
      + 'catch(e){return ""}})()',
    ));

    try {
      await expect('a blank browser tab really opened, so there is a bar to read', async () => made !== '');

      await page.wait(900);

      const bar = JSON.parse(String(await page.evaluate(
        '(()=>{const names=[...document.querySelectorAll(".bw-machine-name")].map(n=>(n.textContent||"").trim());'
        + 'const marks=[...document.querySelectorAll(".bw-served")].map(n=>(n.textContent||"").trim());'
        + 'const picker=document.querySelector(".bw-machine");'
        + 'const menu=document.querySelector(".bw-menu");'
        + 'const words=[picker?(picker.textContent||"")+" "+(picker.title||"")+" "+(picker.getAttribute("aria-label")||""):"",'
        + 'menu?(menu.innerText||""):"",marks.join(" ")].join(" ~ ");'
        + 'return JSON.stringify({names,marks,words,hasPicker:Boolean(picker),'
        + 'stage:Boolean(document.querySelector(".bw-stage"))})})()',
      )));

      // NOT PROVED rather than failed, and the difference is the whole point of
      // this guard. That bar is drawn by the browser workspace, and the workspace
      // only exists inside an open project: an install with nothing open in it has
      // no bar anywhere in its window, and is right not to. Which is this machine
      // missing something, not the product getting something wrong — and every
      // check below reads that bar, so failing here would announce that the phrase
      // he reported six times in three days is back, about a bar nobody looked at.
      // The blank tab above really was made — the engine answered with an id — but
      // asking the engine for a page hangs one on the window; it does not open the
      // workspace that draws the bar, and nothing a guard is allowed to do will.
      if (bar.stage !== true) {
        cannotRunHere(
          'the browser bar is not on screen on this computer: the app has no project open here — its window is '
          + 'sitting on the "Open a project" welcome screen — and that bar is part of the browser workspace, which '
          + 'only exists inside an open project. The blank tab this check asked for was made (the engine answered '
          + 'with an id), but asking the engine for a page hangs one on the window without opening the workspace '
          + 'that draws the bar. Run this against an install that has a project open with a browser tab in it, and '
          + 'the rest of this will run.',
        );
      }

      await expect('with no page loaded, nothing inside the address field names a machine', async () => {
        // The exact shipped defect: a mark asserting a machine about a page that
        // was never fetched. Nothing was served, so there is nobody to name, and
        // naming one is inventing a fact.
        return bar.marks.length === 0;
      });

      await expect('at most one machine label is drawn on the bar at a time', async () => {
        // Two labels is the complaint itself — *"it is showing both, selected one
        // and this one"* — whichever two controls they came from. One is the
        // picker; zero is a desktop with nothing paired, where the control is
        // absent rather than empty and that is correct.
        return bar.names.length + bar.marks.length <= 1;
      });

      await expect('the words "This machine" are nowhere on that bar', async () => {
        // Asked of the chip, its hover, its screen-reader label, the menu and the
        // mark together. Every one of those five carried the phrase at some point
        // in the same week, and each was fixed on its own.
        return /this machine/i.test(bar.words) === false;
      });

      await expect('a second machine is paired here for the half that needs one to be watched', async () => {
        // Said out loud rather than skipped. The failure he filmed needed a
        // machine to be CHOSEN — with nothing paired the picker is not drawn at
        // all, and every check above is measuring a bar that cannot be wrong in
        // the way he reported. Pair one and run it again.
        //
        // And the move itself is deliberately not performed even when there is
        // one: choosing a machine re-points a live window's addresses and opens
        // tunnels on the far end, which is the product changing under the thing
        // watching it. What the move would prove is proved from the rule read
        // above.
        return bar.hasPicker === true && view.machines.length > 0;
      });
    } finally {
      // A guard that leaves a window open changes what the next guard sees, and a
      // guard that depends on what another one left behind is a guard nobody can
      // trust.
      if (made !== '') {
        await page.evaluate(
          `(async()=>{try{await window.deck.browserClose(${JSON.stringify(made)})}catch(e){}})()`,
        );
      }
    }
  },
};
