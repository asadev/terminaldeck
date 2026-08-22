import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { actionLabel, actionVerb, hasAction, McpStoreRow } from './McpStoreRow'
import { StoreHeader } from './McpStore'
import type { McpStoreRow as Row, McpStoreView } from './mcp-store-bridge'

/**
 * A store row and the store's bar, actually rendered.
 *
 * There is no DOM in this project's test setup, so this renders through
 * `react-dom/server` the way `browser/ToolRow.test.tsx` does. The panel around
 * these loads through an effect, which SSR never runs, so the row and the bar
 * are where everything worth asserting lives.
 *
 * What is being asserted is the disclosure. The facts on a row are not
 * decoration — `mcp-store.ts` refuses an install whose runtime is missing or
 * whose required field is empty, printing the same words the row printed — so a
 * row that drew the name and hid the rest would be asking somebody to agree to
 * something they were never shown.
 */

const ROW: Row = {
  id: 'guarded',
  name: 'guarded',
  summary: 'Reads the thing.',
  category: 'utility',
  tags: [],
  homepage: 'https://example.com/guarded',
  registry: 'https://www.npmjs.com/package/guarded',
  licence: 'MIT',
  version: '1.2.3',
  runtime: 'node',
  runtimeBinary: 'npx',
  origin: 'third-party',
  command: 'npx -y guarded',
  inputs: [
    {
      key: 'API_TOKEN',
      label: 'API token',
      hint: 'From their dashboard.',
      kind: 'secret',
      into: 'env',
      required: true,
      inEnvironment: false,
    },
  ],
  state: 'available',
  scope: '',
  taken: '',
  blocked: '',
  caveat: '',
}

function draw(row: Row, over: Partial<Parameters<typeof McpStoreRow>[0]> = {}): string {
  return renderToStaticMarkup(
    <McpStoreRow
      row={row}
      busy={false}
      values={{}}
      said=""
      arming={false}
      onValue={() => {}}
      onAct={() => {}}
      onArm={() => {}}
      {...over}
    />,
  )
}

describe('the store row', () => {
  it('shows the four facts an install is checked against', () => {
    const html = draw(ROW)
    expect(html).toContain('https://example.com/guarded')
    expect(html).toContain('https://www.npmjs.com/package/guarded')
    expect(html).toContain('npx')
    expect(html).toContain('npx -y guarded')
    expect(html).toContain('API token')
    expect(html).toContain('MIT')
    expect(html).toContain('1.2.3')
  })

  it('says a row needs a token before anything is pressed, not after', () => {
    /*
     * The requirement in one test: *"a row that cannot work without one says so
     * BEFORE install rather than failing after."* The field is on the row, the
     * Needs line names it, and the button cannot be pressed while it is empty.
     */
    const html = draw(ROW)
    expect(html).toContain('Needs API token before it can be installed.')
    expect(html).toContain('disabled=""')
  })

  it('takes a secret in a field that does not show it', () => {
    expect(draw(ROW)).toContain('type="password"')
    expect(draw({ ...ROW, inputs: [{ ...ROW.inputs[0], kind: 'path' }] })).toContain('type="text"')
  })

  it('enables the button once the field is filled', () => {
    const html = draw(ROW, { values: { API_TOKEN: 'sk-1' } })
    expect(html).not.toContain('Needs API token before')
    expect(html).toContain('>Install</button>')
  })

  it('offers no Install at all when the runtime is missing', () => {
    /*
     * Not a disabled one. The browser store's rule, and it exists because a
     * greyed-out button is a thing people press repeatedly and a sentence is a
     * thing they read once.
     */
    const html = draw({
      ...ROW,
      state: 'unavailable',
      blocked: 'docker is not on this machine. It needs Docker.',
    })
    expect(html).toContain('docker is not on this machine')
    expect(html).not.toContain('>Install</button>')
    /*
     * And no field either. Rendering the page and looking at it caught this: a
     * Personal access token box sat under a GitHub row that had no Install
     * anywhere on it. Something you can type a secret into that nothing can ever
     * use is worse than an inert button — a person can put a real token in it.
     */
    expect(html).not.toContain('type="password"')
  })

  it('offers no Install when something else owns the name, and shows what does', () => {
    const html = draw({
      ...ROW,
      state: 'taken',
      taken: 'node /home/me/mine.js',
      blocked: 'A server called guarded is already configured and it is not this one.',
    })
    expect(html).toContain('node /home/me/mine.js')
    expect(html).not.toContain('>Install</button>')
    expect(html).not.toContain('type="password"')
  })

  it('keeps Remove on an installed row even when its runtime went away', () => {
    // A runtime uninstalled since does not make the line in the config file
    // undeletable, and that is exactly when somebody wants it gone.
    const installed: Row = { ...ROW, state: 'installed', scope: 'user', blocked: 'anything' }
    expect(hasAction(installed)).toBe(true)
    expect(draw(installed)).toContain('>Remove</button>')
    expect(draw(installed)).toContain('Installed')
  })

  it('arms Remove before it removes', () => {
    // The two-press shape the servers list next door already uses: this deletes
    // a line out of another application's configuration and nothing in this app
    // has an undo.
    const html = draw({ ...ROW, state: 'installed', scope: 'user' }, { arming: true })
    expect(html).toContain('data-danger="true"')
    expect(html).toContain('>Keep</button>')
  })

  it('prints a caveat the install does not fix', () => {
    const html = draw({ ...ROW, caveat: 'Nobody is maintaining this one.' })
    expect(html).toContain('Nobody is maintaining this one.')
  })

  it('hides the fields once it is installed, because there is nothing to type', () => {
    expect(draw({ ...ROW, state: 'installed', scope: 'user' })).not.toContain('type="password"')
  })

  it('does not tell an installed row what it needs before it can be installed', () => {
    // Rendering the page and looking at it caught this: *"Needs Directory it may
    // touch before it can be installed"* under a row that plainly was, next to
    // its Remove. The fields are hidden once installed, so nothing could ever
    // have filled it in.
    expect(draw({ ...ROW, state: 'installed', scope: 'user' })).not.toContain('before it can be installed')
  })
})

