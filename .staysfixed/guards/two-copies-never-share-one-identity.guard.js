/**
 * A second copy was launched with a data folder of its own, precisely so it
 * could not disturb the installed one. The folder was silently discarded, both
 * processes landed on one relay identity, and they spent hours evicting each
 * other at the relay — while his phone showed "Waiting for approval".
 */
export default {
  name: 'two copies of this app never share one relay identity',

  fixed: '2026-08-16',

  because:
    'A machine is one host at the relay, and the relay keeps exactly one host per identity. Two processes that share '
    + 'one `relay-identity.json` therefore share one slot, and each knocks the other off it — every handoff tearing '
    + 'down every device channel, so a phone connects and drops every ten to forty-five seconds and never stays. Both '
    + 'times it was a folder, not a network. The first: a second copy was started with `--user-data-dir` so that it '
    + 'could not touch the installed one, and the code that pins the folder against a rename overwrote the flag — '
    + 'turning `--user-data-dir=/tmp/probe` into `/tmp/terminaldeck`, leaving the named folder empty and both processes '
    + 'reading one identity file. The second: the headless host writing into the desktop app’s own folder. The screens '
    + 'said "Waiting for approval" and "Too many failed attempts"; nothing anywhere was in an error state, and '
    + 'restarting kept appearing to fix it. Two answers to one question — the folder somebody named, and the folder the '
    + 'app pins to — with the pin written to win, is a shape that comes back every time a new way to launch this exists.',

  link: '9ede37c Pairing: one copy per machine — the --user-data-dir that was thrown away',

  async run({ expect, page, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const os = await import('node:os');

    /**
     * The product's own folder rules, loaded and run rather than read.
     *
     * All three are pure — the flag reader takes an argument list, the folder
     * maths takes a platform, a home and an environment, and the identity is a
     * file name — so they answer here exactly as they answer at launch. Bundled
     * in memory and imported as a data URL: nothing is written into the repo,
     * and nothing below ever opens, reads or moves a real identity file. Those
     * are keys; a guard has no business near them.
     */
    const store = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents:
              "export { userDataFlag, pinUserData } from './src/main/user-data'\n"
              + "export { nodePaths } from './src/main/platform/paths'\n"
              + "export { HOST_IDENTITY_FILE } from './src/main/remote/host-identity'\n"
              + "export { BRAND } from './src/shared/brand'",
            resolveDir: project.paths.root,
            loader: 'ts',
          },
          bundle: true,
          format: 'esm',
          platform: 'node',
          write: false,
          logLevel: 'silent',
        });
        const bytes = Buffer.from(built.outputFiles[0].text).toString('base64');
        return await import(`data:text/javascript;base64,${bytes}`);
      } catch {
        // Null rather than a throw, so the claim below fails as its own sentence
        // instead of as a stack trace nobody reads.
        return null;
      }
    })();

    await expect('the folder rules could really be loaded and asked', async () => {
      return store !== null
        && typeof store.userDataFlag === 'function'
        && typeof store.pinUserData === 'function'
        && typeof store.nodePaths === 'function';
    });

    await expect('a folder named on the command line is read, in either spelling', async () => {
      // Read out of the argument list rather than asked of the runtime, and that
      // is the point: the runtime folds the flag into its own answer, and after
      // that there is no way to tell a folder somebody *chose* from one that was
      // merely derived — which is the only distinction that matters here.
      return store.userDataFlag(['--user-data-dir=/somewhere/else']) === '/somewhere/else'
        && store.userDataFlag(['--user-data-dir', '/somewhere/else']) === '/somewhere/else';
    });

    await expect('and nothing that is not a folder is read as one', async () => {
      // A flag with nothing after it, a flag followed by the next flag, and no
      // flag at all. Each of these read as a choice would suppress the pin for a
      // copy that never asked for it, which is the same bug pointing the other
      // way: the installed app quietly starting over in an empty folder.
      return store.userDataFlag(['--user-data-dir=']) === null
        && store.userDataFlag(['--user-data-dir', '--other-flag']) === null
        && store.userDataFlag(['--some-other-flag']) === null
        && store.userDataFlag([]) === null;
    });

    /**
     * What the pin does with a folder somebody named, and with none.
     *
     * Run against a made-up app in a scratch room under the system's temporary
     * folder — the real one is never handed in, nothing of the person's is
     * pointed at it, and the room is removed on every path out. The argument
     * list is the one input the pin reads from the process rather than from its
     * caller, so it is swapped for the length of one synchronous call and put
     * back in a `finally`.
     */
    const pinning = await (async () => {
      const room = await fsp.mkdtemp(path.join(os.tmpdir(), 'staysfixed-user-data-'));
      try {
        const derived = path.join(room, 'A Display Name');
        const chosen = path.join(room, 'chosen-by-hand');
        const slug = path.join(room, store.BRAND.id);
        /** Whether the pin made a folder of its own beside the derived one. */
        const there = async () => {
          try {
            await fsp.access(slug);
            return true;
          } catch {
            return false;
          }
        };
        await fsp.mkdir(derived, { recursive: true });
        /** @param {string[]} args */
        const pinWith = (args) => {
          const argv = process.argv;
          let setTo = null;
          process.argv = [argv[0] ?? 'node', 'main.js', ...args];
          try {
            store.pinUserData({ getPath: () => derived, setPath: (_key, value) => { setTo = value; } });
          } finally {
            process.argv = argv;
          }
          return setTo;
        };
        const named = pinWith([`--user-data-dir=${chosen}`]);
        const spaced = pinWith(['--user-data-dir', chosen]);
        const derivedAnyway = await there();
        const nobody = pinWith([]);
        return { chosen, slug, named, spaced, derivedAnyway, nobody, pinned: await there() };
      } finally {
        // Removed on every path out. A guard that leaves folders behind is a
        // guard that fills somebody's disk one release at a time.
        await fsp.rm(room, { recursive: true, force: true });
      }
    // Null rather than a throw when the bundle above never loaded, so the two
    // claims under this fail as their own sentences.
    })().catch(() => null);

    await expect('a folder somebody named is obeyed, and nothing is derived beside it', async () => {
      /*
       * The shipped fault, exactly. The pin ran after the runtime had already
       * resolved the flag, so it rewrote `--user-data-dir=/tmp/probe` into
       * `/tmp/terminaldeck` — the named folder left empty, and the second copy
       * sitting on the first one's identity file. Naming a folder on the command
       * line is the most deliberate statement of intent there is, and the pin
       * exists to stop a *rename* moving data without anybody's knowledge, which
       * is the opposite thing.
       */
      return pinning !== null && pinning.named === null && pinning.spaced === null && pinning.derivedAnyway === false;
    });

    await expect('and with nobody naming one, the folder is still pinned by the slug', async () => {
      // The other half, which must survive the fix above. The runtime derives
      // this folder from the *display* name, so a rename silently moves every
      // project, preference and window size to a new folder and starts the
      // person over in an empty one. It has already happened here twice.
      return pinning !== null && pinning.nobody === pinning.slug && pinning.pinned === true;
    });

    await expect('the folder is worked out from the home it is given, so two homes are two identities', async () => {
      // Every input a parameter, which is what makes this answerable at all:
      // the host runs on a Linux server this repository is never built on, and
      // a branch on the running platform can only ever be exercised on the
      // machine it was written on.
      const one = store.nodePaths({ platform: 'darwin', home: '/Users/one', env: {} }).userData();
      const two = store.nodePaths({ platform: 'darwin', home: '/Users/two', env: {} }).userData();
      const server = store.nodePaths({ platform: 'linux', home: '/home/one', env: { XDG_DATA_HOME: '/srv/data' } }).userData();
      return one !== two && one !== server && two !== server;
    });

    await expect('and the identity is one file, under whichever folder that turned out to be', async () => {
      // A bare name, so it can only ever be joined onto a state folder. An
      // absolute path here would put every copy on one file however carefully
      // their folders were kept apart — the bug restored one layer down.
      const file = String(store.HOST_IDENTITY_FILE);
      return file !== '' && path.basename(file) === file && path.isAbsolute(file) === false;
    });

    /** Where the copy under test keeps its own data, asked of the copy itself. */
    const dataDir = String(await page.evaluate(
      "(async()=>{try{const rows=await window.deck.settingsPaths();"
      + "const row=(Array.isArray(rows)?rows:[]).find(r=>r&&r.key==='userData');"
      + "return row&&typeof row.path==='string'?row.path:''}catch(e){return ''}})()",
    ));

    await expect('the running copy can still say where its own data lives', async () => {
      return dataDir !== '' && path.isAbsolute(dataDir);
    });

    await expect('and this copy is not sitting in the installed copy’s folder', async () => {
      /*
       * The whole bug, measured on a running second copy rather than argued
       * about. This app is being opened here beside whatever is installed on
       * this machine, which is exactly the arrangement that fought at the relay
       * for hours — so if the flag were being discarded again, this copy would
       * be in the folder below and reading the installed copy's identity file.
       *
       * Resolved through the file system on both sides, because a scratch folder
       * that is a symbolic link to the installed one passes a string comparison
       * and shares every byte.
       */
      const installed = store.nodePaths({}).userData();
      /** @param {string} at */
      const real = async (at) => {
        try {
          return await fsp.realpath(at);
        } catch {
          // Not there at all is a fine answer: a folder that does not exist is
          // certainly not the one this copy is using.
          return at;
        }
      };
      return (await real(dataDir)) !== (await real(installed));
    });

    /*
     * WHAT THIS GUARD CANNOT REACH, and one hole it deliberately does not cover.
     *
     * The report is a phone that stays attached: fifteen quiet minutes with zero
     * drops, where before the fix they came every ten to forty-five seconds.
     * That needs a real phone and a live relay, and neither can be asked for
     * from here.
     *
     * And the second half of this bug is still reachable on macOS. The headless
     * host works its folder out from the environment, and on a Mac that lands on
     * `~/Library/Application Support/<slug>` — the same folder the desktop app
     * pins to — so a host started here would read the desktop app's identity
     * file and the two would take turns at the relay, which is the 2026-08-28
     * shape exactly. The host's own takeover only sees other hosts; the desktop
     * app is not in its record. That is written down rather than asserted,
     * because a guard is not the place to change the product it watches, and a
     * red line for a decision nobody has taken yet is a guard that gets switched
     * off. `only-one-copy-answers-for-this-machine` covers the host-meets-host
     * half.
     */
  },
};
