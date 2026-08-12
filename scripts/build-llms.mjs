#!/usr/bin/env node
/**
 * Generates website/llms-full.txt from the pages themselves.
 *
 * The file already claimed to be "generated from the pages themselves". It was
 * not — it was hand-maintained, and it drifted: after the app dropped its Intel
 * build, llms-full.txt still told every model that read it that an untested x64
 * artifact shipped. A 2,000-line flattened copy of a ten-page site cannot be
 * kept honest by hand, and this file is aimed squarely at machines that will
 * repeat whatever it says.
 *
 *   node scripts/build-llms.mjs           write the file
 *   node scripts/build-llms.mjs check     fail if the committed file is stale
 *
 * `check` runs in CI, so the site and its machine-readable copy cannot diverge
 * again without something going red.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SITE = join(ROOT, 'website')
const OUT = join(SITE, 'llms-full.txt')
const WIDTH = 76

/** Page order is reading order, not file order: what it is, then how to get it. */
const PAGES = [
  ['index.html', 'Home', 'https://terminaldeck.dev/'],
  ['features.html', 'Features', 'https://terminaldeck.dev/features'],
  ['docs/index.html', 'Docs', 'https://terminaldeck.dev/docs/'],
  ['download.html', 'Download', 'https://terminaldeck.dev/download'],
  ['changelog.html', 'Changelog', 'https://terminaldeck.dev/changelog'],
  ['roadmap.html', 'Roadmap', 'https://terminaldeck.dev/roadmap'],
  ['about.html', 'About', 'https://terminaldeck.dev/about'],
  ['privacy.html', 'Privacy', 'https://terminaldeck.dev/privacy'],
  ['terms.html', 'Terms', 'https://terminaldeck.dev/terms'],
  ['security.html', 'Security', 'https://terminaldeck.dev/security'],
]

const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', hellip: '…',
  mdash: '—', ndash: '–', laquo: '«', raquo: '»', times: '×', middot: '·',
  lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”',
  ge: '≥', le: '≤', deg: '°', copy: '©', check: '✓',
}

const decode = (s) =>
  s
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&([a-z]+);/gi, (m, name) => ENTITIES[name] ?? ENTITIES[name.toLowerCase()] ?? m)

/** Wrap to WIDTH, but never break a line that is already a code line. */
function wrap(text, indent = '') {
  const words = text.split(/\s+/).filter(Boolean)
  const lines = []
  let line = indent
  for (const w of words) {
    if (line.trim() && line.length + 1 + w.length > WIDTH) {
      lines.push(line)
      line = indent + w
    } else {
      line = line.trim() ? `${line} ${w}` : indent + w
    }
  }
  if (line.trim()) lines.push(line)
  return lines.join('\n')
}

/**
 * Reduces one page's <main> to markdown.
 *
 * Deliberately not a general HTML-to-markdown converter: it handles the tags
 * this site actually uses and would rather drop an unknown wrapper than invent
 * structure. Nav, header and footer are excluded — repeating the same menu ten
 * times is noise to a reader that already has every page.
 */
function pageToMarkdown(html) {
  const main = /<main[^>]*>([\s\S]*?)<\/main>/i.exec(html)
  let body = main ? main[1] : html
  body = body
    .replace(/<(script|style|template)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<nav\b[^>]*>[\s\S]*?<\/nav>/gi, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/gi, '')

  const out = []
  // One pass over the block-level tags, in document order.
  const blocks = /<(h1|h2|h3|h4|p|li|dt|dd|pre|blockquote)\b[^>]*>([\s\S]*?)<\/\1>/gi
  let m
  while ((m = blocks.exec(body)) !== null) {
    const tag = m[1].toLowerCase()
    const raw = m[2]

    if (tag === 'pre') {
      const code = decode(raw.replace(/<[^>]+>/g, ''))
        .replace(/^\n+|\n+$/g, '')
      if (code.trim()) out.push(['```', code, '```'].join('\n'))
      continue
    }

    // Inline code survives as backticks; everything else becomes plain text.
    const text = decode(
      raw
        .replace(/<code[^>]*>([\s\S]*?)<\/code>/gi, (_, c) => `\`${c.replace(/<[^>]+>/g, '')}\``)
        .replace(/<strong[^>]*>([\s\S]*?)<\/strong>/gi, '**$1**')
        .replace(/<br\s*\/?>/gi, ' ')
        .replace(/<[^>]+>/g, ''),
    )
      .replace(/\s+/g, ' ')
      .trim()
    if (!text) continue

    if (tag === 'h1') out.push(`## ${text}`)
    else if (tag === 'h2') out.push(`### ${text}`)
    else if (tag === 'h3') out.push(`#### ${text}`)
    else if (tag === 'h4') out.push(`##### ${text}`)
    else if (tag === 'li') out.push(wrap(`- ${text}`).replace(/\n(?!- )/g, '\n  '))
    else if (tag === 'dt') out.push(`**${text}**`)
    else if (tag === 'blockquote') out.push(wrap(`> ${text}`))
    else out.push(wrap(text))
  }
  return out.join('\n\n')
}

function build() {
  // The summary is the one paragraph that must match llms.txt exactly: both
  // are read as the project's own description, and two versions of it is how a
  // model ends up quoting the older one.
  const llms = readFileSync(join(SITE, 'llms.txt'), 'utf8')
  const summary = /^>\s*([\s\S]*?)(?:\n\n|\n#)/m.exec(llms)?.[1].replace(/\s+/g, ' ').trim() ?? ''

  const parts = [
    '# Terminal Deck',
    '',
    `> ${summary}`,
    '',
    wrap(
      'This file is every page of https://terminaldeck.dev as one markdown ' +
        'document, generated from the pages themselves by scripts/build-llms.mjs. ' +
        'Built by Asad Iqbal. MIT licensed. Repository: https://github.com/asadev/terminaldeck',
    ),
  ]

  for (const [file, title, url] of PAGES) {
    const html = readFileSync(join(SITE, file), 'utf8')
    parts.push('', '---', '', `# ${title}`, '', `Source: ${url}`, '', pageToMarkdown(html))
  }
  return `${parts.join('\n').replace(/\n{3,}/g, '\n\n')}\n`
}

const generated = build()

if (process.argv[2] === 'check') {
  const onDisk = readFileSync(OUT, 'utf8')
  if (onDisk !== generated) {
    console.error(
      '\n  website/llms-full.txt is out of date with the pages it claims to be generated from.\n' +
        '  Run: node scripts/build-llms.mjs\n',
    )
    process.exit(1)
  }
  console.log('llms-full.txt matches the site.')
} else {
  writeFileSync(OUT, generated)
  console.log(`wrote ${OUT} — ${generated.split('\n').length} lines from ${PAGES.length} pages`)
}
