import { normalize } from 'node:path'
import { describe, expect, it } from 'vitest'
import { addMcpServer, buildAddArgs, resolveRequest, tokenizeCommand, type McpAddRequest } from './mcp-add'

/**
 * The command this builds is never seen by anyone.
 *
 * That is what makes it worth pinning. Every mistake available here is silent:
 * a scope flag that goes to the wrong place writes a server into a file nobody
 * reads, a missing `--` feeds the MCP server's own `-y` to the CLI's argument
 * parser, and a mis-tokenised path drops half a command. In all three the CLI
 * exits 0 and the panel says it worked — which is exactly the failure shape
 * (every layer reporting success while nothing happened) that the notification
 * work next door was written to stamp out.
 */

function request(overrides: Partial<McpAddRequest> = {}): McpAddRequest {
  return {
    name: 'files',
    scope: 'user',
    transport: 'stdio',
    command: 'npx -y @modelcontextprotocol/server-filesystem /tmp',
    url: '',
    extras: [],
    projectPath: null,
    ...overrides,
  }
}

describe('tokenizeCommand', () => {
  it('splits a plain command line', () => {
    expect(tokenizeCommand('npx -y server-filesystem /tmp')).toEqual([
      'npx',
      '-y',
      'server-filesystem',
      '/tmp',
    ])
  })

  it('keeps a quoted path with a space in one piece', () => {
    // The reason this function exists rather than `line.split(' ')`. On macOS
    // most interesting folders have a space in them.
    expect(tokenizeCommand('npx server "/Users/me/My Folder"')).toEqual([
      'npx',
      'server',
      '/Users/me/My Folder',
    ])
    expect(tokenizeCommand("npx server '/Users/me/My Folder'")).toEqual([
      'npx',
      'server',
      '/Users/me/My Folder',
    ])
  })

  it('treats single quotes as literal, the way a shell does', () => {
    expect(tokenizeCommand(`echo '\\n not an escape'`)).toEqual(['echo', '\\n not an escape'])
  })

  it('honours escapes outside quotes and \\" inside them', () => {
    expect(tokenizeCommand('server /Users/me/My\\ Folder')).toEqual(['server', '/Users/me/My Folder'])
    expect(tokenizeCommand('server "say \\"hi\\""')).toEqual(['server', 'say "hi"'])
  })

  it('keeps an explicitly empty argument', () => {
    expect(tokenizeCommand('server --flag ""')).toEqual(['server', '--flag', ''])
  })

  it('collapses runs of whitespace rather than emitting blanks', () => {
    expect(tokenizeCommand('  npx   \t server  ')).toEqual(['npx', 'server'])
    expect(tokenizeCommand('   ')).toEqual([])
  })

  it('refuses an unclosed quote instead of guessing which half was meant', () => {
    expect(() => tokenizeCommand('npx "unterminated')).toThrow(/unclosed quote/i)
  })
})

