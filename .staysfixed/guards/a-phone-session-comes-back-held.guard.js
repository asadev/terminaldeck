/**
 * "Two out of six survive, the rest are clean new sessions" — the four that did
 * not come back were the ones his phone had started.
 */
export default {
  name: 'a session started from a phone comes back after a restart, still held inside its folder',

  fixed: '2026-08-27',

  because:
    'His words: *"the biggest problem I have in the Windows version — when I update and restart the application it is '
    + 'losing all of the conversation history, and always I need to log in the account again."* Then, sharper: *"some '
    + 'of the sessions survive, just like maybe two out of six, and the rest are like clean new sessions"* — and that '
    + 'detail is what found it. A session a phone starts is confined: spawned inside a boundary held to the folder that '
    + 'device was granted, with a home of its own. It was never written into the list the app restores from, so on '
    + 'restart only the sessions started at the desk came back and the rest reopened empty. It is one bug with two '
    + 'faces: the agent\'s login lives inside that device home, so forgetting the session lost the login too — *"this '
    + 'logout issue is not just with the Windows application, it is the same with the headless."* His Mac looked fine '
    + 'because his Mac sessions were local and unconfined, which is why it read as a Windows fault for weeks.',

  link: 'd3aefa4 Remember and restore phone-started (confined) sessions; mine-workdir/days/2026-08-27.md',

  async run({ expect, project, run: shell, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /**
     * Lift a function out of a built bundle and hand it back callable.
     *
     * The built file rather than `src`: a guard cannot import TypeScript, and
     * the bundle is what a person installs. Braces are counted rather than
     * parsed — enough for these three bodies, and anything mis-read will not
     * compile, which the floor below turns into a red line instead of a silent
     * pass. `extra` carries anything the body closes over.
     *
     * @param {string} source @param {string} name @param {string} extra
     */
    const lift = (source, name, extra = '') => {
      const at = new RegExp(`(?:async )?function ${name}\\s*\\(`).exec(source);
      if (at === null) return null;
      let depth = 0;
      let i = source.indexOf('{', at.index);
      for (; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}' && (depth -= 1) === 0) break;
      }
      try {
        return new Function(`${extra}\n${source.slice(at.index, i + 1)}\nreturn ${name};`)();
      } catch {
        return null;
      }
    };

    /**
     * The two shipped halves, and both are asked every question below.
     *
     * The desktop is where he saw it and the headless host is where he saw it
     * *again* on the same day — "it is the same with the headless" — and the
     * host is the one that matters most, because a phone's sessions live there.
     * One of them fixed is how this bug spent a week looking like a Windows
     * problem.
     */
    const halves = [
      { what: 'the desktop', file: 'out/main/index.js' },
      { what: 'the headless host', file: 'out/headless/chunk-host.mjs' },
    ];

    for (const half of halves) {
      const source = await fsp.readFile(path.join(project.paths.root, half.file), 'utf8').catch(() => '');

      await expect(`${half.what} is built, so there is something to ask`, async () => {
        // A missing bundle is not a clean run. Everything below is a claim about
        // shipped code, and a file that could not be read would let all of it
        // pass having examined nothing.
        return source !== '';
      });

      const restorableTab = lift(source, 'restorableTab');
      const spawnReconfined = lift(
        source,
        'spawnReconfined',
        // The sentence it throws with reaches for the Windows install and the
        // file system; the sentence is not what is under test and the refusal
        // is, so it is stubbed here and said out loud rather than smuggled.
        'function unconfinedReason(){ return "no mechanism has been measured on this platform" }',
      );
      const restoreOpenSessions = lift(source, 'restoreOpenSessions');

      await expect(`${half.what}'s three restore decisions lifted out of the build and run`, async () => {
        // Run, not matched. A grep proves a name is present; only calling it
        // proves the decision it makes, and it is the decision that shipped
        // wrong.
        return typeof restorableTab === 'function'
          && typeof spawnReconfined === 'function'
          && typeof restoreOpenSessions === 'function';
      });

      await expect(`${half.what} writes a phone's session down, with the device it was held for`, async () => {
        /*
         * The whole of "2 of 6". A confined session used to be lumped in with a
         * launch the app composes for itself: both answered "not a tab", so
         * neither was remembered, so neither came back. The device id is the
         * one thing a restore needs — the folder, the home and the git identity
         * are all rebuilt from it.
         */
        const asked = restorableTab({
          confined: true,
          appComposed: false,
          deviceId: 'device-in-his-pocket',
          requested: undefined,
          inherited: undefined,
          mint: () => 'a-fresh-tab-name',
        });
        return asked.tabKey === 'a-fresh-tab-name' && asked.confineDeviceId === 'device-in-his-pocket';
      });

      await expect(`${half.what} still refuses to remember the copilot`, async () => {
        // The half that was right and must stay right. Restoring one produces a
        // bare Claude session in `<userData>/copilot` — no layer, no tools, no
        // fence — hidden from the sidebar and billing. One machine already had
        // two of them written down.
        const asked = restorableTab({
          confined: false,
          appComposed: true,
          deviceId: undefined,
          requested: undefined,
          inherited: undefined,
          mint: () => 'should-not-be-used',
        });
        return asked.tabKey === null && asked.confineDeviceId === null;
      });

      await expect(`${half.what} would rather forget a confined session than bring it back loose`, async () => {
        // The invariant under the fix: a session with a boundary and no device
        // to rebuild it from could only come back unconfined, so it is not
        // remembered at all. Safe silence, not a boundary that lapses on the
        // next launch.
        const asked = restorableTab({
          confined: true,
          appComposed: false,
          deviceId: undefined,
          requested: undefined,
          inherited: undefined,
          mint: () => 'should-not-be-used',
        });
        return asked.tabKey === null && asked.confineDeviceId === null;
      });

      await expect(`${half.what} remembers a session opened at the keyboard with no device on it`, async () => {
        // The two that always survived. They must keep surviving, and they must
        // not acquire a boundary they never had.
        const asked = restorableTab({
          confined: false,
          appComposed: false,
          deviceId: undefined,
          requested: 'the-tab-it-was',
          inherited: undefined,
          mint: () => 'should-not-be-used',
        });
        return asked.tabKey === 'the-tab-it-was' && asked.confineDeviceId === null;
      });

      await expect(`${half.what} brings a phone's session back inside the same device's home`, async () => {
        /*
         * The second face of the bug: the logout. The agent's credentials live
         * inside the device's own home, so a session brought back outside it is
         * a session signed out — which is what he was reporting when he said he
         * has to log in again after every update. What is asserted is that the
         * guest home is opened for that same device and that its environment
         * and the rebuilt boundary both reach the spawn.
         */
        const seen = { env: null, confine: null, owner: null };
        const meta = await spawnReconfined({ cwd: '/somewhere' }, 'device-in-his-pocket', {
          platform: 'win32',
          confinementKind: () => 'appcontainer',
          openGuestSession: async (deviceId) => ({
            env: { HOME: `/homes/${deviceId}` },
            close: () => undefined,
            started: () => undefined,
          }),
          confineForDevice: (deviceId) => ({ folder: `/granted/${deviceId}` }),
          start: async (_input, env, confine) => {
            seen.env = env;
            seen.confine = confine;
            return { id: 'the-session' };
          },
          noteOwner: (_sessionId, deviceId) => {
            seen.owner = deviceId;
          },
        });
        return meta.id === 'the-session'
          && seen.env?.HOME === '/homes/device-in-his-pocket'
          && seen.confine?.folder === '/granted/device-in-his-pocket'
          && seen.owner === 'device-in-his-pocket';
      });

      await expect(`${half.what} refuses to start it at all where the boundary cannot be rebuilt`, async () => {
        /*
         * The conservative half of the same deal, and the reason this is not
         * simply "always start it". On a Windows machine before its one-time
         * grant there is no mechanism, and the plain starter would silently drop
         * the boundary and run a device's session loose. So it refuses before
         * the spawn and the restore reports why — the session does not come
         * back, and it is never brought back unheld.
         */
        try {
          await spawnReconfined({ cwd: '/somewhere' }, 'device-in-his-pocket', {
            platform: 'win32',
            confinementKind: () => 'none',
            openGuestSession: async () => {
              throw new Error('a guest home must not even be opened when the answer is no');
            },
            confineForDevice: () => ({ folder: '/never' }),
            start: async () => ({ id: 'must-not-start' }),
            noteOwner: () => undefined,
          });
          return false;
        } catch (refusal) {
          return /not started rather than started unconfined/.test(String(refusal.message ?? refusal));
        }
      });

      await expect(`${half.what} hands every remembered session back to the starter, each with its own device`, async () => {
        /*
         * The two decisions above, joined up — the shape of the actual morning:
         * a list holding sessions from the desk and sessions from the phone, all
         * of which have to come back, each as confined as it was. The deps are
         * all injected, so this starts nothing and reads nothing off this
         * machine.
         */
        const handed = [];
        const saved = [
          { cwd: '/w/at-the-desk', provider: 'claude', profileId: null, cols: 80, rows: 24, lastSeenAt: 1, tabKey: 'desk' },
          { cwd: '/w/from-the-phone', provider: 'claude', profileId: null, cols: 80, rows: 24, lastSeenAt: 2, tabKey: 'phone', confineDeviceId: 'device-in-his-pocket' },
        ];
        const result = await restoreOpenSessions({
          enabled: () => true,
          saved: () => saved,
          plan: async (list) => list.map((session) => ({ session, outcome: 'resume', reason: 'it has a conversation' })),
          spawn: async (input, confineToDeviceId) => {
            handed.push({ tab: input.tabKey, resume: input.resume, device: confineToDeviceId });
            return { id: `session-${handed.length}` };
          },
          announce: () => undefined,
          report: () => undefined,
        });
        return result.started.length === 2
          && handed.length === 2
          && handed[0].device === null
          && handed[0].resume === true
          && handed[1].device === 'device-in-his-pocket'
          && handed[1].resume === true
          && handed[1].tab === 'phone';
      });

      await expect(`${half.what} wires that re-confining starter into its own launch restore`, async () => {
        /*
         * And the last link, which is the one a refactor breaks: the restore
         * has to be handed the starter that rebuilds a boundary, not the plain
         * one. A plain `startSession` here brings a phone's sessions back
         * unconfined and the boundary lapses silently on every restart — and
         * this host restarts on its own whenever WSL shuts its distribution
         * down, so that is the ordinary case rather than the rare one.
         */
        const at = source.indexOf('restoreOpenSessions({');
        if (at < 0) return false;
        let depth = 0;
        let i = source.indexOf('{', at);
        for (; i < source.length; i += 1) {
          if (source[i] === '{') depth += 1;
          else if (source[i] === '}' && (depth -= 1) === 0) break;
        }
        const wiring = source.slice(at, i + 1);
        return /spawn: [\w.]*restoreSpawn\b/.test(wiring);
      });
    }

    /* ── and what this cannot do, said out loud ────────────────────────────
     *
     * The report is six sessions, a restart and a count. Not one part of that
     * is a guard's to perform: it takes a phone to start the confined ones, an
     * update-and-restart of a real install, and the platform he was actually on
     * — with its own data directory, never his. A guard may not start a
     * session, and it certainly may not restart the app the other guards are
     * sharing. So the two checks below look for the machines that pass needs.
     * What is missing there is a missing machine, never a broken product, so
     * the second one says the run cannot be answered here instead of failing —
     * a red line about a bug nobody looked for is a false alarm, and a false
     * alarm is worse than a gap that says it is one. They are not a formality:
     * the decisions above are read out of the build, and a decision that reads
     * correctly and behaves otherwise is exactly the shape this arrived in.
     */

    await expect('a phone or simulator is here to start the confined sessions from', async () => {
      // CoreSimulator's own binary, not `xcrun simctl`: `xcrun` hangs on this
      // Mac. Android counts too — the same sessions come from either client.
      const ios = await shell(
        '"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl" list devices booted',
        { timeoutMs: 8000 },
      );
      if (ios.code === 0 && /\(Booted\)/.test(ios.stdout)) return true;
      const android = await shell('adb devices || "$HOME/Library/Android/sdk/platform-tools/adb" devices', { timeoutMs: 8000 });
      return android.stdout.split('\n').some((line) => /^\S+\s+device$/.test(line.trim()));
    });

    // He saw it on Windows and on a headless host, neither of which is this Mac
    // — and on this Mac it does not reproduce at all, because sessions started
    // here are unconfined. So this is not something the product can get wrong;
    // it is something this machine does not have. Said as a refusal rather than
    // an expectation, because failing here would announce that an old bug is
    // back when nothing has looked for it. Named the way the rest of this
    // repository names a real machine to work against, so there is one
    // convention and not two.
    if (String(process.env.TD_SERVER_ADDRESS ?? '').trim() === '') {
      cannotRunHere(
        'no second machine is named to watch the restart on: TD_SERVER_ADDRESS is empty. '
        + 'The count of six sessions only happens where a phone\'s sessions are confined — a Windows install or a '
        + 'headless host — and never on this Mac, where every session is local and unconfined. Set TD_SERVER_ADDRESS '
        + 'to a machine running a host, with a phone or simulator attached, and this last part will run.',
      );
    }
  },
};
