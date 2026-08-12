# Building and releasing Terminal Deck

How to turn the source in this repository into a disk image someone else can
install. macOS only for now — Linux and Windows targets are not configured.

Everything below is unsigned. That is a deliberate current state, not an
oversight; [Signing](#signing) explains exactly what changes when an Apple
Developer identity exists.

---

## Prerequisites

| Need | Version | Why |
|---|---|---|
| macOS | 12 or newer | Electron 41's own floor, and the SDK the build links against |
| Xcode Command Line Tools | any current | `clang` to compile the native modules, `iconutil` and `tiffutil` to build the artwork, `codesign` and `lipo` to inspect the result |
| Node | 22 or newer | enforced by `engines` in `package.json` |
| npm | 10 or newer | ships with Node 22 |

```bash
xcode-select --install     # if `iconutil` is missing
npm install                # postinstall rebuilds the native modules for Electron
```

`npm install` runs `electron-builder install-app-deps`, which rebuilds
`better-sqlite3` and `node-pty` against Electron's ABI rather than Node's. If
you ever see `NODE_MODULE_VERSION` mismatch at runtime, that step did not run —
`npx electron-builder install-app-deps` repeats it.

No Apple Developer account, certificate or network access to Apple is needed to
produce any of the outputs below.

---

## The commands

Run from the repository root. Never run a packaging command while `npm run dev`
is serving — both write `out/`, and the build will pull the ground out from
under the running app.

```bash
npm run build            # compile main + preload + renderer into out/. Not a package.
npm run art              # regenerate the icon and the disk-image background
npm run pack:mac         # unpackaged .app in release/mac-arm64/ — fastest way to smoke-test
npm run dist:mac         # the real thing: DMG + zip, arm64
npm run release:check    # preflight the contents of release/ before uploading
```

`dist:*` runs `npm run build` first, so it is always one command from a clean
checkout to a disk image.

Every packaging script passes `--publish never`. Nothing in this repository
uploads anything; see [Publishing](#publishing).

> **Build a release with `npm run dist:mac`, in one invocation.**
>
> electron-builder rewrites `latest-mac.yml` every time it runs, listing only
> what *that* run produced. With one architecture that is no longer a way to
> ship a half-written manifest, but the manifest and the files on disk can
> still drift — a rebuilt artifact with a stale manifest beside it is a release
> the updater rejects.
>
> `npm run release:check` exists to catch exactly this, plus missing artifacts
> and any size or SHA-512 in the manifest that disagrees with the file on disk.
> Run it before every upload.

### What each output is

After `npm run dist:mac`, `release/` holds:

| File | What it is | Who consumes it |
|---|---|---|
| `terminaldeck-<version>-arm64.dmg` | Installer disk image, Apple silicon | humans, download page |
| `terminaldeck-<version>-arm64.zip` | The same `.app`, zipped | `electron-updater` |
| `*.blockmap` | Per-file chunk hashes | `electron-updater`, to download only changed blocks |
| `latest-mac.yml` | Update manifest: versions, sizes, SHA-512s | `electron-updater` |
| `mac-arm64/Terminal Deck.app` | The unpackaged bundle the DMG was made from | debugging |
| `builder-debug.yml` | The file globs electron-builder resolved | debugging a packaging surprise |

The DMG is for people. The zip is for the updater — a disk image cannot be
applied as an update, so a release with only DMGs is a release that can never
update itself. Both must be uploaded together, along with `latest-mac.yml` and
the blockmaps.

### Measured sizes

Actual output of `npm run dist:mac` at v0.1.0 on Electron 41.10.5, built on an
M1 Pro:

| | arm64 |
|---|---|
| `.app`, sum of its files | 285 MB |
| `.dmg` | 113.8 MB |
| `.zip` | 113.8 MB |
| `app.asar` (our code + deps) | 19.5 MB | 19.5 MB |

Mebibytes, and the `.app` rows are the sum of the file sizes inside the bundle.
`du -sh` on the same bundle says 293 MB / 303 MB, because it counts allocated
blocks rather than bytes. Expect either number depending on how you measure;
the DMG is the only one anyone downloads.

Almost all of it is Electron. Our own code and its dependencies are the 19.5 MB
`app.asar`; the other ~265 MB is the Chromium framework, and the only way to
move that number is to ship less Electron, not less app.

The `files` rules in `electron-builder.yml` cut `app.asar` from 33 MB to
19.5 MB — measured, by packaging once with those rules removed. They drop
things that only exist in order to compile the native modules, plus every
source map: `better-sqlite3/deps` is the entire SQLite amalgamation, and
`node-pty/prebuilds` carries every platform's binary at once — 58 MB, of which
57 MB is the two Windows slices that can never load here. Those two land in
`app.asar.unpacked` rather than the archive, so they shrink the bundle
(310 MB down to 293 MB) rather than the asar; the asar's own 13 MB comes from
the source maps and the packages' test and example directories.

---

## Apple silicon only

`electron-builder.yml` builds `arm64` and nothing else.

Rosetta is not the reason, and it is the thing everyone assumes: Rosetta
translates Intel binaries to run on Apple silicon, never the reverse. Dropping
the x64 slice costs Apple silicon users nothing at all. The reason is that
**macOS 27 does not run on any Intel Mac.** An Intel slice would serve only the
four Intel models that reach macOS 26 Tahoe — 2019-2020 hardware, last sold in
June 2023 — and no one else, ever again.

It also cost something. CI runs on Apple silicon, so an x64 slice could only be
cross-built, and `node-pty` and `better-sqlite3` compile from source against
Electron's ABI, which is where cross-architecture builds break. It was never
launched on Intel hardware, and there is no Intel hardware here to launch it
on. Meanwhile an Apple silicon user who picked the x64 disk image got a system
notification saying the app will not open in macOS 28, and a first launch that
took half a minute while Rosetta translated Chromium.

A universal binary was the other option and is worse: the sum of both slices,
roughly a 230 MB download for every user, up from 114, buying the same Intel
coverage this decision already declined — paid for in bytes taken from the
users there actually are. It also has to fuse three native binaries —
`better_sqlite3.node`, `pty.node`, and `node-pty`'s `spawn-helper`.

`artifactName` keeps `${arch}` even so. Left off, electron-builder's default
treats x64 as the implicit architecture and drops the suffix, so an unsuffixed
file reads as the Intel build to anyone who knows the convention.

Cross-building works in both directions on either kind of Mac —
electron-builder downloads the other architecture's Electron and rebuilds the
native modules for it. Both artifacts on this page were produced on an M1.

---

## The artwork

Both the app icon and the disk-image background are original, generated from
vector descriptions by two dependency-free scripts:

```
build/art/icon.mjs             the icon
build/art/dmg-background.mjs   the disk-image background
```

`npm run art` runs both and compiles `build/icon.iconset/` into
`build/icon.icns` with `iconutil`.

The icon is drawn from signed-distance fields at each size natively, so no size
is a downscale of a bigger bitmap, and 16px and 32px use a deliberately
simplified composition — at those sizes the prompt chevron is under two pixels
wide and turns to mud. The generated PNGs and the `.icns` are committed, so a
build does not depend on running the generator.

If you change the disk image's `window` or `contents` geometry in
`electron-builder.yml`, change the matching constants at the top of
`build/art/dmg-background.mjs` and re-run `npm run art`, or the background and
the icons will disagree.

Note that `dmg.background` cannot be turned off. Setting it to `null` makes
electron-builder fall through to a stock image bundled inside its own npm
package, so the real choice is our artwork or theirs.

---

## Signing

The build is **not signed**, because there is no Apple Developer identity on
this machine. Everything around signing is already configured, so getting there
later means supplying credentials and deleting one line — no restructuring.

What is already in place in `electron-builder.yml`:

- `hardenedRuntime: true`
- `entitlements: build/entitlements.mac.plist` — JIT and unsigned executable
  memory for V8, library validation disabled so the unsigned `.node` modules
  load, and dyld environment variables allowed because sessions are spawned
  through the user's login shell
- `entitlementsInherit: build/entitlements.mac.inherit.plist` for the nested
  helper bundles
- `identity: null` — the one line that has to go

To sign, once a Developer ID Application certificate exists:

```bash
export CSC_LINK=/absolute/path/to/DeveloperID.p12   # or a base64 data: URL
export CSC_KEY_PASSWORD='…'
# then delete the `identity: null` line in electron-builder.yml
npm run dist:mac
```

electron-builder picks the identity out of the keychain or `CSC_LINK`, signs
every nested binary inside-out, and applies the entitlements above.

**Never reach for `codesign --deep`.** It walks Electron's nested frameworks in
the wrong order and produces a bundle that will not launch. That has already
happened once on this machine. If signing fails, fix the identity or the
entitlements — do not add `--deep`.

### What the unsigned build means for users

With `identity: null`, electron-builder signs **nothing** — it logs `skipped
macOS code signing`. The only signature in the bundle is the ad-hoc one Apple's
linker already put on Electron's own binaries:

```
$ codesign -dvv "release/mac-arm64/Terminal Deck.app"
Identifier=Electron
flags=0x20002(adhoc,linker-signed)
Signature=adhoc

$ codesign --verify "release/mac-arm64/Terminal Deck.app"
…: code has no resources but signature indicates they must be present
```

That is enough for the app to launch on Apple silicon, which is why the
verification below works, and it is why local builds are usable. It is nowhere
near enough for Gatekeeper. Anyone who downloads it gets *"Terminal Deck is
damaged and can't be opened"* or *"cannot be opened because the developer
cannot be verified"*, because the download carries a quarantine flag. Their way
past it is System Settings → Privacy & Security → **Open Anyway**, or:

```bash
xattr -dr com.apple.quarantine "/Applications/Terminal Deck.app"
```

Asking strangers to run `xattr` on an app they just downloaded is a bad look
and trains a bad habit. Treat a Developer ID as a prerequisite for a public
release, not a nice-to-have.

---

## Notarisation

Not done, and not attempted. It requires signing first — Apple will not
notarise an unsigned or ad-hoc-signed bundle.

Once there is an identity, `mac.notarize: false` in `electron-builder.yml`
becomes `true` and the credentials come from the environment:

```bash
export APPLE_ID='the-developer-account@example.com'
export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'   # appleid.apple.com
export APPLE_TEAM_ID='XXXXXXXXXX'                          # 10 chars, from developer.apple.com
npm run dist:mac
```

electron-builder uploads each artifact to Apple's notary service, waits for the
ticket, and staples it. Budget 5–20 minutes per artifact on top of the build,
and remember there are two.

Verify afterwards:

```bash
spctl -a -vvv -t install "release/mac-arm64/Terminal Deck.app"
xcrun stapler validate "release/terminaldeck-<version>-arm64.dmg"
```

### What it costs

| Item | Cost |
|---|---|
| Apple Developer Program membership | **USD 99 / year**, and it is the only way to get a Developer ID certificate |
| Developer ID Application certificate | included in the membership |
| Notarisation itself | free and unlimited, once you are a member |
| App-specific password for the notary service | free |

The membership is the entire monetary cost. The non-monetary cost is that
enrolment takes days rather than minutes (Apple verifies identity, and for a
company it wants a D-U-N-S number), so start it well before a release date.

Distributing through the Mac App Store instead is a different build (`mas`
target, full App Sandbox) and is not configured here — the App Sandbox would
have to allow spawning arbitrary user binaries, which it does not.

---

## Publishing

**Nothing in this repository publishes anything.** Every packaging script passes
`--publish never`, and the `publish:` block in `electron-builder.yml` exists
only so that `app-update.yml` is written into the bundle for `electron-updater`
to read.

Creating the GitHub repository and uploading a release are the owner's to
trigger, deliberately, by hand.

```bash
# 1. create the repo and push (once)
gh repo create asadev/terminaldeck --public --source=. --remote=origin --push

# 2. build the artifacts
npm run dist:mac
npm run release:check

# 3. cut a release and upload everything the updater needs
gh release create v0.1.0 \
  release/terminaldeck-0.1.0-*.dmg \
  release/terminaldeck-0.1.0-*.zip \
  release/terminaldeck-0.1.0-*.blockmap \
  release/latest-mac.yml \
  --title "Terminal Deck 0.1.0" --generate-notes
```

Upload the zips, the blockmaps and `latest-mac.yml` as well as the DMGs. A
release with only DMGs is one that `electron-updater` cannot read.

---

## Verifying a build

The v0.1.0 disk image was mounted and the app inside it launched and confirmed
to open its window, natively on Apple silicon.

An earlier note here claimed the Intel build had been verified too, "under
Rosetta 2". That was not a test of anything: running an x86_64 build under
Rosetta on Apple silicon exercises the translator, not Intel hardware. No
build of this app has ever run on an Intel Mac, which is part of why there is
no longer an Intel build.

How to repeat it:

```bash
# it mounts
hdiutil attach -nobrowse -readonly release/terminaldeck-0.1.0-arm64.dmg

# the window layout is real: 600x400, icons at (155,180) and (445,180),
# our background, no toolbar or sidebar
#   -> recorded in "/Volumes/Terminal Deck 0.1.0/.DS_Store"

# the app inside launches, from the read-only volume, without touching your
# real profile
open -n "/Volumes/Terminal Deck 0.1.0/Terminal Deck.app" --args --user-data-dir=/tmp/td-verify

# expect four processes: main, GPU, network utility, renderer.
# a renderer only exists if a window was created and loaded.
ps -Ao pid,command | grep "/Volumes/Terminal Deck"

hdiutil detach "/Volumes/Terminal Deck 0.1.0"
```

Sanity-check the bundle itself:

```bash
APP="release/mac-arm64/Terminal Deck.app"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist"   # 12.0
lipo -archs "$APP/Contents/MacOS/Terminal Deck"                                        # arm64
codesign -dvv "$APP"                                                                   # adhoc, today
find "$APP/Contents/Resources/app.asar.unpacked" -name '*.node' -o -name spawn-helper
```

The native modules must be present **outside** `app.asar` — a `.node` file
cannot be loaded from inside an archive, and `node-pty` forks `spawn-helper` as
a real file on disk. If that `find` comes back empty, sessions will fail to
start in the packaged app while working perfectly in `npm run dev`.
