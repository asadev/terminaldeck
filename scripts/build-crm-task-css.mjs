#!/usr/bin/env node
/**
 * Builds `src/renderer/crm-task/crm-task.css` — the stylesheet of the task
 * popup copied from the reference CRM — from the CRM's own styling, with only
 * the colours changed to Terminal Deck's.
 *
 *   node scripts/build-crm-task-css.mjs <node_modules> <design-system.css> <theme.css>
 *
 *   <node_modules>       a folder holding the CRM's `tailwindcss`,
 *                        `@tailwindcss/postcss` and `postcss`
 *   <design-system.css>  the CRM's design-system stylesheet
 *   <theme.css>          the CRM's global stylesheet (its `@theme inline` block
 *                        and its few global rules)
 *
 * What it does, in order:
 *
 * 1. Tailwind, the CRM's own version, over the popup's sources only: the
 *    utilities the copied markup uses, and the CRM's theme block. No preflight
 *    — the app keeps its own base styles.
 * 2. The CRM's design-system and global rules, kept only where every class a
 *    selector names appears in the popup's sources. Its dark-mode rules and its
 *    colour variables are dropped: colours come from step 4 instead.
 * 3. Every selector is scoped under `.crm-task-root` (the popup's portal root),
 *    so nothing reaches the rest of the app, and `@layer` wrappers are removed
 *    so the app's own unlayered base rules cannot outrank the popup's. The
 *    CRM's order is kept: components, then utilities, then its unlayered rules.
 * 4. Colours only: every colour the CRM names — its design-system variables,
 *    Tailwind's palette and any literal colour — becomes one of Terminal Deck's
 *    tokens (`tokens.css`), tinted toward the page or the text by its lightness,
 *    so light and dark both follow the app's theme. Sizes, spacing, radii and
 *    type sizes stay the CRM's; the face is the app's UI font.
 */

import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const [nodeModules, designSystemFile, themeFile] = process.argv.slice(2)
if (!nodeModules || !designSystemFile || !themeFile) {
  console.error('usage: node scripts/build-crm-task-css.mjs <node_modules> <design-system.css> <theme.css>')
  process.exit(2)
}

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const POPUP = join(ROOT, 'src', 'renderer', 'crm-task')
const SHARED = join(ROOT, 'src', 'shared', 'crm')
const OUT = join(POPUP, 'crm-task.css')
const SCOPE = '.crm-task-root'

const require = createRequire(join(resolve(nodeModules), 'noop.js'))
const postcss = require('postcss')
const tailwind = require('@tailwindcss/postcss')

/* ---------------------------------------------------------------- sources -- */


function sourceFiles(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...sourceFiles(path))
    else if (/\.(ts|tsx)$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name)) out.push(path)
  }
  return out
}

