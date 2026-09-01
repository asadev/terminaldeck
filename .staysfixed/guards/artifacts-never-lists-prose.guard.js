/**
 * Told seven times in nine days, and still showing him PLAN.md — because the
 * rule was right and his machine was running the previous night's host.
 */
export default {
  name: 'the Artifacts list never shows markdown or prose, and the host actually running is the one that was fixed',

  fixed: '2026-08-25',

  because:
    'His words, the second time of asking: *"an artifact is still showing the MD files, which is — multiple times I '
    + 'have discussed about it. Artifact should not show the MD files. It should be only for purely the prototypes."* '
    + 'And later, sharper: *"And what about artifacts? Again, I\'m again discussing this. Still we have MD files. Why '
    + 'every time I\'m mentioning and it is still the same?"* Seven mentions between 2026-08-16 and 2026-08-25. The rule '
    + 'itself was written and correct for most of that: a row is a prototype, a picture or a recording, decided from the '
    + 'path, and applied at the scan so the counts above the list are taken from what survived. What kept it wrong on '
    + 'his phone is where the rule runs — inside the host process, on the machine that owns the files — and his machine '
    + 'was still running the previous night\'s host bundle, so the same rows kept arriving. A fix that lives only in a '
    + 'build nobody is running is indistinguishable from no fix at all. That is why half of this guard reads the running '
    + 'program rather than the checkout, and why the same list is asked of two ends that can disagree.',

  link: 'asks-audit-2026-08-28 CRO-078 (also DES-156, HEA-053) — seven mentions, 2026-08-16 to 2026-08-25',

  async run({ expect, page, project, run: shell, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /**
     * The extensions that make a row.
     *
     * Written out here rather than read out of the product — `ARTIFACT_EXTENSIONS`
     * in `src/renderer/components/ArtifactsPanel.tsx` and the three lists behind
     * `pathKind` in `src/main/remote/panels/artifacts.ts` are the same set on
     * purpose. A guard that imported the product's own list would agree with it
     * however wrong it became, which is not a check, it is an echo.
     */
    const ARTIFACT = new Set([
      'html', 'htm', 'xhtml',
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico', 'heic', 'heif', 'svg',
      'pdf', 'mp4', 'm4v', 'mov', 'webm', 'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg',
    ]);

    /** A dotfile with no second dot has no extension at all, and is not a prototype either. */
    const extensionOf = (/** @type {string} */ relPath) => {
      const name = relPath.slice(relPath.lastIndexOf('/') + 1);
      const dot = name.lastIndexOf('.');
      return dot <= 0 ? '' : name.slice(dot + 1).toLowerCase();
    };

    /* ─────────────────────────────────────────────────────────────────────
       What the engine finds, before anything has been dropped.

       Asked of this repository by name rather than of whatever folder the
       window happens to be on: the scan has to contain prose for the filter to
       have anything to do, and a guard that measured a folder nobody has worked
       in would pass by knowing about nothing. `artifacts:list` answers with the
       WHOLE scan — the narrowing is the panel's and the phone panel's, one on
       each side — so this is the raw material both of them are judged against.
       ───────────────────────────────────────────────────────────────────── */
    const scanned = JSON.parse(String(await page.evaluate(
      '(async()=>{try{const answer=await window.deck.listArtifacts({cwd:'
      + `${JSON.stringify(project.paths.root)},scope:'all'});`
      + 'return JSON.stringify({ok:Boolean(answer&&answer.ok===true),'
      + 'names:((answer&&answer.artifacts)||[]).map(a=>String(a.relPath||"")),'
      + 'made:((answer&&answer.artifacts)||[]).filter(a=>Number(a.writes||0)>0)'
      + '.map(a=>String(a.relPath||""))})}'
      + 'catch(e){return JSON.stringify({ok:false,names:[],made:[],why:String(e&&e.message||e)})}})()',
    )));

    await expect('the engine answers for what this project\'s agents actually wrote', async () => {
      return scanned.ok === true && Array.isArray(scanned.names) && scanned.names.length > 0;
    });

    const prose = scanned.names.filter((name) => !ARTIFACT.has(extensionOf(name)));

    await expect('that raw scan really does carry prose and source, so there is something to drop', async () => {
      // The material check, and it is not a formality. Every assertion below is
      // "no markdown reached the screen", and on a folder whose scan held no
      // markdown in the first place every one of them would pass by default —
      // which is the one failure this whole tool exists to prevent.
      return prose.length > 0;
    });

    /* ─────────────────────────────────────────────────────────────────────
       And what the desktop draws out of it.
       ───────────────────────────────────────────────────────────────────── */

    /**
     * The Artifacts page, opened first.
     *
     * Guards share one running app and run one after another, so a guard that
     * reads the screen reads whatever the guard before it left there. Found by
     * the row's own label span rather than by the button's whole text, because a
     * rail row with a count on it carries the number too.
     */
    const opened = Boolean(await page.evaluate(
      '(()=>{const b=[...document.querySelectorAll(\'button.sb-nav\')]'
      + '.find(e=>((e.querySelector(\'.sb-label\')||{}).textContent||\'\').trim()===\'Artifacts\');'
      + 'if(b)b.click();return Boolean(b)})()',
    ));
    await page.wait(1200);

    await expect('the Artifacts page is the one on screen', async () => {
      return opened && Boolean(await page.evaluate('Boolean(document.querySelector(\'.panel-page[data-panel="artifacts"]\'))'));
    });

    const drawn = JSON.parse(String(await page.evaluate(
      '(()=>{const el=document.querySelector(\'.panel-page[data-panel="artifacts"]\');'
      + 'if(!el)return JSON.stringify({found:false,rows:[],onAProject:false,placeholder:"",blank:""});'
      + 'const rows=[...el.querySelectorAll(".artifact-row-name")].map(n=>(n.textContent||"").trim());'
      + 'const none=el.querySelector(".artifacts-none");'
      + 'const title=el.querySelector(".page-blank-title");'
      + 'return JSON.stringify({found:true,rows,'
      + 'onAProject:Boolean(el.querySelector(".artifacts-scope")),'
      + 'placeholder:title?(title.textContent||"").trim():"",'
      + 'blank:none?(none.innerText||"").trim():""})})()',
    )));

    /* ─────────────────────────────────────────────────────────────────────
       Before the page can be judged, there has to be something on it.

       This was an `expect` until 2026-09-01, and it was the wrong shape: it is
       a fact about this COMPUTER, not about the product, and stated as an
       assertion it printed *"a bug that was already fixed is back"* over a bug
       nobody had looked for. An empty Artifacts page is the right answer on a
       window with no project open, and the right answer in a folder whose
       agents have only ever written prose. Neither says a word about the
       filter, so neither may be reported as either verdict.

       What must NOT be swallowed is the third empty page: a project open, the
       scan holding prototypes an agent made, and the list still arriving with
       nothing in it. That is the filter eating its own subject, and it is a
       failure — so it stays an `expect`, below.
       ───────────────────────────────────────────────────────────────────── */

    if (drawn.found !== true || drawn.onAProject !== true) {
      // The Made/Changed header is gone, which means the panel was never drawn:
      // the shell has put its "Open a project" placeholder there instead.
      cannotRunHere(
        'the Terminal Deck window this check drives has no project open, so the Artifacts page is showing its '
        + `"${drawn.placeholder || 'Open a project'}" placeholder instead of a list of anything. `
        + 'Open a project in that window — a folder whose agents have written a prototype, a picture or a '
        + 'recording into it — and this will run.',
      );
    }

    /**
     * The rows that ought to be on the page: files an agent WROTE (rather than
     * edited, which is one chip away and not what the list draws by default)
     * whose extension makes them a prototype, a picture or a recording.
     */
    const shouldBeDrawn = (scanned.made || []).filter((name) => ARTIFACT.has(extensionOf(name)));

    if (shouldBeDrawn.length === 0) {
      cannotRunHere(
        `nothing an agent made in ${project.paths.root} is a prototype, a picture or a recording. `
        + `The scan found ${scanned.names.length} file(s) an agent touched here, ${(scanned.made || []).length} of `
        + 'them written whole, and not one of those is a prototype, a picture or a recording — so an empty '
        + 'Artifacts list is the correct answer and there is no row for the filter to be judged on. Run this '
        + 'against a folder an agent has written an .html prototype, a picture or a recording into, and it '
        + 'will run.',
      );
    }

    await expect('every artifact the scan found reached the page, rather than the list arriving empty', async () => {
      // Only reachable once there IS something that belongs on screen, which is
      // what makes this a claim about the product rather than about the machine.
      // It has to stay: the sentence below is "no prose reached the screen", and
      // on a list with nothing in it that passes by default — which is the one
      // failure this whole tool exists to prevent.
      return drawn.rows.length > 0;
    });

    await expect('not one row on it names a markdown or a prose file', async () => {
      // The complaint itself, word for word: *"an artifact is still showing the
      // MD files."* Asked of every row rather than of `.md` alone, because the
      // rule he was given is "only prototypes" and a `.ts` row is the same
      // sentence with a different extension in it.
      return drawn.rows.every((name) => name !== '' && ARTIFACT.has(extensionOf(name)));
    });

    /* ─────────────────────────────────────────────────────────────────────
       The half that only the running program can answer.
       ───────────────────────────────────────────────────────────────────── */

    /**
     * Every headless host running on this computer, with the file it was really
     * started from and the moment it started.
     *
     * Three things this had to survive, all of them met while writing it:
     *
     *  - `lstart`, not `etimes`. macOS `ps` accepts `etimes` and then simply
     *    omits the column, which reads exactly like a process with no elapsed
     *    time. `ps` prints the day and the month in either order depending on
     *    the locale, so both are read.
     *  - The command line is not the bundle. Installed with `npm install -g` the
     *    host runs as `bin/terminaldeck-host`, a symlink with no `.mjs` and no
     *    `headless` anywhere in it, so every path-shaped token is resolved and
     *    the one that lands on a `.mjs` is the file the code is in.
     *  - The desktop app matches the same word and is not a host. It is dropped
     *    by name, because a guard that measured the window instead of the host
     *    would report the very thing it exists to catch as fine.
     *
     * A non-zero exit from a `grep` that found nothing is returned, never thrown.
     */
    const running = await (async () => {
      const asked = await shell(
        'ps -axo pid=,lstart=,command= | grep -Ei "terminaldeck|headless" | grep -v grep',
        { timeoutMs: 8000 },
      );
      /** @type {{pid: string, startedAt: number, bundle: string}[]} */
      const found = [];
      for (const line of String(asked.stdout || '').split('\n')) {
        const row = line.trim();
        if (row === '') continue;
        const head = /^(\d+)\s+(\w{3}\s+\d{1,2}\s+\w{3}\s+\d{2}:\d{2}:\d{2}\s+\d{4}|\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.*)$/.exec(row);
        if (!head) continue;
        const command = head[3];
        if (/Terminal Deck\.app|[Ee]lectron|Helper/.test(command)) continue;
        let bundle = '';
        for (const token of command.split(/\s+/)) {
          if (!token.includes('/')) continue;
          const real = await fsp.realpath(token).catch(() => '');
          // Named entry points only. The word `headless` turns up inside other
          // programs' arguments — a browser flag, a test runner's inline script —
          // and a `.mjs` resolved out of one of those is not this product's host.
          if (['host.mjs', 'cli.mjs', 'daemon.mjs'].includes(path.basename(real))) { bundle = real; break; }
        }
        if (bundle === '') continue;
        found.push({ pid: head[1], startedAt: Date.parse(head[2].replace(/\s+/g, ' ')), bundle });
      }
      return found;
    })();

    await expect('a headless host is running on this computer for the phone half to be watched on', async () => {
      // Said out loud rather than skipped. The rule lives in the host, the host
      // runs on the machine that owns the files, and the whole reason this bug
      // survived four tellings is that nobody checked which build was running.
      // With no host here there is nothing to read, and a pass would be a lie.
      return running.length > 0;
    });

    await expect('the bundle each of them was started from carries the filter, by name', async () => {
      // Grepped out of the file the process was actually launched with, not out
      // of `src/`. The build is not minified, so `isArtifact` and `onlyArtifacts`
      // survive into it under their own names; both, because the second one is
      // the seam that matters — the filter has to run at the scan, ahead of every
      // count, or *"3 made here"* ends up standing over an empty list.
      if (running.length === 0) return false;
      for (const host of running) {
        const folder = path.dirname(host.bundle);
        let carries = false;
        for (const name of ['chunk-host.mjs', path.basename(host.bundle), 'host.mjs', 'cli.mjs']) {
          const file = path.join(folder, name);
          const text = await fsp.readFile(file, 'utf8').catch(() => '');
          if (text.includes('isArtifact') && text.includes('onlyArtifacts')) carries = true;
        }
        if (!carries) return false;
      }
      return true;
    });

    await expect('and each of them started AFTER the bundle it is running was last written', async () => {
      // This is the actual 2026-08-26 failure, and it is invisible from the
      // source tree: the file on disk had the fix, the process in memory did not,
      // and his phone kept receiving the rows the old code produced. A host older
      // than its own bundle is a host that has not been restarted since the
      // deploy — which is the same thing as not being deployed.
      if (running.length === 0) return false;
      for (const host of running) {
        const stat = await fsp.stat(host.bundle).catch(() => null);
        if (stat === null || !Number.isFinite(host.startedAt)) return false;
        // A second of slack: the process is launched from the file it was just
        // written to, and the two timestamps are taken by different clocks.
        if (host.startedAt + 1000 < stat.mtimeMs) return false;
      }
      return true;
    });

    await expect('a phone is paired here for the list to be read on the surface he reported it from', async () => {
      // The row he saw was on his phone, not on this screen, and the two are
      // drawn by two different panels off one shared rule. With no device paired
      // this end can only prove its own half, and it says so rather than
      // reporting the other one clean.
      const said = String(await page.evaluate(
        '(async()=>{try{const list=await window.deck.listRemoteDevices();'
        + 'return JSON.stringify(Array.isArray(list)?list:((list&&list.devices)||[]))}'
        + 'catch(e){return "[]"}})()',
      ));
      const devices = JSON.parse(said);
      return Array.isArray(devices) && devices.length > 0;
    });
  },
};
