/**
 * The microphone drew nothing at all while it was recording, because the red and
 * the pulse both named tokens this app has never defined.
 */
export default {
  name: 'every colour, curve and spacing the app draws with names a token that exists',

  fixed: '2026-08-21',

  because:
    'Ten style rules asked for named colours and animation curves this app has never defined. Nobody sees that: an '
    + 'undefined custom property is not a parse error, it is an invalid value at computed-value time, so the cascade '
    + 'picks the declaration and then throws the value away and the element goes on drawing something plausible. The '
    + 'worst was the microphone. While recording it asked for a red that does not exist and a pulse that does not '
    + 'exist, so the tint died, color-mix() died with its argument and left the button transparent, and the animation '
    + 'shorthand reset to none — the one control whose whole job is to answer "is it still on" answered by not '
    + 'changing. Several other controls were drawing one step louder or quieter than intended, one of them directly '
    + 'under a comment saying it was meant to be quieter. All ten shipped, none was reported, and renaming a token is '
    + 'a one-line change.',

  link: '47ace73 Ten declarations named tokens that do not exist and drew nothing',

  async run({ expect, page }) {
    /**
     * Every rule the running app actually loaded, swept in the page rather than read out of
     * the source. What ships is a bundle: a token deleted from one stylesheet while another
     * still reads it is only true of the build, and the build is what a person opens.
     */
    const swept = JSON.parse(String(await page.evaluate(`(()=>{
      let text = '';
      for (const sheet of document.styleSheets) {
        // A group rule's own cssText carries everything nested inside it, so the media
        // queries and the two theme blocks come along without walking into them.
        try { for (const rule of sheet.cssRules) text += rule.cssText + '\\n' } catch (e) { /* not ours to read */ }
      }
      const defined = new Set();
      for (const decl of text.matchAll(/(--[A-Za-z0-9_-]+)\\s*:/g)) defined.add(decl[1]);
      // Reads with NOTHING behind them, on purpose. Five names in this app are measured by
      // the running layout and published from JavaScript — a sheet's height, a tree row's
      // depth — and every one of those is read with a fallback beside it. A read with no
      // fallback is a promise the stylesheet cannot keep on its own.
      const read = [...text.matchAll(/var\\(\\s*(--[A-Za-z0-9_-]+)\\s*\\)/g)].map((use) => use[1]);
      const phantom = [...new Set(read.filter((name) => !defined.has(name)))];
      return JSON.stringify({ defined: defined.size, read: read.length, phantom: phantom.slice(0, 20) });
    })()`)));

    await expect('the sweep really read the stylesheets this app loaded', async () => {
      // The failure a subtraction like this cannot notice about itself: a moved folder or a
      // stylesheet that never loaded leaves nothing to subtract, and finding no phantoms in
      // an empty set looks exactly like finding none in a whole app.
      return swept.defined > 150 && swept.read > 500;
    });

    await expect('no declaration names a colour, curve or spacing the app never defines', async () => {
      // When this fails, `src/renderer/styles/phantom-tokens.test.ts` is the same subtraction
      // over the source and prints the file and line of every one of them.
      return swept.phantom.length === 0;
    });

    /**
     * The recording state's own two declarations, computed off screen.
     *
     * A probe rather than a recording: switching the microphone on would change the product
     * this is watching, and it is not needed — the fault was never in the recorder, it was
     * in whether these two values survive being computed. The probe is removed before the
     * next line runs.
     */
    const drawn = JSON.parse(String(await page.evaluate(`(()=>{
      const probe = document.createElement('div');
      probe.style.position = 'fixed';
      probe.style.left = '-9999px';
      probe.style.top = '0';
      probe.style.background = 'color-mix(in srgb, var(--color-critical) 14%, transparent)';
      probe.style.animation = 'dc-pulse 1.6s var(--ease) infinite';
      document.body.appendChild(probe);
      try {
        const seen = getComputedStyle(probe);
        return JSON.stringify({ tint: seen.backgroundColor, pulse: seen.animationName });
      } finally {
        probe.remove();
      }
    })()`)));

    await expect('the recording tint still has a colour in it once it is computed', async () => {
      // Transparent is precisely what shipped: color-mix() dies with an invalid argument and
      // the background falls back to nothing, on a button that is meant to be tinted red.
      return drawn.tint !== '' && drawn.tint !== 'rgba(0, 0, 0, 0)' && drawn.tint !== 'transparent';
    });

    await expect('and the pulse it is animated with is still an animation', async () => {
      // `animation` is a shorthand and does not inherit, so one bad token inside it resets
      // the whole thing to none. That is how the pulse died silently beside the tint.
      return drawn.pulse === 'dc-pulse';
    });
  },
};
