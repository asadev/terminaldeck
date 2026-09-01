/**
 * His office PC answers on 2222, and every screen in the app said it was on 22.
 */
export default {
  name: 'a server on an unusual port shows that port on every screen that says where it is',

  fixed: '2026-08-22',

  because:
    'Asad’s office PC is reached on port 2222. The app dialled it correctly and then printed the bare IP on every '
    + 'screen that says where a server is — the Address row in Settings, the row under Machines, the server’s own '
    + 'page and the rows on the Coding AI pane. Not one of those screens '
    + 'could have done better: the summary the main process sends the window carried no `port` field at all, so the '
    + 'number stopped at the bridge. That is worse than an omission — an address is what somebody reads off a screen '
    + 'and types into `ssh`, and they get "connection refused" from a machine this app is talking to happily. The '
    + 'opposite fix is a bug too: `:22` on every row is a character that is true of nearly every server and buries the '
    + 'one row where the number is a decision. Both halves are guarded, and a fifth surface writing its own version of '
    + 'the sentence is the obvious next failure.',

  link: '78e9372 A server on a non-default SSH port showed only its IP, app-wide',

  async run({ expect, page, project }) {
    const path = await import('node:path');
    const { pathToFileURL } = await import('node:url');

    /**
     * The three stops the port has to make, loaded and RUN rather than read.
     *
     * Reading these files and looking for the word "port" would prove nothing — the field was
     * declared and stored the whole time, and what was missing was the one line that copies it
     * onto the wire. Node runs a TypeScript file directly, so the actual journey can be walked:
     * what the main process sends, what the window lets through, and what the composer prints.
     */
    const load = async (/** @type {string} */ file) =>
      import(pathToFileURL(path.join(project.paths.root, file)).href);

    const engine = await load('src/main/servers/summary.ts');
    const window_ = await load('src/renderer/machines/servers/types.ts');
    const composer = await load('src/shared/server-where.ts');

    /** His own case, in the shape the store holds it. */
    const office = {
      id: 's1',
      name: 'Office PC',
      address: '192.0.2.11',
      port: 2222,
      username: 'admin',
      credential: 'key',
      hostKey: null,
      addedAt: 0,
      lastConnectedAt: null,
      startIn: null,
      drivesWindows: false,
    };

    /** @param {Record<string, unknown>} row */
    const crossed = (row) => window_.asServers([engine.serverSummary(row)])[0];

    await expect('the main process puts the port on the wire at all', async () => {
      // The exact thing that was missing. Everything below it was already right.
      return engine.serverSummary(office).port === 2222;
    });

    await expect('the window keeps the port the main process sent', async () => {
      return crossed(office)?.port === 2222;
    });

    await expect('and the line every screen draws names it', async () => {
      return composer.serverWhere(crossed(office)) === 'admin at 192.0.2.11:2222';
    });

    await expect('a server on the usual port is not given a number nobody needs', async () => {
      return composer.serverWhere(crossed({ ...office, port: 22 })) === 'admin at 192.0.2.11';
    });

    await expect('a main process too old to send a port draws the same line as one on 22', async () => {
      // Every build before the field existed says nothing, and "said nothing" has to read as
      // the usual port — which is what those servers overwhelmingly are. A blank after the
      // colon would be a third, invented answer.
      return composer.serverWhere({ address: '192.0.2.11', username: 'admin' }) === 'admin at 192.0.2.11';
    });

    await expect('a number nothing could be listening on is dropped rather than printed', async () => {
      return crossed({ ...office, port: 0 })?.port === undefined;
    });

    await expect('an IPv6 address is bracketed, so what is printed can be typed', async () => {
      // `::1:2222` cannot be read by anything. This is the form ssh, every browser and this
      // app's own remote code already use.
      return composer.serverAddress({ address: '::1', port: 2222 }) === '[::1]:2222';
    });

    /**
     * What this running copy actually has stored. Only a question — nothing here adds a
     * server, and adding one to prove a rendering would leave a machine behind in somebody’s settings.
     */
    const stored = String(await page.evaluate(
      "(async()=>{try{const l=await window.deck.listServers();"
      + "const rows=Array.isArray(l)?l:(l&&l.servers)||[];"
      + "return JSON.stringify(rows.map(s=>({address:String(s.address||''),port:s.port,username:String(s.username||'')})))"
      + "}catch(e){return 'ERR '+String(e&&e.message||e)}})()",
    ));

    await expect('the running app can still be asked where its servers are', async () => {
      return stored.startsWith('[');
    });

    const servers = stored.startsWith('[') ? JSON.parse(stored) : [];
    if (servers.length > 0) {
      // Only when this copy has a server stored, which a run on a scratch settings folder does
      // not. The journey above is what proves the fix then; this is the same claim made against
      // pixels when there is something to draw.
      await page.evaluate(
        "(()=>{const b=[...document.querySelectorAll('button.sb-nav')]"
        + ".find(e=>((e.querySelector('.sb-label')||{}).textContent||'').trim()==='Machines');"
        + "if(b)b.click();return Boolean(b)})()",
      );
      await page.wait(500);

      const drawn = String(await page.evaluate(
        "[...document.querySelectorAll('.servers-row-where,.servers-page-where,.settings-server-where')]"
        + ".map(e=>(e.textContent||'').trim()).join(' ~ ')",
      ));

      await expect('every server on screen is named the way the one composer names it', async () => {
        return servers.every((/** @type {any} */ s) =>
          drawn.includes(composer.serverWhere({ address: s.address, port: s.port, username: s.username })));
      });

      await expect('and no row prints the usual port as though it were a decision', async () => {
        return /:22\b/.test(drawn) === false;
      });
    }
  },
};
