/**
 * A Windows user's update panel printed four stack frames, his own home directory,
 * and the entire releases feed with the notes escaped inside it twice.
 */
export default {
  name: 'a failed update check says one plain sentence, never a stack trace or a releases feed',

  fixed: '2026-08-20',

  because:
    'The library this app updates through builds its error message by appending the whole Atom feed it just fetched '
    + 'onto the sentence. A Windows user whose network moved mid-request saw all of it in the panel: four node_modules '
    + 'frames, `C:\\Users\\…` twice, and the release notes escaped into the message twice over, in a box the size of the '
    + 'window. The panel was doing exactly what it was told — print the error. Two faults, not one: the text was a '
    + 'diagnostic written for whoever wrote the library, and the thing being reported was not a failure at all — a '
    + 'network that moves under a request means ask again, and nobody asked for a background check, so nobody needs to '
    + 'be told it could not finish. The library still builds that message on every release; one shaping function is all '
    + 'that stands between it and the screen.',

  link: '291d093 The update panel was printing the whole releases feed',

  async run({ expect, page, project }) {
    const path = await import('node:path');
    const { pathToFileURL } = await import('node:url');

    /**
     * The shaping function itself, loaded and run rather than read. Node runs a TypeScript
     * file directly, so the claim below is made against the real code the panel is fed by,
     * not against a copy of it kept in a guard.
     */
    const shaper = await import(
      pathToFileURL(path.join(project.paths.root, 'src/main/updates/update-error.ts')).href
    );

    /**
     * What a real Windows install put on screen on 2026-08-20, kept verbatim, because every
     * fault in it is a separate thing that has to be stripped: the wrapper sentences, the
     * Chromium code, four frames carrying a stranger's home directory, and the feed.
     */
    const REAL_WINDOWS_FAILURE = [
      'Cannot parse releases feed: Error: Unable to find latest version on GitHub',
      '(https://github.com/asadev/terminaldeck/releases/latest), please ensure a production',
      'release exists: Error: net::ERR_NETWORK_CHANGED at SimpleURLLoaderWrapper.<anonymous>',
      '(node:electron/js2c/browser_init:2:135010) at newError (C:\\Users\\Asus\\AppData\\Local\\',
      'Programs\\Terminal Deck\\resources\\app.asar\\node_modules\\builder-util-runtime\\out\\',
      'error.js:5:19) XML: <?xml version="1.0" encoding="UTF-8"?> <feed><entry><content',
      'type="html">&lt;h3&gt;Install&lt;/h3&gt; &lt;p&gt;macOS 12 or later, Apple silicon:',
    ].join(' ');

    const said = shaper.describeUpdateError(new Error(REAL_WINDOWS_FAILURE));

    await expect('the real Windows failure comes out as one short sentence', async () => {
      return typeof said.text === 'string' && said.text.length <= 120 && said.text.split('\n').length === 1;
    });

    await expect('nothing from inside the program reaches the panel with it', async () => {
      // Every one of these was on his screen. A truncated feed is not more useful than no
      // feed, so they are dropped whole rather than shortened.
      return !said.text.includes('<')
        && !said.text.includes('node_modules')
        && !said.text.includes('C:\\')
        && !/\.js:\d+/.test(said.text)
        && !/\bat\s+\S+\s*\(/.test(said.text);
    });

    await expect('a network that moved is called worth trying again, not broken', async () => {
      // This is what lets a background check stay silent. Without it the panel opens on a
      // laptop waking up, which is the second half of the same complaint.
      return said.transient === true;
    });

    await expect('every code a moving network produces is read the same way', async () => {
      return ['net::ERR_INTERNET_DISCONNECTED', 'net::ERR_NAME_NOT_RESOLVED', 'getaddrinfo ENOTFOUND github.com', 'connect ETIMEDOUT 140.82.121.4:443']
        .every((code) => shaper.describeUpdateError(new Error(code)).transient === true);
    });

    await expect('a refused connection is not called worth trying again', async () => {
      // Retrying either of these just fails again more slowly, and a panel that keeps
      // promising to retry something that cannot work is its own defect.
      return ['net::ERR_CERT_AUTHORITY_INVALID', 'connect ECONNREFUSED 140.82.121.4:443']
        .every((code) => shaper.describeUpdateError(new Error(code)).transient === false);
    });

    await expect('a failure with nothing to say still says something', async () => {
      // The panel draws a headline over this. An empty string leaves it drawn over a blank,
      // which reads as the app having lost its place.
      return [new Error(''), {}, null, undefined, ''].every((thrown) => {
        const answer = shaper.describeUpdateError(thrown);
        return typeof answer.text === 'string' && answer.text.trim() !== '';
      });
    });

    /**
     * And the same claim against the window, whatever page happens to be open.
     *
     * The update banner is mounted for the life of the app and draws nothing while there is
     * nothing to say, so this is read where it lives rather than by pressing anything: a
     * guard must never start a check that reaches off this machine, and pressing the button
     * would also be the app doing something nobody asked it to.
     */
    const banner = String(await page.evaluate(
      "(()=>{const b=document.querySelector('aside.upd-banner');return b?(b.innerText||'').trim():''})()",
    ));

    await expect('the banner, if it is up at all, is showing a sentence and not a dump', async () => {
      if (banner === '') return true;
      return banner.length <= 400
        && !banner.includes('node_modules')
        && !banner.includes('<?xml')
        && !banner.includes('&lt;')
        && !/\bat\s+\S+\s*\([^)]*:\d+:\d+\)/.test(banner);
    });

    await expect('and it is not reporting a moving network to somebody who did not ask', async () => {
      // A transient failure on a check nobody pressed for is meant to end in silence. The
      // codes below are the ones that mean "ask again"; none of them belongs on screen.
      return /net::ERR_|ENOTFOUND|EAI_AGAIN|ECONNRESET/.test(banner) === false;
    });
  },
};
