#!/usr/bin/env node
/**
 * Preflight for a macOS release. Run it after `npm run dist:mac` and before
 * uploading anything:
 *
 *   npm run release:check
 *
 * It exists because of one specific, silent, entirely reproducible failure:
 * electron-builder rewrites `latest-mac.yml` on every invocation with only the
 * architectures that invocation built. Build arm64 and x64 in two separate
 * commands and the manifest ends up describing whichever ran last. Nothing
 * warns you. The DMGs on the release page look complete, and every user on the
 * other architecture is offered the wrong update — or none.
 *
 * So: this checks that the artifacts are all present, that the manifest names
 * every one of them, and that the sizes and hashes in the manifest match the
 * files actually on disk.
 */

import { createHash } from 'node:crypto'
import { readFileSync, existsSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const RELEASE = resolve(process.argv[2] ?? join(ROOT, 'release'))
const { version, name } = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))

const ARCHES = ['arm64']
const problems = []
const note = (s) => process.stdout.write(`  ${s}\n`)

/** Minimal YAML reader — latest-mac.yml is a fixed, flat shape, not free-form. */
function parseManifest(text) {
  const files = []
  let current = null
  for (const line of text.split('\n')) {
    const item = line.match(/^ {2}- url: (.+)$/)
    if (item) {
      current = { url: item[1].trim() }
      files.push(current)
      continue
    }
    const field = line.match(/^ {4}(sha512|size): (.+)$/)
    if (field && current) current[field[1]] = field[2].trim()
  }
  return files
}

const sha512 = (p) => createHash('sha512').update(readFileSync(p)).digest('base64')

if (!existsSync(RELEASE)) {
  console.error(`No ${RELEASE}. Run \`npm run dist:mac\` first.`)
  process.exit(1)
}

process.stdout.write(`Checking ${RELEASE} for ${name} ${version}\n\n`)

const expected = []
for (const arch of ARCHES) {
  for (const ext of ['dmg', 'zip']) {
    expected.push(`${name}-${version}-${arch}.${ext}`)
    expected.push(`${name}-${version}-${arch}.${ext}.blockmap`)
  }
}

for (const f of expected) {
  if (existsSync(join(RELEASE, f))) note(`ok    ${f}`)
  else problems.push(`missing artifact: ${f}`)
}

const manifestPath = join(RELEASE, 'latest-mac.yml')
if (!existsSync(manifestPath)) {
  problems.push('missing latest-mac.yml — electron-updater has nothing to read')
} else {
  const listed = parseManifest(readFileSync(manifestPath, 'utf8'))
  note(`ok    latest-mac.yml lists ${listed.length} file(s)`)

  for (const arch of ARCHES) {
    if (!listed.some((f) => f.url.includes(`-${arch}.zip`))) {
      problems.push(
        `latest-mac.yml does not list the ${arch} zip. ` +
          'This is what building one architecture at a time does — ' +
          'rebuild both in a single `npm run dist:mac`.',
      )
    }
  }

  for (const f of listed) {
    const p = join(RELEASE, f.url)
    if (!existsSync(p)) {
      problems.push(`latest-mac.yml points at ${f.url}, which is not in ${RELEASE}`)
      continue
    }
    const size = statSync(p).size
    if (f.size && Number(f.size) !== size) {
      problems.push(`${f.url}: manifest says ${f.size} bytes, file is ${size}`)
    } else if (f.sha512 && sha512(p) !== f.sha512) {
      problems.push(`${f.url}: sha512 in the manifest does not match the file`)
    } else {
      note(`ok    ${f.url} matches its manifest entry`)
    }
  }
}

if (problems.length) {
  process.stdout.write('\n')
  for (const p of problems) process.stderr.write(`FAIL  ${p}\n`)
  process.stderr.write(`\n${problems.length} problem(s). Do not upload this.\n`)
  process.exit(1)
}

process.stdout.write('\nRelease looks complete and self-consistent.\n')
