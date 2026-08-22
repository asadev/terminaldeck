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

  it('names both kinds with one word, because it leads to both', () => {
    /*
     * There was a line under this row naming servers *and* the owner's own
     * computers, and this test checked that both were in it. The line is gone
     * with every other panel blurb — see `shell/panels.ts` — so what is left to
     * check is that the label itself is the umbrella word rather than one of
     * the two kinds under it. "Remote" or "Servers" here would send half the
     * people looking for the other one somewhere else, which is the same
     * failure the deleted sentence existed to prevent.
     */
    expect(panelSpec('remote').label).toBe('Machines')
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
      // `store` is the one row added to this rail since, and it is not a
      // counter-example to the requirement above — it *removed* two surfaces
      // rather than adding one. The store was a modal inside the browser and a
      // tab on the MCP page; it is one page now, and both of those are gone.
      // See the note beside `store` in `shell/panels.ts`.
      'store',
      'github',
      'readiness',
      'mcp',
      'remote',
      'hooks',
    ])
  })

  it('sits under Integrations, with the rest of what this app reaches out to', () => {
    /*
     * Asad, reading the rail back: *"also move machines in the integrations
     * section in the side panel."* It was in the foot before — the quiet strip
     * with the update notice and Settings.
     *
     * Pinned because the argument for the foot is still quotable and somebody
     * will quote it: the machines you can reach do not change when you open a
     * different folder. True, and not what this run sorts on — an MCP server
     * can be `user` scope too. Every row here is a connection out of this app
     * to something that is not this app, and a rented server or a paired phone
     * is exactly that.
     */
    expect(panelSpec('remote').group).toBe('integrations')
  })

  it('does not appear a second time anywhere else in the rail', () => {
    // Two rows reaching one page is worse than either placement on its own,
    // and the move is the moment that becomes possible to ship. `PANELS` is
    // the whole inventory, so counting it here catches a copy left behind.
    expect(PANELS.filter((panel) => panel.id === 'remote')).toHaveLength(1)
    expect(PANELS.filter((panel) => panel.label === 'Machines')).toHaveLength(1)
  })
})
