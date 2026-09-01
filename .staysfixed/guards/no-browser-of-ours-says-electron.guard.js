/**
 * Google refused the sign-in, it was fixed on one browser surface, and nine days
 * later the identical refusal came back on a different one.
 */
export default {
  name: 'no browser this product opens announces itself as Electron or as headless',

  fixed: '2026-08-27',

  because:
    'He reported *"Google sign-in refuses"* on 2026-08-17, and ten days later, of the machine browser: *"it is saying '
    + 'this browser or app may not be secure so like I am not being able to log in my Google account."* Measured on '
    + '2026-08-18: the same authorisation URL loaded with Electron\'s own user agent gets `GeneralOAuthLite` and a '
    + 'legacy consent path, and without the `Electron` token gets the ordinary consent screen — so the token alone is '
    + 'the refusal. That was stripped for the desktop\'s shared and worker profiles, and nine days later the same '
    + 'refusal returned on a **different browser this product ships**: the machine\'s headless Chromium, which names '
    + 'itself `HeadlessChrome` and carried `navigator.webdriver`. A third fault made every stuck sign-in hang for ever '
    + '— a denied pop-up hands the page `null`, so the sign-in library waits for a message from a window it never got. '
    + 'This product opens browsers on five surfaces and the fix has to be true of all of them at once, which is exactly '
    + 'what it was not.',

  link: 'asks-audit-2026-08-28 BRO-081; src/main/browser-user-agent.ts carries both measurements',

  async run({ expect, page, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /**
     * Lift a function out of a built bundle and hand it back callable.
     *
     * The built file rather than `src`, because a guard cannot import
     * TypeScript and because the bundle is the thing that gets packaged, signed
     * and run. Braces are counted rather than parsed, which is enough for these
     * bodies; anything it mis-reads will not compile, and the floor below says
     * so before any claim is made on top of it. `extra` carries the constants a
     * lifted body closes over — substituting our own would hide a cleaner whose
     * pattern had stopped matching, which is the whole failure being watched.
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

    /** @param {string} rel */
    const built = async (rel) => {
      const text = await fsp.readFile(path.join(project.paths.root, rel), 'utf8').catch(() => null);
      return text === null ? '' : text;
    };

    const desktop = await built('out/main/index.js');
    const host = await built('out/headless/chunk-host.mjs');
    const launcher = await built('out/headless/chunk-version.mjs');

    await expect('the three built browsers are all here to be read', async () => {
      // A missing bundle is not a clean run. Every claim below is made against
      // shipped code, and a file that could not be read would otherwise let the
      // whole guard pass having examined nothing.
      return desktop !== '' && host !== '' && launcher !== '';
    });

    const shellTokens = /const SHELL_TOKENS = .+;/.exec(desktop);
    const cleanUserAgent = shellTokens === null ? null : lift(desktop, 'cleanUserAgent', shellTokens[0]);
    const machineBrowserUserAgent = lift(host, 'machineBrowserUserAgent');
    const chromiumFlags = lift(launcher, 'chromiumFlags');

    await expect('the shipped cleaner, the shipped machine agent and the shipped flag list all lifted', async () => {
      // Read out of the build and run, rather than read and matched: a check
      // that greps for a call site says the code is there, not that it still
      // does anything. This one calls it.
      return typeof cleanUserAgent === 'function'
        && typeof machineBrowserUserAgent === 'function'
        && typeof chromiumFlags === 'function';
    });

    /** What this Electron actually says it is, asked of the app that is running. */
    const own = String(await page.evaluate('navigator.userAgent'));

    await expect('the app’s own window still names the shell, so there is a tell to remove', async () => {
      /*
       * The floor, and it is deliberately fragile.
       *
       * Everything below removes a token from this string. If Electron ever
       * spells its token differently, the cleaner stops finding it, every check
       * under here goes on passing, and the refusal is back with nothing red.
       * So the input is asked of the running app rather than pasted in from
       * 2026-08-18, and a change in what it says fails here — where somebody
       * reads it — instead of silently in Google's hands.
       */
      return /\bElectron\//.test(own);
    });

    await expect('the shared tab, the worker and every guest are handed a user agent with no shell in it', async () => {
      // Run on what this Electron says right now, not on the measured string:
      // the bug is "the cleaner no longer matches what the shell emits", and
      // only today's string can show that.
      const cleaned = String(cleanUserAgent(own));
      return /\b(?:Electron|terminaldeck|Terminal ?Deck)\//i.test(cleaned) === false
        && /Chrome\/\d+/.test(cleaned)
        && /AppleWebKit\/537\.36/.test(cleaned);
    });

    for (const platform of ['darwin', 'win32', 'linux']) {
      await expect(`the machine browser on ${platform} presents a plain Chrome, not a headless one`, async () => {
        /*
         * The second surface, and the reason this guard covers more than one.
         * `--headless=new` names itself `HeadlessChrome`, which is the loudest
         * thing a browser can say to Google's check — and no amount of
         * stripping the Electron token reaches it, because it is a wholly
         * separate browser. All three platforms, because he hit it on Windows
         * and on the Mac and the string is composed per platform.
         */
        const said = String(machineBrowserUserAgent(platform, '146.0.7680.216'));
        return /Headless/i.test(said) === false
          && /\bElectron\//.test(said) === false
          && /Chrome\/146\.\d+\.\d+\.\d+/.test(said);
      });
    }

    await expect('that machine browser is not launched advertising a debugger either', async () => {
      /*
       * The other half of the same refusal, measured on 2026-08-27 against this
       * exact launch: with nothing here `navigator.webdriver` read `true`, and
       * with `--disable-blink-features=AutomationControlled` it reads `false`.
       * `--enable-automation` would turn the tell back on and raise an
       * automation infobar besides, so its absence is asserted as well as the
       * flag's presence.
       */
      const flags = chromiumFlags({ userDataDir: '/dev/null/not-used', userAgent: machineBrowserUserAgent('darwin', '146.0.7680.216') });
      return flags.includes('--disable-blink-features=AutomationControlled')
        && flags.some((flag) => /^--user-agent=/.test(flag) && /Headless/i.test(flag) === false)
        && flags.some((flag) => flag.startsWith('--enable-automation')) === false;
    });

    /* ── the surfaces on the desktop, which is where it came back ───────── */

    /**
     * A file with its comments stripped and its whitespace flattened, so the
     * paragraph explaining a rule cannot satisfy a search for the rule.
     * @param {string} rel
     */
    const code = async (rel) =>
      (await fsp.readFile(path.join(project.paths.root, rel), 'utf8'))
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/^[ \t]*\/\/.*$/gm, ' ')
        .replace(/\s+/g, ' ');

    /** @param {string} source @param {string} header */
    const declaration = (source, header) => {
      const at = source.indexOf(header);
      if (at < 0) return null;
      let depth = 0;
      let i = source.indexOf('{', at);
      for (; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}' && (depth -= 1) === 0) break;
      }
      return i >= source.length ? null : source.slice(at, i + 1);
    };

    const tab = await code('src/main/browser-tab.ts');
    const isolation = await code('src/main/browser-isolation.ts');

    for (const [what, header, source] of [
      ['the shared tab', 'function hardenedGuestSession()', tab],
      ['a worker profile', 'function workerSession(', tab],
      ['an isolated tab', 'function harden(', isolation],
    ]) {
      await expect(`${what} is given the cleaned user agent when its jar is built`, async () => {
        /*
         * One claim per surface, because "fixed on one surface" is what this
         * bug is. The user agent is a property of the SESSION, so the only
         * place it can be set is where the session is made — and each of these
         * three makes one. As of this guard being written the isolated tab does
         * not set one at all, so it keeps Electron's default and a sign-in
         * inside a private tab is refused exactly as the shared tab used to be.
         * That is a live defect in the product, recorded in the audit as still
         * open, and it is left failing here on purpose rather than quietly
         * dropped from the list.
         */
        const body = declaration(source, header);
        return body !== null && /setUserAgent\(cleanUserAgent\(/.test(body);
      });
    }

    await expect('a new tab still gets its jar from one of exactly those three, and no fourth', async () => {
      /*
       * The class, not the incident. This bug came back because a *new* browser
       * surface appeared and nobody asked it the question. Every tab's session
       * is chosen in one expression, so the names in that expression are the
       * complete list of surfaces — and the day a fourth is added, this fails
       * and somebody has to decide whether it announces the shell.
       */
      const chosen = /session: ([^,]+),/.exec(tab);
      if (chosen === null) return false;
      const named = new Set(String(chosen[1]).match(/[A-Za-z_$][\w$]*/g) ?? []);
      const known = new Set(['isolatedSession', 'opts', 'isolationKey', 'worker', 'hardenedGuestSession']);
      return named.size === known.size && [...named].every((name) => known.has(name));
    });

    await expect('a sign-in pop-up is still answered with a window rather than refused', async () => {
      /*
       * The third fault, and the one that made a refusal look like a hang.
       * Measured on Electron 41.10.5: a handler answering `deny` returns `null`
       * to `window.open`, and every OAuth library keeps that handle and waits
       * for a `postMessage` from it — so the sign-in completes in a tab in the
       * strip with no way to tell the page that opened it. *"The verification
       * link gets stuck"*, exactly. `wantsPopupWindow` is the routing rule; a
       * handler that stopped consulting it and went back to a blanket deny is
       * the regression.
       */
      const opener = declaration(tab, 'wc.setWindowOpenHandler(');
      return opener !== null
        && /if \(wantsPopupWindow\(ask\)\) \{ .{0,200}action: 'allow'/.test(opener);
    });

    /* ── what this cannot prove, said plainly ──────────────────────────────
     *
     * That Google itself accepts the sign-in. That takes a real account, and a
     * real account is a once-per-release walk by a person, on each surface, not
     * something a guard may hold. What is here is the mechanism underneath the
     * refusal — the tokens each surface presents and the automation flag — and
     * that is the half that has silently broken twice.
     */
  },
};
