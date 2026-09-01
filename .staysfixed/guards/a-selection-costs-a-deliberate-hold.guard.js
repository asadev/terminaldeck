/**
 * "If I scroll, it's coming blue. It's not scrolling, it's selecting." Both
 * numbers were ten, so the same drag scrolled sometimes and selected sometimes.
 */
export default {
  name: 'a selection on the phone terminal costs a deliberate hold, and a drag never starts one',

  fixed: '2026-08-27',

  because:
    'The other half of the one-finger rule. Refusing the library’s drag is not enough on its own: this app installs a '
    + 'long press that starts a selection, and for two rounds that press and the scroll reached their moment of '
    + 'decision on the same touch event — both thresholds were ten points, and nothing in the framework says which is '
    + 'asked first. The same drag scrolled sometimes and selected sometimes, which is worse than either behaviour '
    + 'chosen on purpose. The press was also half a second, which is not a press at all: it is how long somebody rests '
    + 'a finger on a wall of text before dragging it. Measured on a live session, a finger held for 0.65s and then '
    + 'dragged selected eleven lines and moved the terminal by nothing. So four numbers and three declared '
    + 'relationships hold this gesture up, they live in three different files, and the only thing that has ever '
    + 'checked the numbers against each other is a comment.',

  link: 'asks audit IOS-021 — four reports over thirteen days, fixed three times; review-2026-08-26-evening B3',

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
     * The source with its comments taken out.
     *
     * Every rule below is argued at length in prose directly above the code that
     * keeps it — including the numbers, written out in sentences. Three tests in
     * this repository already ban a string by reading source TEXT and fail on a
     * comment that merely mentions it; this is the same trap from the other end,
     * where a rule deleted from the code but still described above it would read
     * as intact.
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
    /** A constant's value, or NaN — which every claim below refuses. */
    const number = (text, name) => {
      const found = new RegExp(`static let ${name}[^=]*=\\s*([0-9.]+)`).exec(text);
      return found === null ? Number.NaN : Number(found[1]);
    };

    const gestures = code(await source('ios/TerminalDeck/Terminal/TerminalGestures.swift'));
    const view = code(await source('ios/TerminalDeck/Terminal/DeckTerminalView.swift'));
    const finger = code(await source('ios/UITests/TerminalScrollUITests.swift'));

    const hold = number(gestures, 'selectionHold');
    const slop = number(gestures, 'selectionSlop');
    const scrollSlop = number(view, 'scrollSlop');
    const hesitation = (() => {
      const found = /static let hesitation[^=]*=\s*([0-9.]+)/.exec(finger);
      return found === null ? Number.NaN : Number(found[1]);
    })();

    await expect('the four numbers this gesture hangs on were really read out of the source', async () => {
      // The floor. A constant that has been renamed comes back as NaN, and NaN
      // compares false against everything — so without this claim a rename would
      // quietly turn every comparison below into a pass about nothing.
      return [hold, slop, scrollSlop, hesitation].every((n) => Number.isFinite(n));
    });

    await expect('a finger on its way to a scroll fails the press before the scroll can begin', async () => {
      /*
       * The inequality the whole gesture rests on, and it lives in two files. Both
       * numbers used to be ten — the scroll view's own hysteresis — so a finger
       * crossing that distance reached the press's failure and the scroll's start
       * on the same touch event, and the outcome was a race. Below it, the press
       * fails first every time: an ordering rather than a coin toss.
       */
      return slop < scrollSlop;
    });

    await expect('and not so far below it that a resting hand’s tremor cancels a deliberate press', async () => {
      // A finger on glass wanders two or three points on its own. A press that
      // failed on that would be a copy gesture only steady hands can make.
      return slop >= 4;
    });

    await expect('the press is longer than a hesitation, and short enough that a test can still make it', async () => {
      // Half a second is a pause before a scroll, not a long press — measured, on
      // a live session. The ceiling is the tooling: the runner cannot synthesise a
      // stationary hold much past six tenths, so a press pushed far above this is
      // one nothing can exercise at all.
      return hold >= 0.65 && hold <= 0.8;
    });

    await expect('the one test that puts a finger on glass still holds for less time than the app asks', async () => {
      /*
       * The cross-file relationship nothing else checks. `TerminalScrollUITests`
       * presses for a measured hesitation and then drags, and it proves scrolling
       * only while that hesitation is SHORTER than the app's threshold. Lower the
       * threshold back towards half a second — which is what two of the three
       * rounds did — and that test starts selecting: on a phone it goes red, and
       * on every machine without a phone it goes quiet. This is the half that
       * still says something here.
       */
      return hesitation < hold;
    });

    await expect('one finger scrolls, and only one', async () => {
      // The scroll view will drive its pan with any number of fingers, so without
      // this a two-finger pinch also slides the scrollback out from under the text
      // it is resizing. He asked for the one-finger rule twice.
      return /panGestureRecognizer\.maximumNumberOfTouches\s*=\s*1/.test(gestures);
    });

    await expect('nothing may start a selection on a terminal that is already moving', async () => {
      /*
       * The hole the timing cannot close: a press is only asked whether it may
       * begin when its timer fires, and by then the finger may have been resting
       * on content that is scrolling. A slow scroll that paused to read, and a
       * finger put down to stop a flick — both mean *stop* on every other surface
       * on the phone, and both used to turn the screen blue here.
       */
      const first = tidy(block(gestures, gestures.indexOf('func gestureRecognizerShouldBegin')));
      return /^if isSelectionGesture\([^)]*\),\s*terminal\.isScrolling \{ return false \}/.test(first);
    });

    await expect('the scroll and the two selection gestures may never own the finger together', async () => {
      /*
       * A recogniser that has already begun is never asked whether it may begin,
       * so the refusals are blind to the case where the scroll started first and
       * the press fired afterwards. Under a blanket "yes, run together" both then
       * own the finger and the selection grows while the content slides under it.
       * The tap and the pinch stay simultaneous on purpose — one only observes,
       * the other is two fingers.
       */
      const rule = tidy(block(gestures, gestures.indexOf('shouldRecognizeSimultaneouslyWith')));
      return rule.includes('terminal.panGestureRecognizer')
        && rule.includes('!isSelectionGesture(gestureRecognizer)')
        && rule.includes('!isSelectionGesture(other)');
    });

    await expect('and the scroll waits for the selection drag to say no', async () => {
      // Both are pans with the same threshold and the order they are consulted in
      // is undefined, so dragging the end of a selection scrolled the terminal
      // about half the time. A failure requirement makes it a rule; it costs
      // nothing, because the selection drag refuses itself in the same event
      // unless the finger came down on a selection's end.
      const rule = tidy(block(gestures, gestures.indexOf('shouldBeRequiredToFailBy')));
      return rule.includes('=== selectionDrag') && rule.includes('=== terminal.panGestureRecognizer');
    });

    const android = code(await source('android/terminal-view/src/main/java/com/termux/view/TerminalView.java'));

    await expect('on the other phone, the only thing that starts a selection is still the long press', async () => {
      /*
       * Android was right the whole time and is checked anyway, because the
       * terminal view it is right *inside* is vendored into this repository — a
       * folder somebody will one day update from upstream, which is exactly how a
       * gesture rule that nobody wrote down comes back. One call, and it is in the
       * long press: not in a drag, not in a touch handler.
       */
      const calls = (android.match(/startTextSelectionMode\(/g) || []).length;
      const press = block(android, android.indexOf('void onLongPress(MotionEvent event)'));
      // Two: the declaration of the method, and the one call inside the press.
      return calls === 2 && press.includes('startTextSelectionMode(');
    });

    await expect('and a finger that is not a mouse scrolls it', async () => {
      // The gate that made this platform correct without anybody arguing about
      // it: a drag is reported to the program as a mouse move only when it really
      // came from a mouse. Everything else scrolls.
      const scroll = tidy(block(android, android.indexOf('boolean onScroll(')));
      return scroll.includes('isFromSource(InputDevice.SOURCE_MOUSE)') && scroll.includes('doScroll(');
    });

    /*
     * What is NOT proved here.
     *
     * That a hold of the right length still selects, on glass. It is deliberately
     * not tested on a phone either, and the reason is written into
     * `TerminalScrollUITests`: the runner cannot synthesise a stationary hold
     * longer than about six tenths of a second whatever it is asked for, bisected
     * one variable at a time. Writing a green test by lowering the app's threshold
     * until the tool could reach it would be testing the tool. The gesture is on
     * the by-hand list in `ios/WhatToTest.md` before a release, and the ceiling
     * above keeps it a gesture a hand can make.
     *
     * The refusal of the library's own drag — the other half of this defect — is
     * in `one-finger-always-scrolls-the-terminal` and is not restated here.
     */
  },
};
