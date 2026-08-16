import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  FileViewer,
  formatBytes,
  HIGHLIGHT_MAX_CHARS,
  languageOf,
  renderTokens,
  tokenize,
  type Language,
} from './FileViewer'

/**
 * There is no DOM environment in this project's test setup, so the component
 * renders to static markup. The scanner is pure and gets the weight of the
 * coverage, because it is the part that can quietly corrupt what is on screen.
 */

const LANGUAGES: readonly Language[] = ['js', 'json', 'css', 'shell', 'yaml', 'markdown']

/* -------------------------------------------------------- the invariant -- */

describe('tokenize never changes the text', () => {
  /**
   * The one property that matters. Everything else here is about colour; this
   * is about whether the pane is still showing the file. A scanner that drops
   * a character, doubles one, or reorders two turns a reading surface into a
   * lie, and the failure is invisible unless it is asserted.
   */
  const SAMPLES: Record<Language, string> = {
    js: [
      "import { readFile } from 'node:fs'",
      '/* a block comment',
      '   over two lines */',
      'const answer = 42 // trailing',
      'const tpl = `multi',
      'line ${value} template`',
      "const apostrophe = 'it\\'s escaped'",
      'export default function main(): void {}',
      '',
    ].join('\n'),
    json: '{\n  "name": "terminaldeck",\n  "private": true,\n  "count": 3\n}\n',
    css: '/* head */\n@media (max-width: 760px) {\n  .a { color: #fff; padding: 0 12px; }\n}\n',
    shell: [
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      '# a comment',
      'name="deck"        # trailing comment',
      "raw='no \\escapes here'",
      'if [ -n "$name" ]; then echo "hi"; fi',
      '',
    ].join('\n'),
    yaml: [
      '# a comment',
      'name: release',
      'on:',
      '  push:',
      '    tags: ["v*"]',
      'jobs:',
      '  - name: build',
      '    run: npm test # trailing',
      '',
    ].join('\n'),
    markdown: [
      '# Title',
      '',
      'Some prose with `inline code` and a * star.',
      '',
      '```ts',
      'const x = 1',
      '```',
      '',
      '> a quote',
      '',
    ].join('\n'),
  }

  for (const language of LANGUAGES) {
    it(language, () => {
      const source = SAMPLES[language]
      expect(tokenize(source, language).reduce((all, token) => all + token.text, '')).toBe(source)
    })
  }

  it('survives text that is nothing like the language it is read as', () => {
    // A `.ts` file mid-save, a broken heredoc, a file of emoji — none of these
    // may lose a byte.
    const nasty = 'const a = "unterminated\n/* unclosed\néèê \u{1F600} `\n'
    for (const language of LANGUAGES) {
      expect(tokenize(nasty, language).reduce((all, token) => all + token.text, '')).toBe(nasty)
    }
  })

  it('emits no empty tokens', () => {
    for (const language of LANGUAGES) {
      for (const token of tokenize(SAMPLES[language], language)) {
        expect(token.text.length).toBeGreaterThan(0)
      }
    }
  })
})

/* ------------------------------------------------------------- languages -- */

describe('languageOf', () => {
  it('knows the languages this repository is made of', () => {
    expect(languageOf('src/main/index.ts')).toBe('js')
    expect(languageOf('a/b.tsx')).toBe('js')
    expect(languageOf('package.json')).toBe('json')
    expect(languageOf('styles/tokens.css')).toBe('css')
    expect(languageOf('scripts/build.sh')).toBe('shell')
    expect(languageOf('.github/workflows/release.yml')).toBe('yaml')
    expect(languageOf('README.md')).toBe('markdown')
  })

  it('leaves an unknown extension uncoloured rather than guessing', () => {
    // A Python file painted with JavaScript's reserved words is worse than a
    // Python file painted black.
    expect(languageOf('script.py')).toBeNull()
    expect(languageOf('main.rs')).toBeNull()
    expect(languageOf('LICENSE')).toBeNull()
    expect(languageOf('.gitignore')).toBeNull()
  })
})

/* ---------------------------------------------------------------- colour -- */

