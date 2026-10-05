import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar } from './Sidebar'

/**
 * What the native macOS window hides, and that it hides nothing in Electron.
 *
 * Every rule is written under `:root[data-shell='native']`, which only the
 * native window's page shim sets — so the Electron window, which never has the
 * attribute, matches none of them. Each class those rules name must be a class
 * the app really renders (a rule for a class nothing draws hides nothing and
 * reads as if it did), and the rail's three duplicates of native chrome — its
 * collapse arrow, its New session button and its Settings line — must be inside
 * the rail that is hidden whole.
 */

const RENDERER = join(__dirname, '..')
const NATIVE = ":root[data-shell='native']"

function files(dir: string, test: (name: string) => boolean, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) files(path, test, out)
    else if (test(entry.name)) out.push(path)
  }
  return out
}

const SHEETS = files(RENDERER, (name) => name.endsWith('.css')).map((path) => ({
  path,
  css: readFileSync(path, 'utf8').replace(/\/\*[\s\S]*?\*\//g, ''),
}))
const SOURCE = files(RENDERER, (name) => /\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name))
  .map((path) => readFileSync(path, 'utf8'))
  .join('\n')

/** Every rule whose selector mentions the native shell, as [selector, body]. */
const NATIVE_RULES = SHEETS.flatMap(({ css }) =>
  [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .map((match) => [match[1].trim(), match[2].trim()] as const)
    .filter(([selector]) => selector.includes('data-shell')),
)

const ruleFor = (selector: string): string | undefined =>
  NATIVE_RULES.find(([candidate]) => candidate.split(',').map((part) => part.trim()).includes(selector))?.[1]

describe('native-mode CSS', () => {
  it('scopes every rule to the native shell, so the Electron window matches none', () => {
    expect(NATIVE_RULES.length).toBeGreaterThan(8)
    for (const [selector] of NATIVE_RULES) {
      for (const part of selector.split(/,(?![^(]*\))/)) {
        expect(part.trim().startsWith(NATIVE), part).toBe(true)
      }
    }
  })

  it('names only classes the app really renders', () => {
    const classes = new Set(
      NATIVE_RULES.flatMap(([selector]) => [...selector.matchAll(/\.([a-z][a-z0-9-]*)/g)].map((match) => match[1])),
    )
    expect(classes.size).toBeGreaterThan(8)
    for (const name of classes) {
      expect(new RegExp(`["'\`\\s]${name}["'\`\\s]`).test(SOURCE), `.${name} is not rendered anywhere`).toBe(true)
    }
  })

  it('hides the web side panel and the edge that peeks it out', () => {
    expect(ruleFor(`${NATIVE} .sidebar`)).toContain('display: none')
    expect(ruleFor(`${NATIVE} .sidebar-edge`)).toContain('display: none')
  })

  it('takes the rail’s own duplicates of the native chrome with it', () => {
    const rail = renderToStaticMarkup(
      <Sidebar
        width={264}
        projects={[]}
        tabs={[]}
        activeTabId={null}
        activePanel={null}
        panels={[]}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
        onSelectPanel={() => {}}
        onNewSession={() => {}}
        onNewBrowserTab={() => {}}
        onOpenProject={() => {}}
        onCloseProject={() => {}}
        onOpenSettings={() => {}}
        onOpenAlerts={() => {}}
        onToggleCollapsed={() => {}}
        onPeekStart={() => {}}
        onPeekEnd={() => {}}
        onStartResize={() => {}}
        storage={null}
      />,
    )
    expect(rail.startsWith('<aside class="sidebar"')).toBe(true)
    // The collapse arrow, New session, and the Settings line: all inside it.
    expect(rail).toContain('class="sidebar-arrow"')
    expect(rail).toContain('class="sb-new"')
    expect(rail).toContain('class="sb-row sb-settings"')
  })

  it('drops the drag strip and the rail’s reveal buttons, and the room kept for them', () => {
    expect(ruleFor(`${NATIVE} .window-drag`)).toContain('display: none')
    expect(ruleFor(`${NATIVE} .toolbar-reveal`)).toContain('display: none')
    expect(ruleFor(`${NATIVE} .toolbar[data-sidebar-collapsed]:not([data-under-strip])`)).toContain('padding-left: var(--sp-4)')
  })

  it('hides a top bar that only says a name, and keeps one with anything else on it', () => {
    const titleOnly = NATIVE_RULES.find(([selector]) => selector.startsWith(`${NATIVE} .toolbar:not(:has(`))
    expect(titleOnly?.[1]).toContain('display: none')
    // What keeps it: controls, the folder and login chips, a subtitle, Hoot's mark.
    for (const kept of ['.toolbar-actions > *', '.toolbar-chips', '.toolbar-subtitle', '.toolbar-mark']) {
      expect(titleOnly?.[0]).toContain(kept)
    }
  })

  it('hides the web tab strip row whole — tabs, openers and reveal button — which the native top bar draws', () => {
    expect(ruleFor(`${NATIVE} .strip`)).toContain('display: none')
    const strip = readFileSync(join(RENDERER, 'browser/WorkspaceTabStrip.tsx'), 'utf8')
    // One row: the openers and the reveal button are inside the element hidden.
    const root = strip.indexOf('className="strip"')
    expect(root).toBeGreaterThan(-1)
    for (const inner of ['className="strip-openers"', 'className="strip-list"']) {
      expect(strip.indexOf(inner), inner).toBeGreaterThan(-1)
    }
  })

  it('hides the Settings sheet’s own list of sections, which the native window draws', () => {
    expect(ruleFor(`${NATIVE} .settings-rail`)).toContain('display: none')
    expect(ruleFor(`${NATIVE} .settings`)).toContain('grid-template-columns: minmax(0, 1fr)')
  })
})
