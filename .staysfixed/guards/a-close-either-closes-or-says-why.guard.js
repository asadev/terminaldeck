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

  async run({ expect, page, cannotRunHere }) {
    // No session's ✕ is pressed here. A guard may not delete a session, so that press is out of
    // reach and so is the phone's copy of this control, which needs the iOS app. What is asked
    // instead are the three things that have to be true for the press to produce anything at all:
    // the app is set to ask, the card it would draw is in this build, and the fact that used to
    // make it refuse is now only something the card reads. Then the guard opens one window of its
    // own, measures every ✕ a person can see, and presses the one ✕ it is allowed to: its own
    // window's, which deletes nothing but what the guard itself made.

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

    /**
     * Which windows are on the bar, by the id each tab carries.
     *
     * Read before and after the guard opens its own, because that difference is the only honest
     * way to know which tab is the guard's. This used to be taken on trust from
     * `window.deck.browserCreate()` — and that call never reaches the bar at all. It makes a page
     * in the main process and hands its state back; the bar learns about windows only through the
     * renderer's own path, the one the globe takes. Replayed in `.harness/` on 2026-10-03: the
     * call answered `b1`, the bar went on showing `s1` alone, and the check that "a window really
     * opened" passed on the answer. So the ✕s this guard measured were whatever an earlier guard
     * had left on the bar, never one of its own.
     */
    const onTheBar = async () => JSON.parse(String(await page.evaluate(
      "JSON.stringify([...document.querySelectorAll('[data-strip-tab]')].map((t) => t.getAttribute('data-tab-id')))",
    )));

    /**
     * The globe a person would press: the bar's own while there is a bar, the sidebar's when the bar
     * is not drawn yet — it is not, until something is open. Both open the same window the same way.
     */
    const globe = String(await page.evaluate(
      "(()=>{for(const s of ['.strip-open[aria-label=\"New browser tab\"]','.sb-new-alt[aria-label=\"New browser tab\"]']){"
      + 'const el=document.querySelector(s);if(!el)continue;const r=el.getBoundingClientRect();'
      + "if(r.width>0&&r.height>0)return s}return ''})()",
    ));
    if (globe === '') {
      // No globe at all is a build or a setting without the browser pane, which is a question this
      // guard cannot answer — not a ✕ that refused.
      cannotRunHere('There is no "New browser tab" button on screen, so this guard cannot open a window of its own to measure. Turn the browser on in Settings and run it again.');
    }

    const before = await onTheBar();
    await page.click(globe);
    await page.wait(600);
    /** The one window this guard opens, so it can put the bar back as it found it. */
    const opened = (await onTheBar()).find((id) => !before.includes(id)) ?? '';

    try {
      await expect('a window really opened on the bar, so there is a ✕ of its own to look at', async () => {
        // Asked of the bar, not of the call that opened it — see `onTheBar` for the guard that
        // passed this on an answer while the bar showed nothing new.
        return opened !== '';
      });

      await expect('and every ✕ on the bar is a control a press can actually reach', async () => {
        // The dead ✕ the audit found separately, measured rather than pressed. A control that is
        // zero-sized, hidden, disabled or covered by something else takes the click and does
        // nothing, which looks from the outside exactly like a close that silently refused.
        //
        // "On the bar" means inside the strip's visible run of tabs. A full bar scrolls, and a tab
        // scrolled past either edge is clipped by the strip itself: its ✕ is not on screen, a
        // person cannot see it to press it, and the "‹ 2" / "3 ›" count is what names it. Counting
        // those was the second reason this check failed — on a bar of twelve at 1280 points four
        // of twelve read as dead, every one of them outside the strip. So a ✕ outside the strip's
        // box is accepted only while the strip really is scrolling, which is the one honest reason
        // for it to be there; anything inside the box has to take the press at its own centre.
        const measured = JSON.parse(String(await page.evaluate(
          "(()=>{const rail=document.querySelector('.strip-rail');if(!rail)return JSON.stringify({rail:false,out:[]});"
          + 'const rb=rail.getBoundingClientRect();const scrolls=rail.scrollWidth>rail.clientWidth+1;const out=[];'
          + "for(const b of document.querySelectorAll('.strip-tab-close')){"
          + 'const box=b.getBoundingClientRect();const style=getComputedStyle(b);'
          + 'const x=Math.round(box.left+box.width/2),y=Math.round(box.top+box.height/2);'
          + 'const inside=x>=rb.left&&x<=rb.right&&y>=rb.top&&y<=rb.bottom;'
          + 'const hit=inside?document.elementFromPoint(x,y):null;'
          + 'out.push({inside,w:Math.round(box.width),h:Math.round(box.height),pointer:style.pointerEvents,'
          + 'shown:style.visibility!=="hidden"&&style.display!=="none",off:b.disabled===true,'
          + 'reached:hit!==null&&(hit===b||b.contains(hit))})}'
          + 'return JSON.stringify({rail:true,scrolls,out})})()',
        )));
        if (!measured.rail) return false;
        const onScreen = measured.out.filter((c) => c.inside);
        const scrolledAway = measured.out.filter((c) => !c.inside);
        if (onScreen.length === 0) return false;
        if (scrolledAway.length > 0 && !measured.scrolls) return false;
        return onScreen.every((c) => c.w > 0 && c.h > 0 && c.shown && !c.off && c.pointer !== 'none' && c.reached);
      });

      await expect('and pressing the ✕ on the window it opened takes that window off the bar', async () => {
        // The press itself, on the one ✕ a guard may press: a window it made, which deletes nothing
        // anybody was using. Measuring says a press can land; this says what the press then does.
        await page.click(`[data-tab-id="${opened}"] .strip-tab-close`);
        await page.wait(400);
        return !(await onTheBar()).includes(opened);
      });
    } finally {
      // A guard that leaves a window open changes what the next guard sees, and a guard that
      // depends on what another one left behind is a guard nobody can trust. Pressed in the page
      // rather than with the pointer, because this runs exactly when the pointer may have failed.
      if (opened !== '') {
        await page.evaluate(
          '(()=>{const b=document.querySelector(' + JSON.stringify(`[data-tab-id="${opened}"] .strip-tab-close`)
          + ');if(b)b.click()})()',
        );
      }
    }
  },
};
