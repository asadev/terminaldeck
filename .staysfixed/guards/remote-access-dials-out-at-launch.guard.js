/**
 * The phone said "connected" and showed old messages, because there was nothing to attach to.
 */
export default {
  name: 'remote access dials out at launch, with nobody pressing anything',

  fixed: '2026-08-14',

  because:
    'Remote access — the whole point of the phone apps — had never once run on his Mac outside a test. It started only '
    + 'from a button two menus deep in Settings and nothing re-ran it on the next launch, so you turned it on, quit, '
    + 'reopened, and it was silently off again with the switch as the only evidence. Measured on the machine it was '
    + 'written on: the host identity on disk, two paired iPhones in the trust store, the relay reachable, and not one '
    + 'socket from that Mac to it. That is the "it says connected but shows old messages" report — the phone was '
    + 'attaching to a host that was not there. The rule is one line in one place ("on unless stored off"), no type can '
    + 'catch its absence, and every test that starts a server calls start() itself.',

  link: '3938381 Dial the relay at launch, so a paired phone has something to attach to',

  async run({ expect, page }) {
    // Only questions. Nothing here starts, stops or pairs anything: `remote:start` would
    // turn on remote access for real, and `remote:stop` would write it off for the next
    // launch — a guard that changes the product it is watching is a guard nobody can trust.
    await expect('the window can still ask this machine about remote access at all', async () => {
      const said = String(await page.evaluate(
        "(async()=>{try{ if(typeof window.deck?.remoteStatus!=='function') return 'MISSING';"
        + "const s=await window.deck.remoteStatus(); return s&&typeof s==='object'?'OK':'EMPTY';"
        + "}catch(e){ return 'REJECTED '+String(e&&e.message||e) }})()",
      ));
      return said === 'OK';
    });

    /** What this copy has been told about remote access, if anything. */
    const stored = String(await page.evaluate(
      "(async()=>{try{const s=await window.deck.getSettings();const v=(s&&s.values)||{};"
      + "return JSON.stringify({off:v['remote.enabled']===false,"
      + "written:Object.prototype.hasOwnProperty.call(v,'remote.enabled')})}catch(e){return 'ERR'}})()",
    ));

    await expect('this copy was never told to stay off, so the launch dial was supposed to run', async () => {
      // A missing key means yes, and that direction is the feature: the only state worth
      // storing is the one where somebody deliberately turned remote access off. If this copy
      // HAS been switched off then not dialling is correct and there is nothing here to
      // prove — so the guard fails and says so, rather than reporting green on a question it
      // never got to ask.
      return stored.startsWith('{') && JSON.parse(stored).off === false;
    });

    await expect('remote access dialled out on its own, with nobody pressing anything', async () => {
      /*
       * The launch dial is deliberately not awaited — it shells out to Tailscale and crosses
       * the internet, and the window must not wait on either — so the mark it leaves can
       * arrive a second or two after the app is up. Ten looks at half a second each.
       *
       * What is asked is only that SOMETHING happened without a person. A link, a running
       * listener, or a sentence saying why not: `start()` records its reason on the way past,
       * and a status that is running:false with every field still null is the shipped bug
       * exactly — nobody dialled at all. Deliberately not "running is true": whether the relay
       * answers from this network is not this app's promise, and a guard that needs the
       * internet to be up is a guard that gets switched off in a week.
       */
      for (let look = 0; look < 10; look += 1) {
        const said = String(await page.evaluate(
          "(async()=>{try{const s=await window.deck.remoteStatus();return JSON.stringify({"
          + "running:Boolean(s&&s.running),reason:(s&&s.reason)??null,direct:(s&&s.directReason)??null,"
          + "relay:s&&s.relay?'yes':null})}catch(e){return 'ERR'}})()",
        ));
        if (said.startsWith('{')) {
          const status = JSON.parse(said);
          if (status.running || status.relay !== null || status.reason !== null || status.direct !== null) return true;
        }
        await page.wait(500);
      }
      return false;
    });

    await expect('and the launch dial did not record itself as a decision somebody made', async () => {
      // Only a press writes this key. Recording the automatic start would make "on" and
      // "never touched" the same stored state, and the difference between them is the entire
      // point of storing anything.
      return JSON.parse(stored).written === false;
    });

    /*
     * WHAT THIS GUARD CANNOT REACH, said here rather than left to be assumed. The report was
     * about the SECOND launch — on, quit, reopen, silently off — and guards share one running
     * app that nobody may restart underneath them, so the relaunch is not proved here. What
     * is proved is the half that made the second launch fail: this app dials without being
     * asked, and it does not write down that it was asked. The relaunch is `autostart.test.ts`
     * with a stored `false`, and the end-to-end proof is a phone.
     */
  },
};
