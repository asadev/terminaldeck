/**
 * He typed the six digits, the screen cleared, and no machine ever appeared.
 * Two copies were knocking each other off one slot every 25 to 55 seconds,
 * forever, with nothing in an error state in either window.
 */
export default {
  name: 'only one copy answers for this machine, and a second host takes the slot over instead of fighting for it',

  fixed: '2026-08-28',

  because:
    'Twice, on two different halves of the product. Asad could not pair his phone: two copies of the app were running '
    + 'from one settings folder, so they shared one relay identity, and the relay keeps exactly one host per identity — '
    + 'each copy evicted the other every 25 to 55 seconds, forever. The slot is claimed cleanly, so every measurement '
    + 'aimed at it came back healthy; a phone dialled the shared name and was routed to whichever copy held it at that '
    + 'instant, and half the time that was the copy with no code on screen, which refuses the handshake silently and by '
    + 'design. Twelve days later the same shape came back on the server half: an orphaned host process, started outside '
    + 'the service manager, kept the identity — and restarting never helped, because the daemon **refused to start** '
    + 'while a host was running rather than taking over, so nothing a person could type could clear it. Every new way to '
    + 'run this — systemd, a bare shell, a dev build, an installer run while the app is open — is a new way for two of '
    + 'them to exist, and neither of them says a word about it.',

  link: '35cfc04 Host takes over a stale peer instead of refusing (and 9ede37c Pairing: one copy per machine)',

  async run({ expect, page, read, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const os = await import('node:os');

    /*
     * Nothing here starts a second copy. It would be the exact proof and it is
     * not a guard's to do: the second copy's whole job is to reach into the
     * first and bring its window forward, and a guard that rearranges the app
     * the guards after it are reading is a guard nobody can trust. What is asked
     * instead is whether the lock that second copy would meet is really being
     * held, right now, by the copy that is running.
     */

    /** Where the copy under test keeps its own data, asked of the copy itself. */
    const dataDir = String(await page.evaluate(
      "(async()=>{try{const rows=await window.deck.settingsPaths();"
      + "const row=(Array.isArray(rows)?rows:[]).find(r=>r&&r.key==='userData');"
      + "return row&&typeof row.path==='string'?row.path:''}catch(e){return ''}})()",
    ));

    await expect('the running copy can still say where its own data lives', async () => {
      // Asked rather than computed, because the whole bug is about *which*
      // folder a copy landed in, and a folder this guard worked out for itself
      // would be a second opinion rather than the answer.
      return dataDir !== '' && path.isAbsolute(dataDir);
    });

    await expect('the lock a second copy would meet is one this platform can be asked about', async () => {
      /*
       * Said plainly instead of guessed at. The process singleton is a symlink
       * in the data folder on macOS and Linux, and on Windows it is a kernel
       * mutex and a hidden window with no file anywhere. A guard that found no
       * file there and called that a pass would be reporting on its own
       * blindness, which is the one failure this whole tool exists to prevent —
       * so it fails here and says which half it could not reach. The claims
       * below this one are the host's, and they run on every platform.
       */
      return process.platform !== 'win32';
    });

    /** What the running copy wrote into its own folder to claim this machine. */
    const claim = await (async () => {
      try {
        return await fsp.readlink(path.join(dataDir, 'SingletonLock'));
      } catch {
        return null;
      }
    })();

    await expect('the running copy really holds the lock, in its own data folder', async () => {
      // Not "the code asks for the lock" — the lock itself, on disk, taken. A
      // build that stopped asking would leave no file here and would look
      // identical from inside the window.
      return claim !== null && claim !== '';
    });

    await expect('and the lock names this machine and a process that is alive', async () => {
      /*
       * `<hostname>-<pid>`, which is the whole of what a second copy reads
       * before deciding whether to quit. Both halves matter and each has its own
       * wrong answer: a lock naming a *dead* pid is broken and stepped over, so
       * it is no lock at all; a lock naming *another host* is one this copy
       * never took, and the singleton will not break it — which is a second copy
       * quitting on somebody else's lock, or refusing to.
       */
      const named = /^(.*)-(\d+)$/.exec(String(claim));
      if (named === null) return false;
      if (named[1] !== os.hostname()) return false;
      try {
        // Signal 0 asks whether the process is there and sends it nothing.
        process.kill(Number(named[2]), 0);
        return true;
      } catch {
        return false;
      }
    });

    /**
     * The host's own eviction, run for real with the machine mocked out.
     *
     * Every dependency it has is a parameter — is this pid alive, is it one of
     * ours, send it a signal, wait — which is what makes it answerable here with
     * no process signalled and no clock waited on. The wait is a fake that
     * returns immediately: a guard that really slept out the five-second budget
     * would be a guard somebody switches off, and this repository has already
     * learned not to fake load or time in the other direction.
     */
    const host = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents: "export { evictStaleHost } from './src/headless/host-eviction'",
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
        return null;
      }
    })();

    await expect('the host takeover could really be loaded and asked', async () => {
      return host !== null && typeof host.evictStaleHost === 'function';
    });

    /**
     * A machine with one process on it, described rather than had.
     *
     * @param {{alive: boolean, ours: boolean, leavesOn?: NodeJS.Signals}} world
     */
    const machine = (world) => {
      /** @type {string[]} */
      const sent = [];
      let alive = world.alive;
      return {
        sent,
        deps: {
          alive: () => alive,
          isOurHost: () => world.ours,
          signal: (_pid, sig) => {
            sent.push(sig);
            if (sig === world.leavesOn) alive = false;
          },
          wait: async () => undefined,
        },
      };
    };

    await expect('a host that is still running is ended, so the new one can have the identity', async () => {
      // The 2026-08-28 fault in one line. Refusing to start left that host alive
      // holding this machine's relay slot, and no restart could clear it.
      const world = machine({ alive: true, ours: true, leavesOn: 'SIGTERM' });
      return (await host.evictStaleHost(4242, world.deps)) === 'terminated'
        && world.sent.join(',') === 'SIGTERM';
    });

    await expect('one that will not leave politely is not left holding the slot either', async () => {
      // SIGTERM first so that evicting even a supervised host cannot trip its
      // restart rule into a fight, then the impolite one.
      const world = machine({ alive: true, ours: true, leavesOn: 'SIGKILL' });
      return (await host.evictStaleHost(4242, world.deps)) === 'killed'
        && world.sent.join(',') === 'SIGTERM,SIGKILL';
    });

    await expect('a pid that is not one of ours is never signalled', async () => {
      // Our host died and its number was reused. Signalling it would be this app
      // harming an unrelated process to tidy its own bookkeeping — and the
      // number belongs to whatever the machine started next.
      const world = machine({ alive: true, ours: false });
      return (await host.evictStaleHost(4242, world.deps)) === 'not-ours' && world.sent.length === 0;
    });

    await expect('and one that survives both says so instead of reporting success', async () => {
      // A zombie, or an uninterruptible sleep. Answering `terminated` here would
      // be a new host dialling out beside a live one — this bug, restored, by a
      // function that thought it had fixed it.
      const world = machine({ alive: true, ours: true });
      return (await host.evictStaleHost(4242, world.deps)) === 'stuck';
    });

    await expect('and the host still reaches for that takeover before it clears the record', async () => {
      /*
       * The order is the fix. The record is what names the pid to end, so a
       * daemon that cleared it first would have nothing left to evict and would
       * start beside a live host — two on one identity, which is the bug — with
       * the bookkeeping now saying there is only one.
       */
      const daemon = String(await read('src/headless/daemon.ts'))
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/(^|[^:])\/\/[^\n]*/g, '$1');
      const evicts = daemon.indexOf('evictStaleHost(');
      const clears = daemon.indexOf('clearDaemonRecord(');
      return evicts > 0 && clears > 0 && evicts < clears;
    });

    /*
     * WHAT THIS GUARD CANNOT REACH.
     *
     * The report itself — a phone that pairs and stays paired — needs a phone, a
     * live relay and fifteen quiet minutes, and the drops it is looking for came
     * every ten to forty-five seconds before the fix. The Windows half of the
     * lock is a kernel mutex with no file, and is named above rather than
     * skipped. What is proved here is that this copy is holding the lock a
     * second copy reads, that the lock names a live process on this machine, and
     * that a host meeting another host ends it rather than starting beside it.
     */
  },
};
