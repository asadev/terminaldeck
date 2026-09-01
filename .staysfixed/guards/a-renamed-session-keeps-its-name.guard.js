/**
 * Two rows in his rail both read "Commander", and only one of them existed.
 */
export default {
  name: 'everything that lists a session calls it by its own name, once',

  fixed: '2026-08-21',

  because:
    'Two mirror-image faults, a day apart. First a picker ignored the name he had typed and printed the built-in one, '
    + 'so a session he had renamed "commander" was still listed as "copilot"; that was repaired in the picker, and the '
    + 'Overview page went on listing the copilot twice, by its folder. Then the renaming helper keyed off the **folder** '
    + 'rather than the session and ran after the typed title had been stored, so an ordinary session opened in the '
    + 'copilot’s folder was overwritten with the copilot’s name — *"why do we have two commander sessions and none of '
    + 'this is calling template?"*. Four surfaces in this window derive a session’s name and each one derives it from a '
    + 'slightly different place, so one of them drifting is the normal way this returns.',

  link: 'review-2026-08-20 K3 + AUDIT-FINDINGS-rerun, review-2026-08-21 T59 — one surface fixed, another still wrong the same night',

  async run({ expect, page }) {
    // Read-only throughout. Nothing here renames anything, and nothing starts a
    // session to have something to rename — a guard that renames a session is a
    // guard that has changed the very field it is checking. What it does instead
    // is read the names the app is showing right now against the names the app
    // itself holds, which is the comparison nobody was making.

    await expect('both halves of the rename channel are still wired', async () => {
      // A name typed at this desk has to reach the machine, and a name typed on
      // a phone or another of his machines has to come back — that gap is what
      // let one session wear two names on two of his own screens. A preload
      // missing either half fails silently: the field closes, the label repaints
      // locally, and nothing else ever hears.
      const missing = String(await page.evaluate(
        "['renameSession','onSessionRenamed'].filter(n=>typeof window.deck?.[n]!=='function').join(', ')",
      ));
      return missing === '';
    });

    /**
     * The copilot's row: what it is called out loud, and what it is called on
     * screen. The row is pinned and singleton, so it is here whatever page the
     * guard before this one left open — which is the only reason this guard can
     * assert on a name at all without opening anything.
     */
    const pinned = JSON.parse(String(await page.evaluate(
      "(()=>{const row=document.querySelector('[data-copilot-row]');"
      + "if(!row)return 'null';const block=row.closest('section');"
      + "const label=row.querySelector('.sb-label');"
      + "return JSON.stringify({spoken:block?(block.getAttribute('aria-label')||''):'',"
      + "shown:label?(label.textContent||'').trim():''})})()",
    )));

    await expect('the copilot is named on its row, and named the same way twice', async () => {
      // Both strings come from the same prop today, and that is the point: the
      // fault was a second reader falling back to the built-in word while the
      // row showed the typed one. A screen reader and an eye disagreeing about
      // what a thing is called is that fault, in its quietest costume.
      return pinned !== null && pinned.shown !== '' && pinned.shown === pinned.spoken;
    });

    await expect('that name is on exactly one row in the rail', async () => {
      // "Two commander sessions" where one existed. Counted across the whole
      // rail, because the duplicate did not appear beside the original — it
      // appeared in another group entirely.
      const times = Number(await page.evaluate(
        "(()=>{const row=document.querySelector('[data-copilot-row]');if(!row)return -1;"
        + "const label=row.querySelector('.sb-label');const name=label?(label.textContent||'').trim():'';"
        + "if(name==='')return -1;"
        + "return [...document.querySelectorAll('aside .sb-label')]"
        + ".filter(e=>(e.textContent||'').trim()===name).length})()",
      ));
      return times === 1;
    });

    await expect('no two rows in the rail read as the same thing', async () => {
      // The rail already knows how to do this — when a name, a folder and an
      // account all fail to separate two rows it prints the head of the session
      // id beside them. This is that ladder still working: two rows with
      // identical text mean it stopped being climbed.
      const same = String(await page.evaluate(
        "(()=>{const rows=[...document.querySelectorAll('aside .sb-row.sb-open')]"
        + ".map(e=>(e.innerText||'').replace(/\\s+/g,' ').trim()).filter(t=>t!=='');"
        + "const twice=rows.filter((t,i)=>rows.indexOf(t)!==i);"
        + "return [...new Set(twice)].join(' | ')})()",
      ));
      return same === '';
    });

    // Overview is the page that listed the copilot twice, so this guard goes
    // there rather than reading whatever the guard before it left on screen.
    await page.evaluate(
      "(()=>{const b=[...document.querySelectorAll('button,[role=button],a')]"
      + ".find(e=>(e.textContent||'').trim()==='Overview');if(b)b.click();return Boolean(b)})()",
    );
    await page.wait(400);

    await expect('no two cards on Overview read as the same thing either', async () => {
      // The same ladder, on the other surface, and this is the surface that was
      // still wrong the night the first one was fixed. A card that needs telling
      // apart carries the same eight characters the rail uses, so a card and a
      // row can be matched by eye.
      const same = String(await page.evaluate(
        "(()=>{const cards=[...document.querySelectorAll('.board-title')]"
        + ".map(e=>(e.innerText||'').replace(/\\s+/g,' ').trim()).filter(t=>t!=='');"
        + "const twice=cards.filter((t,i)=>cards.indexOf(t)!==i);"
        + "return [...new Set(twice)].join(' | ')})()",
      ));
      return same === '';
    });

    await expect('every session that has a name of its own is called that in the rail too', async () => {
      // The cross-surface half — the one the first fix missed. Only cards
      // carrying a real name are compared: `Session 4` is not a name, it is what
      // the app calls a session nobody and nothing has named yet, and the two
      // surfaces counting from different ends is a separate fault with its own
      // note on the board. The id a card prints beside a twinned name is left
      // out the same way, by reading only the card's own text nodes.
      //
      // This one only bites with a session open. With nothing running both lists
      // are empty and it is true for free — so this guard is worth running
      // against an app somebody has actually been working in, which is where the
      // fault was found both times.
      const strays = String(await page.evaluate(
        "(()=>{const text=e=>[...e.childNodes].filter(n=>n.nodeType===3)"
        + ".map(n=>n.textContent).join('').replace(/\\s+/g,' ').trim();"
        + "const rail=new Set([...document.querySelectorAll('aside .sb-label')]"
        + ".map(e=>(e.textContent||'').trim()));"
        + "return [...document.querySelectorAll('.board-title')].map(text)"
        + ".filter(name=>name!==''&&!/^Session \\d+$/.test(name)&&!rail.has(name)).join(' | ')})()",
      ));
      return strays === '';
    });
  },
};
