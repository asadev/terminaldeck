#!/usr/bin/env node
// make-windows-update.mjs: writes windows-update.json + windows-update.json.sig for one Windows-only release.
// The installed Windows app reads them from the fixed "windows-stable" release (WindowsReleaseFeed.cs) and accepts
// them only when the Windows-only Ed25519 key signed them; every byte of the MSIX is then checked against them.
//
//   node windows/scripts/windows/make-windows-update.mjs --msix <TerminalDeck-<v>-x64.msix> --version <a.b.c.d>
//     --tag windows-v<a.b.c.d> --commit <40-hex> --out <new folder> [--notes <file>] [--repo asadev/terminaldeck]
//   The private key comes from the WINDOWS_UPDATE_ED25519_KEY environment variable (PEM text; in the workflow it is
//   the repository secret of that name) or --key <pem file>. It never comes from the repository.
//   --test-key yes: allow a key whose public half is not compiled into the app (tests only).
//
// Writes only into --out (which must not exist yet). Never uploads anything.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto'
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const args = {}
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i]
  if (!key?.startsWith('--') || process.argv[i + 1] === undefined || args[key.slice(2)] !== undefined) fail(`invalid or repeated option ${key}`)
  args[key.slice(2)] = process.argv[i + 1]
}
function fail(message) { process.stderr.write(`[windows-update] ${message}\n`); process.exit(1) }
const known = ['msix', 'version', 'tag', 'commit', 'out', 'notes', 'repo', 'key', 'date', 'test-key']
for (const key of Object.keys(args)) if (!known.includes(key)) fail(`unknown option --${key}`)
for (const key of ['msix', 'version', 'tag', 'commit', 'out']) if (!args[key]) fail(`--${key} is required`)
const repo = args.repo ?? 'asadev/terminaldeck'
const { version, tag } = args
if (!/^\d+\.\d+\.\d+\.\d+$/.test(version)) fail('--version must be a.b.c.d (the MSIX package version)')
if (tag !== `windows-v${version}`) fail(`--tag must be windows-v${version}`)
if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) fail('bad --repo')
if (!/^[0-9a-f]{40}$/.test(args.commit)) fail('--commit must be the full commit sha')
const out = resolve(args.out)
if (existsSync(out)) fail(`--out ${out} already exists; use a fresh folder`)

const msixPath = resolve(args.msix), msixFile = basename(msixPath)
if (msixFile !== `TerminalDeck-${version}-x64.msix`) fail(`--msix must be named TerminalDeck-${version}-x64.msix`)
const sha256 = await new Promise((done, failed) => {
  const hash = createHash('sha256')
  createReadStream(msixPath).on('data', (b) => hash.update(b)).on('error', failed).on('end', () => done(hash.digest('hex')))
})
const asset = (file) => `https://github.com/${repo}/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(file)}`

// Same shape as release-manifest.json's Windows part (GitHubReleaseChannel.Parse reads both), plus "platform".
const feed = {
  schema: 1,
  product: 'terminaldeck',
  platform: 'windows',
  version,
  tag,
  commit: args.commit,
  releaseDate: args.date ?? new Date().toISOString(),
  notesUrl: `https://github.com/${repo}/releases/tag/${encodeURIComponent(tag)}`,
  notes: args.notes ? readFileSync(args.notes, 'utf8').trim().slice(0, 4000) || null : null,
  windows: {
    file: msixFile,
    url: asset(msixFile),
    size: statSync(msixPath).size,
    sha256,
    packageName: 'TerminalDeck',
    publisher: 'CN=Terminal Deck Stable',
    version,
    architecture: 'x64',
  },
}

const pem = args.key ? readFileSync(args.key, 'utf8') : process.env.WINDOWS_UPDATE_ED25519_KEY
if (!pem || !pem.includes('PRIVATE KEY')) fail('no Windows update key: set WINDOWS_UPDATE_ED25519_KEY (repository secret) or pass --key')
const privateKey = createPrivateKey(pem)
if (privateKey.asymmetricKeyType !== 'ed25519') fail('the Windows update key must be Ed25519')
const own = Buffer.from(createPublicKey(privateKey).export({ format: 'jwk' }).x, 'base64url').toString('base64')
// The app's compiled-in keys, read from the source this run builds: a key the app does not carry is refused here,
// before anything is published, instead of on every PC after.
const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, '..', '..', 'src', 'TerminalDeck.Core', 'Platform', 'WindowsReleaseFeed.cs'), 'utf8')
if (!source.includes(`"${own}"`) && args['test-key'] !== 'yes') fail(`this key's public half ${own} is not in WindowsReleaseFeed.PublicKeys`)

const bytes = Buffer.from(JSON.stringify(feed, null, 2) + '\n', 'utf8')
const signature = sign(null, bytes, privateKey)
if (!verify(null, bytes, createPublicKey(privateKey), signature)) fail('the signature does not verify')
mkdirSync(out, { recursive: true })
writeFileSync(join(out, 'windows-update.json'), bytes, { flag: 'wx' })
writeFileSync(join(out, 'windows-update.json.sig'), signature.toString('base64') + '\n', { flag: 'wx' })
process.stdout.write(JSON.stringify({ out, version, tag, sha256, size: feed.windows.size, key: own }, null, 2) + '\n')
