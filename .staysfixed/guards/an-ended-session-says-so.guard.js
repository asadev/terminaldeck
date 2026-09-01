/**
 * The connection had ended, and underneath the line saying so the agent was still drawn as live.
 */
export default {
  name: 'a session that has ended says so, instead of leaving a live-looking agent on screen',

  fixed: '2026-08-24',

  because:
    'Asad filmed a session whose connection had ended. Under the line saying the connection ended, the pane still showed '
    + 'a running agent — its composer, its placeholder, its effort chip, its permission footer. All four belong to the '
    + 'agent, not to this app: they are the last frame it painted before its pty went away, and a terminal emulator has '
    + 'no reason of its own to stop showing the last frame it was given. Nothing in the app ever told the pane its '
    + 'session was over. Worse, the controls above stayed pressable and the keyboard went on accepting keystrokes that '
    + 'were read and thrown away in silence — one terminal matched no branch, the other handed the bytes to a link that '
    + 'answered false into a call site that dropped the answer. Liveness was read in two places and neither of them was '
    + 'the pane, so every new terminal surface added here is a fresh chance to repeat it.',

  link: '398af33 Say what happened when a session ends, instead of leaving its last frame on',

  async run({ expect, page }) {
    // No session is started here and none is killed. A guard may not create the thing it watches,
    // so what is asked of the running app is the two halves that make the notice possible at all:
    // the doors the news arrives through, and the rules that draw it over the frozen frame. The
    // keystroke half — that typing into a dead pane now changes something on screen — needs a live
    // session to kill, and is named here rather than quietly left out.

    /**
     * The three ways a session ends that the notice has separate words for: the program in it
     * finished, a shell on a server closed, the far machine went away. Each is a different door
     * into this window, and the bug is what happens when one of them is not there — the pane is
     * never told, so it goes on drawing a photograph as if it were live.
     */
    const doors = [
      ['onSessionExit', 'a session on this computer has ended'],
      ['onServerShellClosed', 'a shell on a server has closed'],
      ['onMachinesState', 'a paired machine has gone away'],
    ];

    for (const [door, news] of doors) {
      await expect(`the window can still hear that ${news}`, async () => {
        // Subscribing and immediately unsubscribing, which changes nothing and is the only way to
        // learn that the door works in both directions. A subscription that hands back no way to
        // stop listening cannot be cleaned up by the effect that opened it, and that is a real
        // shape in this bridge rather than a hypothetical one.
        const said = String(await page.evaluate(
          `(()=>{try{ const open = window.deck && window.deck.${door};
             if (typeof open !== 'function') return 'MISSING';
             const stop = open(() => {});
             if (typeof stop !== 'function') return 'NO WAY BACK';
             stop();
             return 'OK';
           }catch(e){ return 'REJECTED ' + String(e && e.message || e) }})()`,
        ));
        return said === 'OK';
      });
    }

    /**
     * One rule out of the stylesheets the app has actually loaded, read for the declarations that
     * do the work rather than for its text. Nothing on screen is an ended session while a guard is
     * running, so the rules are the only place the drawing can be checked from — and they are the
     * right place: when the notice was dropped once before, its stylesheet went with it.
     *
     * @param {string} test A JavaScript expression over `sel`, the rule's own selector.
     */
    const ruleWhere = async (test) => {
      const found = String(await page.evaluate(
        '(()=>{for(const sheet of document.styleSheets){let rules;try{rules=sheet.cssRules}catch(e){continue}'
        + 'for(const rule of rules){const sel=(rule.selectorText||"").trim();if(sel===""||!(' + test + '))continue;'
        + 'return JSON.stringify({sel,opacity:rule.style.opacity,filter:rule.style.filter,'
        + 'position:rule.style.position,bottom:rule.style.bottom,z:rule.style.zIndex,css:rule.cssText})}}'
        + 'return ""})()',
      ));
      return found === '' ? null : JSON.parse(found);
    };

    await expect('a pane whose session is over still fades its frozen frame and drains the colour out of it', async () => {
      const fade = await ruleWhere('/data-ended/.test(sel) && /terminal-surface/.test(sel)');
      if (fade === null) return false;
      // Both halves, because they answer different parts of "this is a photograph". A Claude Code
      // frame is mostly colour — an orange spinner, a green diff — and fading alone leaves those
      // reading as live state at half strength.
      const opacity = Number(fade.opacity);
      return Number.isFinite(opacity) && opacity > 0 && opacity < 1 && /saturate\(/.test(String(fade.filter));
    });

    await expect('and the notice stands over the composer at the foot of the pane', async () => {
      // The placement is the whole point rather than a layout preference: the composer, its
      // placeholder and the permission footer are one block of the agent's own drawing at the
      // bottom of its output, and that block is what invited the keystroke.
      const notice = await ruleWhere('sel === ".session-ended"');
      if (notice === null) return false;
      // The distance is read as a number rather than compared to the text in the stylesheet.
      // `bottom: 0` is what the file says and `0px` is what the CSSOM says back — Blink
      // re-serialises every length it parses, so a string comparison against the authored
      // token is a comparison against something the browser never returns. Read as a number,
      // `0`, `0px` and `0rem` are the one thing this cares about: the notice is flush with
      // the foot of the pane, over the composer rather than floating above it.
      const flushToFoot = Number.parseFloat(String(notice.bottom));
      return notice.position === 'absolute' && flushToFoot === 0 && Number(notice.z) >= 1;
    });

    await expect('the notice is a card with a ground of its own, not a line lost in the frame behind it', async () => {
      // A card with no background sits on the faded frame and reads as part of it, which is the
      // state this whole notice exists to end. `var(--…)` values are pending substitutions in the
      // CSSOM and read back empty through `rule.style`, so the declaration is checked on the rule's
      // own text — the one place a variable is still visible.
      const card = await ruleWhere('sel === ".session-ended-card"');
      if (card === null) return false;
      return /background:/.test(card.css) && /border:/.test(card.css);
    });
  },
};
