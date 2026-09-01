/**
 * 0.14.0 handed every server session the copilot's whole tool endpoint, and the
 * shell closed the instant it connected — on a stranger's machine, not ours.
 */
export default {
  name: 'a session started on a server keeps its shell, with browser tools of its own',

  fixed: '2026-08-28',

  because:
    'He passed the app to somebody else: *"somebody has downloaded and installed that, so when they started a session '
    + 'they have seen this error — so it is not just for us, it is with the application somehow."* And the shape of it: '
    + '*"with the local devices it is working, but only when you interact with any server it happens."* The release '
    + 'before had folded every server session\'s tools onto the copilot\'s full control endpoint, and on a real host '
    + 'that closed the session\'s shell the moment it connected. Local sessions took a different path and were '
    + 'untouched, which is why it read as one machine\'s fault rather than the product\'s — the first diagnosis blamed '
    + 'his network and was wrong. The repair gives a session its own browser-only endpoint again, built so it cannot '
    + 'become the singleton the copilot owns: *"normal sessions just need the browser only. The copilot needs all of '
    + 'them. Keep them separate."* It is a regression introduced by the immediately preceding release that reached a '
    + 'stranger, which is exactly the shape a guard exists for.',

  link: 'f2b6410 headless server sessions get a browser-only endpoint, not the copilot’s full one',

  async run({ expect, project, run: shell, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /*
     * The headless host's own bundle, which is the thing that ships to a
     * server. The desktop is deliberately not read here: local sessions never
     * had this fault, and it is the host that a stranger installs.
     */
    const host = await fsp
      .readFile(path.join(project.paths.root, 'out/headless/chunk-host.mjs'), 'utf8')
      .catch(() => '');

    await expect('the headless host is built, so there is something to read', async () => {
      // Every claim below is about shipped code. A file that could not be read
      // would let all of them pass having examined nothing, which is the one
      // failure this whole tool exists to prevent.
      return host !== '';
    });

    /** @param {string} source @param {string} name @param {string} extra */
    const lift = (source, name, extra = '') => {
      const at = new RegExp(`(?:async )?function ${name}\\s*\\(`).exec(source);
      if (at === null) return null;
      let depth = 0;
      let i = source.indexOf('{', at.index);
      for (; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}' && (depth -= 1) === 0) break;
      }
      return source.slice(at.index, i + 1);
    };

    /** The name a session's endpoint is held under, followed rather than assumed. */
    const sessionServer = /(\w+) = await openStandaloneDeckControlServer\(\{ control: (\w+) \}\)/.exec(host);

    await expect('the host still opens a second, independent endpoint for sessions', async () => {
      // 0.14.0 had no such opener at all: there was one endpoint and every
      // session was pointed at it. Its existence is the fix, and its arguments
      // are read below rather than trusted.
      return sessionServer !== null;
    });

    await expect('and that endpoint is built over the browser-only control, not the host’s whole surface', async () => {
      // The control decides what the endpoint can do. `createHeadlessBrowserControl`
      // is the browser verbs over the machine's own Chromium; the copilot's is
      // built over this host's entire core.
      const built = new RegExp(`const ${sessionServer?.[2] ?? '\\u0000'} = createHeadlessBrowserControl\\(`);
      return sessionServer !== null && built.test(host);
    });

    await expect('a session is handed that endpoint, and never the copilot’s', async () => {
      /*
       * This is the line the bug was. It read
       * `createSessionTools(headlessCopilot.endpoint, …)`, and the seam test of
       * the day had enshrined it. Followed by name from the assignment above,
       * so renaming the variable moves the check with it and pointing it back
       * at the copilot fails — and matched as a *call*, because the declaration
       * one screen up (`function createSessionTools(endpoint, …)`) answers a
       * naive search for the name with its own parameter list.
       */
      const handed = /(?<!function )createSessionTools\(\s*([\w.]+)/.exec(host);
      return handed !== null && handed[1] === `${sessionServer?.[1]}.endpoint`;
    });

    await expect('there is exactly one place a session’s tools are composed', async () => {
      // Two wirings is how one of them goes stale: the fix restored the 0.13.0
      // arrangement, and a second composition living beside it is the next
      // release folding them together again.
      return (host.match(/(?<!function )createSessionTools\(/g) ?? []).length === 1;
    });

    await expect('the copilot still has its own full endpoint, so this is not proved by deleting it', async () => {
      // The floor under everything above. A build with no copilot would satisfy
      // every "not the copilot's" claim on this page and be a different, worse
      // product.
      return /startHeadlessCopilot\(\{/.test(host) && /async function startDeckControlServer\(/.test(host);
    });

    await expect('the session’s endpoint can never become the one the copilot owns', async () => {
      /*
       * The property that keeps them apart for good, read out of the two
       * openers rather than out of a comment. `currentEndpoint()` returns a
       * module-level variable; the singleton opener assigns it — that is the
       * copilot claiming it — and the standalone opener must never touch it, or
       * a session's browser-only endpoint would silently displace the copilot's
       * full one and the routine runner would read a session's server as its
       * own.
       */
      const returned = /function currentEndpoint\(\) \{\s*return (\w+);/.exec(host);
      const singleton = lift(host, 'startDeckControlServer');
      const standalone = lift(host, 'openStandaloneDeckControlServer');
      if (returned === null || singleton === null || standalone === null) return false;
      // An assignment, not a property or a read: `endpoint: opened.endpoint` is
      // the standalone handing its own back, which is the whole point of it.
      const assigns = new RegExp(`(?<![.:\\w$])${returned[1]}\\s*=(?!=)`);
      return assigns.test(singleton) && assigns.test(standalone) === false;
    });

    await expect('and the control behind it answers nothing but browser verbs', async () => {
      /*
       * "Browser-only" made mechanical. The session control is built over a
       * surface that is a proxy with no session, file or settings behind it —
       * so a built-in that ever reached it throws by name instead of returning
       * a plausible empty answer. Lifted and called, because a stub that
       * answered `undefined` would look identical from the outside and would be
       * the control that looks like it works and does not.
       */
      const surface = lift(host, 'headlessSurface');
      if (surface === null) return false;
      const made = new Function(`${surface}\nreturn headlessSurface();`)();
      try {
        // Any property at all, because the proxy answers every name the same
        // way: with something that refuses when it is used.
        made.sessions();
        return false;
      } catch (refusal) {
        return /serves only browser verbs/.test(String(refusal.message ?? refusal));
      }
    });

    /* ── the half that needs a real machine, said out loud ─────────────────
     *
     * Everything above is the wiring, read out of the bundle a server runs. The
     * report itself is behaviour on somebody else's box: start a session, send
     * one message, wait thirty seconds, and find the terminal still alive with
     * no error status. A guard may not do that — starting a session and typing
     * into it is the product being changed by the thing watching it — and this
     * Mac cannot reproduce it at all, because a local session never took this
     * path. The clean reproduction was a fresh cloud box.
     *
     * So the live half needs a real host to run against, and having none is
     * something this MACHINE is missing rather than something the product got
     * wrong. It used to be written as a failing expectation only because there
     * was no way to say that — which printed "a bug that was already fixed is
     * back" over a bug nobody had looked for. It declines instead now, and only
     * this last stretch stops: every check above has already run against the
     * shipped bundle and can still fail. What is left is read-only — it asks the
     * host what it is, and nothing else.
     */

    const address = String(process.env.TD_SERVER_ADDRESS ?? '').trim();

    if (address === '') {
      // The same variables the rest of this repository uses to name a machine to
      // work against, so there is one convention and not two.
      cannotRunHere(
        'no server is named to run the live half against: TD_SERVER_ADDRESS is empty, and this Mac cannot stand in '
        + 'for one, because a local session never takes the path this bug lived on. Point TD_SERVER_ADDRESS at a '
        + 'machine running the headless host — with TD_SERVER_USER and TD_SERVER_PORT if it needs them, and an ssh '
        + 'key this machine can use without a password — and the live half will run.',
      );
    }

    await expect('and that host answers for itself, so the session pass can actually be run', async () => {
      /*
       * `status` only, which reads and starts nothing. `BatchMode` so a host
       * this machine has no key for fails in a second instead of sitting on a
       * password prompt for ever, and the PATH is widened the way the app's own
       * probe widens it — the host installs into `~/.local/bin`, which a
       * non-interactive ssh does not have.
       */
      if (address === '') return false;
      const user = String(process.env.TD_SERVER_USER ?? '').trim();
      const port = String(process.env.TD_SERVER_PORT ?? '').trim();
      const asked = await shell(
        `ssh -o BatchMode=yes -o ConnectTimeout=8 ${port === '' ? '' : `-p ${port}`} `
        + `${user === '' ? '' : `${user}@`}${address} `
        + `'PATH="$PATH:$HOME/.local/bin:$HOME/bin" terminaldeck status'`,
        { timeoutMs: 25_000 },
      );
      // Its own first line names the product and the version it is running. A
      // host that answers "not serving" still counts: it is a machine a session
      // can be started on, which is what this check is looking for.
      return asked.code === 0 && /host \d+\.\d+\.\d+/.test(asked.stdout);
    });
  },
};
