/**
 * `browser install` downloaded 183 MB, printed a version, exited 0 — and the browser
 * could not execute a single instruction.
 */
export default {
  name: 'an install that reports success means the browser it installed really starts',

  fixed: '2026-08-22',

  because:
    'Measured on a rented Ubuntu box, not reasoned about: the command that puts a browser on a server downloaded '
    + '183 MB, matched the checksum, unpacked 372 MB, printed the version and exited cleanly, while thirteen of the '
    + 'shared libraries the program needs were not on that machine. Printing a version is not a start — it prints a '
    + 'string and exits before a zygote, a crash handler, a sandbox or a renderer exists — so with a deliberately '
    + 'broken helper the version still printed and exited 0 and every real start died. The advice underneath it was '
    + 'one hardcoded Ubuntu line shown to people on every other kind of Linux, and behind that a browser that cannot '
    + 'run could take the whole server host down and every session with it. It comes back because checking a version '
    + 'string is the cheaper check to write, and it is green over a browser that has never run.',

  link: '39a4891 An install that says it worked has to mean the browser starts',

  async run({ expect, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const os = await import('node:os');
    const url = await import('node:url');

    /**
     * The install, as the server actually ships it.
     *
     * `out/headless/chunk-version.mjs` is the built host — the same code
     * `terminaldeck browser install` runs on a box. Its exports are one-letter
     * names, so the letters are read out of the CLI's own import line rather
     * than guessed: the bundle names them, and a bundler that renumbers them
     * renames both sides at once.
     */
    const built = path.resolve(project.paths.root, 'out/headless/chunk-version.mjs');
    const cli = await fsp.readFile(path.resolve(project.paths.root, 'out/headless/cli.mjs'), 'utf8').catch(() => '');
    const letters = new Map(
      [...cli.matchAll(/([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)/g)].map((found) => [found[2], found[1]]),
    );

    /** @type {Record<string, any> | null} */
    let host = null;
    await expect('the host that installs a browser on a server is built and readable', async () => {
      // A guard that cannot look must never report that everything is fine, so
      // this fails rather than passing quietly. `npm run build:headless` is what
      // it is asking for.
      host = await import(url.pathToFileURL(built).href).catch(() => null);
      return host !== null && letters.has('installChromium');
    });

    const named = (what) => /** @type {any} */ (host)[String(letters.get(what))];
    const installChromium = named('installChromium');
    const chromiumLibraryHint = named('chromiumLibraryHint');
    const detectPackageFamily = named('detectPackageFamily');
    const CHROMIUM_PATH_ENV = named('CHROMIUM_PATH_ENV');

    await expect('the install, the hint and the family reader are all still there to be asked', async () => {
      return (
        typeof installChromium === 'function'
        && typeof chromiumLibraryHint === 'function'
        && typeof detectPackageFamily === 'function'
        && typeof CHROMIUM_PATH_ENV === 'string'
      );
    });

    /**
     * A program that starts, says nothing and exits 0 — the bug in one file.
     *
     * `/bin/echo` is the shape that shipped: it runs, it exits cleanly, and it
     * is not a browser. Where there is no `/bin/echo` this machine's own Node
     * stands in; it exits on the browser's flags instead of succeeding, which
     * still proves the launch was demanded and still never answers a command.
     */
    const notABrowser = (await fsp.stat('/bin/echo').catch(() => null)) === null ? process.execPath : '/bin/echo';

    /**
     * A folder of this guard's own, and the reason it is passed in.
     *
     * `installChromium` writes its verification profile under whatever root it
     * is given, and the default root is the app's real browser folder. A guard
     * that wrote there would be changing the product it is watching. Nothing
     * here reaches the network either: the side-load door is answered before
     * anything is fetched, so no download starts and nothing is installed.
     */
    const scratch = await fsp.mkdtemp(path.join(os.tmpdir(), 'td-guard-install-'));
    try {
      const sideload = { [CHROMIUM_PATH_ENV]: notABrowser };

      /** @type {any} */
      let asked = null;
      await expect('an install that has to prove the browser starts refuses one that cannot', async () => {
        asked = await installChromium({ env: sideload, root: scratch, verify: 'run' });
        return asked !== null && asked.ok === false;
      });

      await expect('and the refusal is a sentence, not a stack trace', async () => {
        // Two of this command's messages went out as raw traces. A person on a
        // server has a terminal and no debugger, and `at Object.<anonymous>`
        // tells them nothing they can act on.
        const why = String(asked?.why ?? '');
        return why.length > 0 && /\n\s+at\s/.test(why) === false;
      });

      await expect('the cheap check would have called that same browser installed', async () => {
        // The floor under the check above. Same binary, same call, only the
        // proof weakened to the one the bug shipped with — and it comes back
        // "installed". If this ever stops being true the refusal above may be
        // coming from somewhere harmless, like the path not existing, and would
        // no longer be evidence that a launch was demanded.
        const cheaply = await installChromium({ env: sideload, root: scratch, verify: 'linkage' });
        return cheaply?.ok === true;
      });
    } finally {
      await fsp.rm(scratch, { recursive: true, force: true });
    }

    /**
     * Which command a box of each kind is told to run.
     *
     * `detectPackageFamily` takes the "is this command here" question as a seam
     * for exactly this reason: every branch of it belongs to a machine this
     * repository is never built on, so the only place it can be exercised is
     * from a Mac, with the answers supplied.
     */
    const families = [
      { box: 'an Alpine box', owns: 'apk', says: CHROMIUM_PATH_ENV },
      { box: 'a Fedora box', owns: 'dnf', says: 'dnf' },
      { box: 'a CentOS box', owns: 'yum', says: 'yum' },
      { box: 'an Arch box', owns: 'pacman', says: 'pacman' },
      { box: 'a SUSE box', owns: 'zypper', says: 'zypper' },
      { box: 'a Debian box', owns: '', says: 'apt-get' },
    ];

    for (const family of families) {
      await expect(`${family.box} is told to install them with its own package manager`, async () => {
        const hint = String(chromiumLibraryHint(detectPackageFamily((command) => command === family.owns)));
        // Both halves matter. Naming the right manager is the fix; not naming
        // apt is the bug — one hardcoded Ubuntu line was printed to everybody,
        // and a line that cannot run on the box reading it is worse than none.
        const borrowed = family.says !== 'apt-get' && /\bapt(-get)?\b/.test(hint);
        return hint.includes(family.says) && borrowed === false;
      });
    }
  },
};
