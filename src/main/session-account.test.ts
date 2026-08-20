import { describe, expect, it } from 'vitest'
import {
  agentUnder,
  environmentValue,
  environmentWasRead,
  parseProcessTable,
} from './session-account'

/**
 * Reading a session's login off the running process, rather than assuming it.
 *
 * The fixtures are transcribed from this Mac, because every one of them encodes
 * something that would otherwise be guessed at. The commands, so they can be
 * re-run:
 *
 *     $ ps -Ao pid=,ppid=,command= | grep claude
 *      2471   850 claude
 *       850   837 -zsh
 *     $ ps eww -p 2471 | tr ' ' '\n' | grep -c '='
 *     28
 *     $ env CLAUDE_CONFIG_DIR=/tmp/fake-cfg node -e '…' &
 *     $ ps eww -p $! | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR
 *     CLAUDE_CONFIG_DIR=/tmp/fake-cfg
 *
 * The ladder itself — spawn record, then process environment — is exercised
 * through `accountFor` in `usage-ipc.test.ts`, which is where its consequences
 * are actually visible. What is pinned here is the reading, because a parser
 * that is quietly wrong about an environment produces a confident wrong account
 * name, which is the failure this whole module was written to stop.
 */

const TABLE = [
  ' 2471   850 claude',
  '  850   837 -zsh',
  '  837   740 login -pfl apple /bin/bash -c exec -la zsh /bin/zsh',
  '  740     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal',
  '57565 57205 claude --session-id e90c48be-c4e5-4c6b-9e09-ffb2ff05193d',
  '57205 57200 /Users/apple/Projects/terminaldeck/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron .',
].join('\n')

describe('the process table', () => {
  it('parses pid, parent and the whole command line', () => {
    const rows = parseProcessTable(TABLE)
    expect(rows).toHaveLength(6)
    expect(rows[0]).toEqual({ pid: 2471, ppid: 850, command: 'claude' })
    // The command keeps its arguments: the session id on it is how a reader
    // tells a session this app named from one it did not.
    expect(rows[4]?.command).toContain('--session-id')
  })

  it('ignores a header line or anything else that is not a row', () => {
    expect(parseProcessTable('  PID  PPID COMMAND\n\n  not a row\n 12 3 sh')).toEqual([
      { pid: 12, ppid: 3, command: 'sh' },
    ])
  })
})

describe('finding the agent under a session', () => {
  /*
   * The whole reason the table is walked rather than the pty's child inspected.
   * In Terminal the agent is a child of the login shell, which is a child of
   * `login`, which is a child of Terminal itself — three levels from the thing
   * that owns the window.
   */
  it('finds an agent that is a grandchild rather than a child', () => {
    const rows = parseProcessTable(TABLE)
    expect(agentUnder(rows, 740, ['claude'])?.pid).toBe(2471)
  })

  it('matches on the basename, so a path and a bare name are one agent', () => {
    const rows = parseProcessTable(' 10 1 /opt/homebrew/bin/claude --session-id x')
    expect(agentUnder(rows, 1, ['claude'])?.pid).toBe(10)
  })

  it('answers null when nothing under the session is an agent', () => {
    const rows = parseProcessTable(TABLE)
    // A shell with nothing running in it. There is no login to name, and this
    // is the case that must not fall through to the machine's default.
    expect(agentUnder(rows, 850, ['codex'])).toBeNull()
  })
})

describe('reading one variable out of `ps eww`', () => {
  const DUMP =
    '  PID   TT  STAT      TIME COMMAND\n' +
    ' 2471 s001  S+     0:12.34 claude --session-id abc ' +
    'PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR=/Users/apple/.claude-work ' +
    'HOME=/Users/apple SHELL=/bin/zsh\n'

  it('reads the value up to the next variable, not to the next space', () => {
    expect(environmentValue(DUMP, 'CLAUDE_CONFIG_DIR')).toBe('/Users/apple/.claude-work')
    expect(environmentValue(DUMP, 'HOME')).toBe('/Users/apple')
  })

  it('keeps a value that contains spaces', () => {
    const dump = 'x CLAUDE_CONFIG_DIR=/Users/apple/My Claude/cfg HOME=/Users/apple\n'
    expect(environmentValue(dump, 'CLAUDE_CONFIG_DIR')).toBe('/Users/apple/My Claude/cfg')
  })

  /*
   * `ps eww` prints the command line and the environment with nothing between
   * them, so an argument that happens to be spelled `NAME=value` is
   * indistinguishable from a variable — except by position, because the
   * environment comes last.
   */
  it('prefers the environment over an argument that looks like one', () => {
    const dump = 'sh -c CLAUDE_CONFIG_DIR=/decoy claude PATH=/bin CLAUDE_CONFIG_DIR=/real\n'
    expect(environmentValue(dump, 'CLAUDE_CONFIG_DIR')).toBe('/real')
  })

  it('answers null for a variable that is not there', () => {
    expect(environmentValue(DUMP, 'CODEX_HOME')).toBeNull()
  })

  /*
   * The one that decides whether an *absence* may be believed.
   *
   * macOS scrubs the environment of a SIP-protected binary, so `ps eww` against
   * `/bin/sleep` exits zero and prints a command line and nothing else — checked
   * on this machine. A reader treating that as "the variable is unset" would
   * then report the default account for a process whose environment it never
   * saw, which is precisely the wrong answer this module exists to stop.
   */
  it('knows an environment that was scrubbed from one that was read', () => {
    expect(environmentWasRead(DUMP)).toBe(true)
    expect(environmentWasRead('  PID   TT  STAT      TIME COMMAND\n69371   ??  SN  0:00.01 sleep 8\n')).toBe(
      false,
    )
  })
})
