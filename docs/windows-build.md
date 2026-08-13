# Windows packaging — what has been established

Nothing in this repository builds for Windows today. This is the specification
for the job that would, written before the work rather than after it, and
verified where verification was possible from a Mac.

**Every claim below carries its source.** Where it cites a file and line, that
line was read in the installed toolchain and can be relied on. Where it cites
Microsoft, that page was fetched. Everything that needs a Windows machine to
settle is collected in the last section rather than guessed at and buried.

Verified against: `electron-builder` / `app-builder-lib` 26.15.3,
`electron-updater` 6.8.9, `electron` 41.10.5 (ABI 145), `node-pty` 1.1.0,
`better-sqlite3` 12.11.1 — the versions actually installed here on 2026-08-13.

---

## The native modules are the whole problem, and they are already solved

Both native dependencies compile against Electron's ABI, not Node's, which is
why `postinstall` runs `electron-builder install-app-deps`. On Windows they
behave completely differently from each other, and neither behaves the way the
generic advice assumes.

### `better-sqlite3` — downloads a prebuilt Electron binary, does not compile

It is **not** an N-API module: `src/better_sqlite3.cpp` contains zero `napi_`
calls and links V8 directly, so a binary is only valid for the exact ABI it was
built against. It carries `prebuild-install` as a dependency, and
`@electron/rebuild` checks for that first — `module-rebuilder.js:65` tries
`prebuildInstall.usesTool()` before it ever reaches `node-gyp`.

The upstream release for 12.11.1 carries **138 assets**, including:

```
better-sqlite3-v12.11.1-electron-v145-win32-x64.tar.gz
better-sqlite3-v12.11.1-electron-v145-win32-arm64.tar.gz
```

`electron-v145` is Electron 41 — the same number this machine's own rebuild
stamped into `node_modules/better-sqlite3/build/Release/.forge-meta`
(`arm64--145`). So on Windows this module is a download, for either
architecture. No compiler is involved and no cross-compilation risk exists.

### `node-pty` — ships Windows prebuilds, but gets rebuilt anyway

`node-pty` 1.1.0 builds on `node-addon-api` (see its `binding.gyp`), so it *is*
N-API and its prebuilt binaries are ABI-portable across Node and Electron
versions. The npm tarball ships four slices:

```
prebuilds/darwin-arm64   136 KB
prebuilds/darwin-x64      64 KB
prebuilds/win32-x64       30 MB
prebuilds/win32-arm64     28 MB
```

The Windows slices are large for one reason only — **28.5 MB of the 30 MB is
`.pdb` debug symbols** (measured: 28,520,448 bytes across five `.pdb` files in
`win32-x64`). Strip those and **2.5 MB per slice** remains, of which the five
binaries that actually load are 1.31 MB — `conpty.node`,
`conpty_console_list.node`, `pty.node`, `winpty.dll`, `winpty-agent.exe` — and
the other ~1.2 MB is the `conpty/` folder holding `conpty.dll` and
`OpenConsole.exe`, which is not loaded on the default path (see below).

Both numbers matter downstream and are easy to conflate: excluding `.pdb`
everywhere saves ~28.5 MB on Windows, and the `mac:` block excluding
`win32-*/**` removes the remaining **~5 MB** — two slices at 2.5 MB, not one.

`node-pty` has no `prebuild-install` dependency, so `@electron/rebuild` falls
through to `node-gyp` and compiles it from source. On Windows that needs MSVC
and the Windows SDK. `windows-latest` resolves to the `windows-2025` image —
confirmed against `actions/runner-images` on 2026-08-13 — which carries Visual
Studio 2022 Enterprise 17.14 with `VC.Tools.x86.x64`, Windows 11 SDK 26100 and
Python 3.12.10, so the toolchain is there with nothing to install in the
workflow. The label mapping is the durable part; those component versions are a
snapshot of one image release and drift with every image bump. **Whether that
compile actually succeeds has not been observed.**

