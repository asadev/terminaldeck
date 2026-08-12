# Third-party licences

Terminal Deck ships other people's code. This file lists it.

Every licence below was read from the `license` field of that package's own
`package.json` inside `node_modules`, not recalled from memory. Regenerate the
list after any dependency change:

```bash
npm ls --omit=dev --all --parseable | tail -n +2 | while read -r dir; do
  node -p "const p=require('$dir/package.json');\`\${p.name} \${p.version} \${p.license}\`"
done | sort -u
```

`--parseable` rather than `--json` on purpose: it prints the directory each
copy actually lives in, so a nested version is read from its own
`package.json`. Resolving by name against the top of `node_modules` is what
put three wrong licences in an earlier revision of this file.

Snapshot taken against the installed tree at version 0.1.0 — **16 direct**
production dependencies, **157 installed** packages in the production tree
(155 distinct names; `content-type` and `semver` are each present at two
versions), plus the Electron runtime and the two devDependencies that get
bundled into the shipped renderer.

Read each package from its own directory, not from the hoisted copy at the top
of `node_modules`. A nested version can carry a different licence than the
hoisted one of the same name — `chownr` is 3.0.0/BlueOak-1.0.0 at the top level
and 1.1.4/ISC inside `tar-fs`, and only the second is in the production tree.

---

## What actually reaches a user

Three different things get distributed, and they carry licences by different
routes. Lumping them together is how an attribution file ends up wrong.

| Tier | How it ships | Notes |
|---|---|---|
| **Bundled into `out/`** | Inlined into the JS by Vite/Rollup | Includes `react` and `react-dom`, which are devDependencies but end up in the renderer bundle |
| **Unpacked native modules** | `app.asar.unpacked/node_modules` | Only `better-sqlite3` and `node-pty` — verified in the built `.app` |
| **The Electron runtime** | The framework the app is built on | Chromium and Node, with their own large licence set |

Anything else in the production tree is a transitive dependency of those.

---

## Direct production dependencies

