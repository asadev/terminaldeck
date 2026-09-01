/**
 * Stopping the packaged app with a session running printed thirty-five errors on its way out.
 */
export default {
  name: 'quitting with a live session prints nothing and leaks nothing',

  fixed: '2026-08-14',

  because:
    'Quitting the packaged app while a session was running produced thirty-five errors about sending into a render frame '
    + 'that was already gone, plus a warning that eleven listeners had piled up on one object. Neither is text a user '
    + 'reads, and both are the app visibly failing at teardown. It took three attempts because the two obvious fixes are '
    + 'both dead ends: guarding harder does not work — at the moment of a failing send every question Electron will '
    + 'answer says the renderer is healthy — and catching does not work either, because the send swallows the failure and '
    + 'prints it itself. What worked was a liveness flag kept from lifecycle events, one funnel that refuses once it is '
    + 'clear, and one shared destroyed-listener that every module registers into instead of attaching its own. Every new '
    + 'module that wants to know when the window goes away is a candidate to attach its own again.',

  link: 'ae86843 Stop broadcasting into a render frame that is gone, and stop piling up teardown listeners',

  async run({ expect, project }) {
    // WHAT THIS GUARD CANNOT DO, said out loud rather than quietly skipped. The live half of this
    // bug is reproduced by signalling the app's process group with a session running and reading
    // what it printed on the way out — and a guard may not start a session, nor stop the app it is
    // itself running inside. So what is asked here is the mechanism that made those thirty-five
    // errors impossible, read out of the archive that actually ships. It is the archive and not the
    // working tree on purpose: every one of the errors was reported against a packaged build.

    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    const bundle = String(project?.config?.app?.binary ?? '');
    const asar = path.resolve(project.paths.root, bundle, 'Contents', 'Resources', 'app.asar');

    /** What the packaged archive says it contains, read out of its own index rather than by unpacking it. */
    const listing = await (async () => {
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        return { index: JSON.parse(json.toString('utf8').replace(/\0+$/, '')), base: 16 + size };
      } finally {
        await file.close();
      }
    })();

    /** @param {string[]} parts */
    const entry = (parts) => parts.reduce((at, part) => (at && at.files ? at.files[part] : undefined), listing.index);

    /** One file out of the archive, whole. @param {string[]} parts */
    const fileInArchive = async (parts) => {
      const found = entry(parts);
      if (!found) return '';
      // Electron leaves some files beside the archive in `app.asar.unpacked` and marks them so in
      // the index. Reading at an offset those entries do not have is how the phone-client guard
      // first went wrong, and a check that errors is a check nobody trusts.
      if (found.unpacked === true) return fsp.readFile(path.join(`${asar}.unpacked`, ...parts), 'utf8');
      const file = await fsp.open(asar, 'r');
      try {
        const buf = Buffer.alloc(Number(found.size));
        await file.read(buf, 0, buf.length, listing.base + Number(found.offset));
        return buf.toString('utf8');
      } finally {
        await file.close();
      }
    };

    await expect('there is a packaged app here to read', async () => {
      // Said first and on its own, so that a machine which has not built one reads "there is no
      // packaged app" instead of a stack trace out of the middle of a bracket count.
      const found = entry(['out', 'main', 'index.js']);
      return Boolean(found) && Number(found.size) > 100_000;
    });

    /**
     * The shipped bundle with its comments taken out.
     *
     * The build keeps this repository's comments in the file it ships, and those comments discuss
     * this very bug by name: `MaxListenersExceededWarning` is in there, once, in the doc comment of
     * the module that removed it. A check that read the archive as plain text would find the story
     * and report it as the defect — which is exactly how three iOS tests failed on 2026-08-20, on
     * comments that named the thing they banned. So the comments come out before anything is counted.
     */
    const codeOnly = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`\\])\/\/[^\n]*/g, '$1');

    const code = codeOnly(await fileInArchive(['out', 'main', 'index.js']));

    await expect('the shipped app still has one shared place to hear that a window has gone', async () => {
      return /function onWebContentsDestroyed\(/.test(code);
    });

    await expect('and the modules that each used to attach their own listener all register into it', async () => {
      // Eleven modules each wanted to know when the one renderer went away and each attached its
      // own `once('destroyed')`. Every one of them was individually correct; Node counts listeners
      // per emitter, not per module, so being right eleven times is what produced the warning.
      const keys = new Set([...code.matchAll(/onWebContentsDestroyed\(\s*[^,]+,\s*"([a-z-]+)"/g)].map((m) => m[1]));
      // Not an exact count: modules come and go, and a guard that goes red because a feature was
      // renamed is a guard people learn to ignore. What must not change is that the crowd still
      // goes through the one door — and that the two which got it subtly wrong are still in it.
      // `plan-limit` and `cost` guarded per watched entry rather than per window, so one window
      // watching eleven sessions attached eleven listeners all by itself.
      return keys.size >= 8 && keys.has('plan-limit') && keys.has('cost');
    });

    await expect('the renderer\'s own window is listened to exactly once', async () => {
      // The one direct attachment left, and the one that maintains the liveness flag. A second one
      // here is the shape the registry exists to prevent, arriving at the place it hurts most.
      const direct = code.match(/mainWindow\.webContents\.(on|once)\("destroyed"/g) ?? [];
      return direct.length === 1;
    });

    await expect('and every push to the renderer still goes through the one funnel that refuses once it is gone', async () => {
      // The flag, not a question. Measured at the moment of a failing send, with the frame already
      // disposed: quitting=false, window not destroyed, contents not destroyed, not crashed, frame
      // present, not detached — every question Electron answers says the renderer is healthy. Only
      // its own lifecycle knows, which is why this is a flag and why it is cleared in more than one
      // place: on the window going, and again before the quit path starts killing PTYs — because
      // killing a PTY *generates* the last burst of exactly the traffic that used to print.
      const funnel = code.match(/quitting \|\| !rendererAlive/g) ?? [];
      const cleared = code.match(/rendererAlive = false/g) ?? [];
      return funnel.length === 1 && cleared.length >= 2;
    });
  },
};