/** Every word the popup's sources could put in a class attribute. */
function candidates() {
  const words = new Set(['crm-task-root'])
  for (const file of [...sourceFiles(POPUP), ...sourceFiles(SHARED)]) {
    for (const match of readFileSync(file, 'utf8').matchAll(/["'`]([^"'`\n]{1,600})["'`]/g)) {
      for (const word of match[1].split(/[\s{}()$]+/)) if (/^-?[a-z][a-z0-9:_./[\]%#&=-]*$/i.test(word)) words.add(word)
    }
  }
  return words
}

/* ---------------------------------------------------------------- colours -- */

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x))

function srgbToOklch(r, g, b) {
  const lin = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
  const [lr, lg, lb] = [lin(r), lin(g), lin(b)]
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
  const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
  const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
  return { L, C: Math.hypot(A, B), H: ((Math.atan2(B, A) * 180) / Math.PI + 360) % 360 }
}

function num(part, scale = 1) {
  const p = part.trim()
  return p.endsWith('%') ? (Number(p.slice(0, -1)) / 100) * scale : Number(p)
}

/** A colour literal as OKLCH plus alpha, or null when it is not one this reads. */
function parseColour(text) {
  const t = text.trim().toLowerCase()
  if (t === 'white') return { L: 1, C: 0, H: 0, a: 1 }
  if (t === 'black') return { L: 0, C: 0, H: 0, a: 1 }
  let m = /^#([0-9a-f]{3,8})$/.exec(t)
  if (m) {
    let hex = m[1]
    if (hex.length === 3 || hex.length === 4) hex = [...hex].map((c) => c + c).join('')
    const n = (i) => parseInt(hex.slice(i, i + 2), 16) / 255
    return { ...srgbToOklch(n(0), n(2), n(4)), a: hex.length === 8 ? n(6) : 1 }
  }
  m = /^rgba?\(([^)]*)\)$/.exec(t)
  if (m) {
    const parts = m[1].split(/[\s,/]+/).filter(Boolean)
    const [r, g, b] = parts.slice(0, 3).map((p) => num(p, 255) / 255)
    return { ...srgbToOklch(r, g, b), a: parts[3] === undefined ? 1 : num(parts[3]) }
  }
  m = /^oklch\(([^)]*)\)$/.exec(t)
  if (m) {
    const parts = m[1].split(/[\s/]+/).filter(Boolean)
    return { L: num(parts[0]), C: num(parts[1], 0.4), H: Number(parts[2]) || 0, a: parts[3] === undefined ? 1 : num(parts[3]) }
  }
  return null
}

/** Which of the app's tokens a hue belongs to. */
function family(H) {
  if (H < 40 || H >= 345) return 'var(--color-critical)'
  if (H < 100) return 'var(--color-warning)'
  if (H < 170) return 'var(--color-positive)'
  if (H < 215) return 'var(--color-info)'
  if (H < 300) return 'var(--accent)'
  return 'var(--bind-3)'
}

const pct = (x) => `${Math.round(x * 100)}%`

function withAlpha(expr, a) {
  return a >= 0.999 ? expr : `color-mix(in srgb, ${expr} ${pct(a)}, transparent)`
}

/** A grey: the page colour mixed toward the text colour by how dark it is. */
function neutral(c) {
  // Shadows and scrims stay black with their alpha — the app's own convention.
  if (c.a < 0.999 && c.L < 0.3) return `rgb(0 0 0 / ${Math.round(c.a * 1000) / 1000})`
  const ink = clamp((1 - c.L) / 0.8, 0, 1)
  const expr = ink <= 0.01 ? 'var(--bg-primary)' : ink >= 0.98 ? 'var(--text-primary)' : `color-mix(in srgb, var(--text-primary) ${pct(ink)}, var(--bg-primary))`
  return withAlpha(expr, c.a)
}

/** Tailwind's palette by its own family names — a light tint of a hue has too little chroma to tell from a grey. */
const FAMILY_TOKEN = {
  slate: null, gray: null, zinc: null, neutral: null, stone: null,
  red: 'var(--color-critical)', rose: 'var(--color-critical)',
  orange: 'var(--color-warning)', amber: 'var(--color-warning)', yellow: 'var(--color-warning)',
  lime: 'var(--color-positive)', green: 'var(--color-positive)', emerald: 'var(--color-positive)',
  teal: 'var(--color-info)', cyan: 'var(--color-info)',
  sky: 'var(--accent)', blue: 'var(--accent)', indigo: 'var(--accent)', violet: 'var(--accent)',
  purple: 'var(--bind-3)', fuchsia: 'var(--bind-3)', pink: 'var(--bind-3)',
}

/** One of Tailwind's palette variables (`--color-<family>-<step>`) as the app's colour, or null when it is not one. */
function mapPalette(prop, value) {
  const m = /^--color-([a-z]+)-\d+$/.exec(prop)
  if (!m || !(m[1] in FAMILY_TOKEN)) return null
  const c = parseColour(value)
  if (c === null) return null
  const base = FAMILY_TOKEN[m[1]]
  return base === null ? neutral(c) : tinted(c, base)
}

/** A colour of the CRM's as the app's: a token, tinted toward the page (lighter) or the text (darker). */
function mapColour(literal) {
  const c = parseColour(literal)
  if (c === null) return null
  // A grey: little chroma, and for a near-white even less (a tint of a hue keeps some).
  if (c.C < (c.L > 0.9 ? 0.02 : 0.06)) return neutral(c)
  return tinted(c, family(c.H))
}

function tinted(c, base) {
  let expr = base
  if (c.L > 0.64) expr = `color-mix(in srgb, ${base} ${pct(clamp((1 - c.L) / 0.36, 0.04, 1))}, var(--bg-primary))`
  else if (c.L < 0.55) expr = `color-mix(in srgb, ${base} ${pct(1 - clamp(((0.55 - c.L) / 0.35) * 0.7, 0, 0.7))}, var(--text-primary))`
  return withAlpha(expr, c.a)
}

const COLOUR_LITERAL = /#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|oklch\([^)]*\)|(?<![-\w])(?:white|black)(?![-\w])/g

function mapValue(value) {
  if (/url\(/.test(value)) return value
  return value.replace(COLOUR_LITERAL, (literal) => mapColour(literal) ?? literal)
}

/** The CRM's design-system colour variables, pointed at the app's tokens by meaning. */
const SEMANTIC = {
  '--ink': 'var(--text-primary)',
  '--loop': 'var(--accent)',
  '--sky': 'color-mix(in srgb, var(--accent) 50%, var(--bg-primary))',
  '--paper': 'var(--bg-secondary)',
  '--graphite': 'var(--text-primary)',
  '--bg': 'var(--bg-secondary)',
  '--surface': 'var(--bg-primary)',
  '--surface-2': 'var(--bg-secondary)',
  '--surface-3': 'var(--bg-tertiary)',
  '--skel': 'var(--fill-tertiary)',
  '--skel-sheen': 'color-mix(in srgb, var(--bg-primary) 60%, transparent)',
  '--overlay': 'rgb(0 0 0 / 0.4)',
  '--text': 'var(--text-primary)',
  '--text-2': 'var(--text-secondary)',
  '--text-3': 'var(--text-muted)',
  '--text-inverse': 'var(--bg-primary)',
  '--link': 'var(--accent)',
  '--line': 'var(--border)',
  '--line-2': 'var(--border-strong)',
  '--line-focus': 'var(--accent)',
  '--primary': 'var(--accent)',
  '--primary-hover': 'var(--accent-dim)',
  '--primary-active': 'var(--accent-press)',
  '--primary-soft': 'var(--accent-soft)',
  '--primary-soft-2': 'color-mix(in srgb, var(--accent) 22%, var(--bg-primary))',
  '--on-primary': 'var(--accent-fg)',
  '--tint-bg-mix': 'var(--bg-primary)',
  '--tint-fg-mix': 'var(--text-primary)',
  '--e-1': 'var(--shadow-sm)',
  '--e-2': 'var(--shadow-sm)',
  '--e-3': 'var(--shadow-md)',
  '--e-4': 'var(--shadow-lg)',
  '--hue-blue': 'var(--accent)',
  '--hue-sky': 'var(--color-info)',
  '--hue-amber': 'var(--color-warning)',
  '--hue-orange': 'color-mix(in srgb, var(--color-warning) 70%, var(--color-critical))',
  '--hue-violet': 'var(--bind-1)',
  '--hue-indigo': 'color-mix(in srgb, var(--accent) 70%, var(--bind-1))',
  '--hue-teal': 'var(--bind-2)',
  '--hue-slate': 'var(--text-muted)',
  '--hue-emerald': 'var(--color-positive)',
  '--hue-fuchsia': 'var(--bind-3)',
  '--hue-rose': 'var(--color-critical)',
  // The app's own faces: the CRM's web fonts are not bundled.
  '--font-display': 'var(--font-ui)',
  '--font-mono-ds': 'var(--font-mono)',
}
for (const [state, token] of [
  ['ok', 'var(--color-positive)'],
  ['warn', 'var(--color-warning)'],
  ['danger', 'var(--color-critical)'],
  ['info', 'var(--color-info)'],
]) {
  SEMANTIC[`--${state}`] = token
  SEMANTIC[`--${state}-soft`] = `color-mix(in srgb, ${token} 14%, var(--bg-primary))`
  SEMANTIC[`--${state}-text`] = `color-mix(in srgb, ${token} 80%, var(--text-primary))`
}

/** Names the app itself defines, which a scoped copy of the CRM's must not shadow. */
const KEEP_APPS = new Set(['--font-ui', '--font-mono'])

/* ---------------------------------------------------------------- scoping -- */

function scopeSelector(selector) {
  const s = selector.trim()
  if (/^(:root|html|body)$/.test(s) || /^:root:not\(\[data-theme=/.test(s) || s === ':host') return SCOPE
  if (/^(html|body|:root)[\s>]/.test(s)) return `${SCOPE} ${s.replace(/^(html|body|:root)\s*>?\s*/, '')}`
  return `${SCOPE} ${s}`
}

const isDarkOnly = (selector) => /data-theme|\.dark\b|prefers-color-scheme/.test(selector)

/** Every class a selector names, unescaped. */
function classesOf(selector) {
  return [...selector.matchAll(/\.((?:\\.|[A-Za-z0-9_-])+)/g)].map((m) => m[1].replace(/\\(.)/g, '$1'))
}

/* ---------------------------------------------------------------- build -- */

const themeCss = readFileSync(themeFile, 'utf8')
const themeBlock = /@theme inline\s*\{[\s\S]*?\n\}/.exec(themeCss)?.[0] ?? ''
const words = candidates()

const tailwindInput = `@layer theme, base, components, utilities;
@import "tailwindcss/theme.css" layer(theme);
@import "tailwindcss/utilities.css" layer(utilities) source(none);
@source "${POPUP}";
@source "${SHARED}";
${themeBlock}
`

const tw = await postcss([tailwind({ base: POPUP })]).process(tailwindInput, { from: join(resolve(nodeModules), '..', 'crm-task-input.css') })

/** The CRM's own rules: design system first, then the global sheet without its imports, theme and sources. */
const ownCss = `${readFileSync(designSystemFile, 'utf8')}\n${themeCss
  .replace(/@import[^;]+;/g, '')
  .replace(/@theme inline\s*\{[\s\S]*?\n\}/, '')
  .replace(/@source[^;]+;/g, '')}`
const own = postcss.parse(ownCss)

const layered = postcss.root()
const unlayered = postcss.root()
const rootVars = new Map()

function keepRule(rule) {
  if (rule.parent?.type === 'atrule' && /keyframes/.test(rule.parent.name)) return true
  const kept = rule.selectors.filter((selector) => {
    if (isDarkOnly(selector)) return false
    return classesOf(selector).every((name) => words.has(name))
  })
  if (kept.length === 0) return false
  rule.selectors = kept
  return true
}

/** The CRM's variable blocks become one block of the root's, colours mapped. */
function takeVars(rule) {
  if (!rule.selectors.every((s) => /^(:root|html|:host)$/.test(s.trim()) || /^:root,\s*:host$/.test(s.trim()))) return false
  for (const node of [...rule.nodes ?? []]) {
    if (node.type === 'decl' && node.prop.startsWith('--')) {
      if (!KEEP_APPS.has(node.prop)) rootVars.set(node.prop, node.value)
      node.remove()
    }
  }
  return (rule.nodes ?? []).length === 0
}

for (const node of [...own.nodes]) {
  if (node.type === 'comment') continue
  if (node.type === 'atrule' && node.name === 'media' && /prefers-color-scheme/.test(node.params)) continue
  if (node.type === 'atrule' && node.name === 'layer') {
    node.walkRules((rule) => {
      if (!keepRule(rule)) rule.remove()
    })
    for (const child of [...(node.nodes ?? [])]) layered.append(child.clone())
    continue
  }
  if (node.type === 'rule') {
    if (takeVars(node)) continue
    if (keepRule(node)) unlayered.append(node.clone())
    continue
  }
  if (node.type === 'atrule') {
    const copy = node.clone()
    copy.walkRules((rule) => {
      if (!keepRule(rule)) rule.remove()
    })
    unlayered.append(copy)
  }
}

// Tailwind's output: its theme variables join the root's; utilities keep their order.
const utilities = postcss.root()
const properties = postcss.root()
const keyframes = new Map()
tw.root.walkAtRules('property', (at) => {
  properties.append(at.clone())
  at.remove()
})
tw.root.walkAtRules('keyframes', (at) => {
  keyframes.set(at.params, at.clone())
  at.remove()
})
tw.root.walkRules((rule) => {
  if (rule.selectors.every((s) => /^(:root|:host)$/.test(s.trim()))) {
    rule.walkDecls((decl) => {
      if (decl.prop.startsWith('--') && !KEEP_APPS.has(decl.prop)) rootVars.set(decl.prop, decl.value)
    })
    rule.remove()
  }
})
tw.root.each((node) => {
  if (node.type === 'atrule' && node.name === 'layer') {
    if (node.nodes) for (const child of node.nodes) utilities.append(child.clone())
  } else if (node.type !== 'comment') utilities.append(node.clone())
})

// The face is the app's; the CRM's own font variables are not.
rootVars.set('--font-sans', 'var(--font-ui)')
rootVars.delete('--font-mono')

/* ---------------------------------------------------------- assemble -- */

const out = postcss.root()
out.append(postcss.comment({ text: ' Generated by scripts/build-crm-task-css.mjs from the reference CRM\'s styling — do not edit by hand.\n   Every selector is scoped under .crm-task-root; every colour is one of Terminal Deck\'s tokens. ' }))
for (const at of [...properties.nodes]) out.append(at)

const vars = postcss.rule({ selector: SCOPE })
for (const [prop, value] of rootVars) {
  vars.append(postcss.decl({ prop, value: SEMANTIC[prop] ?? mapPalette(prop, value) ?? mapValue(value) }))
}
for (const [prop, value] of Object.entries(SEMANTIC)) if (!rootVars.has(prop)) vars.append(postcss.decl({ prop, value }))
vars.append(postcss.decl({ prop: 'font-family', value: 'var(--font-ui)' }))
vars.append(postcss.decl({ prop: 'color', value: 'var(--text)' }))
vars.append(postcss.decl({ prop: 'line-height', value: '1.5' }))
vars.append(postcss.decl({ prop: '-webkit-font-smoothing', value: 'antialiased' }))
out.append(vars)

// What the CRM's markup takes for granted from a base stylesheet, inside the popup only — never the whole app.
out.append(
  postcss.parse(`
${SCOPE} :where(*, ::before, ::after) { box-sizing: border-box; border: 0 solid; margin: 0; padding: 0; }
${SCOPE} :where(h1, h2, h3, h4, h5, h6) { font-size: inherit; font-weight: inherit; letter-spacing: normal; }
${SCOPE} :where(ol, ul, menu) { list-style: none; }
${SCOPE} :where(img, svg, video, canvas) { display: block; vertical-align: middle; }
${SCOPE} :where(img, video) { max-width: 100%; height: auto; }
${SCOPE} :where(button, input, select, optgroup, textarea) { font: inherit; letter-spacing: inherit; color: inherit; background-color: transparent; border-radius: 0; opacity: 1; }
${SCOPE} :where(button, [role="button"]) { cursor: pointer; }
${SCOPE} :where(a) { color: inherit; text-decoration: inherit; }
${SCOPE} :where(hr) { height: 0; color: inherit; border-top-width: 1px; }
${SCOPE} :where(textarea) { resize: vertical; }
${SCOPE} :where(input::placeholder, textarea::placeholder) { opacity: 1; color: var(--text-muted); }
${SCOPE} :where([hidden]:not([hidden="until-found"])) { display: none !important; }
`),
)

const scoped = (root) => {
  root.walkRules((rule) => {
    if (rule.parent?.type === 'atrule' && /keyframes/.test(rule.parent.name)) return
    rule.selectors = rule.selectors.map((s) => (s.startsWith(SCOPE) ? s : scopeSelector(s)))
  })
  return root
}
for (const node of [...scoped(layered).nodes]) out.append(node)
for (const node of [...scoped(utilities).nodes]) out.append(node)
for (const node of [...scoped(unlayered).nodes]) out.append(node)

// Keyframes keep their steps under a name of the popup's own, so the app's never collide.
for (const [name, at] of keyframes) {
  at.params = `crm-${name}`
  out.append(at)
}
out.walkDecls((decl) => {
  for (const name of keyframes.keys()) {
    if (/animation/.test(decl.prop) || decl.prop.startsWith('--animate')) {
      decl.value = decl.value.replace(new RegExp(`(?<![-\\w])${name}(?![-\\w])`, 'g'), `crm-${name}`)
    }
  }
})
// Keyframes nothing kept animates with (the design system's other screens) are dropped.
const animated = new Set()
out.walkDecls((decl) => {
  if (/animation/.test(decl.prop) || decl.prop.startsWith('--animate')) for (const word of decl.value.split(/[\s,()]+/)) animated.add(word)
})
out.walkAtRules('keyframes', (at) => {
  if (!animated.has(at.params)) at.remove()
})

// The local wiring: the host is layout-free, and a photo's overlay keeps white on black.
out.append(
  postcss.parse(`
.crm-task-host { display: contents; }
${SCOPE} .lightbox { --color-white: rgb(255 255 255); }
`),
)

// Colours: every literal left becomes a token; mono text keeps its characters (styles/verbatim.css's rule).
out.walkDecls((decl) => {
  if (decl.parent?.type === 'atrule' && decl.parent.name === 'property') return
  if (decl.parent?.selector === SCOPE && decl.prop.startsWith('--')) return
  if (decl.prop === '--color-white' && decl.parent?.selector === `${SCOPE} .lightbox`) return
  // The CRM pins its scheme; the app's theme decides here.
  if (decl.prop === 'color-scheme') {
    decl.remove()
    return
  }
  decl.value = mapValue(decl.value)
  if (decl.prop === 'font-family' && /var\(--font-mono\)/.test(decl.value)) {
    if (!decl.parent.some((d) => d.type === 'decl' && d.prop === 'font-variant-ligatures')) {
      decl.after(postcss.decl({ prop: 'font-variant-ligatures', value: 'none' }))
    }
  }
})
out.walkComments((comment, index) => {
  if (index !== 0 || comment.parent !== out) comment.remove()
})

// Nothing empty is kept (rules whose every selector was dropped, media blocks left with nothing in them).
for (let again = true; again; ) {
  again = false
  out.walk((node) => {
    if ((node.type === 'rule' || (node.type === 'atrule' && node.name !== 'property')) && node.nodes && node.nodes.length === 0) {
      node.remove()
      again = true
    }
  })
}

// Every variable the kept rules read is defined: Tailwind's internals default to nothing (their own
// fallbacks apply), and the two the CRM's markup sets inline get a neutral default.
const INLINE_DEFAULTS = { '--hue': 'var(--text-muted)', '--col-w': 'auto' }
const tokensCss = readFileSync(join(ROOT, 'src', 'renderer', 'styles', 'tokens.css'), 'utf8')
const defined = new Set([...`${tokensCss}\n${out.toString()}`.matchAll(/(--[A-Za-z0-9_-]+)\s*:/g)].map((m) => m[1]))
const rootRule = out.nodes.find((node) => node.type === 'rule' && node.selector === SCOPE)
for (const match of out.toString().matchAll(/var\(\s*(--[A-Za-z0-9_-]+)/g)) {
  const name = match[1]
  if (defined.has(name)) continue
  defined.add(name)
  if (name.startsWith('--tw-')) rootRule.append(postcss.decl({ prop: name, value: 'initial' }))
  else if (INLINE_DEFAULTS[name]) rootRule.append(postcss.decl({ prop: name, value: INLINE_DEFAULTS[name] }))
  else console.warn(`warning: ${name} is read but never defined`)
}

// One rule per line block, so a diff of the generated file reads.
out.walk((node) => {
  let depth = 0
  for (let p = node.parent; p && p.type !== 'root'; p = p.parent) depth += 1
  const pad = '  '.repeat(depth)
  node.raws.before = node.parent === out && node === out.first ? '' : `\n${node.type === 'decl' ? '' : depth === 0 ? '\n' : ''}${pad}`
  if (node.type === 'decl') node.raws.between = ': '
  else {
    node.raws.between = node.type === 'rule' ? ' ' : node.nodes ? ' ' : ''
    node.raws.after = `\n${pad}`
    node.raws.semicolon = true
  }
  if (node.type === 'atrule') node.raws.afterName = ' '
})

let css = out.toString()
// Brand-neutral: no class or variable keeps the CRM's own name.
css = css.replace(/\b[a-z]*(?:i)loop[a-z-]*/gi, (name) => name.replace(/(?:i)loop/i, 'crm'))
writeFileSync(OUT, `${css.trim()}\n`)
console.log(`wrote ${OUT}: ${css.length} bytes, ${rootVars.size} variables, ${words.size} source words`)