describe('buildAddArgs', () => {
  it('puts the command behind -- so its own flags survive', () => {
    // Without the separator, `-y` is read by the CLI's parser instead of being
    // handed to npx, and the server is added with a mangled command.
    const args = buildAddArgs(request())
    expect(args).toEqual([
      'mcp',
      'add',
      '--scope',
      'user',
      'files',
      '--',
      'npx',
      '-y',
      '@modelcontextprotocol/server-filesystem',
      '/tmp',
    ])
    expect(args.indexOf('--')).toBeLessThan(args.indexOf('-y'))
  })

  it('names the transport and passes a url straight through', () => {
    expect(buildAddArgs(request({ transport: 'http', command: '', url: 'https://x/mcp' }))).toEqual([
      'mcp',
      'add',
      '--scope',
      'user',
      '--transport',
      'http',
      'files',
      'https://x/mcp',
    ])
  })

  /**
   * The regression that a reading of `--help` does not catch.
   *
   * `-e, --env <env...>` and `-H, --header <header...>` are variadic. Built the
   * obvious way — all options first — the real CLI answered "Invalid
   * environment variable format: files", because `-e` had eaten the server's
   * name. Both of these pin the positional against the flag that can swallow it.
   */
  it('keeps the name out of reach of the variadic -e', () => {
    const args = buildAddArgs(request({ extras: ['API_KEY=abc'] }))
    expect(args.indexOf('files')).toBeLessThan(args.indexOf('-e'))
    // And `--` still terminates the list before the command begins.
    expect(args.indexOf('-e')).toBeLessThan(args.indexOf('--'))
  })

  it('keeps the url out of reach of the variadic -H', () => {
    const args = buildAddArgs(
      request({ transport: 'http', command: '', url: 'https://x/mcp', extras: ['A: b'] }),
    )
    expect(args.indexOf('https://x/mcp')).toBeLessThan(args.indexOf('-H'))
  })

  it('carries the scope the user picked', () => {
    expect(buildAddArgs(request({ scope: 'project', projectPath: '/work/app' }))).toContain('project')
    expect(buildAddArgs(request({ scope: 'local', projectPath: '/work/app' })).slice(0, 4)).toEqual([
      'mcp',
      'add',
      '--scope',
      'local',
    ])
  })

  it('sends environment variables as -e and headers as -H', () => {
    expect(buildAddArgs(request({ extras: ['API_KEY=abc'] }))).toContain('-e')
    const http = buildAddArgs(
      request({ transport: 'http', command: '', url: 'https://x/mcp', extras: ['Authorization: Bearer t'] }),
    )
    expect(http).toContain('-H')
    expect(http).toContain('Authorization: Bearer t')
  })

  it('puts the single-value options before the name, where they are safe', () => {
    // `--scope` and `--transport` take exactly one value, so unlike -e and -H
    // they cannot reach past it.
    const args = buildAddArgs(request({ transport: 'sse', command: '', url: 'https://x/sse', extras: ['A: b'] }))
    const name = args.indexOf('files')
    expect(args.indexOf('--scope')).toBeLessThan(name)
    expect(args.indexOf('--transport')).toBeLessThan(name)
    expect(args.indexOf('-H')).toBeGreaterThan(name)
  })
})

describe('resolveRequest', () => {
  it('rejects a name that could impersonate a flag', () => {
    // Not a quoting problem — nothing here goes through a shell. A positional
    // argument beginning with `-` is read by the CLI's own parser as an option,
    // so `--scope` typed into the name box would rewrite the command.
    expect(() => resolveRequest({ ...request(), name: '--scope' })).toThrow(/name may use letters/i)
    expect(() => resolveRequest({ ...request(), name: '-x' })).toThrow()
    expect(() => resolveRequest({ ...request(), name: '' })).toThrow(/name/i)
  })

  it('accepts the names people actually use', () => {
    for (const name of ['files', 'my-server', 'server_2', 'a.b']) {
      expect(resolveRequest({ ...request(), name }).name).toBe(name)
    }
  })

  it('refuses a project-shaped scope when there is no project', () => {
    // This is the one that would otherwise pass silently: `local` and `project`
    // are addressed by the working directory, so without one the CLI would
    // cheerfully file the server under whatever folder the app happened to be
    // running in and exit 0.
    for (const scope of ['local', 'project'] as const) {
      expect(() => resolveRequest({ ...request(), scope, projectPath: null })).toThrow(/open a project/i)
    }
    expect(resolveRequest({ ...request(), scope: 'local', projectPath: '/work/app' }).scope).toBe('local')
  })

  it('requires the field belonging to the chosen transport', () => {
    expect(() => resolveRequest({ ...request(), command: '' })).toThrow(/command/i)
    expect(() => resolveRequest({ ...request(), transport: 'http', command: '', url: '' })).toThrow(/URL/i)
  })

  it('refuses an unknown scope or transport rather than defaulting to one', () => {
    expect(() => resolveRequest({ ...request(), scope: 'global' })).toThrow(/where to save/i)
    expect(() => resolveRequest({ ...request(), transport: 'grpc' })).toThrow(/how the server is reached/i)
  })

  it('checks that extras are written the way their flag expects', () => {
    expect(() => resolveRequest({ ...request(), extras: ['API_KEY'] })).toThrow(/KEY=value/)
    expect(() =>
      resolveRequest({ ...request(), transport: 'http', command: '', url: 'https://x', extras: ['nope'] }),
    ).toThrow(/Name: value/)
  })

  it('drops blank lines from the extras box instead of sending empty flags', () => {
    expect(resolveRequest({ ...request(), extras: ['A=1', '   ', ''] }).extras).toEqual(['A=1'])
  })

  it('is not fooled by a payload that is not an object', () => {
    for (const bad of [null, undefined, 'add it', 42]) {
      expect(() => resolveRequest(bad)).toThrow()
    }
  })
})

