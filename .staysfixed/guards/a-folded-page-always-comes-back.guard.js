/**
 * He folded the page away and could not get it back — and unfolding gave him
 * four hundred points of black, on black, with no words in it.
 */
export default {
  name: 'a folded page on the phone always offers the way back, and never unfolds onto nothing',

  fixed: '2026-08-26',

  because:
    '"browser window when it collapse it is not expanding back I can not open it back once if I close it inside a '
    + 'session." Two mechanisms wearing one face. The strip’s control was decided by one fact — folded or not — so a '
    + 'machine that would never cast anything drew NO control at all, and a socket that dropped took the way back off '
    + 'a pane he had folded a second earlier: a button that stops existing on its own reads exactly like a button that '
    + 'has stopped working. And the state under it had nothing to say: a pane with no picture drew four hundred and '
    + 'forty points of black over a terminal whose own ground is black, so he pressed, the app changed state '
    + 'correctly, and the screen did not move. The trap underneath is "a state that shows neither a picture nor a '
    + 'sentence", which reopens the day somebody adds a state.',

  link: '83dc9ed The collapsed page always comes back, and the attach menu is a list of names',

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
     * This is the most heavily commented file in the phone app: the rules below
     * are argued in prose, with his own words quoted, directly above the code
     * that keeps them. Three tests in this repository already fail on a comment
     * that merely names a banned string; this is the same trap in the other
     * direction — a rule deleted from the code and still described above it would
     * read as intact to anything matching text.
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

    /** The three acts the strip can offer, as the type declares them. */
    const acts = (block(screen, screen.indexOf('enum SessionPageVerb'))
      .match(/^\s*case\s+([a-zA-Z]\w*)\s*$/gm) || []).map((line) => line.trim().slice(5));

    /** Every reading the pane can have, as the type declares them. */
    const states = (block(screen, screen.indexOf('enum SessionPageStage'))
      .match(/^\s*case\s+([a-zA-Z]\w*)\s*$/gm) || []).map((line) => line.trim().slice(5));

    await expect('both decisions behind the page strip are still in the phone app’s source', async () => {
      // The floor. Everything below reads the text of two types, and a type this
      // guard could not find would let every claim under it pass on an empty
      // string — a guard that checked nothing, which is the one thing worse than
      // no guard.
      return acts.length >= 3 && states.length >= 4;
    });

    await expect('a folded pane always offers the way back, whatever the machine is doing', async () => {
      /*
       * His state exactly: folded, nothing arriving, and a machine that will never
       * cast. The old rule said "there is nothing to unfold to" and drew no
       * control. There is: one line of text saying why there is no picture. So
       * `folded` is answered first and answered unconditionally — nothing about
       * the connection, which moves on its own, may take the button off a pane he
       * has already put away.
       */
      const rule = tidy(block(screen, screen.indexOf('static func verb(folded:')));
      return rule.startsWith('if folded { return .show }');
    });

    await expect('the strip draws a control in every state it can be in', async () => {
      /*
       * The state that drew nothing is the state he could not get out of. So the
       * claim is totality: one arm per act, and every arm makes a button — the
       * same button, under the same name, so the thing he presses is in the same
       * place whatever it is about to do.
       */
      const strip = block(screen, screen.indexOf('switch verb'));
      const arms = strip.split(/case\s+\./).slice(1);
      return arms.length === acts.length
        && acts.every((act) => arms.some((arm) => arm.startsWith(act)))
        && arms.every((arm) => arm.includes('button(') && arm.includes('"session.page.fold"'));
    });

    await expect('and the one button on a folded pane can only bring the page back', async () => {
      // Folded, the strip collapses into a single round button standing where the
      // chevron stood. Every way that press can be answered has to open the pane:
      // an arm that folded it again would be the photograph, one press later.
      const folded = block(screen, screen.indexOf('func foldedButton'));
      const arms = block(folded, folded.indexOf('switch verb')).split(/case\s+\./).slice(1);
      return arms.length > 0 && arms.every((arm) => /show\(\)|askForThePage\(\)/.test(arm))
        && arms.every((arm) => /\bfold\(\)/.test(arm) === false);
    });

    await expect('the three acts say three different things', async () => {
      // A chevron that goes on offering to hide a pane that is already hidden is
      // a control describing a state instead of doing something, which is how
      // this was first reported: "If I click on it, it is not opening."
      const labels = (screen.match(/static let (?:show|hide|ask)Label\s*=\s*"([^"]+)"/g) || [])
        .map((line) => /"([^"]+)"/.exec(line)[1]);
      return labels.length === 3 && new Set(labels).size === 3 && labels.every((word) => word.length > 3);
    });

    await expect('every reading the pane can have is either a picture or a sentence', async () => {
      /*
       * The trap, pinned by totality rather than by example: the switch has to
       * answer every case the type declares, and exactly one of them — the picture
       * — may answer with nothing, because the page is its own answer. A state
       * added tomorrow with no line is four hundred points of black over black
       * again, and that is the screen he pressed at and could not move.
       */
      const said = new Map();
      for (const arm of block(screen, screen.indexOf('var line: String?'))
        .matchAll(/case\s+\.(\w+):\s*return\s+(nil|"([^"]*)")/g)) {
        said.set(arm[1], arm[2] === 'nil' ? null : arm[3]);
      }
      const silent = [...said].filter(([, line]) => line === null).map(([state]) => state);
      return states.every((state) => said.has(state))
        && said.size === states.length
        && silent.length === 1 && silent[0] === 'picture';
    });

    await expect('and none of those sentences is a blank one', async () => {
      // A one-word answer over a black plate is the black box with a smaller box
      // in it. Each of these has to be a sentence somebody can act on: why there
      // is no page, in the words the pane itself will draw.
      const lines = [...block(screen, screen.indexOf('var line: String?'))
        .matchAll(/case\s+\.\w+:\s*return\s+"([^"]*)"/g)].map((found) => found[1]);
      return lines.length === states.length - 1 && lines.every((line) => line.trim().length >= 10);
    });

    await expect('the pane draws that sentence, so an empty state cannot reach the screen', async () => {
      // The decision above is worth nothing if the screen does not print it. The
      // line is drawn from the stage's own reading and carries the identifier the
      // phone suites already reach for.
      return /if pane != \.minimised, let line = stageState\.line/.test(screen)
        && screen.includes('.accessibilityIdentifier("session.page.nocast")');
    });

    await expect('the tests that pin the state machine are still compiled', async () => {
      // A test file that is not built is a comment, and this project is generated
      // from a spec — the folder being listed is what makes the file real. The
      // assertion named here is his own state: folded, nothing arriving, a machine
      // that will never cast.
      const tests = code(await source('ios/Tests/SessionPageTests.swift'));
      const spec = await source('ios/project.yml');
      return /TerminalDeckTests:[\s\S]{0,400}?path:\s*Tests\b/.test(spec)
        && /verb\(folded: true, showing: false, castable: false\)[\s\S]{0,40}\.show/.test(tests)
        && tests.includes('XCTAssertNotNil(stage.line');
    });

    /*
     * What is NOT proved here.
     *
     * That the unfolded pane has a real picture in it, on a real screen. Every
     * claim above is the decision, and the decision was already correct on the
     * build he filmed — what was wrong was what the screen did with it. Proving
     * that wants the phone app on a simulator or a device with a machine it can
     * reach: fold, unfold, and look at what is under the strip. That is
     * `ios/UITests/SessionPageUITests.swift`, which skips loudly without a paired
     * harness.
     *
     * The other half of his sentence — that showing the page asks the machine for
     * it again instead of leaving *Asking for the page…* on the screen for ever —
     * has its own guard, `showing-the-page-asks-the-machine-again`.
     */
  },
};
