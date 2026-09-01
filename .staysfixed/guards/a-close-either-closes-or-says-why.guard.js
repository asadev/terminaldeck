/**
 * He pressed ✕ on a session with browser windows attached and nothing at all happened.
 */
export default {
  name: 'closing a session that has a browser window attached either closes it or says why',

  fixed: '2026-08-20',

  because:
    'The close path refused while a browser window was still bound to the session, and the refusal was silent: the '
    + 'confirmation simply never appeared, so pressing the button produced nothing and there was no way to learn what '
    + 'the obstacle was. In his words — *"if I keep clicking on the cross button to close it, it shows no message until '
    + 'we detach the browser… but otherwise we will not even know that it is the reason."* An attached window was never '
    + 'a good reason to refuse, and nothing refuses on it now; the dialog reads the binding instead and says in one line '
    + 'what becomes of those windows. The same audit found the ✕ on the last window on the bar dead as well. This is the '
    + 'family he complains about most — a control that neither acts nor explains — so every new close path can rejoin it.',

  link: 'review-2026-08-20 item O3; asks-audit-2026-08-28 DES-136 and BRO-030',

  async run({ expect, page }) {
    // Nothing here presses a ✕. A guard may not delete a session, so the press itself is out of
    // reach and so is the phone's copy of this control, which needs the iOS app. What is asked
    // instead are the three things that have to be true for the press to produce anything at all:
    // the app is set to ask, the card it would draw is in this build, and the fact that used to
    // make it refuse is now only something the card reads. Then the one ✕ a guard may safely put
    // on the bar is measured without being pressed.

    await expect('the window can still ask which browser windows belong to which session', async () => {
      // The lookup the dialog does. It is the whole difference between the silent press and the
      // fixed one: the relation lives in the main process, and this is the door the card reads it
      // through to name `B1` and `B2`. A door that stops answering takes the line away and leaves a
      // press that says nothing — which is the bug, arriving by a different route.
      const said = String(await page.evaluate(
        "(async()=>{try{ if (typeof window.deck?.browserBindings !== 'function') return 'MISSING';"
        + ' const view = await window.deck.browserBindings();'
        + " return (view && Array.isArray(view.sessions)) ? 'OK' : 'NOT A VIEW';"
        + "}catch(e){ return 'REJECTED ' + String(e && e.message || e) }})()",
      ));
      return said === 'OK';
    });

    await expect('and the app is still set to ask before deleting a session', async () => {
      // *"Always ask."* — his settlement of 2026-08-17. If the confirmation is off there is nothing
      // for the press to produce and the fixed behaviour is indistinguishable from the bug. Absent
      // is the ordinary state of a fresh install and reads as "ask", exactly as the dialog reads
      // it; only an explicit `false` is off.
      const said = String(await page.evaluate(
        "(async()=>{try{ const settings = await window.deck.getSettings();"
        + " if (!settings || typeof settings !== 'object') return 'NO SETTINGS';"
        + " return settings['general.confirmCloseWorking'] === false ? 'OFF' : 'ASKS';"
        + "}catch(e){ return 'REJECTED ' + String(e && e.message || e) }})()",
      ));
      return said === 'ASKS';
    });

    await expect('and the card that answers the press is in this build', async () => {
      // Read off the stylesheets the app has actually loaded. The card's rules travel with the
      // component that imports them, so a build that dropped the dialog would drop these too — and
      // a ✕ with no dialog behind it is precisely the press that did nothing. The headline and the
      // detail line are both asked for: the detail line is the one that names the windows.
      const drawn = String(await page.evaluate(
        '(()=>{const want=new Set([".close-confirm-headline",".close-confirm-detail"]);const found=new Set();'
        + 'for(const sheet of document.styleSheets){let rules;try{rules=sheet.cssRules}catch(e){continue}'
        + 'for(const rule of rules){const sel=(rule.selectorText||"").trim();if(want.has(sel))found.add(sel)}}'
        + 'return [...found].sort().join(",")})()',
      ));
      return drawn === '.close-confirm-detail,.close-confirm-headline';
    });

    /** The one window this guard opens, so it can put the bar back as it found it. */
    const opened = String(await page.evaluate(
      "(async()=>{try{const made = await window.deck.browserCreate();"
      + "return typeof made==='string' ? made : ((made && (made.id || made.windowId)) || '');"
      + "}catch(e){ return '' }})()",
    ));

    try {
      await expect('a window really opened, so there is a ✕ on the bar to look at', async () => {
        // Never assume what the guard before this one left on screen. Without something of its own
        // on the bar this check would be measuring an empty list and passing on it.
        return opened !== '';
      });

      await page.wait(600);

      await expect('and every ✕ on the bar is a control a press can actually reach', async () => {
        // The dead ✕ the audit found separately, measured rather than pressed. A control that is
        // zero-sized, hidden, disabled or covered by something else takes the click and does
        // nothing, which looks from the outside exactly like a close that silently refused.
        const measured = JSON.parse(String(await page.evaluate(
          "(()=>{const out=[];for(const b of document.querySelectorAll('.strip-tab-close')){"
          + 'const box=b.getBoundingClientRect();const style=getComputedStyle(b);'
          + 'const x=Math.round(box.left+box.width/2),y=Math.round(box.top+box.height/2);'
          + 'const hit=document.elementFromPoint(x,y);'
          + 'out.push({w:Math.round(box.width),h:Math.round(box.height),pointer:style.pointerEvents,'
          + 'shown:style.visibility!=="hidden"&&style.display!=="none",off:b.disabled===true,'
          + 'reached:hit!==null&&(hit===b||b.contains(hit))})}'
          + 'return JSON.stringify(out)})()',
        )));
        if (measured.length === 0) return false;
        return measured.every((c) => c.w > 0 && c.h > 0 && c.shown && !c.off && c.pointer !== 'none' && c.reached);
      });
    } finally {
      // A guard that leaves a window open changes what the next guard sees, and a guard that
      // depends on what another one left behind is a guard nobody can trust.
      await page.evaluate(
        "(async()=>{try{const id=" + JSON.stringify(opened) + "; if(id) await window.deck.browserClose(id) }catch(e){}})()",
      );
    }
  },
};
