/**
 * "This side panel thing is not going away. As soon as I click on any other thing, it is
 * coming up. So maybe I need to stop this." He did — he stopped the copilot to get his rail back.
 */
export default {
  name: 'the copilot’s side panel takes the rail only over the page it is driving, and stays put away once put away',

  fixed: '2026-08-21',

  because:
    'The panel was mounted on "a drive is live" and nothing else, hidden only on the copilot’s own page — so it sat '
    + 'over terminal sessions, over Machines, over the app’s own MCP servers page, and over browser tabs that had '
    + 'nothing to do with the errand. He had stated the rule an hour earlier in the same recording — *"if I am not on '
    + 'the browser window, it will not open, only on the browser window"* — asked for it again at 13:00 and again at '
    + '18:00, and in the end stopped the copilot mid-drive because that was the only way to get the sidebar back. '
    + 'Putting it away did not help: the dismissal was remembered per tab, and the source said so outright — "the panel '
    + 'comes back on the next errand". Underneath both, it was `position: fixed` at a static 264px token over a column '
    + 'whose real width is dragged, so it left a strip of rail showing at one width and clipped the browser’s toolbar '
    + 'at another. Three faults, one panel, and the decision that governs all of them is three lines long.',

  link: 'review-2026-08-21 T38, T39 and T20 — "he said this 2 times", 06:00 and 18:00 of one recording',

  async run({ expect, page, read }) {
    /**
     * The whole decision, lifted out of its module by its braces and RUN.
     *
     * It is exported and pure for exactly this reason: it is the rule that decides whether a
     * panel covers the sidebar at all, and reading the file for the word "front" would pass on
     * every version of this bug — the old code knew about the front page too, it just never
     * asked whether the page in front was the page being driven.
     *
     * Loading the module itself is not an option: it imports React and two siblings without
     * file extensions, which Node will not resolve. The body is plain JavaScript and every
     * TypeScript thing about it is in the signature, so the signature is skipped and the body
     * is handed to a function of this guard's own making. A parameter list that grew a default
     * value with a bracket in it would break the cut, and the checks below would fail loudly
     * rather than quietly.
     */
    const source = String(await read('src/renderer/copilot/driving/rail-panel.ts'));
    const body = (() => {
      const at = source.indexOf('export function railPanelState(');
      if (at < 0) return '';
      const opens = source.indexOf('{', source.indexOf(')', source.indexOf('(', at)));
      let depth = 0;
      for (let i = opens; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}') {
          depth -= 1;
          if (depth === 0) return source.slice(opens + 1, i);
        }
      }
      return '';
    })();
    const decide = body === '' ? null : new Function('drive', 'front', 'folded', body);

    /** A live errand, and the page it is holding — named the way the two halves name it. */
    const errand = { state: 'agent', tabId: 'view-1', step: 'clicking “Sign in”', url: 'https://example.com' };
    const itsPage = { tabId: 'tab-1', viewId: 'view-1' };

    await expect('the decision that governs the panel was found and can be asked', async () => {
      // A rule that cannot be reached is a rule nothing is checking, and every claim below
      // would otherwise throw its way to a failure that reads like the bug rather than like a
      // renamed function.
      return decide !== null && decide(null, null, false) === 'away';
    });

    await expect('nothing of it is drawn while nothing is being driven', async () => {
      // Both quiet states: no errand at all, and an errand that has finished. `idle` is what a
      // drive reports between runs, and a panel that stayed for it would be a panel that never
      // leaves.
      return decide(null, itsPage, false) === 'away'
        && decide({ ...errand, state: 'idle' }, itsPage, false) === 'away';
    });

    await expect('and nothing of it is drawn over anything that is not a browser page', async () => {
      /*
       * His sentence, as one call: *"if I am not on the browser window, it will not open, only
       * on the browser window."* A terminal session, the MCP servers page, Machines, Settings
       * and the copilot's own page are all the same state here — there is no page in front, so
       * there is no `FrontPage`, so the answer is away. This is the exact call the shipped
       * version got wrong, and it got it wrong by never making it.
       */
      return decide(errand, null, false) === 'away';
    });

    await expect('nor over a different browser page than the one the errand is on', async () => {
      // The other half, and the one a looser fix would still fail: "a drive is live" and "a
      // page is in front" both being true does not mean this page is the one being driven. The
      // join is the view id, which is why the store publishes both of a window's names.
      return decide(errand, { tabId: 'tab-2', viewId: 'view-2' }, false) === 'away'
        // And a window that exists but has no page in it yet — the panel is created before its
        // native view is — must not be mistaken for the driven one by an empty id matching an
        // empty id.
        && decide({ ...errand, tabId: '' }, { tabId: 'tab-1', viewId: '' }, false) === 'away';
    });

    await expect('over the page it is actually driving, it takes the rail', async () => {
      // The half that keeps the four above honest. A rule that answered "away" to everything
      // would satisfy all of them and delete the feature.
      return decide(errand, itsPage, false) === 'panel';
    });

    await expect('and once it is put away it stays away, errand after errand', async () => {
      // *"This side panel thing is not going away."* The put-away used to be remembered per
      // browser tab and cleared when the next errand began, so the only way to keep the rail
      // was to stop the copilot. Three different steps of three different errands, on the page
      // it is driving, with the panel folded: not one of them may answer `panel`.
      const errands = [
        errand,
        { ...errand, step: 'reading the page', url: 'https://example.com/two' },
        { ...errand, state: 'human', step: '', url: 'https://example.com/three' },
      ];
      return errands.every((one) => decide(one, itsPage, true) === 'folded');
    });

    await expect('and putting it away is not filed under the page it was put away on', async () => {
      // The mechanism under the claim above, asked where it cannot be faked: a fold that took
      // a page, a tab or an errand to file itself under is a fold that expires when that thing
      // changes, which is what "the panel comes back on the next errand" meant. Empty
      // parentheses are the whole of the fix — there is nothing to key it on.
      return /export function foldRailPanel\(\s*\)/.test(source)
        && /export function openRailPanel\(\s*\)/.test(source);
    });

    /**
     * One rule out of the stylesheets the app has actually loaded, read for the declarations
     * that do the work rather than for its text.
     *
     * Nothing is being driven while a guard runs, so the panel is not on screen and the rules
     * are the only place its arrangement can be checked from — and they are the right place:
     * when this panel stopped floating, its old sheet was deleted with the float.
     *
     * @param {string} selector
     */
    const ruleFor = async (selector) => {
      const found = String(await page.evaluate(
        '(()=>{for(const sheet of document.styleSheets){let rules;try{rules=sheet.cssRules}catch(e){continue}'
        + 'for(const rule of rules){if((rule.selectorText||"").trim()!==' + JSON.stringify(selector) + ')continue;'
        + 'return JSON.stringify({position:rule.style.position,width:rule.style.width,'
        + 'flex:rule.style.flex||rule.style.flexGrow,css:rule.cssText})}}'
        + 'return ""})()',
      ));
      return found === '' ? null : JSON.parse(found);
    };

    await expect('the panel is a part of the rail’s column rather than a sheet floating over it', async () => {
      /*
       * *"This should actually replace with this instead of coming in front of it somehow."*
       * The old panel was `position: fixed` at a fixed width over a column whose width is
       * dragged, and that mismatch is both halves of what he filmed: a strip of rail showing
       * beside it at one width, the page's toolbar clipped at another.
       *
       * There is no width declared in this rule at all, and that absence IS the fix — it is a
       * flex item in the sidebar's own column, so it is the rail's width by construction,
       * whatever the seam was last dragged to. A width appearing here is the bug coming back.
       */
      const rail = await ruleFor('.copilot-rail');
      if (rail === null) return false;
      return rail.position === '' && rail.width === '' && rail.flex !== '';
    });

    await expect('and the one panel that genuinely must float is drawn at the rail’s live width', async () => {
      // The scan's panel cannot join the layout — narrowing `.main` refits every terminal in
      // the window and reflows the buffers its own highlights are anchored to — so it is given
      // the number instead of the column. It was sized with the static token, which is the
      // same fault on the same edge. `var(--…)` reads back empty through `rule.style`, so the
      // declaration is checked on the rule's own text, the one place the variable survives.
      const scan = await ruleFor('.drive-panel');
      if (scan === null) return false;
      return scan.position === 'fixed' && /width:\s*var\(--rail-width/.test(scan.css);
    });

    /** The number that rule reads, and the column it is supposed to describe. */
    const column = await (async () => {
      const answer = String(await page.evaluate(
        '(()=>{const said=getComputedStyle(document.documentElement).getPropertyValue("--rail-width").trim();'
        + 'const rail=document.querySelector("aside.sidebar");'
        + 'return JSON.stringify({said,real:rail?Math.round(rail.getBoundingClientRect().width):null})})()',
      ));
      // Never a throw. An unreadable answer reads as "nothing published", which fails the
      // claim below by name rather than stopping the guard before the last two.
      try {
        return JSON.parse(answer);
      } catch {
        return { said: '', real: null };
      }
    })();

    await expect('that live width is published, in pixels, by the window itself', async () => {
      // Absent, the rule above silently falls back to the 264px token and the whole fix is
      // undone by an effect that stopped running.
      return /^\d+(\.\d+)?px$/.test(column.said) && Number.parseFloat(column.said) > 0;
    });

    if (column.real !== null) {
      await expect('and it is the width the rail is actually drawn at, not a token’s idea of it', async () => {
        // Measured rather than assumed, because this is the half that produced the dead strip
        // and the clipping. Only meaningful when the rail is on screen — collapsed, the
        // element is not rendered at all and there is nothing to measure against.
        return Math.abs(Math.round(Number.parseFloat(column.said)) - column.real) <= 1;
      });
    }

    /** Whether anything is being driven in this copy right now. A read; it steers nothing. */
    const driving = String(await page.evaluate(
      "(async()=>{try{ if(typeof window.deck?.browserDriveStatus!=='function') return 'MISSING';"
      + "const s=await window.deck.browserDriveStatus();"
      + "return String((s&&s.state)||'none') }catch(e){ return 'REJECTED '+String(e&&e.message||e) }})()",
    ));

    await expect('the window can still ask this machine what is being driven', async () => {
      // The panel's whole existence hangs off this answer, and a channel that has quietly gone
      // missing takes the gate with it: the old panel needed only "a drive is live", and a
      // build that cannot ask that is a build where the question is being answered somewhere
      // else again.
      return driving === 'none' || driving === 'idle' || driving === 'agent' || driving === 'human';
    });

    if (driving === 'none' || driving === 'idle') {
      await expect('with nothing being driven, no panel of the copilot’s is on screen', async () => {
        // The weak half, and it is named as weak: the version that shipped the bug also drew
        // nothing while nothing was driving. It is here to catch the next shape of it — a
        // panel mounted on the copilot merely existing, which is one edit away from a panel
        // mounted on a drive existing.
        return (await page.count('.copilot-rail')) === 0;
      });
    }

    /*
     * WHAT THIS GUARD CANNOT REACH, said here rather than left to be assumed.
     *
     * The write-up asks for a copilot drive started on a browser tab and then a walk through
     * the MCP servers page, Machines and a terminal session with nothing drawn over them; for
     * the panel closed, three tabs clicked, and another errand run; and for the sidebar dragged
     * to an unusual width. Every one of those starts something, or stores something: a drive is
     * an agent acting on a real page, and a drag writes a width to disk. A guard may not do
     * either.
     *
     * So the decision they would all exercise is exercised directly instead — every state he
     * found the panel in, by name — and the two things that decision cannot say are measured
     * off the running window: that the panel has no width of its own, and that the number the
     * floating one reads is the column's real one.
     */
  },
};
