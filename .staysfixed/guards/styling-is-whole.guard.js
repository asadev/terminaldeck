/**
 * The app opened with no styling at all, and every one of 13,457 tests passed while it did.
 */
export default {
  name: 'the app still draws its own styling, and no stylesheet is left half-open',

  fixed: '2026-08-21',

  because:
    'Two branches were merged by pasting both versions of the same four style rules together, which left four missing '
    + 'closing brackets. A stylesheet with a missing bracket does not complain — it silently stops applying everything '
    + 'after it. The app opened with no sidebar background, bullet points down the navigation, browser-default headings '
    + 'and a window you could see through. Nothing automated noticed; only somebody looking at it did. This repository '
    + 'merges ten or more branches at a time and a style conflict is resolved by hand every round, so it will happen again.',

  link: 'd497000 Four rules left open by a merge, and the whole app unstyled behind them',

  async run({ expect, page }) {
    await expect('the side rail has a background of its own, not the window showing through', async () => {
      const colour = String(await page.evaluate("(()=>{const n=document.querySelector('aside.sidebar')||document.querySelector('aside');return n?getComputedStyle(n).backgroundColor:''})()"));
      // Transparent is what a half-open stylesheet leaves behind, and it is the exact thing
      // that made the window see-through. Any real colour is fine; nothing is not.
      return colour !== '' && colour !== 'rgba(0, 0, 0, 0)' && colour !== 'transparent';
    });

    await expect('the navigation has no bullet points down it', async () => {
      const marked = await page.evaluate("[...document.querySelectorAll('aside ul, nav ul')].some(u=>getComputedStyle(u).listStyleType!=='none')");
      return marked === false;
    });

    await expect('the stylesheet still carries its rules rather than stopping part way', async () => {
      // A bracket left open does not remove the sheet — it truncates it. Counting what
      // survived is the cheapest way to see that, and it is what nothing was doing before.
      const rules = Number(await page.evaluate("[...document.styleSheets].reduce((n,s)=>{try{return n+s.cssRules.length}catch(e){return n}},0)"));
      return rules > 1500;
    });

    await expect('headings are styled by the app, not left at the browser default', async () => {
      const weight = String(await page.evaluate("(()=>{const h=document.querySelector('h1,h2,h3');return h?getComputedStyle(h).fontFamily:''})()"));
      return weight !== '' && !/^-apple-system$|^Times/.test(weight);
    });
  },
};
