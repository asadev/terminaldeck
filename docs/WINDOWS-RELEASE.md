# Releasing the Windows app

The Windows app is released on its own, from this repository, by anyone with write access. No Mac, no private PC:
GitHub's own Windows machines build, test, sign and publish it (`.github/workflows/windows-release.yml`). Mac
releases and Windows releases do not wait for each other and do not touch each other's files.

## How it fits together

| What | Where |
|---|---|
| Mac releases | tags `v0.21.4`, `v0.21.5`, ... One of them is GitHub's "latest". The Mac app, `install.sh` and terminaldeck.dev read "latest". |
| Windows releases | tags `windows-v0.21.5.0`, `windows-v0.21.6.0`, ... Never "latest". Each holds the installer (`TerminalDeck-<version>-x64.msix`), `TerminalDeck-Stable.cer`, `SHA256SUMS-windows.txt` and its own signed `windows-update.json`. |
| Windows update channel | one fixed release, tag `windows-stable` (a pre-release; never delete it). It holds the current `windows-update.json` + `.sig`. Installed Windows apps read it and offer the update in the side panel. |
| Signing | the installer: the Terminal Deck Stable certificate (the one installed PCs already trust). The update file: the Windows-only update key. Both are repository secrets; nobody can read them back, the workflow uses them. |

The app checks the Windows channel and the newest combined (Mac + Windows) release and offers whichever Windows
version is newer, so an old-style combined release still reaches Windows too.

## Release a new Windows version

1. **Merge** the pull requests that should go out into `main` (as usual).
2. **Run the workflow**: Actions > **Windows release** > **Run workflow**.
   - Branch: `main`.
   - mode: `release`.
   - version: leave empty for the next number (for example 0.21.2.0 becomes 0.21.3.0), or type four numbers
     yourself (it must be higher than what installed apps have; the workflow refuses anything else).
   - notes: one or two lines about what changed. People see them on the release page and in the app.
3. **Wait** (about 30-60 minutes). The run builds every project, runs every test project, builds the phone-link
   engine, packages and signs the MSIX, then publishes. Any failure stops it before anything is published; the
   test results are attached to the run as `windows-check`.
4. **Check the release**: Releases > `Terminal Deck for Windows <version>`. It has the `.msix`, the `.cer`,
   `SHA256SUMS-windows.txt` and `windows-update.json` (+ `.sig`). The run's last step prints
   "Live: installed apps are now offered <version>" and the "latest" release, which must still be a Mac `v...` tag.

Want to try first without publishing? Run with mode `dry-run` (any branch). It builds, tests and packages an
unsigned MSIX you can download from the run for two days. Nothing is published.

## What people get

- **Installed apps** (from this channel on): within their next update check the side panel shows
  "Update available · <version>", then **Restart to update**. The app downloads the MSIX from the release,
  checks its size, SHA-256, name, publisher and version against the signed update file, hands the running
  sessions over, and Windows installs it and reopens the app. Sessions keep running.
- **New installs**: from the release page: the `.cer` once (Trusted People), then the `.msix`.

## Pull a bad release back

1. Run **Windows release** with mode `point-back` and version = the last good version (for example 0.21.5.0).
   The channel then offers that version again; nobody is offered the bad one any more. Nothing is re-signed: each
   release keeps its own signed update file.
2. PCs that already installed the bad version stay on it (an app never installs an older version). Fix the
   problem, merge, and release a **higher** number (mode `release`); they get that.
3. Optionally edit the bad release on GitHub and tick "Set as a pre-release" so the download page stops showing
   it. Do not delete `windows-stable`, and do not mark any Windows release as "latest".

## Rules

- Never tick "Set as the latest release" on a Windows release: the Mac app and the server installer read "latest".
  The workflow never sets it, and puts "latest" back if GitHub moved it.
- Version numbers only go up. Windows numbers are independent of the Mac's; tags never clash (`windows-v...` vs `v...`).
- Never commit a `.pfx`, `.pem`, password or key. The secrets are set once by the repository owner.
