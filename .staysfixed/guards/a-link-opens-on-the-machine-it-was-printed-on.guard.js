/**
 * "As soon as I tell them open a browser, they just directly go inside my PC and
 * they opens." His biggest problem with the browser, and the first of its causes
 * was one missing argument.
 */
export default {
  name: 'a link clicked in a terminal opens in this app, on the machine the session ran on',

  fixed: '2026-08-21',

  because:
    'A URL an agent printed in a terminal is clicked, and the page opens in Chrome on his Mac — for a session running '
    + 'on his PC, or on a server in another country. Four causes, and the first is one missing argument: the remote '
    + 'terminal and the server terminal both asked for link handling with **no session id**, where the local terminal '
    + 'passes one. With no session the routing answers "the system", and the system is the default browser of whichever '
    + 'computer the window is on. Elsewhere the machine was passed as an empty string, which in this feature is a '
    + 'positive claim of "this computer" rather than "unknown", so a session on his PC was looked up under this Mac\'s '
    + 'key and found to belong to nobody. It comes back easily: the identity argument is **optional** — a terminal that '
    + 'forgets it compiles clean and runs clean, and every new terminal pane is a new call site.',

  link: 'review-2026-08-21 T35, T36, T58 — "so this is my biggest problem, like browser currently"',

  async run({ expect, page, read, project }) {
    /*
     * Only questions, and the one channel this touches is asked something it
     * refuses before it routes anything. `link:open` with an empty address
     * returns `refused` on its first line — no window, no tab, no page handed to
     * the machine — so the name can be proved registered without opening
     * anything anywhere. A guard that opened a page would be a guard that
     * changes the product it is watching.
     */
    await expect('the channel a terminal click travels on still answers under that name', async () => {
      const said = String(await page.evaluate(
        "(async()=>{try{ if(typeof window.deck?.openLink!=='function') return 'MISSING';"
        + "return String(await window.deck.openLink({url:''})) }catch(e){ return 'REJECTED '+String(e&&e.message||e) }})()",
      ));
      // This app has registered a channel under one name and called it under
      // another three times in three days, and a missing name here is not an
      // error on screen — it is a click that does nothing at all.
      return said === 'refused';
    });

    /**
     * A file with its comments taken out.
     *
     * Every prose mention of the hook and of an empty machine in these files is
     * inside a comment — including the paragraph that describes this very
     * defect — so a sweep that reads the text as written finds the bug in the
     * apology for the bug. Three tests in this repository have already failed
     * that way, on their own comments.
     *
     * @param {string} source
     */
    const code = (source) => source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1');

    /**
     * What a call to `useTerminalFind` was handed, with the balanced brackets
     * walked rather than a line matched: the server terminal's argument is four
     * lines long and spread over a conditional.
     *
     * The hook's own definition wears the same spelling, so a `function` in
     * front of it is what tells the one declaration from the calls.
     *
     * @param {string} source
     */
    const identitiesPassed = (source) => {
      /** @type {string[]} */
      const found = [];
      const call = 'useTerminalFind(';
      for (let at = source.indexOf(call); at >= 0; at = source.indexOf(call, at + 1)) {
        if (/function\s+$/.test(source.slice(Math.max(0, at - 12), at))) continue;
        let depth = 0;
        for (let i = at + call.length - 1; i < source.length; i += 1) {
          if (source[i] === '(') depth += 1;
          else if (source[i] === ')') {
            depth -= 1;
            if (depth === 0) {
              found.push(source.slice(at + call.length, i).trim());
              break;
            }
          }
        }
      }
      return found;
    };

    const terminals = [
      { where: 'src/renderer/components/TerminalView.tsx', machine: false, what: 'a session on this computer' },
      { where: 'src/renderer/machines/RemoteTerminal.tsx', machine: true, what: 'a session on a paired machine' },
      { where: 'src/renderer/machines/servers/ServerTerminal.tsx', machine: true, what: 'a shell on a server' },
    ];

    /** @type {{where: string, machine: boolean, what: string, passed: string[], source: string}[]} */
    const read3 = [];
    for (const terminal of terminals) {
      // A file that has moved comes back as an empty string rather than as a
      // thrown error, so the claim below fails as its own sentence instead of
      // as a stack trace nobody reads.
      const source = code(await read(terminal.where).then(String).catch(() => ''));
      read3.push({ ...terminal, source, passed: identitiesPassed(source) });
    }

    await expect('all three terminals were really found and read', async () => {
      // The hole a sweep like this cannot notice about itself: a renamed file
      // returns nothing, and nothing satisfies every claim below it.
      return read3.length === 3 && read3.every((one) => one.passed.length === 1);
    });

    for (const terminal of read3) {
      await expect(`${terminal.what} hands the click the session it was printed in`, async () => {
        // The whole of the first cause. Without this the address reaches the
        // main process bare, and a bare address is routed to the machine.
        return /\bsessionId\b/.test(terminal.passed[0]);
      });
    }

    for (const terminal of read3.filter((one) => one.machine)) {
      await expect(`${terminal.what} says which machine it is on, as well as which session`, async () => {
        // Both halves or neither. The binding is keyed `<machineId>\0<sessionId>`,
        // so a session on his PC carrying only its own id is looked up under
        // this computer's key and found to be nobody's — which routes it to
        // the machine again, by the other door.
        return /\bmachineId\b/.test(terminal.passed[0]);
      });
    }

    for (const terminal of read3) {
      await expect(`${terminal.what} never claims to be on this computer when it does not know`, async () => {
        // `''` is not "unknown" in this feature, it is "this computer" — an
        // answer rather than a question. A terminal that cannot say where it is
        // must leave the field out and let `machineOfSession` answer.
        return /machineId\s*:\s*(''|""|``)/.test(terminal.passed[0]) === false;
      });
    }

    await expect('and no fourth terminal has appeared that goes round the hook that owns links', async () => {
      /*
       * The reason this is a class and not an incident. Links, the OSC 8
       * handler and the three chords all live in one hook, and a pane that
       * builds its own `new Terminal` without calling it gets xterm's own
       * default — which is `window.open()` with no argument, the address
       * discarded, and a blank tab in its place.
       *
       * Counted over the app's own terminals only. The phone client builds one
       * too and cannot reach any of this.
       */
      const built = read3.reduce((n, one) => n + (one.source.match(/new Terminal\s*\(/g) ?? []).length, 0);
      return built === 3;
    });

    /**
     * The product's own routing decision, loaded and run rather than read.
     *
     * `browser-binding.ts` is deliberately a map with no dependencies, so it
     * bundles and answers here exactly as it does inside the main process. Built
     * in memory and imported as a data URL — nothing is written to disk — and
     * the copy that answers below carries its own empty map, so no session this
     * app is really running is read or touched by asking it anything.
     */
    const routing = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents: "export { resolve } from './src/main/browser-binding'",
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

    await expect('the decision behind that click could really be loaded and asked', async () => {
      return routing !== null && typeof routing.resolve === 'function';
    });

    await expect('a click with no session behind it still goes out to the machine', async () => {
      // Not a bug — the honest answer for a URL nobody can attribute, and the
      // floor under the two claims after it. If this stopped saying `system`,
      // they would both pass on a build where the question was never asked.
      return routing.resolve(null, '').kind === 'system';
    });

    await expect('a click in a session on this computer keeps the page inside the app', async () => {
      return routing.resolve('a-session', '', { known: true }).kind !== 'system';
    });

    await expect('and a click in a session on another machine keeps it inside the app too', async () => {
      // The remote half, asked of the decision rather than of a machine. This
      // is the arithmetic; the click itself is below.
      return routing.resolve('a-session', 'a-machine', { known: true }).kind !== 'system';
    });

    /*
     * WHAT THIS GUARD CANNOT REACH, said plainly rather than left to be assumed.
     *
     * The click itself, in a remote terminal and in a server terminal, needs a
     * paired second machine and a connected server — and the last hop, that the
     * page appears in the app's own browser **on the machine the session runs
     * on** rather than in Chrome on this Mac, can only be seen by looking at
     * both screens. Nothing here presses a link: a guard that opened a page
     * would be a guard that changes the product it watches.
     *
     * What is proved here is every step before that hop: the channel answers,
     * all three terminals hand it a session, the two off-machine ones say which
     * machine, none of them claims this computer without knowing, no fourth
     * terminal has gone round the hook, and the decision those arguments feed
     * still keeps an attributed URL inside the app.
     */
  },
};
