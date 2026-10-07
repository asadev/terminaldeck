#!/usr/bin/env node
/** Generate a local native ZIP and its separate feed. Never publishes anything. */
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const rootPath = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const root = JSON.parse(readFileSync(join(rootPath, 'package.json'), 'utf8'))
const options = {}
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i]
  if (!key?.startsWith('--') || !process.argv[i + 1] || options[key.slice(2)] !== undefined) throw new Error(`Invalid or repeated option: ${key}`)
  options[key.slice(2)] = process.argv[i + 1]
}

try {
  for (const key of Object.keys(options)) {
    if (!['app', 'output-dir', 'version', 'tag', 'architecture', 'bundle-id', 'notes'].includes(key)) throw new Error(`Unknown option: --${key}`)
  }
  for (const key of ['app', 'output-dir', 'version', 'architecture']) if (!options[key]) throw new Error(`--${key} is required`)
  if (!/^\d+\.\d+\.\d+$/.test(options.version)) throw new Error('--version must be an exact stable release version')
  if (!['arm64', 'x64'].includes(options.architecture)) throw new Error('--architecture must be arm64 or x64')
  const app = realpathSync(resolve(options.app))
  if (!app.endsWith('.app')) throw new Error('--app must be a signed native app bundle')
  const output = resolve(options['output-dir'])
  if (output.startsWith('/Applications/') || output.startsWith(join(process.env.HOME ?? '', 'Library', 'Application Support') + '/')) {
    throw new Error('--output-dir must be a local build directory')
  }
  const plist = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(app, 'Contents', 'Info.plist')], { encoding: 'utf8' }))
  if (plist.CFBundleShortVersionString !== options.version || !plist.CFBundleIdentifier || !plist.CFBundleExecutable) throw new Error('The app version or identity does not match the feed')
  if (options['bundle-id'] && plist.CFBundleIdentifier !== options['bundle-id']) throw new Error('The app has a different bundle identifier')
  const resources = join(app, 'Contents', 'Resources')
  // The Node-free layout NativeUpdatePackage accepts (NativeWebAssets.validateApp):
  // declared Node-free, both helpers, the web assets, and no Node/Electron payload.
  if (plist.TDNativeOnly !== true) throw new Error('Only the Node-free native app (TDNativeOnly) can get a native update feed')
  for (const legacy of ['runtime', 'engine', 'app.asar', 'app.asar.unpacked']) {
    if (existsSync(join(resources, legacy))) throw new Error(`The native app still carries a Node payload: Contents/Resources/${legacy}`)
  }
  if (existsSync(join(app, 'Contents', 'Frameworks', 'Electron Framework.framework'))) throw new Error('The native app still carries Electron')
  for (const name of [plist.CFBundleExecutable, 'TerminalDeckNativeHelper', 'TerminalDeckJSCorePluginHelper']) {
    if (!statSync(join(app, 'Contents', 'MacOS', name)).isFile()) throw new Error(`Native app program is missing: Contents/MacOS/${name}`)
  }
  for (const path of ['native-updates/install-update.sh', 'web/renderer/index.html', 'web/native-web/shim.js',
    'web/pwa/index.html', 'licenses/SwiftTerm.txt']) {
    if (!statSync(join(resources, path)).isFile()) throw new Error(`Native app resource is missing: ${path}`)
  }
  const lipo = execFileSync('/usr/bin/lipo', ['-archs', join(app, 'Contents', 'MacOS', plist.CFBundleExecutable)], { encoding: 'utf8' })
  const wanted = options.architecture === 'x64' ? 'x86_64' : 'arm64'
  if (!lipo.trim().split(/\s+/).includes(wanted)) throw new Error(`The app is built for ${lipo.trim()}, not ${options.architecture}`)
  const hash = async (path, algorithm, encoding) => {
    const value = createHash(algorithm)
    for await (const bytes of createReadStream(path)) value.update(bytes)
    return value.digest(encoding)
  }
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'pipe' })
  const repositoryURL = new URL(typeof root.repository === 'string' ? root.repository : root.repository.url)
  if (repositoryURL.protocol !== 'https:' || repositoryURL.hostname !== 'github.com') throw new Error('The update repository must be on GitHub')
  const repository = repositoryURL.pathname.replace(/\.git$/, '').replace(/\/$/, '')
  if (!/^\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) throw new Error('Invalid GitHub repository')
  const tag = options.tag ?? `v${options.version}`
  if (!/^[A-Za-z0-9_.-]+$/.test(tag)) throw new Error('--tag must be a single safe GitHub tag')
  const filename = `${root.name}-native-${options.version}-${options.architecture}.zip`
  const archive = join(output, filename)
  const feedPath = join(output, 'latest-native-mac.yml')
  if (existsSync(archive) || existsSync(feedPath)) throw new Error('The native archive/feed already exists; choose a fresh local output directory')
  mkdirSync(output, { recursive: true })
  execFileSync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive], { stdio: 'pipe' })
  const feed = {
    schemaVersion: 1,
    channel: 'native-mac',
    version: options.version,
    bundleIdentifier: plist.CFBundleIdentifier,
    architecture: options.architecture,
    url: `https://github.com${repository}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(filename)}`,
    sha512: await hash(archive, 'sha512', 'base64'),
    size: statSync(archive).size,
    releaseDate: new Date().toISOString(),
    releaseNotes: options.notes ? readFileSync(options.notes, 'utf8') : null,
  }
  if (feed.size > 2_147_483_648) throw new Error('Native update archives are limited to 2 GiB')
  writeFileSync(feedPath, Object.entries(feed).map(([key, value]) => `${key}: ${JSON.stringify(value)}`).join('\n') + '\n', { flag: 'wx' })
  process.stdout.write(`${JSON.stringify({ archive, feed: feedPath, version: feed.version, size: feed.size }, null, 2)}\n`)
} catch (error) {
  process.stderr.write(`[native-feed] ${error.message}\n`)
  process.exitCode = 1
}
