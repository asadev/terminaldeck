/**
 * Three nights of "remote is fixed" while 3,628 tests stayed green over a dead cipher.
 */
export default {
  /**
   * Longer than the default half minute on purpose: this one bundles the probe
   * and starts Electron, and a guard that times out reports nothing at all —
   * which is the exact failure this bug is made of.
   */
  timeoutMs: 180_000,

  name: 'the sealed channel works in the runtime the app actually ships on',

  fixed: '2026-08-14',

  because:
    'The encryption every phone connection is built on used a cipher Electron does not ship. Node links OpenSSL, '
    + 'Electron links BoringSSL, and BoringSSL has no ChaCha of any kind — so every relayed handshake threw inside the '
    + 'desktop, the throw was swallowed, and the channel closed with nothing on the wire and nothing in the log. '
    + '3,628 tests missed it because a test suite runs under whatever node is on the path, and that runtime has the '
    + 'cipher. The knock-on was worse: the host proved its stored keypair by running a handshake, so a healthy identity '
    + 'was judged corrupt and regenerated on every launch, orphaning every phone that had ever been paired. He was told '
    + 'three nights running that remote was fixed, and it was not. A suite that never loads the runtime it ships on can '
    + 'be entirely green while the product is entirely dead, and every new primitive is a fresh chance at it.',

  link: 'session 2026-08-14 — three nights of “remote is fixed”; scripts/check-electron-crypto.mjs',

  async run({ expect, read, run: shell }) {
    /*
     * The product's own probe, run as the product runs it.
     *
     * It bundles `src/main/remote/sealed.electron-probe.ts` and executes it
     * under `ELECTRON_RUN_AS_NODE=1`, which is Electron's Node with Electron's
     * crypto and no window anywhere near it. Nothing here touches the app the
     * other guards are sharing: this is a separate process, it opens no window,
     * and the identity it loads twice lives in a throwaway folder of its own.
     */
    const probe = await shell('node scripts/check-electron-crypto.mjs', { timeoutMs: 150_000 });
    const said = `${probe.stdout}\n${probe.stderr}`;

    await expect('the sealed channel is exercised under Electron, not under the test runner’s Node', async () => {
      // The whole bug in one line. The probe refuses to run anywhere but under
      // Electron, so a runtime line naming a version is also proof that it was
      // not quietly skipped — and a skip is how this survived its first day.
      return /runtime: electron \d+\.\d+/.test(said);
    });

    await expect('and that Electron is the one this app is built on', async () => {
      // A check that ran under some other Electron is a check about some other
      // product. Majors only: a patch release moves under everybody's feet, and
      // it is the major that carries a crypto library.
      const wanted = /"electron":\s*"[^\d]*(\d+)\./.exec(await read('package.json'));
      const ran = /runtime: electron (\d+)\./.exec(said);
      return wanted !== null && ran !== null && wanted[1] === ran[1];
    });

    await expect('every one of its checks passes there', async () => {
      return probe.code === 0 && /\bFAIL\b/.test(said) === false;
    });

    await expect('and it really ran a body of them, rather than none', async () => {
      // The floor. "Quietly succeeded because nothing happened" is the precise
      // shape of the bug underneath this guard, so the count is read rather
      // than the exit code trusted: a probe that ran no checks and exited 0
      // would otherwise be indistinguishable from a healthy one. The number
      // grows; it has never shrunk.
      const counted = /(\d+)\/(\d+) checks passed/.exec(said);
      return counted !== null && counted[1] === counted[2] && Number(counted[2]) >= 10;
    });

    /*
     * The two halves of this bug that are NOT proved here, named so that nobody
     * reads a green line as more than it is.
     *
     * The desktop also never dialled out — the connect call was reachable only
     * from a settings button, so the app sat with a valid identity, two paired
     * phones and a healthy relay and never opened a socket. Proving that wants
     * the real relay: a socket leaving this machine on launch, and the relay's
     * host count rising as the app starts and falling as it quits. Neither can
     * be asked from here without switching remote access on, which a guard may
     * never do to the product it is watching.
     *
     * The third fault — three releases with no phone client inside them — has
     * its own guard, `phone-client-is-in-the-build`, and is not restated here.
     */
  },
};
