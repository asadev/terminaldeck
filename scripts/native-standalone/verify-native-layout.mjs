import { closeSync, constants, existsSync, fstatSync, lstatSync, openSync, readFileSync, readSync, readdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

export const placeholderNode = "#!/bin/sh\nprintf '%s\\n' 'Terminal Deck no longer uses Node; this placeholder only lets older updaters accept this version'\nexit 1\n"
export const placeholderManifest = '{"removed":true,"reason":"native app; placeholder for older updaters"}\n'

function hostIntegrated(app) {
  const path = join(app, 'Contents', 'Info.plist')
  if (!existsSync(path)) return false
  const bytes = readFileSync(path)
  // Leave legacy OFF layouts/fixtures alone. Binary plists need the same
  // native parser the release-feed validator already uses on this Mac.
  if (bytes.subarray(0, 8).toString() !== 'bplist00' && !bytes.toString('utf8').includes('TDHostIntegrated')) return false
  const plist = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path], { encoding: 'utf8' }))
  if (plist.TDHostIntegrated !== undefined && typeof plist.TDHostIntegrated !== 'boolean') throw new Error('TDHostIntegrated must be a Boolean')
  return plist.TDHostIntegrated === true
}

function assertSessionHost(app) {
  for (const directory of ['Contents', 'Contents/MacOS']) {
    const stat = lstatSync(join(app, directory))
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`Invalid session-host directory: ${directory}`)
  }
  const path = join(app, 'Contents', 'MacOS', 'TerminalDeckSessionHostHelper')
  const stat = lstatSync(path)
  if (!stat.isFile() || stat.isSymbolicLink() || !(stat.mode & 0o111)) throw new Error('Invalid native session-host helper: expected a regular executable')
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const current = fstatSync(descriptor), header = Buffer.alloc(32)
    const size = readSync(descriptor, header, 0, header.length, 0)
    const magic = header.subarray(0, 4).toString('hex')
    if (!current.isFile() || !(current.mode & 0o111) || current.dev !== stat.dev || current.ino !== stat.ino || size !== 32 || !['cffaedfe', 'feedfacf'].includes(magic)) {
      throw new Error('Invalid native session-host helper: expected a 64-bit Mach-O executable')
    }
    const type = magic === 'cffaedfe' ? header.readUInt32LE(12) : header.readUInt32BE(12)
    if (type !== 2) throw new Error('Invalid native session-host helper: Mach-O type must be executable')
  } finally { closeSync(descriptor) }
}

// The bridge contains exactly three inert files, never an executable Node runtime.
export function assertNativeLayout(app) {
  if (hostIntegrated(app)) assertSessionHost(app)
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
