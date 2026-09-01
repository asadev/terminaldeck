/**
 * "MCP servers page does nothing. Source control shows nothing. Files shows nothing."
 * All three were reading a folder nobody could see, and none of them said which.
 */
export default {
  name: 'every page that reports on a folder names the folder it is reporting on',

  fixed: '2026-08-20',

  because:
    'Three separate complaints in one review, and one cause under all of them. The Files, Source control and MCP '
    + 'servers pages were bound to an invisible "current project" nobody could see or set: it follows whichever session '
    + 'is in front, and falls back to whichever folder happens to be first in the list. An auditor registered exactly '
    + 'one project, clicked its row, opened Source control and got a completely different repository’s working tree — '
    + 'with nothing anywhere on the page naming the folder, so there was no way to tell a wrong answer from an empty '
    + 'one. From outside, all three read as "does nothing". The fallback is still how the folder is chosen, so what '
    + 'makes it safe is the line on the page: a page that reports on something has to say what.',

  link: 'review-2026-08-20 REQUIREMENTS.md G3, G4, G5; cause in AUDIT-FINDINGS-firstrun.md',

  async run({ expect, page }) {
    /**
     * What this copy actually has open, asked of the engine rather than read off the rail.
     *
     * The whole bug was a page disagreeing with the list, so the list has to come from
     * somewhere other than a page. Only a question: nothing here opens or closes a folder.
     */
    const projects = JSON.parse(String(await page.evaluate(
      '(async()=>{try{const l=await window.deck.listProjects();'
      + 'const rows=Array.isArray(l)?l:(l&&l.projects)||[];'
      + 'return JSON.stringify(rows.map(p=>String((p&&p.path)||p||"")).filter(Boolean))'
      + '}catch(e){return "[]"}})()',
    )));

    /**
     * Guards share one running app and run one after another, so every page is opened here
     * rather than assumed. The rail row is found by its own label span, not by the button's
     * whole text: a row carrying a count badge carries the number too.
     *
     * @param {string} label
     * @param {string} panel  The id the page draws on itself, so arriving is proved.
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
     * The scope line, read off whatever page is open.
     *
     * The path comes from the element's title rather than from its text, because the line is
     * truncated from the left in CSS — what is on screen is the tail of the path, and a guard
     * comparing tails would happily agree with two different checkouts both called `web`.
     */
    const scopeOf = async (/** @type {string} */ panel) => String(await page.evaluate(
      `(()=>{const el=document.querySelector('.panel-page[data-panel=${JSON.stringify(panel)}]');`
      + 'if(!el)return JSON.stringify({found:false});'
      + 'const scope=el.querySelector(".page-scope");'
      + 'const where=scope?((scope.querySelector(".page-scope-where")||{}).textContent||"").trim():"";'
      + 'const p=scope?scope.querySelector(".page-scope-path"):null;'
      + 'const blanks=[...el.querySelectorAll(".page-blank")].map(b=>({'
      + 'title:((b.querySelector(".page-blank-title")||{}).textContent||"").trim(),'
      + 'action:Boolean(b.querySelector(".page-blank-action"))}));'
      + 'return JSON.stringify({found:true,panel:el.getAttribute("data-panel"),'
      + 'path:p?String(p.getAttribute("title")||p.textContent||"").trim():null,where,blanks})})()',
    ));

    /**
     * The pages whose subject IS the open folder, and MCP servers, which is the third
     * complaint and is deliberately not one of them: its subject can be a paired machine
     * picked on the page itself, so it draws its own scope line and is allowed to name
     * somewhere else — but only while saying so.
     */
    const pages = [
      ['Overview', 'overview'],
      ['Files', 'files'],
      ['Artifacts', 'artifacts'],
      ['Source control', 'git'],
      ['AI readiness', 'readiness'],
      ['MCP servers', 'mcp'],
    ];

    /** @type {{panel: string, path: string|null, where: string, blanks: {title: string, action: boolean}[]}[]} */
    const seen = [];
    for (const [label, panel] of pages) {
      if (!(await openPage(label, panel))) continue;
      const said = JSON.parse(await scopeOf(panel));
      if (said.found) seen.push(said);
    }

    /** The ones the shell itself puts a folder line on. */
    const folderPages = seen.filter((one) => one.panel !== 'mcp');

    await expect('enough of the folder pages opened for this to mean anything', async () => {
      // A walk that found nothing to look at would pass by knowing about nothing, which is the
      // one failure this whole tool exists to prevent.
      return folderPages.length >= 3;
    });

    await expect('no page reports on a folder this app does not have open', async () => {
      // The auditor's frame: one project registered, one row clicked, and a completely
      // different repository's working tree on the page.
      return seen.every((one) => one.path === null || projects.includes(one.path));
    });

    if (projects.length > 0) {
      await expect('every folder page names the folder it read', async () => {
        // The frame he recorded: "Artifacts", "AI readiness", "MCP servers" as bare headings
        // with no folder anywhere on them, while the folder in play was an empty ~/Templates.
        return folderPages.every((one) => typeof one.path === 'string' && one.path.length > 1);
      });

      await expect('and the pages reporting on this machine all name the same one', async () => {
        // Six pages, one subject. This is the claim that would have caught the original: two
        // of them naming two different folders in the same window, with nobody able to say
        // which was the one the rail meant.
        const here = folderPages[0]?.where ?? '';
        const mine = seen.filter((one) => one.where === here && one.path !== null);
        return mine.length >= 2 && new Set(mine.map((one) => one.path)).size === 1;
      });
    } else {
      await expect('with no folder open, every one of them says so and offers the way out', async () => {
        // The other half of "does nothing". A page with no folder to read has to say that is
        // what happened, and carry the one thing that changes it — not draw its title over an
        // empty white page, which is indistinguishable from being broken.
        return folderPages.every((one) => one.blanks.some((blank) => blank.title.length >= 3 && blank.action));
      });
    }
  },
};
