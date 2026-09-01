/**
 * Fixed, shipped, and he filmed it selecting again the next day: the fix kept an
 * exception for full-screen programs, and the one program he uses is one.
 */
export default {
  name: 'one finger on the phone terminal always scrolls, with no exception left for a full-screen program',

  fixed: '2026-08-27',

  because:
    'Dragging one finger down the terminal on his phone turned the screen blue instead of scrolling it. The terminal '
    + 'library installs a pan of its own that reads a one-finger drag as a text selection, and the first two attempts '
    + 'refused it only in some modes — the last of them let it through on the alternate screen while a program had '
    + 'mouse reporting on, which is exactly what a coding agent runs in. So the one thing he uses this app for fell '
    + 'straight through the hole and he reported the same defect against a build that already carried its fix: '
    + '"it is still not scrolling in terminal with one finger, its selecting the text." Four reports over thirteen '
    + 'days, fixed three separate times. The shape that lets it back is always the same — an exception that reads '
    + 'sensibly in the file and is wrong under his thumb — so the rule is now absolute and has to stay absolute.',

  link: '5e9f18b One finger always scrolls the terminal — no alternate-screen exception (asks audit IOS-021)',

  async run({ expect, read }) {
    /**
     * A file, or an empty string where there is no such file.
     *
     * A moved file must fail as a sentence somebody can act on rather than as a
     * stack trace in the middle of a release — and it must never be mistaken for
     * a clean sweep, which is what the first claim below is for.
     *
     * @param {string} file
     */
    const source = async (file) => {
      try {
        return String(await read(file));
      } catch {
        return '';
      }
    };

    /**
     * The same source with its comments taken out.
     *
     * Not tidiness. Three tests in this repository ban a string by reading source
     * TEXT, and a comment that merely *names* the banned thing fails exactly like
     * using it — that cost three red tests in one night on 2026-08-26. These two
     * files are the other half of the same trap: the rule this guard checks is
     * spelled out in prose, at length, a few lines above the code that keeps it,
     * including the exact words of the exception that was removed. A guard that
     * read the prose would go green on a file where the rule had been deleted and
     * the paragraph about it left behind.
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
          // Swift nests block comments, and these files do it.
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

    /** One line of it, so a claim can compare what a branch does. */
    const tidy = (text) => text.replace(/\s+/g, ' ').trim();

    const view = code(await source('ios/TerminalDeck/Terminal/DeckTerminalView.swift'));
    /** The whole of the decision: which recogniser on this view may begin. */
    const decision = block(view, view.indexOf('override func gestureRecognizerShouldBegin'));

    await expect('the phone app’s terminal is still where this guard looks for it', async () => {
      // The floor, and it is not a formality: everything below judges the text of
      // one method, and a method this guard could not find would let every claim
      // under it pass on an empty string. That is the one failure this whole tool
      // exists to prevent.
      return view.includes('class DeckTerminalView: TerminalView') && tidy(decision).length > 200;
    });

    await expect('the library’s own one-finger drag is refused outright', async () => {
      // The library adds two plain pans that cannot be told apart by class — one
      // for selection, one for mouse reporting — so the rule is about the class,
      // and the whole rule is `false`.
      return tidy(block(decision, decision.indexOf('is UIPanGestureRecognizer'))) === 'return false';
    });

    await expect('and nothing about the program on the other end can bring the exception back', async () => {
      /*
       * The hole itself, named by the words that used to be in this method.
       * "Allow the library's pan on the alternate screen when a program has asked
       * for the mouse" is a reasonable-sounding sentence and it is precisely what
       * kept selecting text under his thumb, because Claude Code's own display is
       * the alternate screen with mouse reporting on. There is no test available
       * at this moment that separates "this drag is a mouse-report the program
       * wants" from "this is him trying to scroll", so the decision may not ask
       * the emulator anything at all.
       */
      return /mouseMode|isCurrentBufferAlternate|alternate|getTerminal|mouseEvents/i.test(decision) === false;
    });

    await expect('the library’s own long press is refused too', async () => {
      // It only ever opened a menu with a *Select* item in it — a second tap for
      // something this app's own press does directly. Left enabled it fires under
      // this app's press and the two disagree about what a hold means.
      return tidy(block(decision, decision.indexOf('is UILongPressGestureRecognizer'))) === 'return false';
    });

    await expect('this app’s own recognisers are told apart by identity, never by class', async () => {
      // The library attaches a long press and two pans — the same three classes
      // this app installs. "Ours" is therefore a fact that has to be recorded when
      // a recogniser is installed; inferred by class it is a coin toss, and a
      // wrong answer here refuses the gesture that does the selecting.
      return decision.includes('owned.contains(ObjectIdentifier(')
        && /func claim\(/.test(view) && view.includes('owned.insert(ObjectIdentifier(');
    });

    await expect('and the scroll itself is refused only while a selection drag has the finger', async () => {
      // The other side of the same rule. This is the gesture that scrolls, so it
      // must never be the one that loses — except to a drag that is adjusting a
      // selection, which is the only time it is not the finger's owner.
      const scroll = tidy(block(decision, decision.indexOf('=== panGestureRecognizer')));
      return scroll.includes('!isSelecting') && scroll.includes('super.gestureRecognizerShouldBegin');
    });

    const tests = code(await source('ios/Tests/TerminalGesturesTests.swift'));

    await expect('the test that would notice this coming back still arms itself first', async () => {
      /*
       * The cheap stand-in for a finger, and the thing that makes it worth having:
       * it feeds the escape sequences that put the terminal on the alternate
       * screen with the mouse on, and it asserts the terminal really took them
       * BEFORE it asserts the refusal. Without those two lines the test would pass
       * on a terminal that never switched screens — green, and about nothing,
       * which is how this defect survived two fixes.
       */
      const body = block(tests, tests.indexOf('func testAForeignPanIsRefusedEvenOnTheAlternateScreenWithTheMouseOn'));
      return body.includes('[?1049h') && body.includes('[?1000h')
        && body.includes('isCurrentBufferAlternate') && body.includes('mouseMode')
        && /XCTAssertFalse\(view\.gestureRecognizerShouldBegin/.test(body);
    });

    await expect('and the folder that test lives in is still built into a test target', async () => {
      // A test file that is not compiled is a comment. This project is generated
      // from a spec, so the folder being listed is what makes the file real.
      const spec = await source('ios/project.yml');
      return /TerminalDeckTests:[\s\S]{0,400}?path:\s*Tests\b/.test(spec);
    });

    /*
     * What is NOT proved here, said plainly so a green line is not read as more
     * than it is.
     *
     * A finger on glass. Everything above is the rule as it is written in the
     * shipped source, and the rule was right in the file for two of the three
     * rounds this defect ran — what was wrong was what happened under his thumb.
     * The one test that puts a finger on the terminal is
     * `ios/UITests/TerminalScrollUITests.swift`, it needs a real phone paired to a
     * running harness, and it skips loudly without one.
     *
     * The other half of the same gesture — that a deliberate hold still DOES
     * select, and that the hold is longer than a hesitation — is not restated
     * here; it has its own guard, `a-selection-costs-a-deliberate-hold`.
     */
  },
};