All 16 are MIT except `dompurify`, which is dual-licensed — see
[Needs a decision](#needs-a-decision).

| Package | Version | Licence | Used for |
|---|---|---|---|
| `@modelcontextprotocol/sdk` | 1.30.0 | MIT | MCP client and inspector |
| `@xterm/xterm` | 6.0.0 | MIT | The terminal renderer |
| `@xterm/headless` | 6.0.0 | MIT | Background emulator behind status detection |
| `@xterm/addon-fit` | 0.11.0 | MIT | Terminal resize |
| `@xterm/addon-web-links` | 0.12.0 | MIT | Clickable URLs in terminal output |
| `@xterm/addon-search` | 0.16.0 | MIT | Declared, not currently imported |
| `@xterm/addon-serialize` | 0.14.0 | MIT | Declared, not currently imported |
| `@xterm/addon-webgl` | 0.19.0 | MIT | Declared, not currently imported |
| `better-sqlite3` | 12.11.1 | MIT | Reading Chrome's cookie database on import (lazy `import()`) |
| `chokidar` | 5.0.0 | MIT | Transcript, git and file watchers |
| `dompurify` | 3.4.13 | **(MPL-2.0 OR Apache-2.0)** | Sanitising rendered markdown |
| `electron-updater` | 6.8.9 | MIT | Declared; nothing imports it yet (auto-update is Phase 8) |
| `gridstack` | 12.6.0 | MIT | Dashboard widget grid |
| `marked` | 17.0.6 | MIT | Markdown rendering |
| `node-pty` | 1.1.0 | MIT | Every terminal process |
| `picomatch` | 4.0.5 | MIT | Declared and deliberately unused — see `src/main/deckignore.ts` |

Five of these are declared but not imported. That is a housekeeping matter, not
a licensing one: they are all MIT, and an unused MIT dependency creates no
obligation. They are listed because this file claims to describe what is in
`package.json`.

## Bundled from devDependencies

Vite inlines these into the renderer bundle, so they are distributed with the
app even though `package.json` lists them under `devDependencies`. Attribution
follows distribution, not the dependency section.

| Package | Version | Licence |
|---|---|---|
| `react` | 19.2.8 | MIT |
| `react-dom` | 19.2.8 | MIT |

TypeScript (Apache-2.0) and Vite (MIT) are build tools whose own code does not
end up in the output, so they are not distributed and need no attribution here.

## The Electron runtime

| Component | Version | Licence |
|---|---|---|
| Electron | 41.10.5 | MIT — "Copyright (c) Electron contributors; Copyright (c) 2013-2020 GitHub Inc." |

Electron embeds Chromium and Node.js, which carry hundreds of their own
licences (BSD-3-Clause for Chromium itself, plus a long tail). Electron ships
the full text next to its prebuilt binary — `node_modules/electron/dist/`
holds `LICENSE` (Electron's own MIT, 1 KB) and `LICENSES.chromium.html`
(19 MB). Do not restate that file here.

**It is not currently in the packaged app.** `electron-builder` does not copy
either file into the bundle. Checked against a real build:

```sh
find "release/mac-arm64/Terminal Deck.app" -iname '*licen*'
# → only app.asar.unpacked/node_modules/{node-pty,better-sqlite3}/LICENSE
```

So the app as built today ships Chromium's code with none of Chromium's
notices. See [Needs a decision](#5-the-runtime-notices-are-not-in-the-bundle).

`Contents/Frameworks/` also carries three Objective-C frameworks that come
with Electron's Squirrel-based updater and are not npm packages, so they appear
nowhere in `npm ls`: `Squirrel.framework`, `Mantle.framework` and
`ReactiveObjC.framework`. None of them carries a licence resource inside the
bundle either. Squirrel is named in `LICENSES.chromium.html`; Mantle and
ReactiveObjC are not.

## Vendored native source

Two dependencies compile third-party C in-tree. This is invisible to `npm ls`
and is the part most attribution files miss.

| Vendored in | Component | Version | Licence |
|---|---|---|---|
| `better-sqlite3` | SQLite (`deps/sqlite3/sqlite3.c`) | 3.53.2 | Public domain |
| `node-pty` | winpty (`deps/winpty`) | — | MIT — "Copyright (c) 2011-2016 Ryan Prichard" |
| `node-pty` | conpty (`third_party/conpty`) | 1.23.251008001 | MIT (Microsoft, from `microsoft/terminal`) |

winpty and conpty are Windows-only and are **not** present in the current
macOS-only build. They become distributed material the moment a Windows target
is added to `electron-builder.yml`.

---

## Needs a decision

Five items are not plain MIT/BSD/ISC/Apache-2.0, are not stated at all, or are
missing from the build. Only the last one blocks a release; the rest want a
conscious choice on record.

### 1. `dompurify` — (MPL-2.0 OR Apache-2.0)

Dual-licensed, so the choice is the distributor's. **Take Apache-2.0.** MPL-2.0
is a file-level copyleft: modified MPL files must stay MPL and have their source
published. Terminal Deck bundles DOMPurify unmodified into a JS bundle, which is
survivable under either, but Apache-2.0 costs nothing here and removes the
question entirely. Record the election in this file — that is all "electing" a
branch of a dual licence requires.

**Action: state Apache-2.0 as the elected licence and keep DOMPurify unmodified.**
If it ever needs patching, patch it at the call site, not in `node_modules`.

### 2. `argparse@2.0.1` — Python-2.0

Reached via `electron-updater → js-yaml → argparse`. The Python Software
Foundation licence is permissive and imposes no copyleft, but it is unusual
enough that automated licence scanners flag it, and its clause 3 requires a
summary of changes if the code is modified. Nothing here modifies it.

**Action: accept.** Note that `electron-updater` is currently imported by
nothing — dropping that dependency removes this entire subtree.

### 3. `sax@1.6.1` — BlueOak-1.0.0

A modern permissive licence, OSI-approved and MIT-compatible, but young enough
that some corporate policy lists have not caught up with it.

`chownr` is *not* a second instance of this. The BlueOak-1.0.0 `chownr` is
3.0.0, hoisted to the top of `node_modules` for the dev tree only; the copy in
the production tree is `tar-fs/node_modules/chownr@1.1.4`, which is ISC. Read
from the top-level directory it looks like a BlueOak dependency, which is how
it was mis-filed here the first time.

**Action: accept.** No obligation beyond keeping the notice.

### 4. `@cfworker/json-schema` — not installed

Declared as an **optional** peer dependency of `@modelcontextprotocol/sdk`. It
is absent from `node_modules` and absent from the packaged app, so it is not
distributed and needs no attribution. Listed here only so that a future reader
who spots it in the lockfile does not conclude the inventory is incomplete.

**Action: none. Do not add it just to satisfy a warning.**

### 5. The runtime notices are not in the bundle

The MIT licence on Terminal Deck's own code is satisfied by shipping `LICENSE`.
Chromium's BSD-3-Clause and the long tail underneath it are not: their notices
have to travel with the binary, and today nothing in
`release/mac-arm64/Terminal Deck.app` carries them.

**Action: copy the runtime notices into the packaged app before the first
tagged release.** In `electron-builder.yml`:

```yaml
extraResources:
  - from: node_modules/electron/dist/LICENSE
    to: LICENSE.electron.txt
  - from: node_modules/electron/dist/LICENSES.chromium.html
    to: LICENSES.chromium.html
```

That adds ~19 MB to a ~114 MB download. The alternative — linking to the file
from an About panel rather than shipping it — is not equivalent, because the
notice requirement follows the binary, not the website. This is the one item on
this page that is an actual obligation rather than a preference.

### Multi-licensed, defaulting to the permissive branch

`expand-template` (MIT OR WTFPL) and `rc` (BSD-2-Clause OR MIT OR Apache-2.0)
are both build-chain transitives of `prebuild-install`
(`better-sqlite3 → prebuild-install → …`). Elect **MIT** for both.

---

## Full production tree

157 installed packages, grouped by licence exactly as read from each
package's own directory on disk.

### MIT (134)

`@hono/node-server` 2.1.0 · `@modelcontextprotocol/sdk` 1.30.0 ·
`@types/trusted-types` 2.0.7 · `@xterm/addon-fit` 0.11.0 ·
`@xterm/addon-search` 0.16.0 · `@xterm/addon-serialize` 0.14.0 ·
`@xterm/addon-web-links` 0.12.0 · `@xterm/addon-webgl` 0.19.0 ·
`@xterm/headless` 6.0.0 · `@xterm/xterm` 6.0.0 · `accepts` 2.0.0 ·
`ajv-formats` 3.0.1 · `ajv` 8.20.0 · `base64-js` 1.5.1 ·
`better-sqlite3` 12.11.1 · `bindings` 1.5.0 · `bl` 4.1.0 ·
`body-parser` 2.3.0 · `buffer` 5.7.1 · `builder-util-runtime` 9.7.0 ·
`bytes` 3.1.2 · `call-bind-apply-helpers` 1.0.2 · `call-bound` 1.0.4 ·
`chokidar` 5.0.0 · `content-disposition` 1.1.0 · `content-type` 1.0.5 ·
`content-type` 2.0.0 · `cookie-signature` 1.2.2 · `cookie` 0.7.2 ·
`cors` 2.8.6 · `cross-spawn` 7.0.6 · `debug` 4.4.3 ·
`decompress-response` 6.0.0 · `deep-extend` 0.6.0 · `depd` 2.0.0 ·
`dunder-proto` 1.0.1 · `ee-first` 1.1.1 · `electron-updater` 6.8.9 ·
`encodeurl` 2.0.0 · `end-of-stream` 1.4.5 · `es-define-property` 1.0.1 ·
`es-errors` 1.3.0 · `es-object-atoms` 1.1.2 · `escape-html` 1.0.3 ·
`etag` 1.8.1 · `eventsource-parser` 3.1.1 · `eventsource` 3.0.7 ·
`express-rate-limit` 8.6.2 · `express` 5.2.1 · `fast-deep-equal` 3.1.3 ·
`file-uri-to-path` 1.0.0 · `finalhandler` 2.1.1 · `forwarded` 0.2.0 ·
`fresh` 2.0.0 · `fs-constants` 1.0.0 · `fs-extra` 10.1.0 ·
`function-bind` 1.1.2 · `get-intrinsic` 1.3.0 · `get-proto` 1.0.1 ·
`github-from-package` 0.0.0 · `gopd` 1.2.0 · `gridstack` 12.6.0 ·
`has-symbols` 1.1.0 · `hasown` 2.0.4 · `hono` 4.13.1 · `http-errors` 2.0.1 ·
`iconv-lite` 0.7.3 · `ip-address` 10.5.0 · `ipaddr.js` 1.9.1 ·
`is-promise` 4.0.0 · `jose` 6.2.8 · `js-yaml` 4.3.1 ·
`json-schema-traverse` 1.0.0 · `jsonfile` 6.2.1 · `lazy-val` 1.0.5 ·
`lodash.escaperegexp` 4.1.2 · `lodash.isequal` 4.5.0 · `marked` 17.0.6 ·
`math-intrinsics` 1.1.0 · `media-typer` 1.1.1 · `merge-descriptors` 2.0.0 ·
`mime-db` 1.54.0 · `mime-types` 3.0.2 · `mimic-response` 3.1.0 ·
`minimist` 1.2.8 · `mkdirp-classic` 0.5.3 · `ms` 2.1.3 ·
`napi-build-utils` 2.0.0 · `negotiator` 1.0.0 · `node-abi` 3.94.0 ·
`node-addon-api` 7.1.1 · `node-pty` 1.1.0 · `object-assign` 4.1.1 ·
`object-inspect` 1.13.4 · `on-finished` 2.4.1 · `parseurl` 1.3.3 ·
`path-key` 3.1.1 · `path-to-regexp` 8.4.2 · `picomatch` 4.0.5 ·
`pkce-challenge` 5.0.1 · `prebuild-install` 7.1.3 · `proxy-addr` 2.0.7 ·
`pump` 3.0.4 · `range-parser` 1.3.0 · `raw-body` 3.0.2 ·
`readable-stream` 3.6.2 · `readdirp` 5.1.1 · `require-from-string` 2.0.2 ·
`router` 2.2.0 · `safe-buffer` 5.2.1 · `safer-buffer` 2.1.2 · `send` 1.2.1 ·
`serve-static` 2.2.1 · `shebang-command` 2.0.0 · `shebang-regex` 3.0.0 ·
`side-channel-list` 1.0.1 · `side-channel-map` 1.0.1 ·
`side-channel-weakmap` 1.0.2 · `side-channel` 1.1.1 ·
`simple-concat` 1.0.1 · `simple-get` 4.0.1 · `statuses` 2.0.2 ·
`string_decoder` 1.3.0 · `strip-json-comments` 2.0.1 · `tar-fs` 2.1.5 ·
`tar-stream` 2.2.0 · `tiny-typed-emitter` 2.1.0 · `toidentifier` 1.0.1 ·
`type-is` 2.1.0 · `universalify` 2.0.1 · `unpipe` 1.0.0 ·
`util-deprecate` 1.0.2 · `vary` 1.1.2 · `zod` 4.4.3

### ISC (12)

`chownr` 1.1.4 · `graceful-fs` 4.2.11 · `inherits` 2.0.4 · `ini` 1.3.8 ·
`isexe` 2.0.0 · `once` 1.4.0 · `semver` 7.7.4 · `semver` 7.8.5 ·
`setprototypeof` 1.2.0 · `which` 2.0.2 · `wrappy` 1.0.2 ·
`zod-to-json-schema` 3.25.2

### BSD-3-Clause (3)

`fast-uri` 3.1.5 · `ieee754` 1.2.1 · `qs` 6.15.3

### BSD-2-Clause (1)

`json-schema-typed` 8.0.2

### Apache-2.0 (2)

`detect-libc` 2.1.2 · `tunnel-agent` 0.6.0

### BlueOak-1.0.0 (1)

`sax` 1.6.1

### Python-2.0 (1)

`argparse` 2.0.1

### Multi-licensed (3)

`dompurify` 3.4.13 — (MPL-2.0 OR Apache-2.0), electing **Apache-2.0** ·
`expand-template` 2.0.3 — (MIT OR WTFPL), electing **MIT** ·
`rc` 1.2.8 — (BSD-2-Clause OR MIT OR Apache-2.0), electing **MIT**

---

## Bottom line

Nothing in this tree is copyleft in a way that reaches Terminal Deck's own
source. No GPL, no LGPL, no AGPL, no SSPL. The only file-level copyleft on offer
is DOMPurify's MPL-2.0, and its dual licence lets us decline it. Shipping the
app under MIT is clean.

One thing is outstanding rather than clean: every licence in this tree is a
notice licence, and the notices for the Electron runtime are not yet inside the
built app. That is item 5 above, and it is the one to close before tagging a
release — the npm tree is fine; the bundle is short a file.
