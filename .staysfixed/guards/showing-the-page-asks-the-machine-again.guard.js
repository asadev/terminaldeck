/**
 * "but it is still not opening after closing" — the pane open, the words
 * *Asking for the page…* on it, for ever. Caused by the previous round's fix.
 */
export default {
  name: 'showing a folded page asks the machine for it again, whatever the wire believes',

  fixed: '2026-08-26',

  because:
    'Three rounds on one sentence, and the last cause was our own previous fix. Pressing *Show the page* wrote '
    + '"Asking for the page…" on the screen and then asked for nothing at all, because a guard in front of the rebuild '
    + 'read "is this window already casting" — a fact that stays TRUE across a fold, since folding changes only the '
    + 'height and the canvas is deliberately kept mounted at zero height so the fold does not stop the cast. On a page '
    + 'with no reason to repaint, no frame was ever coming to end that sentence. Underneath it the canvas made the '
    + 'same mistake from the other side: it renegotiated on width alone, and a fold moves only height, so a canvas '
    + 'that had lost its cast or its frame sink while it had no box had no moment at which it would ever ask again. '
    + 'Both are one-line rules, both sounded right, and both were bought with a guarantee this feature does not have.',

  link: 'review-2026-08-25-night ROUND-3 X2 / asks audit IOS-107, eight mentions',

  async run({ expect, read }) {
    /** A file, or nothing where there is no such file — see the first claim. */
    const source = async (file) => {
      try {
        return String(await read(file));
      } catch {
        return '';
      }
    };

    /**
     * The source with its comments taken out — and here that is the whole of
     * whether this guard means anything.
     *
     * The fact this rule must never read is named eleven times in the prose of
     * these two files, in the paragraphs explaining why it must never be read.
     * A guard matching raw text would find it every time and report the defect
     * that is being *described*. It is the same trap that failed three iOS tests
     * in one night on 2026-08-26 from the other end, where a comment naming a
     * banned string failed exactly like using it.
     *
     * @param {string} text
     */
    const code = (text) => {
      let out = '';
      let at = 0;
      let depth = 0;
      let inString = false;
      while (at < text.length) {
        const two = text.slice(at, at + 2);
        if (depth > 0) {
          if (two === '/*') { depth += 1; at += 2; continue; }
          if (two === '*/') { depth -= 1; at += 2; continue; }
          out += text[at] === '\n' ? '\n' : ' ';
          at += 1;
          continue;
        }
        if (inString) {
          if (text[at] === '\\') { out += text.slice(at, at + 2); at += 2; continue; }
          if (text[at] === '"') inString = false;
          out += text[at];
          at += 1;
          continue;
        }
        if (two === '//') { while (at < text.length && text[at] !== '\n') at += 1; continue; }
        if (two === '/*') { depth = 1; at += 2; continue; }
        if (text[at] === '"') inString = true;
        out += text[at];
        at += 1;
      }
      return out;
    };

    /** What is between the braces of the block that starts after `from`. */
    const block = (text, from) => {
      if (from < 0) return '';
      const start = text.indexOf('{', from);
      if (start < 0) return '';
      let depth = 0;
      for (let at = start; at < text.length; at += 1) {
        if (text[at] === '{') depth += 1;
        else if (text[at] === '}') {
          depth -= 1;
          if (depth === 0) return text.slice(start + 1, at);
        }
      }
      return '';
    };

    const tidy = (text) => text.replace(/\s+/g, ' ').trim();

    const screen = code(await source('ios/TerminalDeck/Screens/SessionPageView.swift'));
    const canvas = code(await source('ios/TerminalDeck/Screens/WatchView.swift'));

    await expect('both rules this defect was made of are still in the phone app’s source', async () => {
      // The floor. Every claim below judges the text of a small function, and a
      // function this guard could not find would let all of them pass on an empty
      // string — a guard that proves nothing while reporting that it did.
      return screen.includes('enum SessionPageAsk') && canvas.includes('enum WatchRenegotiation')
        && tidy(block(screen, screen.indexOf('private func askForThePage'))).length > 20;
    });

    await expect('what a press for the page does never reads whether a cast is already running', async () => {
      /*
       * The rule is a type rather than a line of code precisely so that the thing
       * it must not depend on is written into its signature and can be held there.
       * The fact is handed in and deliberately dropped: it means "a watch of ours
       * is left and something is registered to draw the answer", both of which
       * survive a fold, and reading it is what made the control dead.
       */
      const rule = block(screen, screen.indexOf('static func canvas(isCasting:'));
      return rule.trim().length > 0 && rule.includes('isCasting') === false;
    });

    await expect('and there is exactly one answer it can give, so a new one cannot pass silently', async () => {
      // One case, and a switch with no default at the only place it is asked. A
      // future round that decides some picture is worth leaving alone has to add a
      // case, which breaks that switch and fails a test — rather than quietly
      // reusing a fact that has already cost him three reports.
      const cases = (block(screen, screen.indexOf('enum SessionPageAsk'))
        .match(/^\s*case\s+[a-zA-Z]\w*\s*$/gm) || []).length;
      const asked = block(screen, screen.indexOf('switch SessionPageAsk.canvas'));
      return cases === 1 && /\bdefault\s*:/.test(asked) === false && asked.includes('recast()');
    });

    await expect('pressing for the page asks, every time, with nothing standing in front of it', async () => {
      /*
       * The line that was here is the whole of his third report — a guard that
       * returned early, after the asking sentence had already been put on the
       * screen. So this body may not refuse itself: no guard, no early return.
       * It says what is happening, re-reads the machine's windows, and rebuilds.
       */
      const press = tidy(block(screen, screen.indexOf('private func askForThePage')));
      return /\bguard\b/.test(press) === false && /\breturn\b/.test(press) === false
        && press.includes('reread()') && press.includes('recast()');
    });

    await expect('and the rebuild is a real one — a new canvas, not a redraw', async () => {
      // Only a new canvas re-adopts the frame sink and sends a fresh watch, and a
      // fresh watch is the only way pixels come back for a page that has no reason
      // to repaint. The token is in the canvas's identity, which is what makes the
      // rebuild happen rather than being an intention.
      const rebuild = tidy(block(screen, screen.indexOf('private func recast()')));
      return /pageHeight\s*=\s*0/.test(rebuild) && /recastToken\s*\+=\s*1/.test(rebuild)
        && screen.includes('recastToken)');
    });

    await expect('unfolding the pane and asking for the page are one act', async () => {
      // It was two lines that moved the pane, on the assumption that a page folded
      // away is a page still arriving. One sink, one watcher on the host and three
      // screens that can mount a canvas make that false, so the chevron must never
      // again be a state change against a cast that has stopped.
      return tidy(block(screen, screen.indexOf('private func show()'))).includes('askForThePage()');
    });

    await expect('and folding it still stops nothing', async () => {
      // The other side of the same rule, and the reason the guard above it was
      // wrong: the canvas is kept mounted through a fold on purpose. If folding
      // ever starts telling the host to stop, the window closes, the agent's
      // window goes with it, and this becomes a much larger defect than a dead
      // button.
      const away = tidy(block(screen, screen.indexOf('private func fold()')));
      return away.length > 0 && /unwatch|stopWatching|stopCasting/i.test(away) === false;
    });

    await expect('a canvas whose box came back from nothing asks the host again', async () => {
      /*
       * The second mechanism, one file over. The width test is still right for
       * what it was written for — a rotation renegotiates, and the keyboard moves
       * the height on every keystroke, so a re-watch per height change would be a
       * page that flickers under somebody's hands. What it could not see is a box
       * that went to NOTHING and came back, which is exactly what a fold does.
       * Zero is not a smaller box, it is no box: nothing was drawn, so there is
       * nothing to protect by staying quiet.
       */
      const rule = tidy(block(canvas, canvas.indexOf('static func asksAgain(')));
      return rule.includes('width != lastWidth')
        && rule.includes('hasRoom') && rule.includes('!hadRoom')
        && /height/i.test(rule) === false;
    });

    await expect('and the canvas measures its box on both sides, since a fold only moves the height', async () => {
      // The caller is half the rule: a box measured on width alone is the same
      // defect with the arithmetic moved. Asking is also when the frame sink is
      // re-taken, because this canvas may have been mounted and blind the whole
      // time it had no box — a canvas on another tab takes the sink with no
      // callback here at all.
      const laid = tidy(block(canvas, canvas.indexOf('override func layoutSubviews')));
      return laid.includes('bounds.height') && laid.includes('hasRoom:') && laid.includes('hadRoom:')
        && laid.includes('adopt()') && laid.includes('startWatching()');
    });

    await expect('the tests that hold both halves are still compiled', async () => {
      // A test file that is not built is a comment, and this project is generated
      // from a spec. The two named here are the two mechanisms: the answer that
      // must not depend on the fact it is handed, and the keystroke that must not
      // restart a screencast.
      const tests = code(await source('ios/Tests/SessionPageTests.swift'));
      const spec = await source('ios/project.yml');
      return /TerminalDeckTests:[\s\S]{0,400}?path:\s*Tests\b/.test(spec)
        && tests.includes('func testTheAnswerDoesNotDependOnTheOneFactItIsHanded')
        && tests.includes('func testAKeyboardChangingTheHeightNeverRestartsTheCast')
        && tests.includes('func testACanvasThatComesBackFromNothingAsksForTheCastAgain');
    });

    /*
     * What is NOT proved here.
     *
     * That real pixels arrive within a few seconds of the press. That needs the
     * phone app AND a machine it can reach, because the press genuinely goes to a
     * host, which renders and encodes a full frame of a desktop-width page before
     * anything on that screen can change. `ios/UITests/SessionPageUITests.swift`
     * does exactly that walk — fold, show, and then wait for the asking line to
     * become either a picture or a different sentence — and it skips loudly
     * without a paired harness.
     *
     * One line of the original report has since been overtaken and a guard should
     * not put it back: *"in any session even co-pilot"*. The copilot deliberately
     * has no floating page any more — *"the floating browser-window pill must be
     * GONE while inside the copilot chat"* — so a claim about a page folded inside
     * a copilot session would now be a claim about a surface that is not there.
     */
  },
};