Which binary loads is not a guess — `lib/utils.js:19` says it plainly:

```js
var dirs = ['build/Release', 'build/Debug', "prebuilds/" + process.platform + "-" + process.arch]
```

`build/Release` first, the prebuilds only as a fallback.

### The `conpty/` folder, and why it does not matter here

`src/win/conpty.cc:181` resolves `conpty\conpty.dll` relative to the directory
`conpty.node` was loaded from. That folder is created by `node-pty`'s
`postinstall` and would be wiped by a later `node-gyp rebuild`, which cleans
`build/` before it builds.

That would be a live bug except that the DLL is only loaded when a caller passes
`useConptyDll: true` — `lib/windowsPtyAgent.js:31` defaults it to `false` — and
`pty-manager.ts` does not pass it. The default path calls Windows' own
`CreatePseudoConsole`. So the missing folder costs nothing today, and would cost
everything the day someone opts in. Do not opt in without checking this first.

---

## The prebuilds exclusion is wrong for Windows, and wrong in a subtle way

`electron-builder.yml` currently carries:

```yaml
- '!**/node_modules/node-pty/prebuilds/**'
```

Its comment is accurate about *why* — a nested `darwin-x64` binary inside an
arm64 bundle is enough for macOS to show "App Update Required — This version of
Terminal Deck will not open in macOS 28", attributed to the parent bundle. The
line is load-bearing on macOS.

On Windows the identical line deletes `win32-x64/`, and the fallback that would
have saved a failed rebuild goes with it. Worse, it is silent: `loadNativeModule`
tries `build/Release` first and succeeds there, so the package looks fine right
up until the rebuild produced something incomplete.

`files` in a platform block is **appended to** the top-level list, not a
replacement. `fileMatcher.js:251` calls `addPatterns(config[name])` and then
`addPatterns(options.customBuildOptions[name])` on line 253, both against the
same matcher, and `customBuildOptions` is the `mac:`/`win:` block. That is what
makes a platform-aware exclusion possible at all, and it is verified rather than
assumed — it is the load-bearing fact under the whole fix.

So the blanket line is replaced by three narrower ones: drop the offending
`darwin-x64` slice everywhere, drop the debug symbols everywhere (28.5 MB of
the 30 MB, useful to nobody downstream), and let each platform drop the other
platform's slices. Exact YAML is in the handoff.

### It changes the macOS bundle too, and that has to be said out loud

The four narrower rules are not Windows-only in effect. Today's blanket line
excludes **all four** slices; the replacement set leaves `darwin-arm64/`
surviving on macOS — 136 KB, `pty.node` plus `spawn-helper`, the latter an
executable Mach-O that is currently not in the bundle and would be after the
change, inside a `hardenedRuntime: true` app with `identity: null`.

Nothing suggests this is harmful: the slice is arm64, so it cannot trigger the
macOS 28 notification the way `darwin-x64` does, and `node-pty` prefers
`build/Release` anyway (`lib/utils.js:19`), so it is dead weight rather than a
new code path. But it is a change to the shipped macOS bundle arriving inside a
change advertised as Windows packaging, and **it has not been packaged and
launched.** Either verify it with one `npm run dist:mac` before merging, or add
`'!**/node_modules/node-pty/prebuilds/darwin-arm64/**'` to the `mac:` block and
keep the macOS bundle byte-identical to today's.

`BUILDING.md` will also need a touch-up: it states the `files` rules drop
"58 MB, of which 57 MB is the two Windows slices", and quotes 310 MB → 293 MB.
Those sentences describe the blanket rule, not this one.

---

## One architecture, and it is x64

The mac decision and the Windows decision look opposite and rest on the same
sentence: **build the architecture you can test, when the other one costs users
nothing.**

