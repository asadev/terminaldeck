import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

export const placeholderNode = "#!/bin/sh\nprintf '%s\\n' 'Terminal Deck no longer uses Node; this placeholder only lets older updaters accept this version'\nexit 1\n"
export const placeholderManifest = '{"removed":true,"reason":"native app; placeholder for older updaters"}\n'

// The bridge contains exactly three inert files, never an executable Node runtime.
export function assertNativeLayout(app) {
  const resources = join(app, 'Contents', 'Resources')
  const present = ['runtime', 'engine'].some(name => existsSync(join(resources, name)))
  if (present) {
    for (const [directory, names] of [['runtime', ['bin', 'manifest.json']], ['runtime/bin', ['node']], ['engine', ['manifest.json']]]) {
      const path = join(resources, directory)
      const stat = lstatSync(path)
      if (!stat.isDirectory() || stat.isSymbolicLink() || JSON.stringify(readdirSync(path).sort()) !== JSON.stringify(names.sort())) {
        throw new Error(`Unexpected payload in ${directory}; only the compatibility placeholders are allowed`)
      }
    }
    for (const [name, bytes] of [['runtime/bin/node', placeholderNode], ['runtime/manifest.json', placeholderManifest], ['engine/manifest.json', placeholderManifest]]) {
      const path = join(resources, name), stat = lstatSync(path)
      if (!stat.isFile() || stat.isSymbolicLink() || readFileSync(path, 'utf8') !== bytes || (name.endsWith('/node') && !(stat.mode & 0o111))) {
        throw new Error(`Invalid compatibility placeholder: ${name}`)
      }
    }
  }
  for (const name of ['app.asar', 'app.asar.unpacked']) {
    if (existsSync(join(resources, name))) throw new Error(`The native app carries Electron: ${name}`)
  }
  if (existsSync(join(app, 'Contents', 'Frameworks', 'Electron Framework.framework'))) throw new Error('The native app carries Electron')
  const placeholder = join(resources, 'runtime', 'bin', 'node')
  function walk(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name)
      if (entry.name === 'node_modules' || entry.name.endsWith('.node') || (entry.name === 'node' && (!present || path !== placeholder))) {
        throw new Error(`The native app carries a Node payload: ${path}`)
      }
      if (entry.isDirectory()) walk(path)
    }
  }
  walk(app)
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  assertNativeLayout(resolve(process.argv[2]))
  console.log('Native layout valid: no Node runtime or Electron; only inert updater placeholders allowed')
}
