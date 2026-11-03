#!/usr/bin/env node
/**
 * Keeps package.json, CHANGELOG.md and the git tag in step.
 *
 * Not run directly — `npm version <patch|minor|major>` drives it through three
 * hooks declared in package.json:
 *
 *   preversion   npm run typecheck && npm test && node scripts/version.mjs check
 *   version      node scripts/version.mjs stamp && git add CHANGELOG.md
 *   postversion  node scripts/version.mjs next
 *
 * npm's ordering is what makes this work. By the time the `version` hook runs,
 * package.json and package-lock.json already carry the new number but the
 * commit has not been made, so a file staged here lands in the same commit npm
 * is about to tag. That is the whole trick: one commit holds the bump and the
 * changelog entry, and the tag points at it. Stamping the changelog in a
 * separate commit is how the two drift.
 *
 * Everything that can be checked is checked in `preversion`, before npm writes
 * anything, because npm does not roll back a failed `version` hook: it leaves
 * package.json and package-lock.json bumped, uncommitted and untagged, and the
 * retry then dies on "Git working directory not clean". Measured, not assumed.
 * `check` is what keeps the empty-changelog case on the harmless side of that
 * line.
 *
 * Nothing here pushes. The tag exists locally until a human runs the push,
 * which is the act that triggers the release workflow.
 */

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CHANGELOG = join(ROOT, 'CHANGELOG.md')

/** The version npm has already written, not one this script decides. */
function currentVersion() {
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
  if (typeof pkg.version !== 'string') throw new Error('package.json has no version')
  return pkg.version
}

/** `owner/repo` from the repository field, so the URLs below have one source. */
function repoSlug() {
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
  const url = pkg.repository?.url ?? ''
  const match = /github\.com[/:]([^/]+\/[^/.]+)/.exec(url)
  if (!match) throw new Error(`cannot read a github slug out of repository.url: ${url}`)
  return match[1]
}

/** Local date. A UTC date stamps tomorrow onto an evening release in Dubai. */
function today() {
  const now = new Date()
  const pad = (n) => String(n).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/**
 * Move everything under `## [Unreleased]` into a section for `version`.
 *
 * Returns the rewritten file. Throws when Unreleased is empty: a release whose
 * changelog says nothing is worse than no release, because the emptiness is
 * only discovered by the person reading it looking for what changed.
 */
export function stampChangelog(source, version, date, slug) {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => /^##\s+\[Unreleased\]/i.test(line))
  if (start === -1) throw new Error('CHANGELOG.md has no "## [Unreleased]" heading')

  let end = lines.findIndex((line, i) => i > start && /^##\s+\[/.test(line))
  if (end === -1) end = lines.findIndex((line, i) => i > start && /^\[[^\]]+\]:\s/.test(line))
  if (end === -1) end = lines.length

  const body = lines.slice(start + 1, end)
  const substantive = body.filter((line) => line.trim() !== '' && !line.trim().startsWith('<!--'))
  if (substantive.length === 0 && process.env.ALLOW_EMPTY_CHANGELOG !== '1') {
    // No version in this message on purpose: the same check runs in preversion,
    // before npm has decided what the next number is.
    throw new Error(
      'nothing is listed under [Unreleased], so this release would ship an empty entry.\n' +
        '  Write what changed in CHANGELOG.md, or set ALLOW_EMPTY_CHANGELOG=1 if this\n' +
        '  really is a no-op release.',
    )
  }

  // Trailing blank lines belong to the gap between sections, not to the entry.
  while (body.length > 0 && body[body.length - 1].trim() === '') body.pop()

  const stamped = ['', `## [${version}] — ${date}`, ...body, '']
  const rewritten = [...lines.slice(0, start + 1), ...stamped, ...lines.slice(end)]

  return withLinks(rewritten.join('\n'), version, slug)
}

/**
 * Repoint `[Unreleased]` at the new tag and add a link for the new version.
 *
 * The compare link is rewritten rather than appended to, so the diff a reader
 * follows from Unreleased always starts at the newest release.
 */
function withLinks(source, version, slug) {
  const base = `https://github.com/${slug}`
  const unreleased = `[Unreleased]: ${base}/compare/v${version}...HEAD`
  const entry = `[${version}]: ${base}/releases/tag/v${version}`

  const lines = source.split('\n')
  const at = lines.findIndex((line) => /^\[Unreleased\]:\s/i.test(line))
  if (at === -1) return `${source.replace(/\n+$/, '')}\n\n${unreleased}\n${entry}\n`

  lines.splice(at, 1, unreleased, entry)
  return lines.join('\n')
}

/**
 * Everything `stamp` needs, asserted before npm has written anything.
 *
 * Runs in `preversion`, so a failure here costs nothing: package.json is
 * untouched, the tree is clean, and the fix is to write the changelog entry
 * and run the same command again.
 */
function check() {
  const source = readFileSync(CHANGELOG, 'utf8')
  const slug = repoSlug()
  // Any version will do — this is a rehearsal, and the number it would be
  // stamped with is not known until npm bumps it a moment from now.
  stampChangelog(source, '0.0.0-preflight', today(), slug)
  console.log('CHANGELOG.md: [Unreleased] has content and can be stamped')
}

function stamp() {
  const version = currentVersion()
  const source = readFileSync(CHANGELOG, 'utf8')
  if (source.includes(`## [${version}]`)) {
    throw new Error(`CHANGELOG.md already has a section for ${version}`)
  }
  writeFileSync(CHANGELOG, stampChangelog(source, version, today(), repoSlug()), 'utf8')
  console.log(`CHANGELOG.md: [Unreleased] → [${version}] — ${today()}`)
}

/** What the human does next. Deliberately not done for them. */
function next() {
  const version = currentVersion()
  const branch = execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { encoding: 'utf8' }).trim()
  console.log(
    [
      '',
      `  v${version} is committed and tagged locally. Nothing has been pushed.`,
      '',
      '  Read it back:',
      '    git show --stat HEAD',
      '',
      '  Then publish — pushing the tag is what starts the release build:',
      `    git push origin ${branch} --follow-tags`,
      '',
      '  Undo instead:',
      `    git tag -d v${version} && git reset --hard HEAD~1`,
      '',
    ].join('\n'),
  )
}

const MODES = { check, stamp, next }
const mode = process.argv[2]
if (!Object.hasOwn(MODES, mode)) {
  console.error(`usage: node scripts/version.mjs <${Object.keys(MODES).join('|')}>`)
  process.exit(2)
}

try {
  MODES[mode]()
} catch (error) {
  console.error(`\n  ${error instanceof Error ? error.message : String(error)}\n`)
  if (mode === 'stamp') {
    // npm has already written the new version by this point and will not put it
    // back. Left alone, the next attempt dies on "Git working directory not
    // clean" without ever saying why, so the way out is printed here.
    console.error('  npm has already bumped package.json. Undo that before retrying:\n')
    console.error('    git checkout -- package.json package-lock.json\n')
  }
  process.exit(1)
}
