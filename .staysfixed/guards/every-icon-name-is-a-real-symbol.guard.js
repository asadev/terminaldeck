/**
 * He asked for a second close button and reported it missing, hours after it had
 * been built and shipped to the simulator in front of him. It was there. It was
 * drawn with a symbol name iOS does not have, so it drew nothing.
 */
export default {
  name: 'every icon the phone app asks for is a symbol that really exists',

  fixed: '2026-08-26',

  because:
    'A finished, working control was invisible because its icon named a system symbol that does not exist. The '
    + 'framework draws nothing at all for an unknown name — no error, no placeholder, no empty box — so the button was '
    + 'there, it worked, and nobody could see it. He reported it as never built. A second dead name turned up the same '
    + 'evening, which makes this a class rather than an incident: the names are typed by hand, they are checked by '
    + 'nothing at build time, and half of them differ from a real symbol by one word.',

  link: 'review-2026-08-26-evening REQUIREMENTS A7 — "I wanted to have two close buttons not just this one"',

  async run({ expect, project, read, run: shell }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /** Where this platform keeps the list of what its own symbols are called. */
    const GLYPHS = '/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources';

    /**
     * The platform's own answer, or null when this machine cannot give one.
     *
     * Null on anything that is not a Mac, and that is deliberately a failure below rather
     * than a quiet pass: a check that cannot see the symbol list has not found zero bad
     * names, it has found nothing, and the two must never print the same.
     */
    const platform = await (async () => {
      const listed = await shell(`plutil -convert json -o - ${GLYPHS}/name_availability.plist`);
      if (listed.code !== 0) return null;
      const renames = await shell(`plutil -convert json -o - ${GLYPHS}/name_aliases.strings`);
      try {
        const availability = JSON.parse(listed.stdout);
        return {
          since: availability.symbols ?? {},
          releases: availability.year_to_release ?? {},
          // A name Apple has renamed still resolves under the old spelling, so an alias is a
          // real name. Leaving them out would fail perfectly good icons.
          renamed: renames.code === 0 ? JSON.parse(renames.stdout) : {},
        };
      } catch {
        return null;
      }
    })();

    await expect('this machine can say which symbols the platform actually has', async () => {
      return platform !== null && Object.keys(platform.since).length > 5000;
    });

    /**
     * Every icon name written into the phone app, with the file it came from.
     *
     * Literals only. A name assembled at run time cannot be collected from the source at
     * all, and that half of this bug is the one that needs the app on a screen — said
     * plainly here rather than covered up by a check that looks thorough.
     */
    const asked = await (async () => {
      const root = path.join(project.paths.root, 'ios', 'TerminalDeck');
      /** @type {{name: string, where: string}[]} */
      const found = [];
      const walk = async (dir) => {
        for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
          const full = path.join(dir, entry.name);
          if (entry.isDirectory()) await walk(full);
          else if (entry.name.endsWith('.swift')) {
            const swift = await fsp.readFile(full, 'utf8');
            for (const use of swift.matchAll(/\b(?:systemName|systemImage):\s*"([^"]+)"/g)) {
              found.push({ name: use[1], where: path.relative(project.paths.root, full) });
            }
          }
        }
      };
      // A missing folder comes back as an empty list rather than as a thrown error, so the
      // claim underneath fails as its own sentence instead of as a stack trace nobody reads.
      try {
        await walk(root);
      } catch {
        /* whatever was reached is what the claim below judges */
      }
      return found;
    })();

    await expect('the icons the phone app draws were really collected', async () => {
      // The same hole the sweep itself would never notice: a moved folder returns no names,
      // and no names pass every check under this one.
      return asked.length > 40 && new Set(asked.map((use) => use.where)).size > 5;
    });

    await expect('not one of them names a symbol the platform does not have', async () => {
      const missing = asked.filter((use) => !(use.name in platform.since) && !(use.name in platform.renamed));
      return missing.length === 0;
    });

    await expect('and every one of them exists as far back as the oldest phone this app supports', async () => {
      /*
       * The same failure, one step out: a name that exists on this Mac and not on the phone
       * in somebody's pocket draws exactly the same nothing, and it draws it only for them.
       * The floor is read from the project spec rather than written here, so raising the
       * deployment target moves this claim with it.
       */
      const spec = String(await read('ios/project.yml'));
      const floor = /deploymentTarget:\s*\n\s*iOS:\s*"?([0-9.]+)/.exec(spec);
      if (floor === null) return false;
      /** @param {string} version */
      const parts = (version) => version.split('.').map((piece) => Number(piece));
      /** @param {string} a @param {string} b */
      const after = (a, b) => {
        const left = parts(a);
        const right = parts(b);
        for (let i = 0; i < Math.max(left.length, right.length); i++) {
          const one = left[i] ?? 0;
          const other = right[i] ?? 0;
          if (one !== other) return one > other;
        }
        return false;
      };
      const tooNew = asked.filter((use) => {
        const year = platform.since[use.name] ?? platform.since[platform.renamed[use.name]];
        const arrived = year === undefined ? undefined : platform.releases[year]?.iOS;
        return typeof arrived === 'string' && after(arrived, floor[1]);
      });
      return tooNew.length === 0;
    });
  },
};
