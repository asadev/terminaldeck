/**
 * Twenty-two hooks across three agent CLIs, all pointing at a socket that no
 * longer existed, and nothing on screen said so. Recorded as the third time.
 */
export default {
  name: 'a second copy of the app never claims the hooks the copy in use depends on',

  fixed: '2026-08-19',

  because:
    'The app installs its own callbacks into each agent CLI\'s real settings file — `~/.claude/settings.json`, '
    + '`~/.codex/hooks.json`, `~/.gemini/settings.json`. On every launch it used to look at hooks that did not match '
    + 'the command IT would write, read that as "stale", and silently re-point all of them at itself. So a second copy '
    + '— a dev build, a beta beside the stable one, a test install — took every session event on the machine from the '
    + 'copy the person was actually using, which then went deaf without ever saying so. Separate data directories buy '
    + 'nothing here: these files live in the agent\'s configuration, not the app\'s. It happened three times in one '
    + 'week on this machine, and two installs of one app is an ordinary thing to have. The repair is one rule — hooks '
    + 'that name another copy\'s endpoint config are that copy\'s — and it is a rule a refactor can drop without any '
    + 'test noticing, because the wrong behaviour looks like a feature.',

  link: 'memory/feedback_never_touch_his_working_install.md — the third occurrence',

  async run({ expect, page, project, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const os = await import('node:os');
    const crypto = await import('node:crypto');
    const { pathToFileURL } = await import('node:url');
    const { createRequire } = await import('node:module');

    /**
     * The real module — compiled the way the app compiles it, then loaded and RUN.
     *
     * Nothing in this guard reads the source as text and matches strings against
     * it. Every claim below is answered by executing the shipped rule against
     * real files on disk, because a grep cannot tell a use from a mention in a
     * comment, and on this project that has already cost a night of failures
     * against tests that were only reading their own words back.
     *
     * Why it is compiled here rather than imported, and rather than taken out of
     * `out/`:
     *
     *  - Importing `src/main/hooks.ts` directly cannot even start. TypeScript
     *    source in this repo names its dependencies without a file extension
     *    (`from './hook-server'`, `from '../shared/brand'`) and Node's ESM
     *    loader will not resolve that, so the import threw before this guard
     *    asked a single question.
     *  - Neither shipped bundle in `out/` can be entered from here either:
     *    `out/main/index.js` is CommonJS that calls `require('electron')` before
     *    it runs a line of its own, and `out/headless/chunk-host.mjs` carries
     *    this module inlined but exports none of it.
     *
     * So the same compiler the build uses — the project's own esbuild, which is
     * what electron-vite runs to produce `out/` — is pointed at the same entry
     * point, and the result is imported. This is the compiled article, built
     * from the source the next build will ship, not a description of it.
     */
    const requireFromProject = createRequire(path.join(project.paths.root, 'package.json'));

    let esbuild;
    try {
      esbuild = await import(pathToFileURL(requireFromProject.resolve('esbuild')).href);
    } catch {
      /*
       * The toolchain is missing from this checkout, not the rule from the app.
       * Nothing has been claimed yet, so nothing is being hushed: without a
       * compiler there is no way to run the shipped rule at all, and a guard
       * that answered anyway would be answering about itself.
       */
      cannotRunHere(
        'the project\'s own compiler is not installed in this checkout — `esbuild`, the bundler electron-vite '
        + `builds \`out/\` with, could not be resolved from ${project.paths.root}. Run \`npm install\` there and `
        + 'this guard will run.',
      );
    }

    /**
     * Built into a directory of this guard's own, and imported out of it.
     *
     * A build failure here is not caught and is not softened: the main process
     * failing to compile is a real answer to a real question, and it belongs on
     * the report rather than behind a reassuring pass.
     */
    const buildDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'td-guard-hooks-build-'));
    let hooks;
    try {
      const outfile = path.join(buildDir, 'hooks.mjs');
      await esbuild.build({
        entryPoints: [path.join(project.paths.root, 'src/main/hooks.ts')],
        outfile,
        bundle: true,
        format: 'esm',
        // `platform: 'node'` leaves the `node:` builtins external on its own.
        // Nothing in this module's graph imports `electron` today — that is why
        // the rule can be run outside the app at all — and it is named external
        // so that if one ever does, this fails on a missing import rather than
        // quietly bundling Electron's stub and answering from it.
        platform: 'node',
        target: 'node20',
        external: ['electron'],
        absWorkingDir: project.paths.root,
        logLevel: 'silent',
      });
      // Nothing in this module graph defers work to a dynamic import or a
      // require, so the file has no more to give once `import()` has resolved
      // and the directory can go straight away.
      hooks = await import(pathToFileURL(outfile).href);
    } finally {
      await fsp.rm(buildDir, { recursive: true, force: true });
      // The compiler keeps a helper process alive; this guard is a visitor on
      // somebody's machine and does not leave one running behind it.
      try {
        esbuild.stop?.();
      } catch {
        // Nothing about tidying up is worth a verdict.
      }
    }

    await expect('the rule that decides whose hooks these are is still there to ask', async () => {
      // A guard that cannot reach the rule must never report that the rule is
      // being followed. A rename here is itself worth stopping a release for:
      // the two startup passes below are the only callers.
      return typeof hooks.staleHooksBelongToAnotherCopy === 'function'
        && typeof hooks.syncInstalledHooks === 'function'
        && typeof hooks.installHooksWhereConfigured === 'function'
        && typeof hooks.hookCommand === 'function'
        && Array.isArray(hooks.HOOK_PROVIDER_IDS)
        && hooks.HOOK_PROVIDER_IDS.length === 3;
    });

    /* ------------------------------------------------ the files on this Mac -- */

    /**
     * The three real configuration files, and what they hash to right now.
     *
     * Taken first, so that everything this guard does afterwards can be proved
     * to have left them alone. It cannot be taken before the app under check
     * launched — that already happened — which is why the ownership claim
     * further down exists as well: it asks who the hooks on this machine
     * currently belong to, and the answer must not be this run.
     */
    const realFiles = hooks.HOOK_PROVIDER_IDS.map((id) => ({
      id,
      file: path.join(os.homedir(), ...hooks.HOOK_PROVIDERS[id].path),
    }));

    const digestOf = async (file) => {
      const body = await fsp.readFile(file).catch(() => null);
      // Absence is an ordinary state — the CLI may not be installed — and it is
      // a value that compares, so it belongs in the same slot as a hash.
      return body === null ? 'absent' : crypto.createHash('sha256').update(body).digest('hex');
    };

    const before = new Map();
    for (const one of realFiles) before.set(one.id, await digestOf(one.file));

    /* ------------------------------------------------------- a second copy -- */

    /**
     * Everything below runs against a scratch home of this guard's own.
     *
     * Not a convenience: the whole subject here is a startup pass writing into
     * files it does not own, and a guard that proved the rule by launching a
     * second copy of the app against the real home would perform the damage it
     * is watching for on the machines where the rule had been lost. So the pass
     * is run directly, with a home it may write to freely, and the real files
     * are only ever read.
     */
    const scratch = await fsp.mkdtemp(path.join(os.tmpdir(), 'td-guard-hooks-'));

    /** One copy of the app's endpoint, as the file records it. */
    const endpointAt = (root, platform) =>
      platform === 'win32'
        ? {
            socketPath: `\\\\.\\pipe\\terminaldeck-${path.basename(root)}`,
            configPath: `${root}\\hook\\hook-endpoint.json`,
            clientPath: `${root}\\hook\\hook-client.ps1`,
            token: 'not-a-real-token',
          }
        : {
            socketPath: `${root}/hook/hook.sock`,
            configPath: `${root}/hook/hook-endpoint.conf`,
            clientPath: null,
            token: 'not-a-real-token',
          };

    // `SystemRoot` is the only environment value the Windows command shape reads,
    // and it is supplied rather than borrowed so the same bytes are written
    // whichever machine this runs on.
    const ENV = { SystemRoot: 'C:\\Windows' };

    /** A settings file holding one copy's complete, well-formed install. */
    const settingsHolding = (id, endpoint, platform) => {
      const spec = hooks.HOOK_PROVIDERS[id];
      const events = {};
      for (const event of spec.events) {
        events[event] = [
          { matcher: '', hooks: [{ type: 'command', command: hooks.hookCommand(id, event, endpoint, platform, ENV) }] },
        ];
      }
      return `${JSON.stringify({ hooks: events }, null, 2)}\n`;
    };

    /** A home with all three CLIs set up and all three already hooked. */
    const homeHolding = async (name, endpoint, platform) => {
      const home = path.join(scratch, name);
      for (const id of hooks.HOOK_PROVIDER_IDS) {
        const file = path.join(home, ...hooks.HOOK_PROVIDERS[id].path);
        await fsp.mkdir(path.dirname(file), { recursive: true });
        await fsp.writeFile(file, settingsHolding(id, endpoint, platform), { mode: 0o600 });
      }
      return home;
    };

    const digestsUnder = async (home) => {
      const out = new Map();
      for (const id of hooks.HOOK_PROVIDER_IDS) {
        out.set(id, await digestOf(path.join(home, ...hooks.HOOK_PROVIDERS[id].path)));
      }
      return out;
    };

    try {
      /*
       * POSIX first, because that is the ground the damage was measured on: his
       * own Mac, three CLIs, twenty-two entries.
       */
      const inUse = endpointAt('/Users/somebody/Library/Application Support/terminaldeck', 'darwin');
      const arriving = endpointAt('/Users/somebody/Library/Application Support/terminaldeck-beta', 'darwin');
      const home = await homeHolding('posix-home', inUse, 'darwin');
      const context = {
        home,
        backupDir: path.join(scratch, 'posix-backups'),
        endpoint: arriving,
        platform: 'darwin',
        env: ENV,
      };

      await expect('the seeded machine really does hold another copy\'s hooks, complete', async () => {
        // The floor, before anything is claimed about leaving them alone. A home
        // whose files were unreadable, or held no hooks at all, would let every
        // claim below pass over nothing — the one failure this whole tool exists
        // to prevent. `stale` is the correct reading here: installed, tagged as
        // ours, aimed somewhere other than this copy.
        return hooks.HOOK_PROVIDER_IDS.every((id) => {
          const status = hooks.readStatus(context, id);
          return status.fileExists
            && status.state === 'stale'
            && status.staleEvents.length === hooks.HOOK_PROVIDERS[id].events.length;
        });
      });

      await expect('the arriving copy recognises all three as somebody else\'s', async () => {
        // Decided from the endpoint config path written into the command, not
        // from probing the socket — a copy that is merely closed still owns its
        // hooks, and liveness would hand them to whoever launched last, which is
        // the behaviour being removed.
        return hooks.HOOK_PROVIDER_IDS.every((id) => hooks.staleHooksBelongToAnotherCopy(context, id) === true);
      });

      const posixBefore = await digestsUnder(home);
      hooks.syncInstalledHooks(context);
      hooks.installHooksWhereConfigured(context);
      const posixAfter = await digestsUnder(home);

      await expect('and both startup passes leave every one of the three files byte-identical', async () => {
        // Two passes, because there are two: the desktop repairs on launch and
        // the headless host installs where a CLI is already set up. Either one
        // alone re-pointing the file is the whole bug, and a machine can be
        // running both.
        return hooks.HOOK_PROVIDER_IDS.every((id) => posixAfter.get(id) === posixBefore.get(id));
      });

      /*
       * The Windows command grammar. Same rule, same two passes, a different
       * spelling of the one thing the rule reads.
       */
      const winInUse = endpointAt('C:\\Users\\Asus\\AppData\\Roaming\\terminaldeck', 'win32');
      const winArriving = endpointAt('C:\\Users\\Asus\\AppData\\Roaming\\terminaldeck-beta', 'win32');
      const winHome = await homeHolding('win-home', winInUse, 'win32');
      const winContext = {
        home: winHome,
        backupDir: path.join(scratch, 'win-backups'),
        endpoint: winArriving,
        platform: 'win32',
        env: ENV,
      };

      await expect('a Windows machine\'s hooks are recognised as another copy\'s too', async () => {
        /*
         * FOUND WHILE WRITING THIS, AND NOT FIXED HERE — Terminal Deck is the
         * thing being watched, not the thing being edited.
         *
         * The ownership rule reads the endpoint config path out of the installed
         * command, and it looks for one filename: `hook-endpoint.conf`. That is
         * the POSIX name. On Windows the same file is `hook-endpoint.json`
         * (`WINDOWS_CONFIG_FILE` in `hook-server.ts`), so the scan finds nothing,
         * an empty result is read as "written before the token moved out of
         * line — ours to migrate", and a second copy on Windows re-points the
         * running copy's hooks exactly as every copy used to.
         *
         * This claim is written the way the rule is meant to work rather than
         * the way it currently does, because a guard that agrees with the defect
         * is a guard that will keep agreeing with it.
         */
        return hooks.HOOK_PROVIDER_IDS.every((id) => hooks.staleHooksBelongToAnotherCopy(winContext, id) === true);
      });

      const winBefore = await digestsUnder(winHome);
      hooks.syncInstalledHooks(winContext);
      hooks.installHooksWhereConfigured(winContext);
      const winAfter = await digestsUnder(winHome);

      await expect('and a Windows machine\'s three files come through byte-identical as well', async () => {
        return hooks.HOOK_PROVIDER_IDS.every((id) => winAfter.get(id) === winBefore.get(id));
      });

      /* ------------------------------------------------------------ the floor -- */

      /**
       * A file the pass genuinely should rewrite.
       *
       * Without this every claim above could be satisfied by a startup pass that
       * does nothing at all — which would be a different way of breaking the
       * same feature, and would look identical from outside. These commands
       * carry the marker and no endpoint config path, which is the shape written
       * before the token moved out of the command line: those really are ours to
       * migrate, and migrating them is why the pass runs.
       */
      const oldHome = path.join(scratch, 'pre-token-home');
      for (const id of hooks.HOOK_PROVIDER_IDS) {
        const spec = hooks.HOOK_PROVIDERS[id];
        const events = {};
        for (const event of spec.events) {
          events[event] = [
            {
              matcher: '',
              hooks: [{
                type: 'command',
                command: `curl -s -X POST http://127.0.0.1:41234/hook/${id}/${event} 2>/dev/null || true ${hooks.HOOK_MARKER}`,
              }],
            },
          ];
        }
        const file = path.join(oldHome, ...spec.path);
        await fsp.mkdir(path.dirname(file), { recursive: true });
        await fsp.writeFile(file, `${JSON.stringify({ hooks: events }, null, 2)}\n`, { mode: 0o600 });
      }

      const oldContext = {
        home: oldHome,
        backupDir: path.join(scratch, 'pre-token-backups'),
        endpoint: arriving,
        platform: 'darwin',
        env: ENV,
      };

      const oldBefore = await digestsUnder(oldHome);
      hooks.syncInstalledHooks(oldContext);
      const oldAfter = await digestsUnder(oldHome);

      await expect('the same pass still repairs hooks that name no copy at all', async () => {
        // If this stops being true the silence above is a pass that has stopped
        // working rather than a pass that is being careful, and every machine
        // upgrading from an older build keeps firing into nothing for ever.
        return hooks.HOOK_PROVIDER_IDS.every((id) => oldAfter.get(id) !== oldBefore.get(id));
      });
    } finally {
      await fsp.rm(scratch, { recursive: true, force: true });
    }

    /* ------------------------------------------- and the machine underneath -- */

    await expect('this guard has not touched one byte of the real agent configs', async () => {
      // Said out loud because the subject is a program writing into somebody's
      // dotfiles. A guard allowed to do that while checking that nothing does it
      // is not a guard anybody can trust.
      for (const one of realFiles) {
        if ((await digestOf(one.file)) !== before.get(one.id)) return false;
      }
      return true;
    });

    /**
     * Where this running copy keeps its own endpoint config.
     *
     * The app under check is itself a second copy — every run is given a
     * settings folder of its own on the command line — sitting beside whatever
     * the person has installed, on their real home directory. So the question
     * the bug asks can be put to the machine directly: do the hooks on it point
     * into this run's data directory?
     */
    const said = JSON.parse(String(await page.evaluate(
      "(async()=>{try{const paths=await window.deck.settingsPaths();return JSON.stringify({paths})}"
      + "catch(e){return JSON.stringify({error:String(e&&e.message||e)})}})()",
    )));

    const userData = Array.isArray(said.paths)
      ? String((said.paths.find((entry) => entry.key === 'userData') || {}).path ?? '')
      : '';

    await expect('the running copy can still say which folder is its own', async () => {
      return userData !== '' && path.isAbsolute(userData);
    });

    /**
     * Every endpoint config path named by a hook of ours in the real files.
     *
     * Scanned here rather than through the module's own reader for one reason:
     * that reader looks for the POSIX filename only (see the Windows claim
     * above), and a guard asking "who owns these" must not inherit the blind
     * spot it is checking for. Both spellings are read.
     */
    const claimedBy = [];
    for (const one of realFiles) {
      const raw = await fsp.readFile(one.file, 'utf8').catch(() => null);
      if (raw === null) continue;
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        // A config this app cannot parse is one it never rewrites either, so it
        // is not evidence of anything and is skipped rather than reported.
        continue;
      }
      const groups = parsed && typeof parsed.hooks === 'object' && parsed.hooks !== null ? parsed.hooks : {};
      for (const value of Object.values(groups)) {
        if (!Array.isArray(value)) continue;
        for (const group of value) {
          for (const entry of (group && Array.isArray(group.hooks) ? group.hooks : [])) {
            const command = typeof entry?.command === 'string' ? entry.command : '';
            if (!command.includes(hooks.HOOK_MARKER)) continue;
            for (const found of command.matchAll(/'([^']*hook-endpoint\.(?:conf|json))'/g)) {
              claimedBy.push({ id: one.id, config: found[1] });
            }
          }
        }
      }
    }

    await expect('no hook on this machine has been re-pointed at the copy under check', async () => {
      // Nothing installed is a perfectly ordinary answer on a machine whose
      // agent CLIs this app has never been asked to hook, and it is reported as
      // such rather than dressed up: with no entries there is nothing here to
      // take, and the claims against the scratch home above are what carry this
      // guard. With entries, this is the bug measured on the real thing.
      if (claimedBy.length === 0) return true;
      return claimedBy.every((one) => !one.config.startsWith(`${userData}${path.sep}`));
    });
  },
};
