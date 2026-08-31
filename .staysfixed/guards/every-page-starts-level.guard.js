/**
 * The Machines page began forty pixels lower than every other page.
 */
export default {
  name: 'every page in the side rail starts at the same height',

  fixed: '2026-08-23',

  because:
    'The Machines page began forty pixels lower than every other page in the rail, so moving to it shifted the whole '
    + 'column down and left a band of empty paper under the title. It had inherited a gap meant to separate one group of '
    + 'settings from the next, in a place where there was nothing above it to be separated from. No test found it — a '
    + 'person looking at the screens in a row did. This app reuses its settings components across panes on purpose, so '
    + 'an inherited margin landing in the wrong place is a recurring shape rather than a one-off.',

  link: 'ed74789 Machines started forty pixels lower than every other page (see also 82386df, 4d2ca0d)',

  async run({ expect, page }) {
    /** Where the first line of a page sits, once that page is on screen. */
    const topOfTheFirstLine = async () => Number(await page.evaluate(
      "(()=>{const main=document.querySelector('main')||document.body;"
      + "const first=[...main.querySelectorAll('h1,h2,h3')].find(h=>h.getBoundingClientRect().height>0);"
      + "return first?Math.round(first.getBoundingClientRect().top):-1})()",
    ));

    /** @param {string} label */
    const openPage = async (label) => {
      await page.evaluate(
        `(()=>{const b=[...document.querySelectorAll('button,[role=button],a')]`
        + `.find(e=>(e.textContent||'').trim()===${JSON.stringify(label)});`
        + `if(b)b.click();return Boolean(b)})()`,
      );
      await page.wait(350);
    };

    const pages = ['Overview', 'Files', 'Artifacts', 'Source control', 'Store', 'GitHub', 'MCP servers', 'Machines'];
    /** @type {{page: string, top: number}[]} */
    const measured = [];
    for (const label of pages) {
      await openPage(label);
      const top = await topOfTheFirstLine();
      if (top >= 0) measured.push({ page: label, top });
    }

    await expect('enough pages opened for this to mean anything', async () => measured.length >= 3);

    await expect('they all start at the same height', async () => {
      const tops = measured.map((m) => m.top);
      const highest = Math.min(...tops);
      const lowest = Math.max(...tops);
      // Not exact equality: sub-pixel layout and a scrollbar appearing move things by ones
      // and twos, and a guard that cries over that gets switched off. Forty pixels was the
      // real fault, and anything approaching it is the same fault.
      return lowest - highest <= 8;
    });
  },
};
