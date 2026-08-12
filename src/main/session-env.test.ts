import { describe, expect, it } from 'vitest'
import { stripInheritedSessionEnv } from './session-env'

/**
 * The fixture is the real inherited set, read off a running copy of this app
 * that had been launched from inside an agent session. Every name here was
 * observed, not imagined.
 */
const INHERITED = {
  CLAUDECODE: '1',
  CLAUDE_AGENT_SDK_VERSION: '0.4.2',
  CLAUDE_CODE_CHILD_SESSION: '1',
  CLAUDE_CODE_DISABLE_CRON: '1',
  CLAUDE_CODE_EAGER_FLUSH: '1',
  CLAUDE_CODE_ENTRYPOINT: 'cli',
  CLAUDE_CODE_EXECPATH: '/usr/local/bin/claude',
  CLAUDE_CODE_HOST_SESSION_ID: 'abc-123',
  CLAUDE_CODE_SESSION_ID: 'def-456',
  CLAUDE_EFFORT: 'xhigh',
  CLAUDE_PID: '4242',
  CLAUDE_PREVIEW_CLASSIFIER_FLOOR: '0.5',
  // The user's own configuration, which must survive.
  ANTHROPIC_API_KEY: 'sk-ant-not-a-real-key',
  ANTHROPIC_BASE_URL: 'https://api.anthropic.com',
  CLAUDE_CONFIG_DIR: '/Users/x/.claude-work',
  PATH: '/usr/bin',
  HOME: '/Users/x',
}

describe('stripInheritedSessionEnv', () => {
  const clean = stripInheritedSessionEnv(INHERITED, 'TERMINALDECK_SESSION_ID')

  it('removes the marker that turns transcript saving off', () => {
    // The whole reason this file exists: chat mode and cost both read the
    // JSONL transcripts, and this one variable stops them being written.
    expect(clean.CLAUDE_CODE_CHILD_SESSION).toBeUndefined()
  })

  it('removes every marker identifying the parent run', () => {
    const leaked = Object.keys(clean).filter((k) => /^(CLAUDECODE|CLAUDE_PID|CLAUDE_CODE_|CLAUDE_AGENT_SDK|CLAUDE_PREVIEW_)/.test(k))
    expect(leaked.filter((k) => k !== 'CLAUDE_CONFIG_DIR')).toEqual([])
  })

  it('removes CLAUDE_EFFORT, which would pin effort for the whole session', () => {
    // A session launched with an effort pin answers "Not applied: the
    // launch-effort pin holds effort at X this session" — so the effort
    // control would be dead through no fault of its own.
    expect(clean.CLAUDE_EFFORT).toBeUndefined()
  })

  it('keeps CLAUDE_CONFIG_DIR, which profiles set deliberately', () => {
    expect(clean.CLAUDE_CONFIG_DIR).toBe('/Users/x/.claude-work')
  })

  it("keeps the user's own Anthropic configuration", () => {
    expect(clean.ANTHROPIC_API_KEY).toBe('sk-ant-not-a-real-key')
    expect(clean.ANTHROPIC_BASE_URL).toBe('https://api.anthropic.com')
  })

  it('keeps everything unrelated', () => {
    expect(clean.PATH).toBe('/usr/bin')
    expect(clean.HOME).toBe('/Users/x')
  })

  it('drops our own session marker inherited from a parent copy', () => {
    const nested = stripInheritedSessionEnv(
      { TERMINALDECK_SESSION_ID: 'outer', HOME: '/Users/x' },
      'TERMINALDECK_SESSION_ID',
    )
    expect(nested.TERMINALDECK_SESSION_ID).toBeUndefined()
    expect(nested.HOME).toBe('/Users/x')
  })

  it('drops undefined values rather than passing them through as "undefined"', () => {
    const out = stripInheritedSessionEnv({ A: undefined, B: 'b' }, 'X')
    expect('A' in out).toBe(false)
    expect(out.B).toBe('b')
  })
})
