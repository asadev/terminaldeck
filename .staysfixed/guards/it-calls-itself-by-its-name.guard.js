/**
 * It shipped calling itself "Deck" in its own window while everything else said Terminal Deck.
 */
export default {
  name: 'the app calls itself Terminal Deck on screen',

  fixed: '2026-08-13',

  because:
    'A find-and-replace cleaning up after a rename also rewrote the one string it was meant to leave alone, so the app '
    + 'shipped titled "Deck" in its own window while the installer, the manifest and the web page all said Terminal Deck. '
    + 'Nothing compared the two, so it built clean and only ever showed up on screen. One bad substitution in either '
    + 'direction brings it back.',

  link: '241aa81 Fix the name, and make it impossible to break silently again',

  async run({ expect, page }) {
    // Everything below is asked of the APP, never of whatever page happens to be open.
    // Guards share one running copy and run one after another, so a guard that reads the
    // screen reads whatever the guard before it left there — this one failed for exactly
    // that reason on its first outing, on a page whose own wording was innocent.

    await expect('the window is titled with the whole name', async () => {
      return (await page.title()).includes('Terminal Deck');
    });

    await expect('the title does not say the half-name on its own', async () => {
      // This is the shipped bug, precisely: the window said "Deck" while the installer, the
      // manifest and the web page all said Terminal Deck.
      const title = await page.title();
      return /\bDeck\b/.test(title.replace(/Terminal Deck/g, '')) === false;
    });

    await expect('the app agrees with itself about what it is called', async () => {
      const said = String(await page.evaluate(
        "(async()=>{try{const b=await window.deck.getBrand();return JSON.stringify(b)}catch(e){return 'ERR'}})()",
      ));
      return said.includes('Terminal Deck');
    });

    await expect('the name in the window and the name the app reports are the same name', async () => {
      // The heart of the bug: two sources of the product's own name that nothing ever
      // compared. Screens come and go and a guard cannot rely on which one is open — but
      // these two must agree in every build, on every screen.
      const title = String(await page.title());
      const brand = String(await page.evaluate(
        "(async()=>{try{const b=await window.deck.getBrand();return typeof b==='string'?b:(b&&(b.name||b.productName||b.appName))||''}catch(e){return ''}})()",
      ));
      return brand !== '' && title.includes(brand);
    });
  },
};
