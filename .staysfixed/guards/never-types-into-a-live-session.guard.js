/**
 * To read the plan limit, the app typed `/usage` into whichever session was in front.
 */
export default {
  name: 'the app never types a command into a session somebody is working in',

  fixed: '2026-08-18',

  because:
    'To read the plan limit, the app literally typed `/usage` into whichever session was in front, leaving the agent\'s '
    + 'own usage panel sitting over his conversation. It retried on every quiet moment, per session, and his account is '
    + 'billed in a way that produces no rolling-window line at all — so the read could never succeed and therefore never '
    + 'stopped. He reported it three times: *"this is what is keep happening repeatedly on windows"*, then *"usage page '
    + 'problem is not fixed its keep coming in the running sessions"*, then, after being told it was Windows-only, '
    + '*"even on mac"*. The 0.5.0 fix only closed the panel afterwards. The real fix removed the typing: the figure is '
    + 'read out of the agent\'s own config file, or from a short-lived process of this app\'s own, and the channel that '
    + 'typed was deleted. It came back once after a fix had shipped, and its cause was published wrongly twice.',

  link: 'asks-audit-2026-08-28 CRO-042 (also DES-121); review 2026-08-18',

  async run({ expect, page, project }) {
    // The full proof records every byte written into a live session's terminal while the usage
    // reading is pressed and hovered, and asserts none of it came from the app. That needs a
    // session, and a guard may not start one. So this is the cheap companion the write-up names:
    // the door that typed is gone from the window, the figure can still be had without a terminal
    // at all, and no path in the shipped app writes the command.

    await expect('the bridge into the window still hands out its whole surface', async () => {
      // Said first because everything below is a claim that something is ABSENT, and an absence
      // proved against an empty list is the one failure this tool exists to prevent. About five
      // hundred doors live on this bridge; anything near zero means the reading is broken, not that
      // the app is clean.
      const doors = Number(await page.evaluate('Object.keys(window.deck || {}).length'));
      return doors >= 200;
    });

    await expect('and none of them is a door that refreshes the plan limits by typing', async () => {
      // `plan:refresh` was that door. It is not that the name went — it is that the *action* moved
      // to a channel which reads a file, and only a person pressing can make it start anything at
      // all. A new door answering to both words again is this bug coming back.
      const named = String(await page.evaluate(
        "Object.keys(window.deck || {}).filter(k => /plan/i.test(k) && /refresh/i.test(k)).join(', ')",
      ));
      return named === '';
    });

    await expect('the usage figure can still be read with no session in front of it at all', async () => {
      // The mechanism of the whole fix in one question. A figure that comes off a file can be asked
      // for with no session; a figure that comes off somebody's terminal cannot. This one takes
      // null and answers, and the day it stops is the day the reading needs a terminal again.
      const said = String(await page.evaluate(
        "(async()=>{try{ if (typeof window.deck?.readUsage !== 'function') return 'MISSING';"
        + ' const answer = await window.deck.readUsage(null);'
        + " return (answer && typeof answer === 'object') ? 'OK' : 'NOTHING';"
        + "}catch(e){ return 'REJECTED ' + String(e && e.message || e) }})()",
      ));
      return said === 'OK';
    });

    // ── and the same question asked of the code that ships, where a path can be seen that no
    //    amount of pressing would have reached today.

    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    const asar = path.resolve(
      project.paths.root,
      String(project?.config?.app?.binary ?? ''),
      'Contents', 'Resources', 'app.asar',
    );

    /** The packaged main bundle, read out of the archive's own index rather than by unpacking it. */
    const shipped = await (async () => {
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        const index = JSON.parse(json.toString('utf8').replace(/\0+$/, ''));
        const found = index.files?.out?.files?.main?.files?.['index.js'];
        if (!found) return '';
        if (found.unpacked === true) return fsp.readFile(path.join(`${asar}.unpacked`, 'out', 'main', 'index.js'), 'utf8');
        const buf = Buffer.alloc(Number(found.size));
        await file.read(buf, 0, buf.length, 16 + size + Number(found.offset));
        return buf.toString('utf8');
      } finally {
        await file.close();
      }
    })();

    await expect('there is a packaged app here to read', async () => shipped.length > 100_000);

    /**
     * The shipped bundle with its comments taken out.
     *
     * This one is not a nicety. The build keeps this repository's comments in the file it ships,
     * and six of them say `/usage` while explaining why the app no longer types it — so a check
     * that grepped the archive as plain text would fail on the account of the fix. That is exactly
     * how three iOS tests failed on 2026-08-20: they read source as text and could not tell a
     * comment naming the banned thing from the banned thing.
     */
    const code = shipped
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/(^|[^:'"`\\])\/\/[^\n]*/g, '$1');

    await expect('the shipped app registers no channel called plan:refresh', async () => {
      // The write-up's own words: no refresh handler by that name exists. A registered channel is a
      // quoted string in this bundle; the comments spell it in backticks, and they are gone anyway.
      return (code.match(/"plan:refresh"/g) ?? []).length === 0;
    });

    await expect('and the plan-limit module is handed no way to write into a session', async () => {
      // This is the fix itself, in one signature. That module used to be given a `write` alongside
      // the channel, and the `write` is what let it type into somebody's terminal and draw a panel
      // over their conversation. Read-only now means it takes the channel and nothing else, so a
      // second argument appearing here is the capability coming back before any caller uses it.
      const signature = /function registerPlanLimitIpc\(([^)]*)\)/.exec(code);
      return signature !== null && signature[1].trim() === 'ipcMain';
    });

    await expect('and nothing in the shipped code is the /usage command itself', async () => {
      // A string that IS the command, rather than a sentence containing the word. Two sentences the
      // app shows a person say "…only near a limit, or when /usage is run", and both are correct
      // and must stay; what may never come back is a literal that starts with the command, with or
      // without the return that sends it.
      const typed = code.match(/["'`]\/usage(\\r|\\n|["'`])/g) ?? [];
      return typed.length === 0;
    });
  },
};
