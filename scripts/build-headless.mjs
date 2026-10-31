#!/usr/bin/env node
/**
 * Turn `out/headless` into an npm package that installs on a server.
 *
 * Two steps and neither is cosmetic:
 *
 *  1. **Shebangs and the execute bit.** npm links a `bin` entry into
 *     `node_modules/.bin` (or `~/.local/bin`) as a symlink to the file itself
 *     on POSIX. A file with no `#!` line is handed to the shell, which reads
 *     `import` as a command and prints something unrelated to what went wrong.
 *
 *  2. **A manifest listing only what the bundle actually imports.** The root
 *     `package.json` carries Electron, electron-builder, React, xterm's browser
 *     addons and gridstack — none of which this needs, all of which would be
 *     downloaded onto somebody's server. So the dependency list is *read out of
 *     the emitted files* rather than copied: whatever survived the bundle is a
 *     dependency, and nothing else is. A package whose dependency list is
 *     maintained by hand is a package that eventually ships without one it
 *     needs.
 *
 * It refuses to write a manifest naming a package the root does not depend on,
 * because the version has to come from somewhere real. A bundle that suddenly
 * imports something new stops the build rather than shipping a `*` range.
 */

import { execFileSync } from 'node:child_process'
import { chmodSync, copyFileSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'out', 'headless')

const root = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))

/* ------------------------------------------------------------------ build -- */

execFileSync('npx', ['vite', 'build', '--config', 'vite.headless.config.ts'], {
  cwd: ROOT,
  stdio: 'inherit',
  // shell:true so Windows resolves npx.cmd (Node refuses to spawn a .cmd
  // directly, EINVAL); the args are static so shell quoting is not a risk.
  shell: true,
})

/* ------------------------------------------------------------ dependencies -- */

/**
 * Every bare specifier the emitted bundles import.
 *
 * Anchored to the start of a line, because the bundles are unminified and carry
 * the source's comments with them — a first attempt matched `from "still
 * working"` out of a sentence in `session-activity.ts` and would have written it
 * into the manifest.
 */
function importedPackages() {
  const found = new Set()
  for (const file of readdirSync(OUT).filter((name) => name.endsWith('.mjs'))) {
    const source = readFileSync(join(OUT, file), 'utf8')
    const patterns = [
      /^import\s[^;]*?\sfrom\s*["']([^"']+)["'];?$/gm,
      /^import\s*["']([^"']+)["'];?$/gm,
      /\bimport\(\s*["']([^"']+)["']\s*\)/g,
    ]
    for (const pattern of patterns) {
      for (const match of source.matchAll(pattern)) {
        const id = match[1]
        if (id.startsWith('node:') || id.startsWith('.') || id.startsWith('/')) continue
        found.add(id.startsWith('@') ? id.split('/').slice(0, 2).join('/') : id.split('/')[0])
      }
    }
  }
  return [...found].sort()
}

const needed = importedPackages()
const dependencies = {}
for (const name of needed) {
  const range = root.dependencies?.[name]
  if (range === undefined) {
    console.error(
      `The headless bundle imports "${name}", which the root package.json does not depend on, ` +
        'so there is no version to publish. Add it there first.',
    )
    process.exit(1)
  }
  dependencies[name] = range
}

/* --------------------------------------------------------------- manifest -- */

const manifest = {
  name: root.name,
  version: root.version,
  description:
    'The Terminal Deck host, without a window — run coding-agent sessions on a server or ' +
    'inside WSL and drive them from your phone.',
  type: 'module',
  bin: {
    terminaldeck: './cli.mjs',
    'terminaldeck-host': './host.mjs',
  },
  engines: root.engines,
  license: root.license,
  author: root.author,
  homepage: root.homepage,
  repository: root.repository,
  /*
   * The root's keywords, minus the one that is not true here.
   *
   * "electron" is accurate for the desktop app and is the opposite of what this
   * package is — somebody searching npm for a way to run agents on a server
   * should not find a result that advertises a browser engine it does not
   * contain.
   */
  keywords: [...root.keywords.filter((word) => word !== 'electron'), 'headless', 'wsl', 'server'],
  /*
   * Named, rather than `*.mjs`, and the reason is `demo.mjs`.
   *
   * The build emits a third program — the public demo host, which approves any
   * device that redeems a code it minted. That is correct for a throwaway
   * container on a box we own and is not something to hand to everybody who
   * types `npm install -g terminaldeck`. A glob would have shipped it the day it
   * was added, silently, which is exactly how a thing like that ends up on
   * somebody's server.
   *
   * The chunk glob is still a glob because Rollup names shared chunks after
   * whichever module it picked, and pinning those would break on the next build.
   */
  files: ['cli.mjs', 'host.mjs', 'chunk-*.mjs', '*.mjs.map', 'README.md', 'LICENSE'],
  dependencies,
}