function kindsOf(source: string, language: Language): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const token of tokenize(source, language)) {
    ;(out[token.kind] ??= []).push(token.text)
  }
  return out
}

describe('what gets coloured', () => {
  it('finds comments, strings, numbers and reserved words in TypeScript', () => {
    const kinds = kindsOf("const a = 42 // note\nimport x from 'y'", 'js')
    expect(kinds.keyword).toContain('const')
    expect(kinds.keyword).toContain('import')
    expect(kinds.number).toContain('42')
    expect(kinds.string).toContain("'y'")
    expect(kinds.comment).toContain('// note')
  })

  it('does not read a hash inside a value as a shell comment', () => {
    // `#fff` used to swallow the rest of the line.
    expect(kindsOf('colour=#fff\n', 'shell').comment).toBeUndefined()
    expect(kindsOf('echo hi # real comment\n', 'shell').comment).toEqual(['# real comment'])
  })

  it('does not let one apostrophe swallow the rest of the file', () => {
    const kinds = kindsOf("// don't\nconst after = 1\n", 'js')
    expect(kinds.string).toBeUndefined()
    expect(kinds.keyword).toContain('const')
  })

  it('reads a YAML key, including one under a sequence dash', () => {
    // The key, not the colon — the punctuation belongs to the line.
    const kinds = kindsOf('name: release\n- run: npm test\n', 'yaml')
    expect(kinds.meta).toEqual(['name', 'run'])
  })

  it('reads a Markdown heading and the inside of a fence', () => {
    const kinds = kindsOf('# Title\n\n```\ncode\n```\ntext\n', 'markdown')
    expect(kinds.meta).toEqual(['# Title\n'])
    expect(kinds.string).toEqual(['code\n'])
    // The line after the closing fence is prose again.
    expect(kinds.plain).toContain('text\n')
  })

  it('reads a CSS at-rule', () => {
    expect(kindsOf('@media screen { .a { top: 0 } }', 'css').keyword).toEqual(['@media'])
  })

  it('keeps ordinary identifiers inside one plain run', () => {
    // One element per token would be tens of thousands of them on a real file.
    const tokens = tokenize('foo bar baz qux quux\n', 'js')
    expect(tokens).toHaveLength(1)
    expect(tokens[0].kind).toBe('plain')
  })
})

describe('renderTokens', () => {
  it('renders plain runs as text and everything else as one span', () => {
    const html = renderToStaticMarkup(<code>{renderTokens(tokenize('const a = 1', 'js'))}</code>)
    expect(html).toContain('<span class="tok-keyword">const</span>')
    expect(html).toContain('<span class="tok-number">1</span>')
    expect(html).not.toContain('tok-plain')
  })
})

/* ---------------------------------------------------------------- viewer -- */

describe('FileViewer', () => {
  it('does not flash an empty state before the tree has opened anything', () => {
    // The Files page opens a file by itself now; the root listing takes a few
    // milliseconds, and "No file open" appearing and vanishing reads as a bug.
    const html = renderToStaticMarkup(<FileViewer root="/p" path={null} />)
    expect(html).not.toContain('Nothing to open')
    expect(html).not.toMatch(/pick something/i)
  })

  it('names the file it is showing for a screen reader', () => {
    const html = renderToStaticMarkup(<FileViewer root="/p" path="src/main/index.ts" />)
    expect(html).toContain('Contents of index.ts')
    expect(html).toContain('index.ts')
    expect(html).toContain('TS')
  })
})

describe('formatBytes', () => {
  it('reads as a person reads a file size', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2048)).toBe('2.0 KB')
    expect(formatBytes(5 * 1024 * 1024)).toBe('5.0 MB')
  })
})

describe('HIGHLIGHT_MAX_CHARS', () => {
  it('is a DOM budget, not a scanner one — big enough for real source files', () => {
    // This repository's largest source file is well under it; a minified
    // bundle is well over, and gets shown plain rather than slowly.
    expect(HIGHLIGHT_MAX_CHARS).toBeGreaterThan(150_000)
  })
})
