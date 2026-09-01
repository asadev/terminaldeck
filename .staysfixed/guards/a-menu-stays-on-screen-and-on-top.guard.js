/**
 * *"If I now click on three dots, the drop-down is coming in the backside, both
 * of them."* And, of the row menu near the foot of a pane: Rename and Remove
 * drawn under the footer, with nothing to press.
 */
export default {
  name: 'a menu or sheet stays fully on screen, above the page, with every row reachable',

  fixed: '2026-08-21',

  because:
    'Three surfaces, two days, one shape. His words for the first: *"if I now click on three dots, the drop-down is '
    + 'coming in the backside, both of them. They should be the top first layer."* And *"it\'s hiding behind. I cannot '
    + 'even see what it shows."* The audit found the second on its own — the settings row menu clipped by its own '
    + 'scrolling pane whenever the row sat near the bottom of the list, measured at 1280×900 as a box of '
    + '`{y: 757.8, h: 98}` against a pane ending at 786, so Use by default, Rename and Remove were all under the footer '
    + 'and none could be pressed. The third was the folded Session-controls sheet running 32 pixels past the bottom of a '
    + '560-pixel window with no scroll, so the rows below the fold could not be reached at all. Two causes underneath. '
    + 'One is a popover placed against its button with no check that the result fits and no cap on its height — and the '
    + 'caps that looked like they answered it could not, because a percentage in `max-height` resolves against the '
    + 'containing block\'s HEIGHT and never against how far down the window that block sits, so the formula subtracted a '
    + '28-pixel chip row and nothing at all for the chrome above it. The other cannot be fixed with CSS in any form: a '
    + 'web page here is a native child view composited ABOVE the whole renderer, so a menu over it is painted over '
    + 'rather than clipped, and no z-index, portal, stacking context or `isolation` reaches it. That one has been '
    + 'rediscovered twice already.',

  link: 'review-2026-08-21 T45; review-2026-08-20 STILL-WRONG NEW-2 and B3; review-2026-08-25-night W9; asks-audit BRO-042',

  async run({ expect, page, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /* ─────────────────────────────────────────────────────────────────────
       Every floating surface in the family, read out of the running stylesheet.

       The CSSOM rather than the source file: what a `.css` in the tree says and
       what the app is painting with are two different questions, and this app
       has already shipped a stylesheet that silently stopped applying half way
       down. Declarations are merged across every rule carrying the selector,
       because three of these four are written twice.

       THE ORDER OF THE TWO LINES IN `walk` IS THE WHOLE THING, and getting it
       wrong cost this guard a false alarm on 2026-09-02. It used to ask "does
       this rule have children?" first and `continue` when it did — reading a
       plain rule's selector only in the branch where it had none. That is
       correct against the CSSOM of about 2022 and wrong against every Chromium
       that speaks CSS Nesting: `CSSStyleRule` is a grouping rule now, so
       `rule.cssRules` is an empty `CSSRuleList` on an ordinary rule rather than
       `undefined` — and an empty `CSSRuleList` is an object, so it is truthy.
       Every single style rule took the children branch, recursed into nothing
       and skipped its own selector, so the walk read 3,411 rules and matched
       none of them. All four surfaces came back `found:false`, which reads
       exactly like "somebody deleted the fix" and was in fact "this guard
       cannot see". Read the rule first; descend only where there is something
       to descend into.
       ───────────────────────────────────────────────────────────────────── */
    const surfaces = JSON.parse(String(await page.evaluate(
      '(()=>{const want=[".bw-popup",".settings-rowmenu-items",".sc-sheet",".ub-sheet"];'
      + 'const out={};for(const sel of want)out[sel]={found:false,cap:"",scroll:""};'
      + 'const walk=(rules)=>{for(const rule of rules){'
      + 'if(rule.selectorText&&rule.style){'
      + 'const parts=String(rule.selectorText).split(",").map(s=>s.trim());'
      + 'for(const sel of want){if(!parts.includes(sel))continue;const one=out[sel];one.found=true;'
      + 'const cap=rule.style.getPropertyValue("max-height")||rule.style.getPropertyValue("max-block-size");'
      + 'if(cap)one.cap=cap;'
      + 'const flow=rule.style.getPropertyValue("overflow-y")||rule.style.getPropertyValue("overflow");'
      + 'if(flow)one.scroll=flow}}'
      + 'if(rule.cssRules&&rule.cssRules.length)walk(rule.cssRules)}};'
      + 'for(const sheet of document.styleSheets){try{walk(sheet.cssRules)}catch(e){}}'
      + 'return JSON.stringify(out)})()',
    )));

    await expect('all four floating surfaces are still in the stylesheet the app is painting with', async () => {
      // A surface that has vanished from the CSSOM is either renamed or behind a
      // bracket somebody left open, and both of those read as "the checks below
      // found nothing to complain about".
      return Object.values(surfaces).every((one) => one.found === true);
    });

    await expect('every one of them is capped in height and scrolls inside itself', async () => {
      // The shared cause, in one sentence: a popover with no room check. A cap
      // with no scroll is worse than neither — it hides the rows instead of
      // running past the edge with them.
      return Object.values(surfaces).every((one) =>
        one.cap !== '' && /^(auto|scroll)$/.test(one.scroll.trim()));
    });

    await expect('the three that hang off a bar or a row take their cap from a measured number', async () => {
      // And this is the half that made the first fix look like a fix. The old cap
      // was `min(560px, calc(100vh - 100% - var(--sp-8)))`, which reads exactly
      // like "the window, less what is above me" and is not: `100%` resolves
      // against the containing block's height. The number CSS cannot name is
      // published by `sheet-room.ts` and `menu-room.ts` at the moment the panel
      // opens, and a cap that stops naming one of those variables is the old
      // arithmetic back, looking correct.
      return /--sheet-room/.test(surfaces['.sc-sheet'].cap)
        && /--sheet-room/.test(surfaces['.ub-sheet'].cap)
        && /--menu-room/.test(surfaces['.settings-rowmenu-items'].cap);
    });

    /* ─────────────────────────────────────────────────────────────────────
       And the same thing measured, on the surface the audit measured.

       Settings is opened here and closed again in the `finally`. Guards share
       one running app and run one after another, so nothing below assumes what
       was on screen when it started, and nothing is left behind for the next one
       to trip over. Opening a disclosure and reading where it landed changes no
       setting, no session and nothing on disk.
       ───────────────────────────────────────────────────────────────────── */
    const openedSettings = Boolean(await page.evaluate(
      '(()=>{const b=document.querySelector(".sb-settings");if(b)b.click();return Boolean(b)})()',
    ));
    await page.wait(900);

    try {
      await expect('Settings is open, so there is a pane with a clipping edge to measure against', async () => {
        return openedSettings && Boolean(await page.evaluate('Boolean(document.querySelector(".modal-overlay .settings"))'));
      });

      // The pane the row menu was measured in. Chosen by the section's own id
      // rather than by the words on the tab: this rail has been renamed twice in
      // two days, and a guard that matched the label would have died with it.
      await page.evaluate(
        '(()=>{const t=document.querySelector(\'.settings-nav-item[data-section="agents"]\');if(t)t.click();return Boolean(t)})()',
      );
      await page.wait(900);

      // Every row's ⋯ menu, opened. A `toggle` event is queued by the browser
      // rather than fired inline, and `placeRowMenu` runs on it, so the
      // measurement has to wait for that turn or it reads the placement the
      // stylesheet alone produced — which is the unfixed geometry.
      const opened = Number(await page.evaluate(
        '(()=>{const all=[...document.querySelectorAll("details.settings-rowmenu > summary")];'
        + 'for(const s of all)s.click();return all.length})()',
      ));
      await page.wait(500);

      const measured = JSON.parse(String(await page.evaluate(
        '(()=>{const out=[];'
        + 'for(const menu of document.querySelectorAll("details.settings-rowmenu[open]")){'
        + 'const panel=menu.querySelector(".settings-rowmenu-items");if(!panel)continue;'
        + 'const box=panel.getBoundingClientRect();if(box.width<1||box.height<1)continue;'
        + 'const rows=[...panel.querySelectorAll("button")];'
        + 'const last=rows.length?rows[rows.length-1].getBoundingClientRect():null;'
        + 'let reachable=false;'
        + 'if(last&&last.width>1&&last.height>1){'
        + 'const at=document.elementFromPoint(Math.round(last.left+last.width/2),Math.round(last.top+last.height/2));'
        + 'reachable=Boolean(at&&panel.contains(at))}'
        + 'let clip={top:0,bottom:window.innerHeight};'
        + 'for(let node=panel.parentElement;node;node=node.parentElement){'
        + 'const style=getComputedStyle(node);'
        + 'if(/(auto|scroll|hidden)/.test(style.overflowY+" "+style.overflow)){'
        + 'const r=node.getBoundingClientRect();clip={top:r.top,bottom:r.bottom};break}}'
        + 'out.push({top:Math.round(box.top),bottom:Math.round(box.bottom),'
        + 'left:Math.round(box.left),right:Math.round(box.right),rows:rows.length,reachable,'
        + 'clipTop:Math.round(clip.top),clipBottom:Math.round(clip.bottom),'
        + 'scrolls:panel.scrollHeight>panel.clientHeight+1,'
        + 'width:window.innerWidth,height:window.innerHeight})}'
        + 'return JSON.stringify(out)})()',
      )));

      await expect('there is at least one row menu here to open, so this is measuring something', async () => {
        // Said as its own sentence rather than folded into the checks below,
        // where an empty list would quietly make all three true. A window with no
        // agent account in it has no row to hang a menu off; add one, or run this
        // where there is one.
        return opened > 0 && measured.length > 0;
      });

      await expect('every one of them is drawn entirely inside the window', async () => {
        // *"Now, see this window is going out of the frame. This one also going
        // out of the frame."* One pixel of slack for sub-pixel layout; the real
        // fault was 32 and 70.
        return measured.every((one) =>
          one.top >= -1 && one.left >= -1 && one.bottom <= one.height + 1 && one.right <= one.width + 1);
      });

      await expect('and inside the pane that clips it, or scrolling because it cannot be', async () => {
        // The exact defect: a box of `{y: 757.8, h: 98, bottom: 855.8}` inside a
        // pane ending at 786. Either it fits in the pane, or it has been capped
        // to the room there is and can be scrolled — never neither, which is the
        // shape that put three items under a footer.
        return measured.every((one) =>
          (one.top >= one.clipTop - 1 && one.bottom <= one.clipBottom + 1) || one.scrolls);
      });

      await expect('and its last item is reachable, not painted under something else', async () => {
        // The whole point of the complaint. A menu that is technically on screen
        // and whose bottom row belongs to whatever is drawn over it is the same
        // dead end as a menu off the edge. `elementFromPoint` is the only honest
        // way to ask "could this be clicked" — a rectangle alone cannot say.
        return measured.every((one) => one.rows > 0 && one.reachable === true);
      });
    } finally {
      // Closed in the order it was opened, and the window put back as it was
      // found. A guard that leaves a modal up changes what every guard after it
      // reads, and a guard that depends on what another one left behind is a
      // guard nobody can trust.
      await page.evaluate(
        '(()=>{for(const menu of document.querySelectorAll("details.settings-rowmenu[open]"))menu.open=false;'
        + 'const close=document.querySelector(".modal-overlay .modal-close");if(close)close.click();'
        + 'return true})()',
      );
      await page.wait(400);
    }

    /* ─────────────────────────────────────────────────────────────────────
       The compositing half, which no rectangle on this screen can prove.

       A menu over a website is not clipped, it is PAINTED OVER: the page is a
       native child view of the window and the whole renderer is one leaf below
       it in the window's own view tree. So the two things that make the fix
       possible are read where they are written, and the pixel proof — a menu
       opened over a real site, looked at — needs a page loaded and a person or a
       screenshot, which a guard may not go and fetch off the internet. What is
       below is the mechanism, not the picture, and it is said out loud that they
       are not the same thing.
       ───────────────────────────────────────────────────────────────────── */

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter. Each rule below is written down in prose directly above
     * the line that implements it — including the paragraph explaining that
     * `z-index` cannot fix this — so a plain search would find the explanation
     * and pass on a build that had stopped obeying it. Three tests on this
     * project have already failed from the other direction, on their own
     * comments.
     *
     * @param {string} rel
     */
    const code = async (rel) => {
      const raw = await fsp.readFile(path.join(project.paths.root, rel), 'utf8');
      return raw
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/^[ \t]*\/\/.*$/gm, ' ')
        .replace(/\s+/g, ' ');
    };

    await expect('the app still watches for a floating surface landing on a page, by that page\'s own rectangle', async () => {
      // Geometry, not "an overlay is open": parking the page for every floating
      // surface would blank a whole website whenever the pointer rested on a
      // sidebar row. The selector is the page's own stage element, and it is the
      // one name the watcher has for the thing it must not be drawn under.
      const watch = await code('src/renderer/browser/overlay-watch.ts');
      return /export const NATIVE_VIEW_SELECTOR = '\.bw-stage'/.test(watch)
        && /export function overlap\(a: Rect, b: Rect\): Rect \| null/.test(watch);
    });

    await expect('and the browser\'s own popups are still portalled where that watcher can see them', async () => {
      // Two sources feed the watcher, and portals into `<body>` are the one that
      // catches surfaces written after it. A popup that stayed inside the
      // workspace's own tree would be invisible to it and painted behind the
      // website — with nothing in the code looking wrong.
      const popup = await code('src/renderer/browser/AnchoredPopup.tsx');
      return /createPortal\(/.test(popup) && /document\.body,?\s*\)/.test(popup);
    });

    await expect('and a popup is still placed by arithmetic that knows where the window ends', async () => {
      // `anchorPopup` is the flip-slide-clamp that keeps a popup on screen when
      // the button it belongs to is at the very bottom or the very right. It is
      // pure and DOM-free precisely so the edge cases can be held to something;
      // losing the clamp is losing the last of the three.
      const anchor = await code('src/renderer/browser/popup-anchor.ts');
      return /export function anchorPopup\(anchor: Box, popup: Size, viewport: Size\): Placement/.test(anchor)
        && /const maxTop = viewport\.height - popup\.height - MARGIN/.test(anchor)
        && /const maxLeft = viewport\.width - popup\.width - MARGIN/.test(anchor);
    });
  },
};