On macOS that meant arm64 only, because Rosetta translates Intel → Apple
silicon and never the reverse, and no Intel Mac runs macOS 27. On Windows it
means x64 only, because the translation runs the *other* way: Windows 11 on ARM
emulates x64, so an x64 build reaches every Windows user alive, including
Snapdragon laptops. An arm64 slice buys those machines native speed and nothing
else.

It is not that arm64 is hard. Both native modules would be satisfied for
`win32-arm64` without a compiler — `better-sqlite3` by download, `node-pty` by
its own N-API prebuild. It is that there is no ARM Windows machine attached to
this project to launch the result on, and shipping an installer nobody has ever
run is the thing this repository already declined to do once.

If that hardware appears: GitHub's `windows-11-arm` runner is GA and free for
public repositories, and this repository is public — so the honest version is a
second native job, not a cross-build from `windows-latest`. That costs a second
`electron-builder` invocation, which lands straight in the manifest hazard
below, and it is why the manifest merge is documented there rather than left as
folklore.

### The `${arch}` landmine, for whoever adds arm64

`NsisTarget.js` builds a single dual-architecture installer by default
(`buildUniversalInstaller`, default `true`). In `finishBuild()` it then does
this:

```js
if (pattern.includes("${arch}") && this.archs.size > 1) {
  [...this.archs].forEach(([arch, appOutDir]) => builds.add(new Map().set(arch, appOutDir)))
}
```

Two architectures plus an `${arch}` in the name yields **three** installers: the
combined one (where `${arch}` and its leading separator are stripped entirely,
`macroExpander.js:9`) and one per architecture. Set
`nsis.buildUniversalInstaller: false` at the same time as adding the second
architecture, or ship three `.exe` files and explain which is which forever.

---

## The icon

`win.icon` defaults to `build/icon.ico`, and there is no `.ico` in `build/` —
`npm run art` produces `icon.iconset/`, `icon.png` and an `.icns` via
`iconutil`, which is macOS-only and does not emit ICO.

A `.ico` is **not strictly required**. `iconConverter.js` walks a candidate list
and falls through to `icon.png`, which exists at 1024×1024, then converts it.
The minimum it will accept for ICO is 256×256 (`ERR_ICON_TOO_SMALL`), so the
existing artwork clears it four times over.

Committing a real `build/icon.ico` is still better, for one reason the automatic
conversion cannot give you: control over which sizes are embedded. Windows picks
per context — 16px in the taskbar and title bar, 32px in Explorer's list views,
48px for medium icons, 256px for the tile and the installer. An ICO should carry
16, 24, 32, 48, 64, 128 and 256, and the small sizes should be the *simplified*
compositions `build/art/icon.mjs` already draws at those sizes rather than
downscales of the 1024. The iconset on disk is already the right source; only an
ICO writer is missing.

---

## Two jobs, one release

Cross-compiling native modules from macOS is the dominant failure mode and is
not proposed here. It is also blocked for a second reason: NSIS needs Wine to
run on a Mac, which is one more untested moving part in the path between source
and installer.

The release therefore needs three jobs, not two: `macos` and `windows` each
build and upload a workflow artifact, and a third job creates the single GitHub
Release once both have finished. Two jobs both calling `gh release create` is a
race, and the loser's assets do not land.

### Both update manifests must survive

`updateInfoBuilder.js:getUpdateInfoFileName` gives Windows no OS suffix at all —
mac writes `latest-mac.yml`, Windows writes plain **`latest.yml`**. They are
different files, so mac and Windows do not overwrite each other. Both must be
uploaded to the same release; `electron-updater` picks the one matching the
platform it is running on.

Within a platform the old hazard is unchanged and is exactly what
`scripts/check-release.mjs` exists to catch: `latest.yml` is rewritten on every
`electron-builder` invocation with only what that invocation produced. Multiple
artifacts merge into one manifest only when they are built in the *same* run —
`writeUpdateInfoFiles` merges by pushing into `existingTask.info.files` for
tasks sharing a channel file.

