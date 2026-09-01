/**
 * The pane printed "Sent." for a banner macOS had already dropped on the floor.
 */
export default {
  name: 'the app only calls a notification delivered when the operating system says it was',

  fixed: '2026-08-14',

  because:
    'The settings pane asked the browser engine whether notifications were allowed, and inside Electron that engine '
    + 'answers granted every time without ever asking macOS. So the Test button was enabled on a permission nobody had '
    + 'checked, the constructor returned, the pane printed "Sent." — and macOS, whose own prompt had never been '
    + 'answered, was dropping every banner in silence. The app then blamed the user’s Focus mode, which was the one '
    + 'cause already ruled out, and sent whoever was debugging it the wrong way. Every layer reported success while '
    + 'nothing happened. The honest answer costs a read of macOS’s own notification store and three outcomes where '
    + 'there used to be one, and the wrong answer is still the short one anybody reaches for first.',

  link: '72b1015 Stop the app saying "Sent." for a banner it never saw arrive',

  async run({ expect, page }) {
    // NOTHING HERE PRESSES TEST. That button posts a real banner on whichever
    // machine the release is being checked on, and a guard that sends something
    // is a guard nobody leaves in a gate. The other half of the original proof
    // — authorisation actually refused — cannot be had read-only either: macOS
    // keeps that per bundle and only a person can answer its prompt. So what is
    // asked is the thing the false "Sent." came from instead: does the app still
    // have an opinion outside itself to consult, and can that opinion say no.

    await expect('all three notification channels are still wired to the engine', async () => {
      // A missing name here is not an error, it is a downgrade. `useNotificationCheck`
      // has a branch for a build whose preload cannot ask the OS anything, and that
      // branch is the one the old "Sent." lived in. This app has registered a channel
      // under one name and called it under another three times in three days.
      const missing = String(await page.evaluate(
        "['notificationSupport','notificationDelivery','openNotificationSettings']"
        + ".filter(n=>typeof window.deck?.[n]!=='function').join(', ')",
      ));
      return missing === '';
    });

    /** What the main process says it can and cannot find out on this computer. */
    const support = JSON.parse(String(await page.evaluate(
      "(async()=>{try{return JSON.stringify(await window.deck.notificationSupport())}catch(e){return 'null'}})()",
    )));

    await expect('it is asking about the operating system it is actually running on', async () => {
      return support !== null && support.platform === process.platform;
    });

    await expect('it can read what the OS did, and point at the switch, exactly where those exist', async () => {
      if (support === null) return false;
      // Per platform rather than "true on a Mac", because both halves of this
      // have a wrong answer that looks fine. Quoting a macOS settings URL at a
      // Windows user is a mistake this codebase has made in bulk; a Linux build
      // claiming it can read a delivery would be the same confident lie one
      // layer further down.
      const pane = process.platform === 'darwin' || process.platform === 'win32';
      const readable = process.platform === 'darwin';
      return support.settingsPane === pane && support.deliveryReadable === readable;
    });

    await expect('asked about a moment nothing can have happened at, it never answers delivered', async () => {
      // The whole bug, as one question. The moment asked about is an hour into
      // the future, so no row in macOS's store can possibly be newer than it and
      // the only honest answers left are "nothing there" and "could not look". A
      // build that has gone back to reporting the constructor's own success has
      // nothing to stop it saying delivered to this.
      //
      // It takes about ten seconds, and that is not slack. macOS writes the row
      // when a banner LEAVES the screen, roughly six seconds in, so the reader
      // polls for nine and a half before it is entitled to say absent — a
      // shorter wait would report "no record" for banners that worked perfectly,
      // which is this same disease pointing the other way.
      const verdict = String(await page.evaluate(
        "(async()=>{try{const r=await window.deck.notificationDelivery(Date.now()+3600000);"
        + "return (r&&r.verdict)||'NO VERDICT'}catch(e){return 'REJECTED '+String(e&&e.message||e)}})()",
      ));
      return verdict === 'absent' || verdict === 'unknown';
    });
  },
};
