/**
 * Two tabs in his own recording read "New tab  browser:17871765".
 */
export default {
  name: 'no tab ever shows a raw internal id in place of a name',

  fixed: '2026-08-20',

  because:
    'When two tabs share a label, the strip walks a ladder of ways to tell them apart, and the last rung is the internal '
    + 'id. Two blank browser windows are both called "New tab", so both fell to that rung — and the helper that shortens '
    + 'an id cuts it at its first hyphen, which a browser id does not have, so the whole thing printed. His own recording '
    + 'shows two tabs reading "New tab browser:17871765". It ate the room as well, truncating the real name, and it '
    + 'reached the tooltip too. This shipped in a release.',

  link: 'review-2026-08-20 carry-over 3, frame f_2450 of his recording',

  async run({ expect, page }) {
    /** Everything this guard opens, so it can put the app back as it found it. */
    const opened = String(await page.evaluate(
      "(async()=>{try{const ids=[];for(let i=0;i<2;i++){const made=await window.deck.browserCreate();"
      + "ids.push(typeof made==='string'?made:(made&&(made.id||made.windowId))||'');}"
      + "return JSON.stringify(ids)}catch(e){return 'ERR '+String(e&&e.message||e)}})()",
    ));

    try {
      await expect('two blank browser windows really opened', async () => {
        return opened.startsWith('[') && JSON.parse(opened).filter(Boolean).length === 2;
      });

      await page.wait(600);

      await expect('neither tab is labelled with a raw id', async () => {
        // The exact shape from the recording: a word, a colon, and a long run of digits.
        const labels = String(await page.evaluate(
          "[...document.querySelectorAll('[role=tab],[class*=tab] ,[class*=Tab]')].map(e=>((e.textContent||'')+' '+(e.title||'')).trim()).join(' ~ ')",
        ));
        return /:\d{6,}/.test(labels) === false;
      });

      await expect('and no raw id is showing anywhere on screen', async () => {
        const shown = String(await page.evaluate("document.body.innerText"));
        return /:\d{6,}/.test(shown) === false;
      });
    } finally {
      // A guard that leaves windows open changes what the next guard sees, and a guard that
      // depends on what another one left behind is a guard nobody can trust.
      await page.evaluate(
        "(async()=>{try{const ids=" + JSON.stringify(opened) + ";"
        + "for(const id of JSON.parse(ids)){ if(id) await window.deck.browserClose(id); }}catch(e){}})()",
      );
    }
  },
};
