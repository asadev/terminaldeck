/**
 * Every session he opened banged a banner over the very screen he was looking at.
 */
export default {
  name: 'the phone stays silent while the app is in front, and says nothing about a session merely starting',

  fixed: '2026-08-27',

  because:
    'His words: *"as soon as i start a new session or i enter inside a new session it is throwing the notifications and '
    + 'even if when i am inside the application i am on the same page but it is throwing the notifications."* The iOS '
    + 'delegate returned banner, list and sound for a foreground presentation, so every alert drew over the app he was '
    + 'already in; Android had the same shape in its own gate, and Android has no OS-level foreground suppression at '
    + 'all, so a posted notification there always shows. Underneath both, nothing asked whether the session had gone '
    + 'from working to waiting, so a session simply appearing was worth a buzz. It was fixed once and reported as '
    + 'Android-only, and he came back with *"notifications problem is not just Android it is iOS also mainly"* — the '
    + 'same defect had been live on the other client the whole time.',

  link: 'mine-workdir/days/2026-08-27.md lines 58–140; asks-audit-2026-08-28 CRO-096 — called fixed while iOS still did it',

  async run({ expect, project, run: shell, cannotRunHere }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');

    /**
     * A file with its comments taken out and its whitespace flattened.
     *
     * Both halves matter. Every rule below is written down in prose directly
     * above the line that implements it — his own quotes, in the source — so a
     * plain search for the rule finds the paragraph explaining it and passes on
     * a client that stopped obeying it. Three iOS tests on this project have
     * already failed on their own comments, from the other direction. Flattening
     * the whitespace afterwards is what keeps a reformat from reading as a
     * regression.
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

    await expect('the iPhone app asks the system to present nothing while it is in front', async () => {
      // `willPresent` is called by iOS only while the app is on screen, so
      // reaching it at all is the proof he is inside the app — and the rule is
      // that inside the app there is no banner, whatever screen he is on. An
      // empty set of options is the whole fix; anything naming .banner, .list or
      // .sound is the defect, and it reads as an ordinary line of code.
      const swift = await code('ios/TerminalDeck/App/AlertCenter.swift');
      return /willPresent notification: UNNotification\) async -> UNNotificationPresentationOptions \{ \[\s*\] \}/.test(swift);
    });

    await expect('the Android app is silenced by being in front alone, whatever screen is open', async () => {
      // Android has no foreground suppression of its own, so this gate is the
      // only place "inside the app means silence" can live. The version he
      // complained about only covered the one session on screen, which let a
      // *different* session banner over him while he was still in the app.
      const kotlin = await code('android/app/src/main/java/dev/terminaldeck/android/alerts/AlertGate.kt');
      return /fun isBeingWatched\([^)]*\): Boolean \{ return isForeground \}/.test(kotlin);
    });

    await expect('neither client raises anything for a session it is seeing for the first time', async () => {
      // The second half of what he was reporting: a session that arrives in the
      // list is either one he just started or one somebody started at the desk,
      // and "a session now exists" is not news. Only a session *changing* later
      // is. Both clients skip a session with no previous status, and both must.
      const swift = await code('ios/TerminalDeck/App/SessionAlerts.swift');
      const kotlin = await code('android/app/src/main/java/dev/terminaldeck/android/alerts/SessionAlerts.kt');
      return /guard let was = previous\[session\.id\] else \{ continue \}/.test(swift)
        && /val was = previous\[session\.id\] \?: continue/.test(kotlin);
    });

    // ── and here is what this guard cannot do, said out loud ──────────────
    //
    // The three cases in the write-up are behaviour on a phone: cause an alert
    // with the app open and watch nothing appear, background it and watch
    // exactly one appear, start a session in the foreground and watch none. Not
    // one of them can be reached from here. A guard may not start a session or
    // drive a session from working to waiting — that is the product changing
    // under the thing watching it — and neither client is on this computer at
    // all. So the two checks below look for the device, and when there is none
    // they fail and say so. They are not a formality: the file checks above are
    // a reading of two clients' rules, and a rule that reads correctly and
    // behaves otherwise is exactly the shape this bug arrived in twice.

    // NOT PROVED rather than failed, for the half of this that needs a device.
    //
    // The checks above read both clients' rules out of their source, which is real and worth
    // having. Watching a banner actually not appear needs a phone, and there is none here. A
    // guard may not boot one and may not drive a session from working to waiting, so on a
    // machine with no device the honest answer is that this was not proved — not that a bug
    // came back. This one was reported fixed on Android and was live on iOS the whole time,
    // so a false alarm on it costs more than most.

    // CoreSimulator's own binary, not `xcrun simctl`: `xcrun` hangs on this Mac and a guard
    // that hangs is a guard somebody switches off.
    const iphone = await shell(
      '"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl" list devices booted',
      { timeoutMs: 8000 },
    );
    const iphoneReady = iphone.code === 0 && /\(Booted\)/.test(iphone.stdout);

    // Touches the Android toolchain and nothing of this product's. The second spelling is
    // where the SDK lands on a Mac when `adb` is not on the path.
    const android = await shell(
      'adb devices || "$HOME/Library/Android/sdk/platform-tools/adb" devices',
      { timeoutMs: 8000 },
    );
    // `<serial>\tdevice`, and nothing else on the line — which is what rules out the header,
    // an `offline` phone and one still asking to be trusted.
    const androidReady = android.stdout.split('\n').some((line) => /^\S+\s+device$/.test(line.trim()));

    if (!iphoneReady || !androidReady) {
      cannotRunHere(
        'the rules were read out of both clients above, but watching a banner not appear needs a device and '
        + (!iphoneReady && !androidReady
          ? 'neither an iPhone simulator nor an Android phone is attached here.'
          : !iphoneReady
            ? 'no iPhone simulator is booted here.'
            : 'no Android phone or emulator is attached here.')
        + ' Boot a simulator or plug a phone in on the machine that runs this check, and it will run.',
      );
    }
  },
};
