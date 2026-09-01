/**
 * A stranger's Windows install opened its update panel onto four stack frames,
 * his own home directory, and the whole releases feed — over a network blip
 * nobody had asked about.
 */
export default {
  name: 'a failed update check reports one sentence when asked, and nothing at all when nobody asked',

  fixed: '2026-08-20',

  because:
    'The library this app updates through appends the entire Atom feed it just fetched onto the text of its own error, '
    + 'and the panel printed what it was handed. On a real Windows machine whose network moved mid-request that was four '
    + 'node_modules frames, `C:\\Users\\…` twice, and the release notes escaped into the message twice over. Two faults, '
    + 'and only one of them is the wording: the thing being reported was not a failure at all. A network moving under a '
    + 'request means ask again, and the check that hit it was a timer\'s, not a person\'s — so the honest answer is to '
    + 'retry twice and then say nothing. It came back three times on three dates, the last from a stranger, because '
    + 'every new failure shape arrives already carrying its own diagnostic and the shortest thing to write is to print '
    + 'it. Its sibling guard reads the shaping function and the banner; this one drives the state machine that decides '
    + 'whether anything is drawn at all.',

  link: '291d093 The update panel was printing the whole releases feed',

  async run({ expect, project, cannotRunHere }) {
    /**
     * Is the bundler this repo builds with installed here at all?
     *
     * Asked first, and kept separate from the build below, because the two
     * failures mean opposite things. No `esbuild` anywhere is a checkout with no
     * `node_modules` — the machine is missing something and this guard has
     * nothing to say about the product either way. A bundle that *fails* is a
     * finding, and it is left below to fail as one.
     */
    const esbuild = await (async () => {
      try {
        return await import('esbuild');
      } catch {
        return null;
      }
    })();

    if (esbuild === null) {
      cannotRunHere(
        'esbuild is not installed in this checkout, and the update controller is TypeScript that has to '
        + 'be built before it can be driven. Run `npm install` in this repo and this will run.',
      );
    }

    /**
     * The real controller, loaded and driven rather than read.
     *
     * `updater.ts` was deliberately written with no Electron value import in it —
     * the one line that reaches for `app` lives in `window-focus.ts` and is
     * injected — which is precisely what lets the shipped state machine be run
     * here, under plain Node, with a fake emitter in place of Squirrel. Nothing
     * below touches the network, the disk or a real update server.
     *
     * Built in memory first rather than imported straight off disk. Node will run
     * a TypeScript file, but it will not resolve the extensionless `./update-error`
     * that this one imports — every relative import in this repo's source is
     * written without an extension — so importing it directly throws before a
     * single question is asked. esbuild resolves those the same way the shipped
     * build does, so what answers below is the code the app ships and not a copy
     * kept in a guard. `electron` and `electron-updater` are left out of the
     * bundle deliberately: neither is imported for a value on any path this
     * drives, and pulling Electron in would destroy the very seam being used.
     * Nothing is written to disk.
     */
    const updates = await (async () => {
      try {
        const built = await esbuild.build({
          stdin: {
            contents:
              'export { createUpdateController, codeSignaturePath, UPDATE_STATE_CHANNEL }'
              + " from './src/main/updates/updater'\n",
            resolveDir: project.paths.root,
            loader: 'ts',
          },
          bundle: true,
          format: 'esm',
          platform: 'node',
          external: ['electron', 'electron-updater'],
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

    await expect('the update controller can still be driven without Electron', async () => {
      // A guard that cannot reach the code it watches must never report that the
      // code is fine. If this fails, either an Electron import has been added to
      // `updater.ts` — and the module's own tests have lost the same seam — or the
      // file no longer builds at all.
      return updates !== null
        && typeof updates.createUpdateController === 'function'
        && typeof updates.codeSignaturePath === 'function'
        && typeof updates.UPDATE_STATE_CHANNEL === 'string';
    });

    /** A packaged, signed macOS build — the only shape that supports updating. */
    const BUNDLE = '/Applications/Terminal Deck.app';
    const EXEC = `${BUNDLE}/Contents/MacOS/Terminal Deck`;
    const FEED = `${BUNDLE}/Contents/Resources/app-update.yml`;

    /**
     * One controller, one fake emitter, one recorded conversation.
     *
     * Fresh for every case on purpose: an automatic check obeys an hourly floor,
     * so two of them through one controller would have the second declined
     * before it ever reached the failure this is about — and a case that never
     * ran would pass by knowing nothing.
     */
    const harness = () => {
      const listeners = { error: [] };
      const calls = { check: 0 };
      const waits = [];
      const pushed = [];
      let rejectWith = null;

      const updater = {
        autoDownload: true,
        autoInstallOnAppQuit: false,
        on(event, listener) {
          (listeners[event] ??= []).push(listener);
          return this;
        },
        async checkForUpdates() {
          calls.check += 1;
          if (rejectWith !== null) throw rejectWith;
          return null;
        },
        async downloadUpdate() {
          return null;
        },
        quitAndInstall() {
          // Counted nowhere because it is never reached: nothing here downloads.
          throw new Error('a guard must never install anything');
        },
      };

      const controller = updates.createUpdateController({
        updater,
        environment: { platform: 'darwin', isPackaged: true, execPath: EXEC, feedConfigPath: FEED },
        broadcast: (channel, state) => pushed.push({ channel, state }),
        // The two files a properly signed, properly packaged build would have.
        fileExists: (file) => file === FEED || file === updates.codeSignaturePath(BUNDLE),
        now: () => 1_000_000,
        // Recorded rather than slept. The ladder is ten seconds of real time and
        // what is under test is its shape, not its duration.
        wait: async (ms) => {
          waits.push(ms);
        },
        // Subscribed to nothing. `start()` is never called either: arming a
        // timer inside a guard is the guard changing what it watches.
        onFocus: () => () => {},
      });

      return {
        controller,
        calls,
        waits,
        pushed,
        failWith: (error) => {
          rejectWith = error;
        },
        emitError: (error) => {
          for (const listener of listeners.error) listener(error);
        },
      };
    };

    /**
     * The four shapes a failed check actually arrives in. Each one is a separate
     * way for the panel to be handed something that is not a sentence.
     */
    const SHAPES = [
      {
        what: 'a feed body glued onto the message',
        // Verbatim from the Windows install on 2026-08-20. Every fault in it is
        // its own thing to strip: the wrapper sentences, the Chromium code, the
        // frames carrying a stranger's home directory, and the feed itself —
        // which arrives on the SAME line as the sentence, so a line split alone
        // would keep all of it.
        thrown: new Error(
          'Cannot parse releases feed: Error: Unable to find latest version on GitHub '
          + '(https://github.com/asadev/terminaldeck/releases/latest), please ensure a production '
          + 'release exists: Error: net::ERR_NETWORK_CHANGED at SimpleURLLoaderWrapper.<anonymous> '
          + '(node:electron/js2c/browser_init:2:135010) at newError (C:\\Users\\Asus\\AppData\\Local\\'
          + 'Programs\\Terminal Deck\\resources\\app.asar\\node_modules\\builder-util-runtime\\out\\'
          + 'error.js:5:19) XML: <?xml version="1.0" encoding="UTF-8"?><feed><entry><content '
          + 'type="html">&lt;h3&gt;Install&lt;/h3&gt;</content></entry></feed>',
        ),
        transient: true,
      },
      {
        what: 'a bare network code',
        thrown: new Error('net::ERR_INTERNET_DISCONNECTED'),
        transient: true,
      },
      {
        what: 'the platform updater refusing the bundle',
        // Squirrel.Mac's own shape: a sentence, then frames that name the path
        // the app is installed at. A person cannot act on either half of that.
        thrown: new Error(
          'Error: Could not get code signature for running application\n'
          + '    at MacUpdater.doDownloadUpdate (/Applications/Terminal Deck.app/Contents/Resources/'
          + 'app.asar/node_modules/electron-updater/out/MacUpdater.js:87:19)',
        ),
        transient: false,
      },
      {
        what: 'an error thrown with a real stack folded into its message',
        // How `builder-util-runtime` re-throws: it builds a new error whose text
        // is the old one's `stack`. The frames below are this file's, made here
        // rather than typed out, so they name a real path on a real machine.
        thrown: new Error(
          `Cannot parse releases feed: ${new Error('The release has no macOS asset.').stack}`,
        ),
        transient: false,
      },
    ];

    /** Everything the panel would have been handed, for one run. */
    const shownBy = (harnessed, state) => {
      const said = [String(state?.message ?? '')];
      for (const one of harnessed.pushed) said.push(String(one.state?.message ?? ''));
      return said.filter((text) => text !== '');
    };

    for (const shape of SHAPES) {
      const run = harness();
      run.failWith(shape.thrown);
      const state = await run.controller.check({ automatic: false });
      const shown = shownBy(run, state);

      await expect(`${shape.what}: the check really failed, so there is something to look at`, async () => {
        // The floor under every claim below it. A fake that was never called, or
        // a controller that swallowed the rejection into `idle`, would let the
        // rest of this pass over a panel nobody proved anything about.
        return run.calls.check >= 1 && state.phase === 'error' && shown.length > 0;
      });

      await expect(`${shape.what}: the panel is handed one short line`, async () => {
        return shown.every((text) => text.length <= 120 && text.split('\n').length === 1);
      });

      await expect(`${shape.what}: no feed, no frame, no path, no error code reaches it`, async () => {
        // Four separate leaks, each of which was on his screen at once. A
        // truncated feed is not more useful than no feed, so the test is
        // presence, not length.
        return shown.every((text) =>
          !text.includes('<')
          && !text.includes('node_modules')
          && !/\bat\s+\S+\s*\(/.test(text)
          && !/net::ERR_|ENOTFOUND|EAI_AGAIN|ECONNRESET/.test(text)
          && !/(\/[A-Za-z0-9._ -]+){2,}/.test(text)
          && !/[A-Za-z]:\\/.test(text));
      });

      await expect(`${shape.what}: and it still says something rather than nothing`, async () => {
        // The other half of the same defect: a panel that strips everything
        // draws a headline over a blank, which reads as the app losing its place.
        return shown.every((text) => text.trim() !== '');
      });
    }

    /* ------------------------------------------------- and the silent half -- */

    const moving = SHAPES[0];

    const asked = harness();
    asked.failWith(moving.thrown);
    const reported = await asked.controller.check({ automatic: false });

    await expect('a check a person pressed for retries twice and then reports', async () => {
      // Twice, not more: the failures this covers settle in seconds or not at
      // all, and a longer ladder only delays the sentence. A button that ends in
      // silence is the dead click this product's own rules forbid.
      return asked.calls.check === 3
        && asked.waits.length === 2
        && asked.waits[0] < asked.waits[1]
        && reported.phase === 'error';
    });

    const timer = harness();
    timer.failWith(moving.thrown);
    const quiet = await timer.controller.check({ automatic: true });

    await expect('a check nobody pressed for retries just as hard and then says nothing', async () => {
      // The half the shaping function cannot do. Nobody asked, so nobody needs
      // telling — but the retries still have to happen, or "says nothing" would
      // just be a check that gave up.
      return timer.calls.check === 3 && quiet.phase === 'idle';
    });

    await expect('and it draws no panel on its way through', async () => {
      return timer.pushed.every((one) => String(one.state?.message ?? '') === ''
        && one.state?.phase !== 'error');
    });

    const raced = harness();
    raced.failWith(moving.thrown);
    const running = raced.controller.check({ automatic: true });
    // The real emitter reports one failure twice — once through the promise and
    // once through the `error` event. Without the same rule on both, the event
    // wins the race and the panel opens anyway, which is how a "fixed" silence
    // came back on a machine that only ever saw the event.
    raced.emitError(moving.thrown);
    const stillQuiet = await running;

    await expect('the error event cannot open the panel the retry loop is holding shut', async () => {
      return stillQuiet.phase === 'idle'
        && raced.pushed.every((one) => one.state?.phase !== 'error');
    });

    const permanent = harness();
    permanent.failWith(SHAPES[2].thrown);
    const spoken = await permanent.controller.check({ automatic: true });

    await expect('a failure that will not fix itself is reported even when nobody asked', async () => {
      // The floor under the two silences above. If this were also quiet, the
      // rule would not be "transient failures stay silent" — it would be
      // "automatic checks never say anything", and a build that can never update
      // would sit there saying so to nobody.
      return permanent.calls.check === 1 && permanent.waits.length === 0 && spoken.phase === 'error';
    });
  },
};
