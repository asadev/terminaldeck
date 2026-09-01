/**
 * The store fetched its list without catching failure, so a failed fetch painted
 * absolutely nothing — for ever.
 */
export default {
  name: 'a list that cannot be read says so, rather than opening blank',

  fixed: '2026-08-21',

  because:
    'The tools store asked for its catalogue with nothing around the call, so when the fetch failed the dialog drew '
    + 'nothing at all and went on drawing nothing. A blank store reads as "there is nothing in this store", which is a '
    + 'different and much more misleading thing than "this store could not be read" — the person is left with no reason '
    + 'and no way forward, and the app looks like it does not work rather than like it could not reach something. It is '
    + 'a one-line shape: a load with no catch on it, and every new panel starts with one. The same failure had already '
    + 'produced three separate complaints about other pages in the same review, so this is asked of every list in the '
    + 'window rather than of the store alone.',

  link: '0f7a39e A store that could not read its list says so, rather than opening blank',

  async run({ expect, page }) {
    /**
     * Every page here is opened first. Guards share one running app and run one after another,
     * so a guard that reads the screen reads whatever the guard before it left there.
     *
     * The rail row is found by its own label span rather than by the button's whole text: a
     * row with a count badge on it carries the number too, and an exact match on the button
     * would silently stop finding exactly the pages that have something to report.
     *
     * @param {string} label
     * @param {string} panel  The id the page draws on itself, so arriving is proved, not assumed.
     */
    const openPage = async (label, panel) => {
      await page.evaluate(
        "(()=>{const b=[...document.querySelectorAll('button.sb-nav')]"
        + `.find(e=>((e.querySelector('.sb-label')||{}).textContent||'').trim()===${JSON.stringify(label)});`
        + 'if(b)b.click();return Boolean(b)})()',
      );
      await page.wait(700);
      return Boolean(await page.evaluate(`Boolean(document.querySelector('.panel-page[data-panel=${JSON.stringify(panel)}]'))`));
    };

    /**
     * What a page is showing, minus the line that says which folder it is about.
     *
     * The scope line is subtracted on purpose. It is drawn by the shell above the view's own
     * body, so a panel that read nothing and drew nothing would still measure forty characters
     * of somebody else's sentence — which is precisely the blank this guard exists to catch.
     */
    const bodyOf = async (/** @type {string} */ panel) => String(await page.evaluate(
      `(()=>{const el=document.querySelector('.panel-page[data-panel=${JSON.stringify(panel)}]');`
      + 'if(!el)return JSON.stringify({found:false});'
      + 'const scope=el.querySelector(".page-scope");const all=el.innerText||"";'
      + 'const s=scope?(scope.innerText||""):"";'
      + 'const body=(s?all.split(s).join(" "):all).replace(/\\s+/g," ").trim();'
      + 'const blanks=[...el.querySelectorAll(".page-blank")].map(b=>({'
      + 'title:((b.querySelector(".page-blank-title")||{}).textContent||"").trim(),'
      + 'words:((b.querySelector(".page-blank-body")||{}).textContent||"").trim(),'
      + 'action:Boolean(b.querySelector(".page-blank-action"))}));'
      + 'return JSON.stringify({found:true,panel:el.getAttribute("data-panel"),body,blanks})})()',
    ));

    const lists = [
      ['Store', 'store'],
      ['Machines', 'remote'],
      ['MCP servers', 'mcp'],
      ['Source control', 'git'],
      ['Files', 'files'],
      ['Artifacts', 'artifacts'],
      ['GitHub', 'github'],
    ];

    /** @type {{panel: string, body: string, blanks: {title: string, words: string, action: boolean}[]}[]} */
    const read = [];
    for (const [label, panel] of lists) {
      if (!(await openPage(label, panel))) continue;
      const said = JSON.parse(await bodyOf(panel));
      if (said.found) read.push(said);
    }

    await expect('enough of the lists opened for this to mean anything', async () => {
      // A walk that found nothing to look at would pass by knowing about nothing, and that is
      // the one failure this whole tool exists to prevent.
      return read.length >= 4;
    });

    await expect('not one of them opened blank', async () => {
      // The bug, exactly: a panel with a heading over an empty white area, and no reason on it.
      // Twelve characters is well under the shortest real answer any of these pages gives.
      return read.every((one) => one.body.length >= 12);
    });

    await expect('every page with nothing to show says what and offers a way on', async () => {
      // A heading alone is the same dead end as a blank — "Nothing to browse in this build" with
      // no sentence under it and nothing to press tells a person nothing they can act on.
      return read.every((one) => one.blanks.every((blank) =>
        blank.title.length >= 3 && (blank.words.length >= 10 || blank.action)));
    });

    await expect('and none of them prints a failure it forgot to read', async () => {
      // What a missing catch leaves on screen when it leaves anything at all: the raw value it
      // was handed, rendered as though it were a sentence.
      return read.every((one) => /\[object Object\]|\bundefined\b|\bNaN\b/.test(one.body) === false);
    });

    await expect('the store, where this started, is answering for itself', async () => {
      // Named separately because it is the page the bug shipped on, and because its list comes
      // from off this machine — the one list in the window whose read can genuinely fail on a
      // person's own desk.
      const store = read.find((one) => one.panel === 'store');
      return store !== undefined && store.body.length >= 12;
    });
  },
};
