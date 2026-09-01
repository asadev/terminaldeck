/**
 * Photographed on his own phone: *iPhone · This phone · Connected now* and,
 * directly under it, *iPhone · Seen 7m ago* — one phone, one key, two rows, and
 * Remove on the wrong one cuts off the phone in your hand.
 */
export default {
  name: 'signing in again is the same device, and the same login is the same account',

  fixed: '2026-08-24',

  because:
    'Both ways a phone gets trusted — the pairing-code redemption and the sign-in — started from a fresh device id and '
    + 'looked at nothing first, so signing in again wrote a second row. Signing in again is an ordinary thing to do: '
    + 'after a revoke, after a password change, or because somebody was not sure it had worked. The result was two rows '
    + 'sharing one X25519 key, each independently granting access, indistinguishable on screen — and two live '
    + 'credentials for one phone. The repair keeps the id (every per-device store in the app is keyed on it, so a new '
    + 'one silently drops that phone\'s folder grants and window grants on the floor), rotates the credential, and '
    + 'DROPS the losing rows rather than tombstoning them, so the stale secret is genuinely refused. It has to reach '
    + 'backwards as well as forwards, because every phone that ever signed in twice already has the duplicate on disk. '
    + 'The account list carried the same shape on a different list, so it is watched here in the same breath.',

  link: 'd0672ac Four defects from the 2026-08-23 phone recording (IOS-053)',

  async run({ expect, project }) {
    const fsp = await import('node:fs/promises');
    const path = await import('node:path');
    const os = await import('node:os');
    const crypto = await import('node:crypto');

    /**
     * The product's own modules, built and then run — not read as text.
     *
     * Handing the `.ts` file straight to `import()` cannot work here, and the way
     * it fails is worth writing down: TypeScript in this repo imports its own
     * neighbours without a file extension (`device-auth.ts` asks for
     * `src/shared/sealed`), and Node's ESM loader will not guess the extension,
     * so the very first import threw before this guard asked a single question.
     * A guard that dies in its own setup reports nothing about the product.
     *
     * So the entry is bundled in memory with esbuild — the same bundler the app's
     * own build runs — and imported as a data URL. That resolves the extensionless
     * imports the way the shipped build resolves them, and what comes back is the
     * real class and the real function, executed. Everything below is therefore
     * behaviour, not a grep: a comment that merely *mentions* `enrollDevice` or
     * `oneRowPerLogin` cannot pass these claims, and a rule that was deleted
     * cannot hide behind one that is still described in prose.
     *
     * Nothing is written into the repo, and no real roster or identity file is
     * opened: `RemoteAuth` takes its storage directory as an argument, and the
     * only directory it is given is a fresh temp folder made below.
     */
    const load = async (file) => {
      try {
        const esbuild = await import('esbuild');
        const built = await esbuild.build({
          stdin: {
            contents: `export * from './${file}'`,
            resolveDir: project.paths.root,
            loader: 'ts',
          },
          bundle: true,
          format: 'esm',
          platform: 'node',
          write: false,
          logLevel: 'silent',
          // The roster deliberately imports no Electron; the account rules are a
          // renderer file that might reach for it. Left external either way, so a
          // module that never touches it at run time still loads here.
          external: ['electron'],
        });
        const bytes = Buffer.from(built.outputFiles[0].text).toString('base64');
        return await import(`data:text/javascript;base64,${bytes}`);
      } catch {
        // Null rather than a throw, so the claim underneath fails as its own
        // readable sentence instead of as a stack trace nobody reads.
        return null;
      }
    };

    /**
     * The host's real trust file, driven directly.
     *
     * `RemoteAuth` takes its storage directory as an argument and its clock as
     * an option, which is what lets the shipped roster be exercised on a folder
     * of this guard's own. Nothing here touches the roster the app is running
     * on, and no device on this machine gains or loses anything.
     */
    const auth = await load('src/main/remote/device-auth.ts');

    await expect('the host\'s device roster is still there to be asked', async () => {
      // A guard that cannot reach the code it watches must never report that the
      // code is fine.
      return auth !== null
        && typeof auth.RemoteAuth === 'function'
        && typeof auth.REMOTE_AUTH_FILE === 'string';
    });

    /** 32 bytes, because that is an X25519 static key and the length is checked. */
    const aKey = () => crypto.randomBytes(32);

    const scratch = await fsp.mkdtemp(path.join(os.tmpdir(), 'td-guard-devices-'));
    try {
      const phone = aKey();
      const laptop = aKey();

      const roster = new auth.RemoteAuth(scratch);

      const first = await roster.enrollDevice('iPhone', '203.0.113.9', phone);
      const second = await roster.enrollDevice('iPhone', '203.0.113.9', phone);

      await expect('a phone can sign in, and then sign in again, and both are accepted', async () => {
        // The floor. A second sign-in that was simply refused would produce one
        // row too, and would be a different product: a person who is not sure it
        // worked has to be able to do it again.
        return first?.ok === true && second?.ok === true;
      });

      await expect('the second sign-in refreshed the row rather than minting one', async () => {
        // The id is what every per-device store in this app is keyed on — folder
        // grants, window grants, the recorded kind — so a new id would start a
        // trusted phone again as a stranger.
        return second.device.id === first.device.id;
      });

      await expect('and Devices holds exactly one row for that phone', async () => {
        const rows = roster.listDevices();
        const mine = rows.filter((row) => row.id === first.device.id);
        return rows.length === 1 && mine.length === 1;
      });

      await expect('the credential the phone is holding still works', async () => {
        // Checked before the stale one, deliberately: a wrong credential costs a
        // failed attempt against both the device and the address, and the good
        // answer must not be read through a limiter this guard tripped itself.
        const said = await roster.verifyCredential(second.credential, '203.0.113.9');
        return said?.ok === true && said.device.id === first.device.id;
      });

      await expect('and the one it replaced is refused, not quietly still live', async () => {
        // The second half of what those two rows were. A re-login the person
        // asked for should retire the secret it replaces; leaving it working is
        // two live credentials for one phone.
        const said = await roster.verifyCredential(first.credential, '203.0.113.9');
        return said?.ok === false;
      });

      const laptopRow = await roster.enrollDevice('MacBook', '203.0.113.10', laptop);

      await expect('two different keys are still two different devices', async () => {
        // The other floor, and it matters more than it looks: a collapse keyed on
        // something too loose — a display name, an address — would merge two
        // strangers' phones, and every iPhone since iOS 16 calls itself "iPhone".
        return laptopRow?.ok === true && roster.listDevices().length === 2;
      });

      /* ------------------------------------ the file every phone already has -- */

      /**
       * The shape the shipped bug left on disk, made by hand.
       *
       * The repair has to reach backwards or it only stops the next duplicate:
       * the rows are already written, on every machine a phone ever signed into
       * twice. So the two good rows are rewritten to share one key — which is
       * exactly what his `remote-auth.json` held — and the roster is then loaded
       * again, as a restart of the host would load it.
       */
      const file = path.join(scratch, auth.REMOTE_AUTH_FILE);
      const stored = JSON.parse(await fsp.readFile(file, 'utf8'));
      const shared = phone.toString('base64');
      for (const row of stored.devices) row.publicKey = shared;
      await fsp.writeFile(file, JSON.stringify(stored, null, 2));

      const restarted = new auth.RemoteAuth(scratch);
      const survivors = restarted.listDevices();

      await expect('a restart collapses two rows that were already sharing one key', async () => {
        return survivors.length === 1;
      });

      await expect('the row it keeps is one of the two that were really there', async () => {
        // Not a synthesised third row, and not the id of something that never
        // signed in: whichever it keeps, the phone that holds that id keeps its
        // grants.
        return survivors[0].id === first.device.id || survivors[0].id === laptopRow.device.id;
      });

      await expect('the losing row is dropped, not left behind marked revoked', async () => {
        // A duplicate is not a device that was taken away — it is a second record
        // of a device that is still trusted — so a tombstone would be the file
        // saying something untrue about the phone in his hand, and would spend a
        // roster slot saying it.
        const raw = JSON.parse(await fsp.readFile(file, 'utf8').catch(() => '{"devices":[]}'));
        const rows = Array.isArray(raw.devices) ? raw.devices : [];
        // Read through the roster as well, because what the file holds only
        // matters through what the roster answers.
        return restarted.listDevices().length === 1 && rows.length <= 1;
      });

      await expect('and the dropped row\'s credential is refused by the restarted host', async () => {
        // Dropping the row is what retires its secret: the id no longer resolves,
        // so the credential is refused like any other unknown one. If it still
        // worked, the duplicate would be gone from the screen and still on the
        // wire, which is the worse of the two states.
        const loser = survivors[0].id === first.device.id ? laptopRow : second;
        const said = await restarted.verifyCredential(loser.credential, '203.0.113.11');
        return said?.ok === false;
      });

      await expect('while the surviving row still lets its own device in', async () => {
        const winner = survivors[0].id === first.device.id ? second : laptopRow;
        const said = await restarted.verifyCredential(winner.credential, '203.0.113.12');
        return said?.ok === true;
      });
    } finally {
      await fsp.rm(scratch, { recursive: true, force: true });
    }

    /* ------------------------------------------------- the same shape, on a list -- */

    /**
     * The account half.
     *
     * He sent a screenshot of one account listed twice, and it is the same
     * defect one list over: an account **is** a config directory, so two
     * directories signed in to one login are two accounts by the app's own
     * definition and one account by every definition a person has. The rule that
     * settles it is a pure function in the renderer, so it is asked directly.
     */
    const accounts = await load('src/renderer/accounts.ts');

    await expect('the account list\'s own one-row-per-login rule is still there', async () => {
      return accounts !== null && typeof accounts.oneRowPerLogin === 'function';
    });

    const row = (id, name, provider, lastUsedAt = null, system = false) => ({
      id,
      name,
      provider,
      configDir: `/Users/somebody/Library/Application Support/terminaldeck/accounts/${id}`,
      system,
      color: '--accent',
      lastUsedAt,
    });

    const signedInAs = (address) => ({ state: 'signed-in', account: address });

    await expect('one login held in two directories is drawn once', async () => {
      // His shape exactly: the machine's own Claude install, and a profile added
      // later and named after the same address. Both print the address, because
      // the CLI is what names the login — which is what makes two directories on
      // one login indistinguishable on screen.
      const list = [row('system', 'Default', 'claude', 200, true), row('p1', 'Work', 'claude', 100)];
      const kept = accounts.oneRowPerLogin(list, {
        system: signedInAs('asad@example.com'),
        p1: signedInAs('asad@example.com'),
      });
      return kept.length === 1;
    });

    await expect('and the row it keeps is the machine\'s own install', async () => {
      // It is the account every fallback chain ends on and it cannot be deleted,
      // so dropping it in favour of a profile would leave the list naming a row
      // that can go away.
      const list = [row('p1', 'Work', 'claude', 900), row('system', 'Default', 'claude', 100, true)];
      const kept = accounts.oneRowPerLogin(list, {
        p1: signedInAs('asad@example.com'),
        system: signedInAs('asad@example.com'),
      });
      return kept.length === 1 && kept[0].id === 'system';
    });

    await expect('unless a session is actually running as the other one', async () => {
      // Dropping the row a session is running as would take the tick off the
      // menu, which is the strongest claim that menu makes.
      const list = [row('system', 'Default', 'claude', 100, true), row('p1', 'Work', 'claude', 900)];
      const kept = accounts.oneRowPerLogin(list, {
        system: signedInAs('asad@example.com'),
        p1: signedInAs('asad@example.com'),
      }, 'p1');
      return kept.length === 1 && kept[0].id === 'p1';
    });

    await expect('one address under two different agents is still two accounts', async () => {
      // The floor. A merge keyed on the address alone would fold a person's
      // Claude login into their ChatGPT login, and handing a Codex home to
      // Claude Code is a broken session rather than a login.
      const list = [row('p1', 'Work', 'claude', 100), row('p2', 'Work', 'codex', 100)];
      const kept = accounts.oneRowPerLogin(list, {
        p1: signedInAs('asad@example.com'),
        p2: signedInAs('asad@example.com'),
      });
      return kept.length === 2;
    });

    await expect('and two rows nobody can name are never merged on a guess', async () => {
      // The second floor, in the other direction. `namedLogin` is null for an
      // install nobody has signed into and for Codex, whose CLI does not print an
      // address at all — and two rows this list cannot name are two rows it
      // cannot prove are one.
      const list = [row('system', 'Default', 'claude', null, true), row('system:codex', 'Default (Codex CLI)', 'codex', null, true)];
      const kept = accounts.oneRowPerLogin(list, {});
      return kept.length === 2;
    });
  },
};
