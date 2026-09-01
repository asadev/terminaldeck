/**
 * Three folders had already piled up on this machine — Pawl, pawl, Terminal Deck —
 * one per rename, each with somebody's settings stranded in it.
 */
export default {
  name: 'renaming the app never moves anybody out of their own settings folder',

  fixed: '2026-08-13',

  because:
    'Electron decides where to keep your settings from the app display name. So every rename silently started every '
    + 'existing user over in an empty folder — sessions, projects, preferences, all apparently gone — with no error at '
    + 'any point. It had already happened twice: Pawl, pawl and Terminal Deck are all sitting in Application Support '
    + 'on this machine, each with its own state.json. The fix pins the folder to the brand slug, which does not move '
    + 'when the product is renamed, and it is one line at startup — which is exactly the line somebody rewrites during '
    + 'the next rebrand.',

  link: 'b12d9dd Pin the data directory to the slug, not the display name',

  async run({ expect, page, project }) {
    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    /** What the running app says it is called, and where it says it keeps things. */
    const said = JSON.parse(String(await page.evaluate(
      "(async()=>{try{const brand=await window.deck.getBrand();const paths=await window.deck.settingsPaths();"
      + "return JSON.stringify({name:(brand&&brand.name)||'',paths})}"
      + "catch(e){return JSON.stringify({error:String(e&&e.message||e)})}})()",
    )));

    await expect('the app can still say where its settings live', async () => {
      return said.error === undefined && Array.isArray(said.paths) && said.paths.length > 0
        && said.paths.every((entry) => typeof entry.path === 'string' && path.isAbsolute(entry.path));
    });

    await expect('the folder it keeps them in is not named after the name on the window', async () => {
      // The shipped symptom, in one line: everything moved into a folder called after the
      // new display name, and the folder called after the old one stayed behind with the
      // person's sessions, projects and preferences in it.
      //
      // Only the app-data folder, and only that folder's own segments. The log folder beside
      // it in this list IS named after the display name — the framework derives that one and
      // nothing here pins it — and a log folder is not somebody's work.
      //
      // This claim cannot see the pinning itself, and that is worth saying rather than
      // covering up: every check hands the app a settings folder of its own on the command
      // line, and an explicit --user-data-dir is obeyed ahead of the pinning on purpose, so
      // under a check the folder is whatever the run named. What it catches is the app
      // relocating itself into the display name anyway. The pinning proper is the two claims
      // after this one, read out of what ships.
      const named = String(said.name || '');
      const home = said.paths.find((entry) => entry.key === 'userData');
      if (named === '' || home === undefined) return false;
      // And it really is the folder everything else sits in, rather than one row of a list.
      const inside = said.paths.filter((entry) => String(entry.path).startsWith(`${home.path}${path.sep}`));
      if (inside.length < 2) return false;
      return !String(home.path).split(path.sep).includes(named);
    });

    /**
     * The packaged main process, read out of the archive by its own index.
     *
     * Unpacking 300 megabytes to answer one question is not a check anybody runs before a
     * release, and the question here is only what one function in one file still does.
     */
    const engine = await (async () => {
      const bundle = String(project?.config?.app?.binary ?? '');
      const asar = path.resolve(project.paths.root, bundle, 'Contents', 'Resources', 'app.asar');
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        const listing = JSON.parse(json.toString('utf8').replace(/\0+$/, ''));
        const entry = ['out', 'main', 'index.js'].reduce(
          (at, part) => (at && at.files ? at.files[part] : undefined),
          listing,
        );
        if (!entry || entry.unpacked === true) return '';
        const body = Buffer.alloc(Number(entry.size));
        await file.read(body, 0, body.length, 16 + size + Number(entry.offset));
        return body.toString('utf8');
      } finally {
        await file.close();
      }
    })();

    await expect('the shipped app still chooses that folder itself instead of letting the framework choose', async () => {
      // Twice: once where it is written, once where it is called. A pinning function that
      // survives a refactor with nobody calling it any more is the whole bug back again,
      // and it looks perfectly healthy in the source.
      const written = /function pinUserData\s*\(/.test(engine);
      const called = (engine.match(/pinUserData\s*\(/g) || []).length >= 2;
      return engine !== '' && written && called && /setPath\(\s*["']userData["']/.test(engine);
    });

    await expect('and it pins that folder to the slug, never to the display name', async () => {
      // The body of the one function, which is short enough that this reads it whole rather
      // than trusting a name. `BRAND.id` is a slug and does not move on a rename; `BRAND.name`
      // is the display name and is the entire defect.
      const at = engine.indexOf('function pinUserData');
      const body = at < 0 ? '' : engine.slice(at, at + 900);
      const brand = /BRAND = \{[\s\S]{0,400}?name:\s*"([^"]+)"[\s\S]{0,400}?id:\s*"([^"]+)"/.exec(engine);
      if (body === '' || brand === null) return false;
      const display = brand[1];
      const slug = brand[2];
      return body.includes('BRAND.id')
        && !body.includes('BRAND.name')
        && slug !== display
        && /^[a-z0-9][a-z0-9-]*$/.test(slug);
    });
  },
};
