/**
 * Succeeding at the login is what destroyed the login: the screen about to show
 * the receipt and the check-and-install step was torn down on the next frame.
 */
export default {
  name: 'finishing the login on a phone does not destroy the screen that shows what happens next',

  fixed: '2026-08-23',

  because:
    'Logging in from the phone creates a server, so `hasServers` flipped true inside the sign-in and `RootView` swapped '
    + 'the gate for the main tabs on the very next frame — destroying the screen that was about to draw the fingerprint '
    + 'receipt and the check-and-install step. The steps existed and had no window to draw in; what a person saw was the '
    + 'form, a spinner and then an empty Sessions tab. Every automated test passed, and the UI test that watches this '
    + 'flow waits for `serverLogin.signedIn` — so it timed out and reported a slow login, which is the least useful true '
    + 'thing it could have said. It was found by photographing a simulator against a real server. The shape is "the '
    + 'condition that says you have succeeded also decides which screen you are on", and it comes back every time a new '
    + 'gate is added.',

  link: '1f4c060 The login screen survives succeeding at the login',

  async run({ expect, project, run: shell, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /**
     * A Swift file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter, and both were paid for. Every rule below is written
     * out in prose directly above the line that implements it, so a plain
     * search finds the paragraph explaining the rule and passes on a screen
     * that stopped obeying it — three iOS tests on this project have already
     * failed from the other direction, on their own comments. Flattening the
     * whitespace afterwards is what stops a reformat reading as a regression.
     *
     * @param {string} rel
     */
    const code = async (rel) =>
      (await fsp.readFile(path.join(project.paths.root, rel), 'utf8'))
        .replace(/\/\*[\s\S]*?\*\//g, ' ')
        .replace(/^[ \t]*\/\/.*$/gm, ' ')
        .replace(/\s+/g, ' ');

    /**
     * One Swift declaration, from its header to its closing brace.
     *
     * Braces are counted rather than parsed, which is enough for these bodies:
     * they hold no brace inside a string, and Swift interpolates with `\(…)`
     * rather than with braces. Every use below asserts the lift found something
     * first, because a lift that silently returned nothing would make every
     * claim under it pass over a screen nobody read.
     *
     * @param {string} source @param {string} header
     */
    const declaration = (source, header) => {
      const at = source.indexOf(header);
      if (at < 0) return null;
      let depth = 0;
      let i = source.indexOf('{', at);
      for (; i < source.length; i += 1) {
        if (source[i] === '{') depth += 1;
        else if (source[i] === '}' && (depth -= 1) === 0) break;
      }
      return i >= source.length ? null : source.slice(at, i + 1);
    };

    const rootView = await code('ios/TerminalDeck/App/RootView.swift');
    const login = await code('ios/TerminalDeck/Screens/ServerLoginView.swift');

    await expect('the gate keeps the login on screen while the login is holding it', async () => {
      // The fix, exactly. Without the second clause this `if` is a pure function
      // of "does a server exist", and creating one is the last thing the login
      // does — so the screen deletes itself at the instant it has something to
      // show. Matched as the whole condition rather than as the flag alone: a
      // flag that is set, cleared and never read is the same bug wearing a
      // variable name.
      return /if \(!model\.isPaired && !model\.hasServers\) \|\| model\.holdingTheLoginGate \{/.test(rootView);
    });

    await expect('the window is claimed when Log in is pressed, before either transport is asked', async () => {
      // Order is the whole of it. The claim has to be made before anything can
      // succeed, because succeeding is what tears the screen down; a claim made
      // in the success handler is a claim made one frame too late, which is
      // where this bug lives.
      const submit = declaration(login, 'private func submit()');
      if (submit === null) return false;
      const claimed = submit.indexOf('holdingTheLoginGate = true');
      const asked = ['model.serverSignIn.submit(', 'connector.'].reduce((first, call) => {
        const at = submit.indexOf(call);
        return at < 0 ? first : Math.min(first, at);
      }, Number.MAX_SAFE_INTEGER);
      return claimed >= 0 && claimed < asked;
    });

    await expect('and it is released only when the person leaves that screen', async () => {
      // `leave()` is the person going: it is what the Open this server button
      // calls. Releasing anywhere else hands the decision back to "have you
      // succeeded", which is the arrangement that shipped.
      const leave = declaration(login, 'private func leave()');
      return leave !== null && /holdingTheLoginGate = false/.test(leave);
    });

    for (const [what, header] of [
      ['the handler that hears the login succeed', '.onChange(of: signedInHostId)'],
      ['the screen that draws what happens next', 'private func arrived('],
    ]) {
      await expect(`${what} never lets go of the window`, async () => {
        // Both of these run at the moment of success, and either one clearing
        // the hold reproduces the original bug precisely — the screen goes as
        // its own content arrives.
        const body = declaration(login, header);
        return body !== null && /holdingTheLoginGate/.test(body) === false;
      });
    }

    await expect('the receipt and the check-and-install step are both still on that screen', async () => {
      // The two things that had no window to draw in. `justLoggedIn: true` is
      // the check-and-install card in the state this screen shows it in — see
      // `HostStep.swift` — and the fingerprint is shown once, at the only
      // moment it can be checked.
      const arrived = declaration(login, 'private func arrived(');
      if (arrived === null) return false;
      return (
        arrived.includes('accessibilityIdentifier("serverLogin.fingerprint")')
        && /HostStepCard\(model: model, serverId: server\.id, justLoggedIn: true\)/.test(arrived)
        && arrived.includes('accessibilityIdentifier("serverLogin.open")')
      );
    });

    await expect('the Face ID offer is at the front door, where it was deliberately moved', async () => {
      /*
       * The third step in the original report, and the one place this guard
       * asserts something the fix did NOT keep.
       *
       * The login screen used to offer *"Use Face ID next time?"* the moment a
       * login succeeded. On 2026-08-24 that was taken off this screen on
       * purpose: the app reconnects to its last server as it opens, so a lock
       * on one server's password meant a prompt on every single launch — *"I
       * wanted this face lock actually not just for one specific server, make
       * it for the overall application."* So the offer moved to one switch on
       * the main Settings page. It is checked here rather than dropped, because
       * "the step was removed" and "the step was lost in a refactor" look
       * identical from the login screen alone.
       */
      const settings = await code('ios/TerminalDeck/Screens/DeckTabs.swift');
      return /AppLockSection\(lock: lock\)/.test(settings);
    });

    await expect('the key field is tall enough for a whole key', async () => {
      // Photographed with a real ed25519 key in: at `4...12` the field wrapped
      // to about thirteen visual lines and clipped the END line, underneath a
      // sentence claiming BEGIN and END were both there. A screen contradicting
      // its own claim is worse than a screen saying nothing.
      const field = /TextField\("-----BEGIN OPENSSH PRIVATE KEY-----", text: \$secret, axis: \.vertical\) \.lineLimit\(4\.\.\.(\d+)\)/.exec(login);
      return field !== null && Number(field[1]) >= 18;
    });

    await expect('the port has a row of its own, under a full-width address', async () => {
      // Side by side, the address column had two thirds of a 390-point screen
      // for a printed server address that is 130 unbroken characters, and the
      // Paste control ended up level with the PORT label and touching it. Read
      // in order: the address field, then the port's own label, then the port
      // field. A field sharing the address's row cannot be introduced by a
      // label of its own that comes after it.
      const address = login.indexOf('accessibilityIdentifier("serverLogin.address")');
      const label = login.indexOf('fieldLabel("Port"');
      const port = login.indexOf('accessibilityIdentifier("serverLogin.port")');
      return address >= 0 && label > address && port > label;
    });

    await expect('the whole flow can still be driven and photographed', async () => {
      // The door this bug was caught through, and the only way the live half
      // below can ever be run: `TD_SERVER_AUTOSUBMIT=1` presses Log in for a
      // `simctl launch`, in DEBUG only, beside the existing prefill. Losing it
      // would not break the product and would make this bug invisible again.
      return /environment\["TD_SERVER_AUTOSUBMIT"\] == "1"/.test(login) && /#if DEBUG/.test(login);
    });

    /* ── and here is the half this cannot do, said out loud ────────────────
     *
     * Everything above is a reading of two screens' rules. The bug itself is a
     * frame: the gate swapping one view for another at the instant the login
     * succeeded, which was found by photographing a simulator against a real
     * server and by nothing else. A guard may not run that flow — logging in
     * writes a server into the phone's keychain and asks somebody's sshd for a
     * session — so the release pass is a person running
     * `ios/Harness/live-server.sh` and looking at the shots. The two checks
     * below say whether that pass can be run on this machine at all.
     *
     * They are not claims about the product, and they no longer fail. A phone
     * that is not booted and a server that was never named are things this
     * MACHINE has not got; failing on them printed "a bug that was already
     * fixed is back" about a bug nobody had gone looking for — a false alarm on
     * every machine without a simulator and a spare sshd, which is most of
     * them, and the fastest way there is to teach somebody to ignore this
     * whole list. `cannotRunHere` is the third answer: NOT PROVED, neither a
     * pass nor a failure, with the missing piece named. "Nothing was watched"
     * and "nothing was wrong" still must never print the same — and now they
     * do not.
     *
     * They stay last on purpose. Every claim about the two screens above has
     * already been made and can still fail; only once the readable half has
     * been read does this stop and say what it could not go on to watch.
     */

    // CoreSimulator's own binary rather than `xcrun simctl`: `xcrun` hangs on
    // this Mac, and a guard that hangs is a guard somebody switches off.
    const simctl = '"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"';
    const booted = await shell(`${simctl} list devices booted`, { timeoutMs: 8000 });
    // Booted is not enough — a simulator with no build on it photographs
    // nothing. `get_app_container` answers a path or exits non-zero.
    const installed = booted.code === 0 && /\(Booted\)/.test(booted.stdout)
      ? await shell(`${simctl} get_app_container booted dev.terminaldeck.ios`, { timeoutMs: 8000 })
      : null;
    if (installed === null || installed.code !== 0 || installed.stdout.trim() === '') {
      cannotRunHere(
        'there is no booted iPhone simulator on this machine with Terminal Deck (dev.terminaldeck.ios) installed on it, '
        + 'and the frame this bug lives in can only be photographed on a running phone. Boot an iPhone simulator and put '
        + 'this build on it — `ios/Harness/live-server.sh` does both — and this will run.',
      );
    }

    if (String(process.env.TD_SERVER_ADDRESS ?? '').trim() === '') {
      // The whole point is what happens *after* a login succeeds, so a fixture
      // proves nothing: it takes an sshd that answers, a host key that matches
      // and a machine to survey. Same variables the UI-test suite takes, so
      // there is one way to say this and not two.
      cannotRunHere(
        'no real server is named for the login to actually succeed at — TD_SERVER_ADDRESS is not set on this machine. '
        + 'This bug only exists in the instant a login succeeds, so a fixture cannot stand in for it: it needs a machine '
        + 'running sshd that this phone can really reach. Set TD_SERVER_ADDRESS, TD_SERVER_USER and TD_SERVER_KEY_BASE64 '
        + '— the same variables `ios/UITests/ServerLoginUITests.swift` and `ios/Harness/live-server.sh` take — to a server '
        + 'you are allowed to log into, and this will run.',
      );
    }
  },
};