The portable executable is deliberately absent from `latest.yml`:
`isWriteUpdateInfo: !this.isPortable`. It also gets no `.blockmap` —
`isBuildDifferentialAware` returns false for portable. Only the NSIS installer
is an update target, which is correct: there is nothing to replace in place when
the app was never installed.

### The artifact names this all agrees on

Three things have to agree — the workflow's upload globs, the release notes, and
`scripts/check-release.mjs`. Written down once so they can be checked against
each other:

| File | Written by | In `latest.yml`? | Blockmap? |
|---|---|---|---|
| `terminaldeck-0.1.0-x64-setup.exe` | `nsis` | yes — this is what updates download | yes |
| `terminaldeck-0.1.0-x64-portable.exe` | `portable` | no | no |
| `latest.yml` | `nsis` | — | — |

`getArtifactArchName` leaves `x64` as `x64` for the `exe` extension (it only
rewrites to `x86_64`/`amd64` for Linux package formats), so `${arch}` resolves
to exactly the string above.

Both targets emit `.exe`, so **each needs its own `artifactName`.** The
inherited top-level pattern would name them identically and whichever finished
second would overwrite the first — silently, since both are legitimate outputs
of the same run. `artifactPatternConfig` reads the target's own `artifactName`
before the platform's, which is what makes the per-target override work.

Arch selection inside a manifest works by substring. `Provider.js:80`:

```js
filteredFiles.find(it => [it.url.pathname, it.info.url].some(n => n.includes(process.arch)))
```

`-x64.exe` matches an x64 client and `-arm64.exe` matches an arm64 one, with no
false match between them ("arm64" does not contain "x64"). Keep `${arch}` in the
artifact name and this stays true for free.

---

## Signing: what an unsigned Windows installer actually does to people

This is worse on Windows than the equivalent on macOS, and it should not be
described in softer words than Microsoft uses.

An unsigned installer trips Microsoft Defender SmartScreen. Microsoft's own
table for "No signature" reads: *warning — "Windows protected your PC"; user
must choose "Run anyway" before the app can run. Enterprise policy can prevent
continuation entirely.* On Windows 11, Smart App Control goes further and
**blocks execution of unsigned files outright** unless the file already has
positive reputation — not a dialog with a way through, a refusal.

And unsigned reputation does not accumulate: *"When a file is not signed,
SmartScreen reputation must build for each new version of your files, starting
with zero reputation."* Every release starts over.

The macOS story — right-click Open, or `xattr -dr com.apple.quarantine` — has no
clean Windows equivalent to put in release notes. "Click More info, then Run
anyway" is the instruction, and it is the same instruction malware distributors
give.

### What it costs to fix

| Option | Cost | Catch |
|---|---|---|
| **SignPath Foundation** | free | open-source projects only, subject to their eligibility review |
| **Azure Artifact Signing** (formerly Trusted Signing) | ~$9.99/month | **individuals: USA and Canada only** — organisations: USA, Canada, EU, UK |
| **OV certificate** (Sectigo, DigiCert, GlobalSign) | $300–500/year | private key must live on a hardware token or cloud HSM (CA/B Forum, since June 2023), which is friction in CI |
| **EV certificate** | $400+/year | buys nothing extra here |
| **Self-signed** | free | SmartScreen treats it as *"Same behavior as no signature"* — plus a false sense of having done something |

The OV figure is Microsoft's own (`signing-package-overview`, "$300–500/year").
Resellers advertise lower, and an earlier draft of this file said "$150–300"
without a source; if a cheaper quote is found, cite it, because this number is
half of why OV is named as the fallback.

The self-signed row previously carried the sentence *"blocks installation for
public users"* in quotation marks attributed to Microsoft. That sentence is not
on `smartscreen-reputation`, `signing-package-overview` or
`sign-msix-package-guide`. What Microsoft actually writes is the table cell
above, plus: *"Self-signed packages can only be installed on machines where the
certificate is explicitly trusted."* The conclusion was right; the quotation was
not Microsoft's, and is corrected here rather than left to be repeated.

