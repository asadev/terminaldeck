/**
 * "when we send our message mostly it is page still stays blank" — and *mostly* was the diagnosis.
 */
export default {
  name: 'no chat box sends a message as one write with the return on the end',

  fixed: '2026-08-22',

  because:
    'The agent programs classify each chunk arriving on their input before they look at the keys inside it, and a chunk '
    + 'of 64 bytes or more is PASTED text — where a carriage return is a new line and not send. Every chat box in this '
    + 'app wrote the message and the return as one lump, so short messages went through and every long one landed in '
    + 'the input box, dropped a line and was never submitted. Nothing was sent, so nothing reached the transcript, so '
    + 'the chat pane correctly showed nothing: "when we send our message mostly it is page still stays blank", and '
    + '*mostly* is the whole diagnosis. Four call sites carried the identical line when it was found, because it is the '
    + 'obvious one-liner and the rule forbidding it lives three files away, in a comment.',

  link: '4bde795 Chat: the message was never sent, and the pane had no way to find out',

  async run({ expect, project }) {
    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    /**
     * The failing shape: a write into a session whose argument is a template ending in `\r`.
     *
     * The name is matched loosely — `writeToSession`, `writeToServerShell`,
     * `writeToMachineSession` and whatever the next transport is called — because the mistake
     * is the shape of the argument and not which wire carries it. `sendToTerminal` is the one
     * correct way to send a message and it splits the two writes with a real gap.
     */
    const ONE_WRITE_SUBMIT = /\bwrite[A-Za-z]*\s*\([^)]*`[^`]*\$\{[^`]*\}\\r`/;

    /**
     * Every line of a file that has the failing shape, asked the same way of the tree and of
     * the build — one rule in one place, because the last time this rule lived in two places
     * it was four call sites before anybody noticed.
     */
    const offendingLines = (text) => {
      const found = [];
      // `/\r?\n/`, not `'\n'`: this repository is checked out with CRLF on Windows, which
      // leaves a `\r` on the end of EVERY line — and this hunts for a `\r` at the end of a
      // line. It matched all of them and failed only the Windows job.
      for (const [index, line] of text.split(/\r?\n/).entries()) {
        // A line of prose describing the defect is not the defect, and the rule is explained
        // in comments in three files, each of which quotes it.
        const code = line.replace(/^\s*(\/\/|\*|\/\*).*$/, '');
        if (!ONE_WRITE_SUBMIT.test(code)) continue;
        // The one allowed use, matched by what it is rather than by where it sits: a server
        // terminal typing the command it was opened to run at an SSH prompt. That is a shell,
        // not an agent's stdin, and the 64-byte rule is the agent's own classifier. Allowed by
        // content because a line number drifts, and a guard that fails when code moves is a
        // guard somebody switches off.
        if (code.includes('writeToServerShell') && code.includes('runCommand')) continue;
        found.push(index + 1);
      }
      return found;
    };

    await expect('the shape this guard hunts for still catches the line that actually shipped', async () => {
      // A pattern that has quietly stopped matching is a guard that passes for ever while
      // checking nothing, which is the one failure this whole tool exists to prevent. These
      // are the exact texts that were in `App.tsx` and in `ServerChatPane`.
      return offendingLines('window.deck.writeToSession(session.id, `${text}\\r`)').length === 1
        && offendingLines('void bridge.writeToServerShell(shellId, `${text}\\r`)').length === 1
        // And it leaves alone both the correct form and the one exception: a bare `\r` is a
        // single keystroke, and the server terminal is typing at a shell prompt.
        && offendingLines("write(id, '\\r')").length === 0
        && offendingLines('void bridge.writeToServerShell(opened, `${runCommand}\\r`)').length === 0;
    });

    /** Every `.ts`/`.tsx` under the renderer that is not a test. */
    const files = [];
    const walk = async (dir) => {
      for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
        if (entry.name === 'node_modules' || entry.name === 'assets') continue;
        const at = path.join(dir, entry.name);
        if (entry.isDirectory()) { await walk(at); continue; }
        if (!/\.tsx?$/.test(entry.name) || /\.test\.tsx?$/.test(entry.name)) continue;
        files.push(at);
      }
    };
    await walk(path.resolve(project.paths.root, 'src', 'renderer'));

    await expect('enough of the renderer was actually read for this to mean anything', async () => {
      // A rule that matches zero files looks exactly like a rule nothing broke. There were
      // 339 files here when this was written; a walk that finds a handful has gone wrong.
      return files.length > 100;
    });

    await expect('no chat box writes the message and the return in a single call', async () => {
      // Whichever file fails this is found again by hand with the same expression:
      //   grep -rnE 'write[A-Za-z]*[[:space:]]*\([^)]*`[^`]*\$\{[^`]*\}\\r`' src/renderer
      // Every chat surface in the app is a candidate, and a new one arrives every few weeks:
      // there were four when this was found, and the composer is the obvious place to write
      // the obvious line.
      for (const file of files) {
        if (offendingLines(await fsp.readFile(file, 'utf8')).length > 0) return false;
      }
      return true;
    });

    /*
     * And the same question of the app that actually ships, because this bug was measured in
     * the packed build and not in the tree: a message of 145 characters typed into chat mode
     * arrived in the input box and sat there.
     */
    const bundle = String(project?.config?.app?.binary ?? '');
    const asar = path.resolve(project.paths.root, bundle, 'Contents', 'Resources', 'app.asar');

    /** The archive's own index, and where its files really begin. */
    const archive = await (async () => {
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        /*
         * NOT `16 + size`. The header is a pickle padded to a four-byte boundary, and this
         * archive's is two bytes short of one — read from the unpadded offset and every file
         * comes back shifted by two bytes, which reads perfectly for the first hundred
         * kilobytes and then goes quietly wrong. Checked against the archive's own recorded
         * SHA-256 on 2026-09-02: unpadded mismatched, padded matched.
         */
        return { index: JSON.parse(json.toString('utf8').replace(/\0+$/, '')), base: 16 + size + ((4 - (size % 4)) % 4) };
      } finally {
        await file.close();
      }
    })();

    /** One packed file, read at its offset rather than by unpacking 300 megabytes. */
    const readPacked = async (parts) => {
      const entry = parts.reduce((at, part) => (at && at.files ? at.files[part] : undefined), archive.index);
      if (!entry) return '';
      // Electron leaves some files beside the archive in `app.asar.unpacked` and marks them so
      // in the index; reading one of those at an offset it does not have is how the
      // phone-client guard first went wrong.
      if (entry.unpacked === true) return fsp.readFile(path.join(`${asar}.unpacked`, ...parts), 'utf8');
      const file = await fsp.open(asar, 'r');
      try {
        const buf = Buffer.alloc(Number(entry.size));
        await file.read(buf, 0, buf.length, archive.base + Number(entry.offset));
        return buf.toString('utf8');
      } finally {
        await file.close();
      }
    };

    const shipped = Object.keys(archive.index?.files?.out?.files?.renderer?.files?.assets?.files ?? {})
      .filter((name) => name.endsWith('.js'));

    await expect('the window the app ships is in the build to be read at all', async () => shipped.length > 0);

    await expect('and the code that ships sends a message the same correct way', async () => {
      // Two questions of the same file, and the second keeps the first honest. The renderer
      // ships readable today, so the failing shape is greppable in it line by line; if a
      // future build starts mangling names then `sendToTerminal` disappears and this fails
      // loudly, rather than passing on a pattern that can no longer match anything.
      let sawTheSender = false;
      for (const name of shipped) {
        const text = await readPacked(['out', 'renderer', 'assets', name]);
        if (offendingLines(text).length > 0) return false;
        if (text.includes('sendToTerminal')) sawTheSender = true;
      }
      return sawTheSender;
    });
  },
};
