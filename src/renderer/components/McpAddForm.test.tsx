import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { draftToRequest, EMPTY_DRAFT, McpAddForm, scopeChoices } from './McpAddForm'

/**
 * No DOM in this project's test setup, so the form is covered the way the rest
 * of this folder is: the pure functions carry the decisions, and the component
 * is rendered to static markup to prove it paints.
 *
 * What is worth guarding here is not the markup. It is the two ways this form
 * can lie — offering a scope it cannot write, and sending a field the user can
 * no longer see.
 */

describe('scopeChoices', () => {
  it('offers only the global scope when no project is open', () => {
    // `local` and `project` are addressed by the working directory the CLI runs
    // in. With no project there is nowhere correct to put them, so offering
    // them would be offering two options that quietly do the wrong thing.
    expect(scopeChoices(null).map((choice) => choice.value)).toEqual(['user'])
  })

  it('offers all three once there is a project to be relative to', () => {
    expect(scopeChoices('/work/app').map((choice) => choice.value)).toEqual(['user', 'local', 'project'])
  })

  it('explains every option it offers', () => {
    for (const choice of scopeChoices('/work/app')) {
      expect(choice.label.length).toBeGreaterThan(0)
      expect(choice.help.length).toBeGreaterThan(0)
    }
  })

  it('warns that a shared server arrives switched off', () => {
    // Verified against the real CLI: a `project`-scope server is read back as
    // disabled with "Not approved for this project yet." Without this line the
    // greyed row that follows a successful add looks like a failed one.
    const shared = scopeChoices('/work/app').find((choice) => choice.value === 'project')
    expect(shared?.help).toMatch(/approve/i)
  })
})

describe('draftToRequest', () => {
  it('sends the command and drops the url for a stdio server', () => {
    // Switching the picker back and forth leaves the other field populated.
    // Sending both and letting the far side choose is how a server gets added
    // from a box the user could no longer see.
    const request = draftToRequest(
      { ...EMPTY_DRAFT, name: 'files', command: 'npx server', url: 'https://left-over' },
      null,
    )
    expect(request.command).toBe('npx server')
    expect(request.url).toBe('')
  })

  it('sends the url and drops the command for an http server', () => {
    const request = draftToRequest(
      { ...EMPTY_DRAFT, name: 'x', transport: 'http', command: 'left over', url: 'https://x/mcp' },
      null,
    )
    expect(request.url).toBe('https://x/mcp')
    expect(request.command).toBe('')
  })

  it('splits the extras box into lines and drops the blank ones', () => {
    const request = draftToRequest({ ...EMPTY_DRAFT, name: 'x', extras: 'A=1\n\n  B=2  \n' }, null)
    expect(request.extras).toEqual(['A=1', 'B=2'])
  })

  it('carries the project path, which is what decides where a scope lands', () => {
    expect(draftToRequest({ ...EMPTY_DRAFT, name: 'x' }, '/work/app').projectPath).toBe('/work/app')
    expect(draftToRequest({ ...EMPTY_DRAFT, name: 'x' }, null).projectPath).toBeNull()
  })

  it('trims what was typed, so a stray space is not part of the name', () => {
    const request = draftToRequest({ ...EMPTY_DRAFT, name: '  files  ', command: '  npx server ' }, null)
    expect(request.name).toBe('files')
    expect(request.command).toBe('npx server')
  })
})

describe('<McpAddForm>', () => {
  const noop = (): void => undefined
  const submit = async (): Promise<{ ok: boolean; message: string }> => ({ ok: true, message: 'Added.' })

  it('renders the fields needed to describe a server', () => {
    const html = renderToStaticMarkup(
      <McpAddForm projectPath="/work/app" onSubmit={submit} onAdded={noop} onCancel={noop} />,
    )
    expect(html).toContain('Name')
    expect(html).toContain('Command')
    expect(html).toContain('Save it for')
    expect(html).toContain('Add server')
  })

  it('says why the per-project options are missing rather than just omitting them', () => {
    // A picker that is quietly shorter than it was is indistinguishable from a
    // broken one. Rule: silence reads as broken.
    const html = renderToStaticMarkup(
      <McpAddForm projectPath={null} onSubmit={submit} onAdded={noop} onCancel={noop} />,
    )
    expect(html).toContain('Open a project')
    expect(html).not.toContain('This project, shared')
  })
})
