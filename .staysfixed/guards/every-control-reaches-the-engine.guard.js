/**
 * The most repeated defect in this product's history: a control wired to a name
 * that does not exist on the other side.
 */
export default {
  name: 'every control still reaches the engine, and no panel is wired to a name that does not exist',

  fixed: '2026-08-12',

  because:
    'The window and the engine behind it talk through a list of named channels. Several were registered under one name '
    + 'and called under another, and a call to a name nobody registered is simply rejected. It happened three times in '
    + 'three days: the browser looked dead, the inspector and the workspace drew nothing, and five panels each showed '
    + 'their own "not available in this window" message. One missing name disables a whole panel, and the panel says '
    + 'something reassuring while it does. Every new feature adds names on both sides of the same seam.',

  link: '929d6ae, 01c49e1, 0d8df0c — three in three days',

  async run({ expect, page }) {
    // Only questions. Nothing here creates a session, adds an agent or changes a setting:
    // a guard that changes the product it is watching is a guard nobody can trust.
    const asked = ['getBrand', 'listAgents', 'listProjects', 'getPreferences', 'listSessions', 'listHeldSessions', 'homeFolder'];

    for (const name of asked) {
      await expect(`asking the engine for ${name} is answered, not rejected`, async () => {
        const said = String(await page.evaluate(
          `(async()=>{try{ if (typeof window.deck?.${name} !== 'function') return 'MISSING';
             const answer = await window.deck.${name}(); return answer === undefined ? 'UNDEFINED' : 'OK';
           }catch(e){ return 'REJECTED ' + String(e && e.message || e); }})()`,
        ));
        return said === 'OK';
      });
    }

    await expect('no panel on screen is showing its own "not available" message', async () => {
      const found = Number(await page.evaluate("(document.body.innerText.match(/not available in this window|not wired into this build|is not available here/gi)||[]).length"));
      return found === 0;
    });
  },
};
