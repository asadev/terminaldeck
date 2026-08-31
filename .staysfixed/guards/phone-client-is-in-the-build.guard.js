/**
 * Three public releases shipped without the phone app inside them.
 */
export default {
  name: 'the phone client is actually inside the shipped app',

  fixed: '2026-08-14',

  because:
    'The desktop app prints an address for you to open on your phone. Three consecutive releases — 0.1.3, 0.1.4 and '
    + '0.1.5 — went out with no phone app inside them at all, so that address answered with nothing. The packaging list '
    + 'named a folder that only exists after a separate build step nobody ran, and a packaging rule that matches zero '
    + 'files looks exactly like one whose files were all filtered out: the packager reports neither. It worked on a '
    + 'developer machine, where the folder happened to be lying around. The phone app is a separate package with its '
    + 'own lockfile, so every new packaging script has to remember it.',

  link: 'c7054e2 Put the phone client in the build, which no release has ever contained',

  async run({ expect, project }) {
    const path = await import('node:path');
    const fsp = await import('node:fs/promises');

    const bundle = String(project?.config?.app?.binary ?? '');
    const asar = path.resolve(project.paths.root, bundle, 'Contents', 'Resources', 'app.asar');

    /**
     * What the packaged archive says it contains. Read out of its own index rather than by
     * unpacking it: unpacking 300 megabytes to answer one question is not a check anybody
     * will run before every release.
     */
    const listing = await (async () => {
      const file = await fsp.open(asar, 'r');
      try {
        const head = Buffer.alloc(16);
        await file.read(head, 0, 16, 0);
        const size = head.readUInt32LE(12);
        const json = Buffer.alloc(size);
        await file.read(json, 0, size, 16);
        return JSON.parse(json.toString('utf8').replace(/\0+$/, ''));
      } finally {
        await file.close();
      }
    })();

    /** @param {string[]} parts */
    const entry = (parts) => parts.reduce((at, part) => (at && at.files ? at.files[part] : undefined), listing);

    await expect('the phone app folder is in the packaged build', async () => {
      return Boolean(entry(['pwa', 'dist']));
    });

    await expect('and its front page is really there, as a file with something in it', async () => {
      // A folder check is not enough, and that is the whole lesson of this bug: an empty
      // folder satisfies a folder check and still serves nothing to the phone.
      const page = entry(['pwa', 'dist', 'index.html']);
      return Boolean(page) && Number(page.size) > 200;
    });

    await expect('the page it serves is real HTML, not a placeholder', async () => {
      const page = entry(['pwa', 'dist', 'index.html']);
      // Electron leaves some files outside the archive, beside it in `app.asar.unpacked`,
      // and marks them so in the index. Reading the archive at an offset those entries do
      // not have is how this check first went wrong, and a check that errors is a check
      // nobody trusts — so both homes are handled.
      const bytes = page?.unpacked === true
        ? await fsp.readFile(path.join(`${asar}.unpacked`, 'pwa', 'dist', 'index.html'), 'utf8')
        : await (async () => {
            const file = await fsp.open(asar, 'r');
            try {
              const head = Buffer.alloc(16);
              await file.read(head, 0, 16, 0);
              const base = 16 + head.readUInt32LE(12);
              const buf = Buffer.alloc(Math.min(Number(page.size), 400));
              await file.read(buf, 0, buf.length, base + Number(page.offset));
              return buf.toString('utf8');
            } finally {
              await file.close();
            }
          })();
      return /<html|<!doctype html/i.test(String(bytes).slice(0, 400));
    });

  },
};