Two of those rows deserve their own sentence.

**EV is no longer the answer, and most advice online is out of date.** EV
certificates used to bypass SmartScreen outright on first download. Microsoft
removed that in 2024 and now writes: *"Paying a premium for EV solely to avoid
SmartScreen warnings is no longer justified."*

**Azure Artifact Signing is the cheapest good option and is geographically
closed to this project.** Individual developers are limited to the USA and
Canada. The owner is in the UAE. That rules it out unless a US, Canadian, EU or
UK company is doing the signing.

Which leaves **SignPath Foundation** as the first thing to try — this project is
MIT-licensed, public, and builds in GitHub Actions, which is the shape their
programme is for — and an **OV certificate** as the paid fallback.

Nothing about signing blocks shipping. An unsigned Windows build installs and
runs; it just makes every user step past a warning that says the software might
be malicious. That is a product decision, not a technical one, and it should be
made on purpose.

### Signing does not block self-updates

Worth knowing before anyone assumes otherwise: `NsisUpdater.js:84` reads
`publisherName` from `app-update.yml` and, when it is absent, returns without
verifying anything. An unsigned Windows build can still update itself. The
integrity guarantee is then the sha512 in `latest.yml` fetched over HTTPS, and
nothing more. `src/main/updates/updater.ts` already declines to claim otherwise,
correctly.

---

## What cannot be settled from here

Stated plainly rather than assumed away. Every item needs a Windows machine or a
CI run on one:

1. **Whether `node-gyp` compiles `node-pty` on the runner.** The toolchain is
   present on the image. Nobody has watched it finish.
2. **Whether `build/Release` is complete after `@electron/rebuild`.** Specifically
   whether `winpty.dll` and `winpty-agent.exe` survive, and whether the `conpty/`
   folder is gone (it should be, harmlessly — see above).
3. **Whether the app runs.** This list was written against the tree as it stood
   a few minutes earlier and was already stale when it was committed; corrected
   here rather than left to mislead. The runtime port has largely landed on the
   `src/main/platform/` seam — `dev-ports.ts` now branches to
   `netstat`+`tasklist` through `platform/ports.ts`, `tailnet.ts` through
   `platform/lookup.ts` and `platform/tailscale.ts`, `profiles.ts` through
   `platform/credential-store.ts`, and `providers.ts` — which owns `loginPath`
   and therefore the PATH that `pty-manager.ts`, `alerts.ts`, `github.ts`,
   `git.ts`, `setup.ts` and the rest consume — picks `COMSPEC || cmd.exe` on
   Windows instead of `$SHELL -l`. Each has Windows unit tests that pin the
   platform explicitly.

   What is *not* ported, at the time of writing: `tool-probe.ts:116` still
   defaults `shell` to `process.env.SHELL || '/bin/zsh'` and builds a
   `which <bin>` command line, neither of which is a Windows idea.

   None of that has been executed on Windows. A seam with tests on both sides is
   not the same as a program that has run. **Packaging being ready does not make
   the app work**, and neither does a green unit test pinned to `'win32'`.
4. **Whether NSIS produces a working installer** with these options, and whether
   an install → update → uninstall round trip is clean.
5. **Whether `npm test` passes on Windows.** It does not, today, and the two
   reasons are known: `deckignore.test.ts:386` and `fs-tree.test.ts:335` both
   call `execFileSync('mkfifo', …)`, which does not exist on Windows. Those two
   need a platform guard before a Windows CI job can be green.

---

## One housekeeping item

`.gitignore` already excludes `*.p12`, `*.pem`, `*.key` and `*.cer` — the file
extensions an Apple identity arrives as. A Windows code-signing certificate
arrives as a **`.pfx`**, which is not in that list. Add it before one is ever
downloaded, not after.
