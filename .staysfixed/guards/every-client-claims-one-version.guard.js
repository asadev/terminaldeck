/**
 * The iPhone sat at 0.1.4 through four desktop releases, and every web deploy
 * had been failing for weeks with nobody the wiser.
 */
export default {
  name: 'the phone apps and the desktop all claim one version number',

  fixed: '2026-08-19',

  because:
    'The version lives in three separate files and nothing kept them in step. The iPhone project stayed at 0.1.4 '
    + 'through four desktop releases, then at 0.5.0 while the desktop shipped 0.6.0, and Android fell behind twice. It '
    + 'is not cosmetic: a phone installs the server software by fetching the release that matches its OWN version, so a '
    + 'client left behind fetches an old release, reports that the install worked, and the connection then fails — '
    + 'every step green, nothing working. The same day turned up the other half: the phone client is built from the '
    + 'repository’s package.json, that one file had been left off the deploy’s upload list, and a build that cannot '
    + 'read it does not degrade, it throws before it starts — so every deploy for weeks had failed and the live address '
    + 'kept serving whatever was there before. Three files, three release paths, and it has already drifted three times.',

  link: '693b770 Every web-app deploy has been failing, and the phone version had drifted (also d1f517a)',

  async run({ expect, read, run: shell, project }) {
    const declared = (text, pattern) => {
      const found = pattern.exec(text);
      return found === null ? '' : found[1];
    };

    const version = String(JSON.parse(await read('package.json')).version ?? '');

    await expect('the desktop names a plain three-part version', async () => {
      return /^\d+\.\d+\.\d+$/.test(version);
    });

    await expect('the iPhone project claims that same version', async () => {
      const marketing = declared(await read('ios/project.yml'), /MARKETING_VERSION:\s*"([^"]+)"/);
      return marketing !== '' && marketing === version;
    });

    await expect('the Android project claims that same version', async () => {
      const gradle = declared(await read('android/app/build.gradle.kts'), /versionName\s*=\s*"([^"]+)"/);
      return gradle !== '' && gradle === version;
    });

    /**
     * Is this file carried when the phone client is deployed?
     *
     * Answered by git's own ignore matcher pointed at `.vercelignore`, rather
     * than by reading the file and hoping the rules were understood the same
     * way the uploader understands them. `--no-index` because every path asked
     * about is tracked, and check-ignore says nothing about tracked paths
     * without it. Exit 0 means the path is excluded from the upload; exit 1
     * means it goes.
     */
    const excluded = async (file) => {
      const asked = await shell(
        `git -c core.excludesFile="${project.paths.root}/.vercelignore" check-ignore --no-index -- "${file}"`,
      );
      return asked.code === 0;
    };

    await expect('the upload list is really the thing being read', async () => {
      // The floor under the two claims below. `.vercelignore` opens by ignoring
      // everything and then names files back, so "not excluded" is the answer a
      // broken command gives too — a wrong path, a git that refused, a matcher
      // reading nothing at all. A file that must NOT be uploaded is the only
      // way to tell a working allowlist from a silent one.
      return await excluded('CHANGELOG.md');
    });

    await expect('the deploy still carries the file the phone client takes its version from', async () => {
      // This is the exact file that was left out. The client's build reads the
      // repository's package.json — not pwa's own, which has carried a 0.1.0
      // nobody has ever bumped — and leaving it out does not weaken the build,
      // it stops it dead before vite starts.
      return (await excluded('package.json')) === false;
    });

    for (const shared of ['src/shared/brand.ts', 'src/main/remote/protocol.ts', 'src/renderer/assets/fonts']) {
      await expect(`the deploy still carries ${shared}, which that build also reads`, async () => {
        // The same class, one directory over. The phone client deliberately
        // imports the product's own sealed channel, wire protocol, brand and
        // faces instead of keeping browser copies that drift — and each of them
        // is named back into an allowlist that starts by ignoring everything.
        // A missing font only warns, which is a live page in the wrong type.
        return (await excluded(shared)) === false;
      });
    }

    // NOT asserted here: that the live phone address serves this exact version.
    // This runs before a release, so the deployed client is the previous one by
    // design, and a guard demanding equality would be red on every honest run —
    // which is how guards get switched off. What broke the live page was the
    // upload list above, and that is checkable here, exactly, every time.
  },
};
