import { describe, expect, it } from 'vitest'
import { readToolFile, toolFileName, toolFileText } from './mcp-share'
import type { ConfiguredServer } from './mcp-store'

/**
 * A tool definition, as a file somebody can be sent.
 *
 * The property under test above all others is what is **not** in the file. A
 * definition that carried somebody's `GITHUB_PERSONAL_ACCESS_TOKEN` would be a
 * credential in a thing people forward, attach and commit — which is the whole
 * reason sharing a config file is normally a bad idea.
 */

const SERVER: ConfiguredServer = {
  name: 'my-notes',
  scope: 'user',
  commandLine: 'npx -y @me/notes /Users/me/Notes',
  transport: 'stdio',
  envKeys: ['API_KEY', 'REGION'],
}

describe('writing one out', () => {
  it('holds the definition and the names of what it needs', () => {
    const parsed: unknown = JSON.parse(toolFileText(SERVER))
    expect(parsed).toMatchObject({
      terminalDeckTool: 1,
      kind: 'mcp-server',
      name: 'my-notes',
      transport: 'stdio',
      command: 'npx -y @me/notes /Users/me/Notes',
      env: ['API_KEY', 'REGION'],
    })
  })

  it('cannot hold a value, because the shape it is given has nowhere to keep one', () => {
    /*
     * The safety property is in the *type*, not in a filter: {@link toolFileText}
     * takes a `ConfiguredServer`, which has no field that could carry a value —
     * so no future edit of this function can start writing one into a file by
     * accident. This test is the reminder of why the parameter is that type.
     */
    const text = toolFileText(SERVER)
    // The names are here; nothing that could be a value is. `API_KEY` appears
    // exactly once, in the list, with nothing after it.
    expect(text).toContain('"API_KEY"')
    expect(text).not.toMatch(/API_KEY\s*[=:]\s*"?\w/)
    expect(text).toContain('It holds no secrets')
  })

  it('puts a URL under url and a command under command, never both', () => {
    const http: unknown = JSON.parse(
      toolFileText({ ...SERVER, transport: 'http', commandLine: 'https://example.com/mcp' }),
    )
    expect(http).toMatchObject({ command: '', url: 'https://example.com/mcp' })
  })

  it('offers a filename that is safe on all three platforms', () => {
    expect(toolFileName('my-notes')).toBe('my-notes.mcpserver.json')
    expect(toolFileName('a/b:c*d')).toBe('a-b-c-d.mcpserver.json')
    expect(toolFileName('///')).toBe('mcp-server.mcpserver.json')
  })
})

describe('reading one back', () => {
  it('round-trips', () => {
    const read = readToolFile(toolFileText(SERVER))
    expect(read.ok).toBe(true)
    if (!read.ok) return
    expect(read.draft).toEqual({
      name: 'my-notes',
      transport: 'stdio',
      command: 'npx -y @me/notes /Users/me/Notes',
      url: '',
      env: ['API_KEY', 'REGION'],
    })
  })

  it('says which field is wrong, not that "something went wrong"', () => {
    // The person reading this is as likely to be the one who wrote the file as
    // the one who received it.
    expect(readToolFile('not json')).toMatchObject({ ok: false, why: expect.stringContaining('JSON') })
    expect(readToolFile('{"kind":"something-else"}')).toMatchObject({
      ok: false,
      why: expect.stringContaining('not an MCP server'),
    })
    expect(readToolFile('{"kind":"mcp-server"}')).toMatchObject({
      ok: false,
      why: expect.stringContaining('no name'),
    })
    expect(readToolFile('{"kind":"mcp-server","name":"a"}')).toMatchObject({
      ok: false,
      why: expect.stringContaining('no command'),
    })
    expect(readToolFile('{"kind":"mcp-server","name":"a","transport":"http"}')).toMatchObject({
      ok: false,
      why: expect.stringContaining('no URL'),
    })
  })

  it('drops a value somebody hand-wrote into the env list', () => {
    /*
     * Somebody editing an exported file will eventually put a value there, and
     * the choice is between carrying it into the form — where it becomes a
     * secret that travelled in a file, which is the thing this format exists not
     * to do — and dropping it, which costs one retype.
     */
    const read = readToolFile(
      JSON.stringify({ kind: 'mcp-server', name: 'a', command: 'npx a', env: ['API_KEY=hunter2'] }),
    )
    expect(read.ok).toBe(true)
    if (!read.ok) return
    expect(read.draft.env).toEqual(['API_KEY'])
  })

  it('narrows everything rather than trusting it', () => {
    // This file arrived from outside — mailed, downloaded, pulled out of a
    // repository — and the only reason its blast radius is "the form is wrong"
    // is that nothing here is cast.
    const read = readToolFile(
      JSON.stringify({ kind: 'mcp-server', name: 'a', command: 'npx a', transport: 42, env: 'nope' }),
    )
    expect(read.ok).toBe(true)
    if (!read.ok) return
    expect(read.draft.transport).toBe('stdio')
    expect(read.draft.env).toEqual([])
  })
})
