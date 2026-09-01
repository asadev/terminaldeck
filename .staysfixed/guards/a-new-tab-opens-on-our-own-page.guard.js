/**
 * "When I start new one see this red error connection refused kind of things."
 */
export default {
  name: 'a new browser tab opens on this app’s own start page, never on the engine’s error page',

  fixed: '2026-08-16',

  because:
    'The start address defaulted to `http://localhost:3000`. On the Mac it was written on something was always '
    + 'listening there, so it looked fine; on a clean install nothing is, so the first thing this product ever showed '
    + 'anybody in its browser was Chromium’s red ERR_CONNECTION_REFUSED page — *"why each session is openeing with an '
    + 'error like this"* — with the app’s own start page, which exists for exactly this moment, only reachable by '
    + 'emptying a field nobody knew about. It was reported, fixed, and reported again four days later on a fresh '
    + 'install, because the fix had been checked on a machine with a dev server running. The default is empty now and a '
    + 'failed load lands back on the same page with one written sentence. Both halves pass trivially on any machine '
    + 'with something on port 3000, which is every machine this is ever developed on.',

  link: 'asks-audit-2026-08-28 BRO-011 — four mentions, 2026-08-12 to 2026-08-16',

  async run({ expect, page, read }) {
    /**
     * What this copy has actually been told, asked of the engine.
     *
     * `values` holds only keys somebody has written, so an absent key is the untouched state —
     * which is the state the bug shipped in and the only state this question can be asked in.
     * The desktop adapter gives every run its own settings folder, so this is normally a copy
     * nobody has answered anything on; against an install where somebody HAS chosen a start
     * address, opening there is correct and there is nothing here to prove, so the check below
     * fails and says so rather than reporting green on a question it never got to ask.
     */
    const stored = String(await page.evaluate(
      "(async()=>{try{const s=await window.deck.getSettings();const v=(s&&s.values)||{};"
      + "return JSON.stringify({written:Object.prototype.hasOwnProperty.call(v,'browser.startUrl'),"
      + "value:String(v['browser.startUrl']??'')})}catch(e){return 'ERR '+String(e&&e.message||e)}})()",
    ));

    await expect('this copy has never been told where a new tab should open', async () => {
      if (!stored.startsWith('{')) return false;
      const said = JSON.parse(stored);
      // Empty counts as untouched: it is the same instruction, typed. What fails this is an
      // address, and an address means the run is on somebody's real profile rather than on a
      // clean one — which is precisely the machine the second report came off.
      return said.value === '';
    });

    const schema = String(await read('src/renderer/settings/settings-schema.ts'));

    await expect('the start address this app ships with is no address at all', async () => {
      /*
       * The one-line change, read where it lives. The entry is found by its id and cut at the
       * next one, so a setting added above or below it moves nothing here.
       *
       * Deliberately not "the default is not localhost:3000". The mistake was not that
       * particular port — it was having a default at all, because a default start address is a
       * guess about a stranger's machine, and 3000 was one framework's convention read as a
       * fact about everybody.
       */
      const at = schema.indexOf("id: 'browser.startUrl'");
      if (at < 0) return false;
      const next = schema.indexOf("id: '", at + 10);
      const entry = schema.slice(at, next > at ? next : schema.length);
      return /default:\s*''\s*,/.test(entry);
    });

    await expect('and nothing else in the settings defaults to an address on somebody else’s machine', async () => {
      // The same mistake has 22 other places to happen in this one file, and every one of them
      // would show up on a stranger's first run rather than on the machine it was typed on.
      // The count keeps the sweep honest: a moved file or a changed shape would leave nothing
      // to subtract, and finding no addresses in an empty list reads exactly like finding none
      // in the whole schema.
      const defaults = [...schema.matchAll(/^\s*default:\s*(.+?),?\s*$/gm)].map((line) => line[1]);
      return defaults.length >= 15
        && defaults.every((value) => /:\/\/|localhost/.test(value) === false);
    });

    /**
     * The two rules that decide what a tab shows, taken out of the panel and RUN.
     *
     * Reading the source for the word "failed" would prove nothing: the flag was there the
     * whole time and what was missing was what it decided. Both functions are exported for
     * exactly this reason — an effect is the one place a rule cannot be tested, and this
     * project's own test run has no DOM — so they are lifted out by their braces and driven.
     *
     * The parameter list is skipped rather than parsed, and the body handed to a function of
     * this guard's own making: the body is plain JavaScript, and everything TypeScript about
     * these two lives in the signature. A signature that grows a default value with a bracket
     * in it would break the cut, and the checks below would fail loudly rather than quietly.
     *
     * @param {string} name
     */
    const panel = String(await read('src/renderer/browser/BrowserWorkspace.tsx'));
    const bodyOf = (name) => {
      const at = panel.indexOf(`export function ${name}(`);
      if (at < 0) return '';
      const opens = panel.indexOf('{', panel.indexOf(')', panel.indexOf('(', at)));
      let depth = 0;
      for (let i = opens; i < panel.length; i += 1) {
        if (panel[i] === '{') depth += 1;
        else if (panel[i] === '}') {
          depth -= 1;
          if (depth === 0) return panel.slice(opens + 1, i);
        }
      }
      return '';
    };

    const onStartPage = new Function('tab', bodyOf('onStartPage'));
    const pageVisible = new Function(
      'onStartPage',
      `return function (tab, state) {${bodyOf('pageVisible')}}`,
    )(onStartPage);

    await expect('a tab that has not been anywhere yet draws this app’s own page', async () => {
      // The state a new tab is in the moment the default stopped being an address. If this
      // ever answers false, a new tab has somewhere else to be — which is the bug, whatever
      // that somewhere is.
      return onStartPage({ url: '', failed: false }) === true
        && onStartPage({ url: 'about:blank', failed: false }) === true;
    });

    await expect('and so does a tab whose load failed, rather than the engine’s own error document', async () => {
      // His screenshot, as one call: the address that was asked for is still on the tab and
      // the view is holding Chromium's red page, and the answer has to be that this app draws
      // its own page over it — with the sentence and the list of what IS listening.
      return onStartPage({ url: 'http://localhost:3000', failed: true }) === true;
    });

    await expect('while a page that loaded is left alone', async () => {
      // The half that keeps the three above honest. A rule that answered "our own page" to
      // everything would satisfy all of them and hide every website in the app.
      return onStartPage({ url: 'https://example.com/docs', failed: false }) === false;
    });

    await expect('the failed page is never composited, so nobody ever sees the red one', async () => {
      /*
       * The other end of the same fix, and it is a separate decision in a separate function:
       * the app's start page is HTML in the window, and the failed document is a native view
       * over the top of it. Drawing one without hiding the other leaves the error page exactly
       * where it was, underneath a page nobody can see.
       *
       * Asked in the most favourable state there is — the active tab, in the visible panel,
       * with no dialog, nothing covering it and nothing being drawn — so the only thing left
       * that can hide it is the rule under test.
       */
      const wideOpen = {
        isActive: true,
        visible: true,
        parkPage: false,
        sessionOpen: false,
        covered: false,
        drawing: false,
        shotOpen: false,
      };
      return pageVisible({ url: 'http://localhost:3000', failed: true }, wideOpen) === false
        // And a page that loaded IS composited in that state, which is what stops this passing
        // on a build that had quietly stopped showing websites at all.
        && pageVisible({ url: 'https://example.com/docs', failed: false }, wideOpen) === true;
    });

    /**
     * What the pages in this window are showing right now, if any are open.
     *
     * Nothing here opens a tab and nothing navigates one: creating a page is creating
     * something, and steering an existing page at a dead address to watch it fail would take
     * away whatever somebody had loaded. So this reads what is already there.
     */
    const said = String(await page.evaluate(
      '(()=>{const list=[...document.querySelectorAll(".bw")].map(el=>{'
      + 'const field=el.querySelector(".bw-address input");'
      + 'return {address:String(field?field.value:""),'
      + 'ourPage:Boolean(el.querySelector(".bw-start")),'
      + 'field:Boolean(el.querySelector(".bw-start-address")),'
      + 'ports:Boolean(el.querySelector(".bw-start-list,.bw-start-note"))}});'
      + 'return JSON.stringify(list)})()',
    ));
    // Never a throw: an unreadable answer must fail a named claim rather than stop the guard
    // at the line it exploded on.
    const drawn = said.startsWith('[') ? JSON.parse(said) : null;

    if (drawn !== null && drawn.length > 0) {
      await expect('no page in this window is sitting on a browser error document', async () => {
        // What the address field reads when the engine's own document has committed. It is the
        // one string on screen that tells the two states apart, because Chromium's error page
        // keeps the address that failed in the bar above it.
        return drawn.every((one) => /^(chrome-error|chrome|about):/.test(one.address) === false
          || one.ourPage === true);
      });

      await expect('and every page showing our own start page offers the field and the list', async () => {
        // The start page is only an answer if it carries the two things it exists to carry:
        // somewhere to type an address, and the ports that are actually listening here. A
        // heading over an empty area is the same dead end as the red page, more politely.
        return drawn.filter((one) => one.ourPage).every((one) => one.field && one.ports);
      });
    }

    /*
     * WHAT THIS GUARD CANNOT REACH, said here rather than left to be assumed.
     *
     * Pressing "New browser tab" would create a page in his window, and navigating one to a
     * dead address to watch it come back would take away whatever was loaded in it — so the
     * two acts the write-up describes are both out. What is asked instead is the state a new
     * tab is born into (no address to go to) and the two rules that decide what it draws, run
     * rather than read.
     *
     * The first check is the one that carries the "fresh profile" requirement, and it carries
     * it honestly: it fails on a copy where somebody has chosen a start address, because on
     * that copy this question has a different right answer. The desktop adapter gives each run
     * its own settings folder, which is what makes it answerable at all.
     */
  },
};
