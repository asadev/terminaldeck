/**
 * The Scraping panel had a switch labelled "screenshot on block". The feature was
 * real and running. The switch was a picture of one.
 */
export default {
  name: 'every switch on the scraping panel has an engine behind it',

  fixed: '2026-08-22',

  because:
    'The switch wrote into a settings object no part of the engine has ever read, while the camera it claimed to '
    + 'govern had been photographing blocked pages all along with no way to stop it: a working feature and a fake '
    + 'control for it, shipped together. The next day the same disease turned up in a cluster on the same panel — '
    + 'every stored scraping setting was read at exactly one moment, when an agent tool armed a page, so a person who '
    + 'switched Images to Fulfill and capture On got nothing at all. Every control looked like it worked and did not. '
    + 'A control drawn before its engine is wired is the normal way features land here, which is why this is a house '
    + 'rule rather than an incident.',

  link: '94dcd9b the camera was real, its switch was a picture of one — 5442ea2 the cluster after it',

  async run({ expect, page, read }) {
    /**
     * A profile nobody has ever made.
     *
     * Only questions are asked below, and they are asked about a profile that does not
     * exist so that not one of them can be mistaken for a person setting something. The
     * engine answers for an unknown profile with what it holds for nobody — which is
     * exactly the shape this guard is here to read.
     */
    const NOBODY = 'staysfixed-guard-no-such-profile';

    const answered = JSON.parse(String(await page.evaluate(
      "(async()=>{try{const config=await window.deck.browserScrapingConfig("
      + JSON.stringify(NOBODY)
      + ");return JSON.stringify({config})}catch(e){return JSON.stringify({error:String(e&&e.message||e)})}})()",
    )));

    await expect('the engine, and not only the panel, holds the scraping settings', async () => {
      const config = answered.config;
      if (answered.error !== undefined || config === null || typeof config !== 'object') return false;
      return ['fleet', 'requests', 'capture', 'assets', 'checks'].every((section) => section in config);
    });

    await expect('every setting the panel can change is a setting the engine answers for', async () => {
      /*
       * The original defect, stated as a comparison rather than as a list: `screenshotOnBlock`
       * was declared in the renderer, drawn as a control, and written into a patch that
       * nothing in the engine had ever heard of. So the panel's own declared shape is read
       * from the source, and every name in it has to come back from the running engine.
       *
       * One-way on purpose. The engine may hold more than the panel draws — it does today —
       * and that is a setting without a control, which is a different complaint. A control
       * without a setting is this one.
       *
       * This reads the working tree against the packaged app, so a control added since the
       * last package fails here. That is the right way round: it is the same sentence as the
       * bug, said a fortnight earlier.
       */
      const source = String(await read('src/renderer/browser/scraping-bridge.ts'))
        .replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '))
        .replace(/\/\/[^\n]*/g, '');

      /** @param {string} shape  The body of one interface, braces matched rather than guessed. */
      const bodyOf = (shape) => {
        const at = source.indexOf(`export interface ${shape}`);
        if (at < 0) return '';
        const opens = source.indexOf('{', at);
        if (opens < 0) return '';
        let depth = 0;
        for (let i = opens; i < source.length; i++) {
          if (source[i] === '{') depth += 1;
          else if (source[i] === '}') {
            depth -= 1;
            if (depth === 0) return source.slice(opens, i + 1);
          }
        }
        return '';
      };

      const declared = new Set();
      for (const shape of ['ScrapingConfig', 'FleetConfig', 'CaptureConfig', 'AssetsConfig', 'ChecksConfig']) {
        const body = bodyOf(shape);
        if (body === '') return false;
        // Every field, including the ones written inline inside a nested brace — two of the
        // three settings groups on that panel are written that way.
        for (const field of body.matchAll(/[{;\n]\s*([A-Za-z][A-Za-z0-9_]*)\s*\??\s*:/g)) declared.add(field[1]);
      }

      /** Every key anywhere in what the engine answered, however deep. */
      const held = new Set();
      const walk = (value) => {
        if (value === null || typeof value !== 'object' || Array.isArray(value)) return;
        for (const [key, under] of Object.entries(value)) {
          held.add(key);
          walk(under);
        }
      };
      walk(answered.config);

      // A subtraction over an empty list proves nothing, which is how a sweep like this
      // usually goes quietly wrong.
      if (declared.size < 10 || held.size < 10) return false;
      return [...declared].every((name) => held.has(name));
    });

    const camera = JSON.parse(String(await page.evaluate(
      "(async()=>{try{const on=await window.deck.browserBlockCapture(" + JSON.stringify(NOBODY) + ");"
      + "return JSON.stringify({on,kind:typeof on,setter:typeof window.deck.browserBlockCaptureSet})}"
      + "catch(e){return JSON.stringify({error:String(e&&e.message||e)})}})()",
    )));

    await expect('the switch that was a picture of one has both of its ends wired', async () => {
      // Asked, never set. The setter is only looked at — flipping it would store an answer
      // for a profile, which is a guard changing the product it watches.
      //
      // A real boolean is the whole point. The reading end existing is what tells a person's
      // switch what it is showing, and it is precisely what this control did not have: the
      // panel drew it out of its own memory and nothing on the engine side had an opinion.
      return camera.error === undefined && camera.kind === 'boolean' && camera.setter === 'function';
    });
  },
};