writeFileSync(join(OUT, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
writeFileSync(join(OUT, 'LICENSE'), readFileSync(join(ROOT, 'LICENSE'), 'utf8'), 'utf8')
writeFileSync(join(OUT, 'README.md'), readme(), 'utf8')

/* --------------------------------------------------------------- shebangs -- */

for (const [command, file] of Object.entries(manifest.bin)) {
  const path = join(OUT, file.replace('./', ''))
  const source = readFileSync(path, 'utf8')
  if (!source.startsWith('#!')) writeFileSync(path, `#!/usr/bin/env node\n${source}`, 'utf8')
  chmodSync(path, 0o755)
  console.log(`  ${command} -> ${file}`)
}

/*
 * The demo host gets a shebang too, and no `bin` entry.
 *
 * `demo/Dockerfile` copies this directory into an image and runs `demo.mjs`
 * directly, so it needs to be executable — but it must not become a command on
 * anybody's PATH, and it is not in `files`, so `npm publish` leaves it behind.
 * Done here rather than in the loop above because the loop is driven by `bin`,
 * and adding it there is the mistake this comment exists to prevent.
 */
const demo = join(OUT, 'demo.mjs')
const demoSource = readFileSync(demo, 'utf8')
if (!demoSource.startsWith('#!')) writeFileSync(demo, `#!/usr/bin/env node\n${demoSource}`, 'utf8')
chmodSync(demo, 0o755)
console.log('  (demo host, not published) -> ./demo.mjs')

/* ------------------------------------------------------- what ships with the app -- */

/*
 * A tarball and the installer, in one folder, for the desktop app to carry.
 *
 * This is what "install it on a server from the connector" is made of. The npm
 * name is a **reservation** — `install-headless.sh` even has a refusal for the
 * package it currently resolves to, *"npm installed terminaldeck and it provided
 * no `terminaldeck` command"* — so a server install has to be handed real bytes,
 * and `src/main/servers/host.ts` puts these two files there over SFTP.
 *
 * `npm pack` rather than a hand-rolled tar, because the manifest above already
 * says exactly what may ship (`files`), and packing any other way would be a
 * second answer to that question — the one that shipped `demo.mjs` the day it
 * was added.
 *
 * The names are fixed rather than versioned. electron-builder copies this whole
 * folder into `Resources/headless`, and a versioned filename would mean the
 * lookup in `host-package.ts` had to know a version string that lives in three
 * other places. The version travels inside the tarball, where npm reads it.
 */
const SHIP = join(ROOT, 'out', 'headless-package')
rmSync(SHIP, { recursive: true, force: true })
mkdirSync(SHIP, { recursive: true })

execFileSync('npm', ['pack', '--silent', '--pack-destination', SHIP], { cwd: OUT, stdio: 'inherit', shell: true })
const packed = readdirSync(SHIP).filter((name) => name.endsWith('.tgz'))
if (packed.length !== 1) {
  console.error(`Expected one tarball in ${SHIP} and found ${packed.length}.`)
  process.exit(1)
}
renameSync(join(SHIP, packed[0]), join(SHIP, 'terminaldeck-host.tgz'))
copyFileSync(join(ROOT, 'scripts', 'install-headless.sh'), join(SHIP, 'install.sh'))
chmodSync(join(SHIP, 'install.sh'), 0o755)

console.log(`\nFor the desktop app to carry: ${SHIP}`)
console.log(`  terminaldeck-host.tgz  (was ${packed[0]})`)
console.log('  install.sh')

console.log(`\nPackage written to ${OUT}`)
console.log(`  dependencies: ${needed.join(', ') || 'none'}`)

/* ----------------------------------------------------------------- readme -- */

function readme() {
  return `# ${root.productName} — headless host

The desktop app minus the window. It runs as a background process, joins the
relay, serves sessions, and is driven from a phone or from ${root.productName}
on another machine.

It is the answer for a Linux server and for WSL, and it is not a reduced
product: sessions in granted folders, the localhost tunnel, clipboard, file
transfer and machine-to-machine pairing all work, because it is the same code
with a different shell around it.

## Install

    npm install -g ${root.name}

Node ${root.engines?.node ?? '>=22'} is required. There is no Electron and no
Chromium in this package.

## Use

    terminaldeck pair      # show a code, type it into your phone, approve it
    terminaldeck status    # running? reachable? what is it holding open?
    terminaldeck folders   # which folders each device may use
    terminaldeck stop

\`terminaldeck-host\` is the process itself. \`terminaldeck pair\` starts it for
you the first time; a service manager should start it directly.

## Keeping it reachable

Run \`terminaldeck status\` — it prints what applies to the machine it is on,
and only that. On a Linux server there is usually nothing to do. Inside WSL
there is: Windows shuts the distribution down when the last terminal closes,
taking the host and every session in it, and \`status\` gives the exact commands
to stop that happening.

    terminaldeck-host --install-service
    systemctl --user enable --now ${root.name}.service
    sudo loginctl enable-linger "$USER"

## Idle mode

With nothing attached, the host holds the relay connection and stops the rest.
It wakes on the first attach, driven by that event rather than by a timer.
\`terminaldeck status\` says which mode it is in and what it is holding open.
`
}
