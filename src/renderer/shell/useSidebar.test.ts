import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { panelAfterSelect } from './useSidebar'

/**
 * The ping-pong, pinned.
 *
 * `~24 consecutive frames` of the recording alternate between the Files page
 * and a blank terminal with the pointer motionless, and the cause was one
 * expression: selecting the view that was already open closed it. Two clicks on
 * a sidebar row did it by hand, and the Files page did it to itself — its tree
 * reports every clicked row through `onOpenFile`, which `App.tsx` answers with
 * `showPanel('files')`, which was a toggle.
 */
describe('panelAfterSelect', () => {
  it('opens a view from a session', () => {
    expect(panelAfterSelect(null, 'files')).toBe('files')
  })

  it('moves straight from one view to another', () => {
    expect(panelAfterSelect('git', 'files')).toBe('files')
  })

  /**
   * The one that matters. Asad, on the double click: *"it should not move to
   * the other one. It should stay there."*
   */
  it('keeps the view open when the same one is asked for again', () => {
    expect(panelAfterSelect('files', 'files')).toBe('files')
  })

  it('never answers null — leaving a view is `clearPanel`, not this', () => {
    for (const id of ['overview', 'files', 'artifacts', 'git'] as const) {
      expect(panelAfterSelect(id, id)).not.toBeNull()
    }
  })
})

/**
 * The loop this fixed runs through `App.tsx`, which no test in this project can
 * mount — there is no DOM environment here (see `wiring.test.ts`). So the seam
 * is read as source: the Files page hands every clicked row to `onOpenFile`,
 * `App.tsx` answers it with `showFile`, and `showFile` navigates to Files. That
 * chain is only safe while navigation is idempotent, and this is the assertion
 * that says so out loud if anybody re-introduces a toggle.
 */
describe('the Files page’s own open-a-file loop', () => {
  const read = (rel: string): string =>
    readFileSync(join(__dirname, '..', '..', '..', 'src', rel), 'utf8')

  it('still routes a clicked file back through the panel selector', () => {
    const app = read('renderer/App.tsx')
    expect(app).toMatch(/const showFile = useCallback\([\s\S]*?showPanel\('files'\)/)
    expect(app).toMatch(/onOpenFile=\{showFile\}/)
  })

  it('has no toggle left in the panel selector', () => {
    const source = read('renderer/shell/useSidebar.ts')
    const selector = source.slice(source.indexOf('const selectPanel'))
    // `setPanel(null)` inside `selectPanel` is the exact shape of the bug: a
    // navigation that can answer "no view at all".
    expect(selector.slice(0, selector.indexOf('const clearPanel'))).not.toMatch(/null/)
  })
})