describe('actionLabel and actionVerb', () => {
  it('are one decision, so a button cannot read Install and remove', () => {
    expect(actionLabel(ROW, false)).toBe('Install')
    expect(actionVerb(ROW)).toBe('install')
    const installed: Row = { ...ROW, state: 'installed' }
    expect(actionLabel(installed, false)).toBe('Remove')
    expect(actionVerb(installed)).toBe('remove')
    expect(actionLabel(ROW, true)).toBe('Working…')
  })
})

/* ------------------------------------------------------------------- bar -- */

const VIEW: McpStoreView = {
  rows: [ROW],
  runtimes: [
    { id: 'node', binary: 'npx', found: true, path: '/opt/homebrew/bin/npx', needs: 'Node.js' },
    { id: 'docker', binary: 'docker', found: false, path: '', needs: 'Docker.' },
  ],
  writer: { found: true, path: '/usr/local/bin/claude' },
  environmentSource: 'login-shell',
  projectPath: '',
}

function bar(over: Partial<Parameters<typeof StoreHeader>[0]> = {}): string {
  return renderToStaticMarkup(
    <StoreHeader
      view={VIEW}
      here="this Mac"
      loading={false}
      scope="user"
      scopes={[{ value: 'user', label: 'All projects', help: 'Available everywhere.' }]}
      adding={false}
      onScope={() => {}}
      onReload={() => {}}
      onAdd={() => {}}
      {...over}
    />,
  )
}

describe('the store bar', () => {
  it('shows what was looked for on this machine and where it was found', () => {
    // Every "cannot run on this machine" sentence on a row refers back to this,
    // so a claim about somebody's computer shows its working.
    const html = bar()
    expect(html).toContain('/opt/homebrew/bin/npx')
    expect(html).toContain('not on this machine')
    expect(html).toContain('docker')
  })

  it('offers “Add your own” as a control, not a footnote', () => {
    /*
     * *"people like to use their own kind of extension … they can just click and
     * attach their own things to this application."* The catalogue is the
     * convenience; arbitrary servers are the capability, so the button is in the
     * bar beside Reload rather than under nineteen rows.
     */
    expect(bar()).toContain('Add your own')
  })

  it('does not say a variable is absent when the shell could not be asked', () => {
    // Three different facts, three different sentences. "Not set" from a failed
    // probe would push somebody into pasting a token they already had.
    expect(bar()).toContain('read from your login shell')
    expect(bar({ view: { ...VIEW, environmentSource: 'unavailable' } })).toContain(
      'could not be asked',
    )
    expect(bar({ view: { ...VIEW, environmentSource: 'process' } })).toContain('own environment')
  })

  it('hides the scope switch when there is only one scope to be in', () => {
    // His most repeated note: *"a dropdown only when some exist. Hide it when
    // empty."* With no project open, `user` is the only place a server can go.
    expect(bar()).not.toContain('role="group"')
  })

  it('shows the scope switch once a project gives it somewhere else to write', () => {
    const html = bar({
      scopes: [
        { value: 'user', label: 'All projects', help: 'Available everywhere.' },
        { value: 'local', label: 'This project only', help: 'Private to this folder.' },
      ],
    })
    expect(html).toContain('This project only')
  })
})
