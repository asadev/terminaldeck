import { describe, expect, it } from 'vitest'
import { PANELS, panelSpec } from './panels'

/**
 * The rail row that leads to Machines.
 *
 * ## Two things are pinned here and they pull in opposite directions
 *
 * The **word** had to change: the row now leads to servers as well as to paired
 * devices, and "Remote" is the wrong name for a rented machine in a data centre
 * that this computer reaches out to. Asad: *"let's replace remote to Machines,
 * and inside machine we can have server and remote other devices."*
 *
 * The **id** had to not change. `'remote'` is what a saved rail position and the
 * feature registry are keyed on, so renaming it would drop somebody back to
 * Overview at their next launch having changed nothing they can see. The same
 * argument is written out about `hooks` in `panels.ts` and about `machines.json`
 * one directory over — that one holds a credential per paired device, and its
 * rename would silently drop everybody's pairings.
 *
 * A test rather than a comment because the two are only correct *together*: a
 * later rename that "tidies up" the id would pass every other test in this
 * repository while quietly resetting everybody's window.
 */

describe('Machines in the rail', () => {
  it('is called Machines and is still keyed on the id it always was', () => {
    const spec = panelSpec('remote')
    expect(spec.label).toBe('Machines')
    expect(spec.id).toBe('remote')
  })

  it('names both kinds in the line under it, because it leads to both', () => {
    // A blurb naming only one of them sends half the people looking for the
    // other one somewhere else. This is also the empty state's subtitle and the
    // toolbar's second line, so it is read more often than the label.
    const blurb = panelSpec('remote').blurb.toLowerCase()
    expect(blurb).toContain('server')
    expect(blurb).toMatch(/computers|devices|phones/)
  })

  it('adds no row to the rail', () => {
    /*
     * The whole placement requirement, and it is checkable: *"we will place it
     * somewhere without making our tool more busy UI, so make a placement to
     * reach to its own private area."* Servers went **inside** a row that
     * already existed. One label changed and nothing was added — a new row
     * would be exactly the busier sidebar the request was against.
     */
    expect(PANELS.map((panel) => panel.id)).toEqual([
      'overview',
      'files',
      'artifacts',
      'git',
      'github',
      'readiness',
      'mcp',
      'remote',
      'hooks',
    ])
  })

  it('stays in the quiet strip at the bottom, not among the project views', () => {
    // The machines you can reach do not change when you open a different
    // folder, which is the whole argument for the foot rather than for the
    // labelled runs above it. Servers do not change it either.
    expect(panelSpec('remote').group).toBe('foot')
  })
})
