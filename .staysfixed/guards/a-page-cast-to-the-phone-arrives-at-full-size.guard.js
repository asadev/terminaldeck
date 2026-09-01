/**
 * The page he opened on his phone came back at 49% — a machine's desktop layout
 * squeezed into a pane. He asked for it twice in one day.
 */
export default {
  name: 'a page cast from a machine is laid out in the rectangle it will be drawn in',

  fixed: '2026-08-26',

  because:
    'A window opened on a machine keeps whatever viewport that machine gave it, and a headless Chromium launched with '
    + 'no window size defaults to 800 x 600. The phone then asks for a screencast width in **device** pixels, and the '
    + 'debugging protocol only *caps the picture* at it — the document is still laid out at 800. The viewer fits that '
    + 'picture into its pane, so what a person actually reads is pane points divided by page CSS pixels: a number that '
    + 'is 100% only by accident, and was 49% on the phone he was holding. No amount of tuning the picture can fix it, '
    + 'because the mistake is in the layout. It comes back because the two numbers are both called "the width" and '
    + 'differ by the screen scale on every phone made this decade — a 393-point pane on a three-times display wants a '
    + '1179-pixel picture of a 393-pixel-wide page — and because the one call that sets a viewport can also fake a '
    + 'display, oversample a surface and serve a phone layout, each of which looks like a size and is not one. '
    + 'His second report of the same thing in a single day.',

  link: 'review-2026-08-26-evening REQUIREMENTS A1 — "it should always open to the normal size", said twice',

  async run({ expect, read, project }) {
    /**
     * The product's own wire parser and its viewport gate, loaded and run rather
     * than read.
     *
     * Both are pure by design — `browser-cdp.ts` says of itself that every
     * decision in it is a function over strings so it can be driven with no
     * Electron around it — so they answer here exactly as they answer in the
     * main process. Bundled in memory and imported as a data URL: nothing is
     * written to disk, no browser is opened, and no page anywhere is resized.
     */
    const wire = await (async () => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents:
              "export { screenCommand } from './src/main/browser-cdp'\n"
              + "export { parseClientMessage, MIN_PAGE_WIDTH, MAX_PAGE_WIDTH, MIN_PAGE_HEIGHT, MAX_PAGE_HEIGHT }"
              + " from './src/main/remote/protocol'",
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
        // rather than as a stack trace nobody reads.
        return null;
      }
    })();

    await expect('the wire and the viewport gate could really be loaded and asked', async () => {
      return wire !== null && typeof wire.parseClientMessage === 'function' && typeof wire.screenCommand === 'function';
    });

    /** @param {Record<string, unknown>} frame */
    const parsed = (frame) => wire.parseClientMessage({ t: 'browser.window.size', id: 'browser:1', ...frame });

    await expect('the wire still carries a rectangle for the page, and both numbers survive it', async () => {
      // 393 x 440 is a phone pane. One CSS pixel per point is the whole of
      // "100 percent like a normal view of any website", so a parser that
      // rounded, scaled or dropped either number would be the defect again.
      const said = parsed({ width: 393, height: 440 });
      return said.ok === true && said.message.width === 393 && said.message.height === 440;
    });

    await expect('a width on its own is refused, because a width on its own does not deliver it', async () => {
      // The same fault from the other axis, and the one an optional height
      // would have left in: the viewer fits by the SMALLER of the two ratios,
      // so a page laid out 393 x 600 and drawn into 393 x 440 arrives at 73%.
      return parsed({ width: 393 }).ok === false && parsed({ height: 440 }).ok === false;
    });

    await expect('a pane nobody planned for is clamped rather than refused', async () => {
      // Deliberately not a refusal: this frame is sent on a **rotation**, and
      // the host answers a parse failure by closing the socket — every terminal
      // and the cast with it. Somebody turning their phone must never cost them
      // that.
      const small = parsed({ width: 12, height: 9 });
      const huge = parsed({ width: 99_999, height: 99_999 });
      return small.ok === true
        && small.message.width === wire.MIN_PAGE_WIDTH
        && small.message.height === wire.MIN_PAGE_HEIGHT
        && huge.ok === true
        && huge.message.width === wire.MAX_PAGE_WIDTH
        && huge.message.height === wire.MAX_PAGE_HEIGHT;
    });

    await expect('but a size nobody measured is still refused', async () => {
      // Not a pane anybody held: a client that divided by zero. It would arrive
      // at Chromium as a viewport override with no size in it, which is the
      // spelling of "turn the override off" — the defect, restored, by accident.
      return parsed({ width: Number.NaN, height: 440 }).ok === false;
    });

    /** @param {Record<string, unknown>} params */
    const gate = (params) => wire.screenCommand({
      transport: 'cdp',
      state: 'agent',
      method: 'Emulation.setDeviceMetricsOverride',
      params,
    });
    const honest = { width: 393, height: 440, mobile: false, deviceScaleFactor: 1 };

    await expect('the machine will lay a document out at exactly that rectangle', async () => {
      return gate(honest).ok === true;
    });

    await expect('a resolution is refused where a size was asked for', async () => {
      // Oversampling leaves the layout exactly where it was and makes the
      // surface bigger, so it is not a size at all — and it is the only value
      // at which the picture cap means what the phone thinks it means.
      return gate({ ...honest, deviceScaleFactor: 3 }).ok === false;
    });

    await expect('and a phone layout is refused too, which would answer the question with a different page', async () => {
      // Mobile emulation honours a meta-viewport and serves the site's phone
      // layout. That answers "how wide is this page" by showing something else,
      // which is the substitution this whole verb exists to avoid.
      return gate({ ...honest, mobile: true }).ok === false;
    });

    await expect('nothing may lie to the page about the display it is on', async () => {
      return ['screenWidth', 'screenHeight', 'screenOrientation', 'positionX', 'positionY']
        .every((key) => gate({ ...honest, [key]: 1 }).ok === false);
    });

    await expect('and "lay it out at nothing" can never arrive as a silently cleared viewport', async () => {
      // A missing or zero side is the protocol's own spelling of *turn the
      // override off*, which is a different verb from *lay it out this wide*
      // and has no caller. Off is the state the complaint was made about.
      return gate({ ...honest, width: 0 }).ok === false && gate({ mobile: false, deviceScaleFactor: 1 }).ok === false;
    });

    /**
     * Swift with its comments taken out.
     *
     * The paragraphs in these files argue about scale at length — the picture's
     * scale, the layer's scale, the transform that is deliberately not one — and
     * a sweep that reads the text as written finds the mistake in the argument
     * against the mistake. Three tests in this repository have already failed
     * that way, on their own comments.
     *
     * @param {string} source
     */
    const code = (source) => source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/[^\n]*/g, '$1');
    const asksInPixels = /displayScale|UIScreen|contentScaleFactor|nativeScale/;

    // A moved file reads as an empty string rather than throwing, so the floor
    // claim under these two fails as its own sentence rather than as a stack
    // trace nobody reads.
    const swiftAt = (where) => read(where).then(String).catch(() => '');
    const screen = code(await swiftAt('ios/TerminalDeck/Screens/MachineWindowView.swift'));
    const cast = code(await swiftAt('ios/TerminalDeck/Screens/WatchView.swift'));

    await expect('the phone screens that do this were really read', async () => {
      // The hole this pair of claims cannot notice about itself: a renamed file
      // reads as an empty string, and an empty string contains no scale.
      return screen.length > 2000 && cast.length > 2000;
    });

    await expect('the picture is still asked for in device pixels, which is where a scale belongs', async () => {
      // The floor under the claim below, and not a formality. Without it, a
      // phone that had stopped scaling *anything* — a screen that never
      // measured, a file that moved — would read as the fix being in place.
      return asksInPixels.test(cast);
    });

    await expect('and the page is asked for in points, where a scale is the whole bug', async () => {
      // The rectangle sent to the machine is the stage's own box in points, so
      // one CSS pixel lands on one point and 100% is 100%. Multiplying it by
      // the screen scale is the arithmetic that produced 49%: it is the picture
      // width, and it is three times too wide to lay a document out in.
      return asksInPixels.test(screen) === false;
    });

    await expect('the phone and the wire agree on how big a page may be asked to be', async () => {
      /*
       * Three copies of one number — the wire's, the phone's, and the gate's —
       * and this repository has watched a version number drift across three
       * files four times. The phone clamps for honesty rather than for safety:
       * the host clamps too, so a phone that asks for 12 and is silently given
       * 240 has a page laid out at a width it does not know about, and every
       * fit it computes from the frames that come back is then wrong about the
       * thing in front of the person holding it.
       */
      const swift = await swiftAt('ios/TerminalDeck/Protocol/MachineBrowserWire.swift');
      /** @param {string} name */
      const declared = (name) => {
        const found = new RegExp(`static let ${name}\\s*=\\s*(\\d+)`).exec(swift);
        return found === null ? null : Number(found[1]);
      };
      return declared('minPageWidth') === wire.MIN_PAGE_WIDTH
        && declared('maxPageWidth') === wire.MAX_PAGE_WIDTH
        && declared('minPageHeight') === wire.MIN_PAGE_HEIGHT
        && declared('maxPageHeight') === wire.MAX_PAGE_HEIGHT;
    });

    /*
     * WHAT THIS GUARD CANNOT REACH, and it is the half he actually looked at.
     *
     * The proof he would recognise is two photographs: the same address opened
     * once as a window on a machine and once as a window on the phone itself,
     * with the rendered text the same height in both and neither drawn below
     * full size. That needs the iPhone app, a reachable host and somebody
     * holding the phone, and none of the three can be asked for from here.
     *
     * What is proved here is the whole of the arithmetic underneath it: the
     * viewer names a rectangle, both numbers survive the wire, a rotation
     * cannot drop the socket, and the machine will lay the document out at
     * exactly that rectangle — one image pixel per CSS pixel per point — while
     * refusing the four other things that call itself a viewport. That is
     * where the 49% came from, and it is checkable on this machine every time.
     */
  },
};
