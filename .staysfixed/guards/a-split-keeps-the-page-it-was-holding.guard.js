/**
 * Press Split, and both halves were empty — the hole a pane leaves measured 584x0.
 */
export default {
  name: 'a page in a split pane still has a rectangle to be drawn in',

  fixed: '2026-08-23',

  because:
    'Splitting the window broke twice by two different mechanisms. First it RELOADED whatever page was open, because '
    + 'the split moved the panel into the pane’s own subtree — a remount by another name, and unmounting one closes '
    + 'its page for real. The answer is that a pane draws an EMPTY body and the page is positioned over the hole, so it '
    + 'is never re-parented. Then two days later the hole itself had no size: it carried `flex: 1` inside a parent that '
    + 'is a block box, where flex grows nothing, so every slot measured its full width by zero pixels — 584x0 and 568x0, '
    + 'in a real window. A zero box is dropped on purpose, a page with no box is judged off-screen, and off-screen is '
    + '`display: none`. Press Split, and both halves were empty. Most browser work touches this layout.',

  link: '734295b The four he meets daily, and 5d17c98 A page in a pane has a rectangle again',

  async run({ expect, page }) {
    /*
     * Nothing here presses Split. A guard shares one running app with the guards after it and
     * they read whatever it leaves on screen, and splitting the window is a real change to the
     * product — so the arrangement is asked about instead of being performed. Which is also
     * the only way to ask it at all: the unit tests for this run in jsdom, which answers every
     * rectangle with zeroes and would pass while measuring nothing. This one has a layout
     * engine and the shipped stylesheet, and that is the whole of what was missing.
     */
    const measured = String(await page.evaluate(
      "(()=>{const body=document.createElement('div');"
      + "body.className='pane-cell-body';body.setAttribute('aria-hidden','true');"
      // Off the side of the window, hidden and deaf to the mouse: a probe must not be
      // something the person watching the run can see, or click by accident.
      + "body.style.cssText='position:absolute;left:-20000px;top:0;width:600px;height:400px;visibility:hidden;pointer-events:none';"
      + "const slot=document.createElement('div');slot.className='pane-remote-slot';body.appendChild(slot);"
      + "try{document.body.appendChild(body);"
      + "const b=body.getBoundingClientRect(),s=slot.getBoundingClientRect();"
      + "return JSON.stringify({bodyW:Math.round(b.width),bodyH:Math.round(b.height),slotW:Math.round(s.width),slotH:Math.round(s.height)});"
      // Always removed, on every path out. A guard that leaves anything in the page changes
      // what the next guard reads, and a guard that reads another one's leftovers is a guard
      // nobody can trust.
      + "}finally{body.remove()}})()",
    ));

    await expect('the hole a pane leaves for a page has a rectangle at all', async () => {
      const box = JSON.parse(measured);
      // The shipped fault, exactly: full width, no height.
      return box.slotW > 0 && box.slotH > 0;
    });

    await expect('and it fills the pane body rather than standing in one corner of it', async () => {
      const box = JSON.parse(measured);
      // Either arrangement is accepted — the slot filling its positioning parent, or the
      // parent laying it out as a flex column. What is refused is the third state, which is
      // what shipped: a slot asking a block parent to grow it. Both answers land on the same
      // rectangle, so measuring is the way to accept both without naming either.
      return box.slotH >= box.bodyH - 1 && box.slotW >= box.bodyW - 1;
    });

    await expect('every hole in the window as it stands now has a rectangle too', async () => {
      // Conditional by nature: an unsplit window has no holes in it, and this list is then
      // empty and says nothing. It is the probe above that covers the case that shipped; this
      // is the free half — if a guard before this one left the window split, the real slots
      // are right there and worth measuring.
      const boxes = String(await page.evaluate(
        "JSON.stringify([...document.querySelectorAll('[data-pane-slot]')]"
        + ".map(e=>{const r=e.getBoundingClientRect();return [Math.round(r.width),Math.round(r.height)]}))",
      ));
      return JSON.parse(boxes).every(([width, height]) => width > 0 && height > 0);
    });

    await expect('a page in a pane is still moved rather than re-parented, which is what reloaded it', async () => {
      /*
       * The first of the two faults, asked of the shipped stylesheet. `.pane-remote-slot` is
       * the empty body a pane draws INSTEAD of the page, and `[data-boxed]` is the attribute
       * the panel carries only when it has been handed a rectangle to stand in. Both exist for
       * one reason: the page stays where it was mounted. If a change puts the page back inside
       * the pane's subtree these two rules are what goes with it, and the reload comes back.
       */
      const found = String(await page.evaluate(
        "(()=>{const seen={};for(const sheet of document.styleSheets){let rules;"
        + "try{rules=sheet.cssRules}catch(e){continue}"
        + "for(const rule of rules){const sel=rule.selectorText||'';"
        + "if(sel==='.pane-remote-slot')seen.hole=rule.style.cssText;"
        + "if(/^\\.bw\\[data-boxed=.true.\\]$/.test(sel))seen.boxed=rule.style.cssText;}}"
        + "return JSON.stringify(seen)})()",
      ));
      const rules = JSON.parse(found);
      if (typeof rules.hole !== 'string' || typeof rules.boxed !== 'string') return false;
      // The four sides have to be RELEASED before the renderer writes its own — the panel
      // fills the pane area with `inset: 0` otherwise, and a `top` and a `left` alone leave it
      // pinned to the far edges and stretched rather than moved. The browser may hand back the
      // shorthand or the four longhands it expands to, and a guard that only knows one of them
      // is a guard that fails on a browser upgrade.
      const released = /inset:\s*auto/.test(rules.boxed)
        || (/top:\s*auto/.test(rules.boxed) && /left:\s*auto/.test(rules.boxed)
          && /right:\s*auto/.test(rules.boxed) && /bottom:\s*auto/.test(rules.boxed));
      return /position:\s*absolute/.test(rules.hole) && /position:\s*absolute/.test(rules.boxed) && released;
    });
  },
};
