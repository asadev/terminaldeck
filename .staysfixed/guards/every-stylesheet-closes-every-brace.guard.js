/**
 * 3,163 opening braces against 3,159 closing ones, and 13,457 tests passed while the app was bare.
 */
export default {
  name: 'every stylesheet closes every brace it opens',

  fixed: '2026-08-21',

  because:
    'A merge was resolved by taking one side whole where both sides had rewritten the same region of a stylesheet, '
    + 'which left four rules with their braces open. CSS reports nothing at all for this: the parser folds everything '
    + 'after an unclosed brace into the rule it never left, so the rest of the bundle simply stops applying. The app '
    + 'opened with no sidebar background, browser-default bullets down the navigation and a window you could see '
    + 'through — and all 13,457 tests passed while it did. The built bundle counted 3,163 opening braces against 3,159 '
    + 'closing ones, which is the whole diagnosis in two numbers. This repository merges ten branches at a time and a '
    + 'style conflict is resolved by hand every round; the same conflict boundary was mishandled five times in that '
    + 'one merge.',

  link: 'd497000 Four rules left open by a merge, and the whole app unstyled behind them',

  async run({ expect, project }) {
    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    /**
     * How a stylesheet balances, counted the only way that is safe to count it.
     *
     * Comments are blanked first — this codebase's stylesheets carry long prose notes, and
     * one of them writes a brace inside a sentence — and so are quoted strings, where a
     * `content: '}'` is a character and not a rule ending. Depth is walked rather than the
     * two totals compared: a sheet that closes one rule too early and opens another too late
     * balances perfectly and is still wrong, and the fault that shipped was a run of four.
     */
    const balance = (css) => {
      const text = css
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/"(?:[^"\\]|\\.)*"/g, '""')
        .replace(/'(?:[^'\\]|\\.)*'/g, "''");
      let depth = 0;
      let closedTooMany = 0;
      for (const ch of text) {
        if (ch === '{') depth += 1;
        else if (ch === '}') {
          depth -= 1;
          if (depth < 0) { closedTooMany += 1; depth = 0; }
        }
      }
      return { left: depth, closedTooMany };
    };

    await expect('this counter still notices a rule left open, and still ignores a brace in prose', async () => {
      // A counter that has quietly stopped counting passes everything for ever, which is the
      // one failure this whole tool exists to prevent. Both directions, because a normaliser
      // that eats too much is as useless as one that eats too little.
      const open = balance('.a { color: red;\n.b { color: blue; }\n');
      const prose = balance('/* a rule looks like .x { y } */\n.x { content: "}"; }\n');
      const early = balance('.a { color: red; } }\n.b { color: blue; }\n');
      return open.left > 0 && prose.left === 0 && prose.closedTooMany === 0 && early.closedTooMany === 1;
    });

    /** Every stylesheet in the tree, which is where a merge leaves the damage. */
    const sheets = [];
    const walk = async (dir) => {
      for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
        if (entry.name === 'node_modules') continue;
        const at = path.join(dir, entry.name);
        if (entry.isDirectory()) { await walk(at); continue; }
        if (entry.name.endsWith('.css')) sheets.push(at);
      }
    };
    await walk(path.resolve(project.paths.root, 'src'));

    await expect('enough stylesheets were actually read for this to mean anything', async () => {
      // A rule that matches zero files reports exactly what a clean tree reports. There were
      // 77 of these when this was written.
      return sheets.length > 20;
    });

    await expect('every stylesheet in the tree closes every brace it opens', async () => {
      for (const sheet of sheets) {
        const { left, closedTooMany } = balance(await fsp.readFile(sheet, 'utf8'));
        if (left !== 0 || closedTooMany !== 0) return false;
      }
      return true;
    });

    /*
     * And the same question of the one stylesheet that actually ships. The four open rules
     * were counted in the BUILT bundle, and a build concatenates every sheet in the tree into
     * it — so a file that balances on its own and a bundle that does not is a bundler fault
     * rather than a merge fault, and this is where the difference shows.
     *
     * `styling-is-whole.guard.js` asks the running window whether it still looks styled, which
     * is the other half of this bug and catches it only once it has been built and launched.
     * This one reads the file that carries it.
     */
    const bundle = String(project?.config?.app?.binary ?? '');
    const asar = path.resolve(project.paths.root, bundle, 'Contents', 'Resources', 'app.asar');

    const archive = await (async () => {
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        /*
         * NOT `16 + size`. The archive's header is a pickle padded to a four-byte boundary and
         * this one is two bytes short of one, so reading from the unpadded offset hands back
         * every file shifted by two bytes — which for a stylesheet looks exactly like the bug
         * this guard is for: a last rule with no closing brace. Checked against the archive's
         * own recorded SHA-256 on 2026-09-02: unpadded mismatched, padded matched. A guard
         * that reports the fault it is hunting for, from its own arithmetic, is worse than no
         * guard at all.
         */
        return { index: JSON.parse(json.toString('utf8').replace(/\0+$/, '')), base: 16 + size + ((4 - (size % 4)) % 4) };
      } finally {
        await file.close();
      }
    })();

    const assets = archive.index?.files?.out?.files?.renderer?.files?.assets?.files ?? {};
    const shipped = Object.keys(assets).filter((name) => name.endsWith('.css'));

    await expect('the stylesheet the app ships is in the build to be read at all', async () => shipped.length > 0);

    await expect('and the stylesheet that ships closes every brace it opens', async () => {
      for (const name of shipped) {
        const entry = assets[name];
        // Electron leaves some files beside the archive in `app.asar.unpacked` and marks them
        // so in the index; reading one of those at an offset it does not have is how the
        // phone-client guard first went wrong.
        const css = entry.unpacked === true
          ? await fsp.readFile(path.join(`${asar}.unpacked`, 'out', 'renderer', 'assets', name), 'utf8')
          : await (async () => {
              const file = await fsp.open(asar, 'r');
              try {
                const buf = Buffer.alloc(Number(entry.size));
                await file.read(buf, 0, buf.length, archive.base + Number(entry.offset));
                return buf.toString('utf8');
              } finally {
                await file.close();
              }
            })();
        const { left, closedTooMany } = balance(css);
        if (left !== 0 || closedTooMany !== 0) return false;
      }
      return true;
    });
  },
};
