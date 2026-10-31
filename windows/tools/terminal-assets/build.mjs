import { build } from 'esbuild'
import { copyFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('../../src/TerminalDeck.App/Assets/terminal/', import.meta.url))
await build({ entryPoints: ['terminal.js'], bundle: true, minify: true, legalComments: 'none', external: ['*.woff2'], outfile: `${out}terminal.js` })
// Cascadia Mono, SIL Open Font License 1.1 (see THIRD-PARTY.md).
for (const [subset, name] of [['latin', 'latin'], ['latin-ext', 'latin-ext'], ['symbols2', 'symbols']])
  await copyFile(`node_modules/@fontsource-variable/cascadia-mono/files/cascadia-mono-${subset}-wght-normal.woff2`, `${out}cascadia-mono-${name}.woff2`)
await writeFile(`${out}index.html`, '<!doctype html>\n<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="terminal.css"></head><body><div id="terminal"><div id="screen"></div></div><script src="terminal.js"></script></body></html>\n')