describe('addMcpServer', () => {
  const path = async (): Promise<string> => '/usr/bin:/bin'

  it('runs the CLI in the project folder, because two scopes are addressed by it', async () => {
    let sawCwd = ''
    let sawArgs: string[] = []
    const result = await addMcpServer(
      { ...request(), scope: 'local', projectPath: '/work/app' },
      {
        path,
        exec: async (_file, args, options) => {
          sawCwd = options.cwd
          sawArgs = args
          return { stdout: 'Added stdio MCP server files to local config', stderr: '' }
        },
      },
    )
    expect(result.ok).toBe(true)
    /*
     * `normalize`, not the literal, and the difference only shows on Windows.
     *
     * `resolveRequest` canonicalises the project path for the machine it is
     * running on — that is correct, because this path is a real folder on that
     * machine and the CLI is about to be run in it. On Windows `normalize`
     * rewrites separators, so `/work/app` legitimately becomes `\work\app` and
     * the literal here failed the CI release build.
     *
     * The assertion that matters is "the CLI was run in the folder we were
     * given", not "the string survived byte for byte", so it is written that
     * way. On POSIX this is still exactly `/work/app`.
     */
    expect(sawCwd).toBe(normalize('/work/app'))
    expect(sawArgs).toContain('local')
    // The CLI's own words, not ours: it is the only thing that knows which file
    // it actually wrote.
    expect(result.message).toContain('local config')
  })

  it('reports a refusal from the CLI instead of claiming success', async () => {
    const result = await addMcpServer(request(), {
      path,
      exec: async () => {
        // execFile attaches the child's output to the error, not to the throw
        // site. Reading only `message` here turns a CLI that explained itself
        // into a bare "Command failed" — the same shape that once hid a
        // Tailscale prompt behind a fifteen-second hang.
        throw Object.assign(new Error('Command failed'), {
          stderr: 'A server named files already exists in user config',
          stdout: '',
        })
      },
    })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('already exists')
  })

  it('names the missing CLI rather than reporting a bare ENOENT', async () => {
    const result = await addMcpServer(request(), {
      path,
      exec: async () => {
        throw Object.assign(new Error('spawn claude ENOENT'), { code: 'ENOENT' })
      },
    })
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/command line tool could not be found/i)
  })

  it('turns a validation failure into a sentence, never a rejection', async () => {
    // The Add button's failure mode must be text under the form. An unhandled
    // rejection here is a dead click, which is the bug class this repo keeps
    // paying for.
    let ran = false
    const result = await addMcpServer({ ...request(), name: '' }, {
      path,
      exec: async () => {
        ran = true
        return { stdout: '', stderr: '' }
      },
    })
    expect(result.ok).toBe(false)
    expect(ran).toBe(false)
    expect(result.message).toMatch(/name/i)
  })

  it('hands the child one spelling of PATH, holding the login value', async () => {
    // This shipped as `{ ...process.env, PATH: path }` and `platform/env-path.
    // test.ts` caught it. That literal is correct here and silently wrong on
    // Windows, where the inherited variable is spelled `Path`: the spread
    // carries `Path` in, the key writes `PATH` beside it, and the child holds
    // two of them with no rule about which it reads — so the login PATH this
    // function went to the trouble of resolving is the one that gets ignored,
    // on the only platform none of us can check by running it.
    //
    // Asserting on the *count* rather than on the literal key is what makes
    // this test mean the same thing on both platforms: whatever this OS calls
    // the variable, there is exactly one of it and it holds what we resolved.
    let sawEnv: NodeJS.ProcessEnv = {}
    await addMcpServer(request(), {
      path,
      exec: async (_file, _args, options) => {
        sawEnv = options.env
        return { stdout: '', stderr: '' }
      },
    })
    const spellings = Object.keys(sawEnv).filter((key) => /^path$/i.test(key))
    expect(spellings).toHaveLength(1)
    expect(sawEnv[spellings[0]]).toBe('/usr/bin:/bin')
    // The rest of the environment still travels — the CLI reads HOME to find
    // ~/.claude.json, so dropping it would file a `user` server nowhere.
    expect(Object.keys(sawEnv).length).toBeGreaterThan(1)
  })

  it('still confirms when the CLI succeeds without saying anything', async () => {
    const result = await addMcpServer(request(), {
      path,
      exec: async () => ({ stdout: '', stderr: '' }),
    })
    expect(result).toEqual({ ok: true, message: 'Added files.' })
  })
})
