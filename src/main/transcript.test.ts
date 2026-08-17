import { appendFileSync, mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { promptTokens } from './cost'
import {
  claudeConfigDir,
  configDirs,
  configDirsFor,
  encodeProjectPath,
  homeScopes,
  installDeviceHomes,
  installHomeScopes,
  isTranscriptPath,
  listTranscripts,
  parseEventLine,
  parseUsage,
  resetDeviceHomes,
  resetHomeScopes,
  SessionAggregator,
  transcriptDir,
  transcriptDirs,
  UNKNOWN_MODEL,
} from './transcript'

/**
 * The two halves of `encodeProjectPath` split cleanly by how portable they are.
 *
 * The character rewrite is the same rule everywhere. `resolve`, which runs
 * first, is not: a macOS fixture is only *drive-relative* on Windows, so
 * `/Users/apple/ClaudeAsad` resolves to `C:\Users\apple\ClaudeAsad` there and
 * encodes to `C--Users-apple-ClaudeAsad` (observed on Windows 11). That is the
 * right answer for that machine and the wrong fixture for it, and there is no
 * way to pin both platforms in one run the way `platform/host.ts` allows —
 * `resolve` reads the host rather than an argument.
 *
 * So the fixtures are split by platform, and each side was read off real
 * `.claude/projects` directories rather than derived from the rule being
 * tested: the macOS ones from this Mac, the Windows ones from
 * `C:\Users\Imza\.claude\projects`.
 */
const ON_WINDOWS = process.platform === 'win32'

describe('encodeProjectPath', () => {
  // Every case below was checked against a real directory in
  // ~/.claude/projects and the `cwd` recorded inside that transcript.
  it.skipIf(ON_WINDOWS)('replaces separators with hyphens', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeAsad')).toBe('-Users-apple-ClaudeAsad')
    expect(encodeProjectPath('/Users/apple/Projects/terminaldeck')).toBe('-Users-apple-Projects-terminaldeck')
  })

  it.skipIf(ON_WINDOWS)('collapses a dot-directory into a double hyphen', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeImza/.claude/worktrees/focused-lumiere-5424d6')).toBe(
      '-Users-apple-ClaudeImza--claude-worktrees-focused-lumiere-5424d6',
    )
  })

  it.skipIf(ON_WINDOWS)('rewrites every non-alphanumeric character, including tildes and spaces', () => {
    expect(
      encodeProjectPath(
        '/Users/apple/Library/Mobile Documents/com~apple~CloudDocs/OpenClaw/workspace',
      ),
    ).toBe('-Users-apple-Library-Mobile-Documents-com-apple-CloudDocs-OpenClaw-workspace')
  })

  it.skipIf(!ON_WINDOWS)('turns a drive letter into its own leading segment', () => {
    // `I:\Claude Temp` is a directory that exists on that machine as
    // `I--Claude-Temp`: the colon and the backslash each become a hyphen, so a
    // drive-rooted path never starts with the single hyphen a POSIX one does.
    expect(encodeProjectPath('I:\\Claude Temp')).toBe('I--Claude-Temp')
  })

  it.skipIf(!ON_WINDOWS)('keeps a UNC path addressable, both slashes and all', () => {
    // Read off that machine with its transcript's own `cwd` field beside it:
    // cwd `\\wsl.localhost\Ubuntu-24.04\home\asad\Claude Temporary` is stored
    // in `--wsl-localhost-Ubuntu-24-04-home-asad-Claude-Temporary`. Both
    // leading backslashes survive as hyphens, and the dots in the distro
    // version are rewritten like any other non-alphanumeric.
    expect(encodeProjectPath('\\\\wsl.localhost\\Ubuntu-24.04\\home\\asad\\Claude Temporary')).toBe(
      '--wsl-localhost-Ubuntu-24-04-home-asad-Claude-Temporary',
    )
  })

  it('normalises a trailing slash away', () => {
    expect(encodeProjectPath('/Users/apple/ClaudeAsad/')).toBe(
      encodeProjectPath('/Users/apple/ClaudeAsad'),
    )
  })

  it('is lossy — distinct paths can collide, so never decode a directory name', () => {
    expect(encodeProjectPath('/a/b')).toBe(encodeProjectPath('/a.b'))
  })
})

describe('transcriptDir', () => {
  const original = process.env.CLAUDE_CONFIG_DIR
  afterEach(() => {
    if (original === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = original
  })

  /**
   * A cwd that is already absolute on this platform, and the directory name it
   * encodes to. The Windows fixtures name their drive rather than relying on
   * `resolve` to supply one: a bare `/x` would pick up whichever drive the
   * suite happens to be running from — `C:` on the machine this was ported on,
   * `D:` on a GitHub Windows runner, which checks out to `D:\a`.
   */
  const CWD = ON_WINDOWS ? 'I:\\Claude Temp' : '/Users/apple/ClaudeAsad'
  const ENCODED = ON_WINDOWS ? 'I--Claude-Temp' : '-Users-apple-ClaudeAsad'

  it('lives under <config>/projects', () => {
    // `join` on both sides, because the answer carries the host's separator and
    // the claim being made is about the shape, not about the slash.
    expect(transcriptDir(CWD, '/tmp/cfg')).toBe(join('/tmp/cfg', 'projects', ENCODED))
  })

  it('honours CLAUDE_CONFIG_DIR, which is how Claude profiles stay isolated', () => {
    process.env.CLAUDE_CONFIG_DIR = '/tmp/work-profile'
    expect(claudeConfigDir()).toBe('/tmp/work-profile')
    expect(transcriptDir(CWD)).toBe(join('/tmp/work-profile', 'projects', ENCODED))
  })

  it('ignores an empty override', () => {
    process.env.CLAUDE_CONFIG_DIR = '   '
    expect(claudeConfigDir()).toMatch(/\.claude$/)
  })
})

/**
 * Where a confined session's transcripts actually are.
 *
 * A session started from a paired device is held inside its granted folder, and
 * the account's home is outside that boundary — so the session runs with a
 * `HOME` of its own and the CLI follows it. Measured with the real Claude Code
 * (2.1.233) on this machine rather than reasoned about:
 *
 *     HOME=/tmp/homeprobe claude config ls
 *       → /tmp/homeprobe/.claude.json          (config, one level up)
 *       → /tmp/homeprobe/.claude/projects/…    (transcripts, here)
 *
 * The consequence, and the reason this block exists: chat mode, the cost pane,
 * alerts and the agent controls all read `~/.claude` and found nothing for a
 * session that was talking. None of them was wrong; they were reading the right
 * directory for the wrong home.
 */
describe('the stores a project can have', () => {
  afterEach(() => {
    resetDeviceHomes()
    resetHomeScopes()
  })

  /** A device-homes root with the given devices in it, each with a store. */
  function homes(devices: Record<string, string[]>): string {
    const root = mkdtempSync(join(tmpdir(), 'device-homes-'))
    for (const [key, projects] of Object.entries(devices)) {
      // `tmp` as well, because the real `prepareDeviceHome` makes one — it is
      // the session's `TMPDIR` — and it must never be mistaken for a store.
      mkdirSync(join(root, key, 'tmp'), { recursive: true })
      for (const project of projects) {
        mkdirSync(join(root, key, '.claude', 'projects', encodeProjectPath(project)), {
          recursive: true,
        })
      }
    }
    return root
  }

  const PROJECT = ON_WINDOWS ? 'I:\\Claude Temp' : '/Users/apple/ClaudeAsad'

  it('is just the profile store when no device has ever run one', () => {
    // The ordinary machine, and every unit test: nothing installed, so nothing
    // extra. A missing *extra* store must never disturb the one that works.
    expect(configDirs({ configDir: '/tmp/cfg', deviceHomes: null })).toEqual(['/tmp/cfg'])
    expect(transcriptDirs(PROJECT, { configDir: '/tmp/cfg', deviceHomes: null })).toEqual([
      transcriptDir(PROJECT, '/tmp/cfg'),
    ])
  })

  it('adds one store per device home, with the profile first', () => {
    const root = homes({ 'dev-a': [PROJECT], 'dev-b': [PROJECT] })
    const dirs = configDirs({ configDir: '/tmp/cfg', deviceHomes: root })
    // Profile first, because it is the answer for nearly everything and a
    // reader that stops at the first hit must stop at the right one.
    expect(dirs[0]).toBe('/tmp/cfg')
    expect(dirs.slice(1).sort()).toEqual(
      [join(root, 'dev-a', '.claude'), join(root, 'dev-b', '.claude')].sort(),
    )
  })

  it('skips a home whose agent has never run, rather than naming an empty path', () => {
    // A device home exists from the moment that device first starts a session;
    // its `.claude` exists only once an agent has actually written something. A
    // watcher subscribing to a directory that will never hold a transcript is a
    // rule nobody can later evaluate against reality.
    const root = homes({ 'dev-a': [PROJECT], 'dev-fresh': [] })
    const dirs = configDirs({ configDir: '/tmp/cfg', deviceHomes: root })
    expect(dirs).toEqual(['/tmp/cfg', join(root, 'dev-a', '.claude')])
  })

  it('survives a device-homes root that is not there', () => {
    // The first launch after an update, and every machine where nobody has
    // paired anything. Failing the whole read here would take the owner's own
    // transcripts down with a directory that has never been needed.
    const root = join(mkdtempSync(join(tmpdir(), 'device-homes-')), 'never-made')
    expect(configDirs({ configDir: '/tmp/cfg', deviceHomes: root })).toEqual(['/tmp/cfg'])
  })

  it('reads the homes again on every call, so a device paired since is seen', () => {
    // Deliberately not cached. The list changes when a device is paired and its
    // first session runs, which is not an event this module hears about — a
    // cache would mean the app cannot see a session until it is restarted.
    const root = mkdtempSync(join(tmpdir(), 'device-homes-'))
    installDeviceHomes(root)
    expect(configDirs({ configDir: '/tmp/cfg' })).toEqual(['/tmp/cfg'])

    mkdirSync(join(root, 'dev-new', '.claude', 'projects'), { recursive: true })
    expect(configDirs({ configDir: '/tmp/cfg' })).toEqual([
      '/tmp/cfg',
      join(root, 'dev-new', '.claude'),
    ])
  })

  it('encodes the project the same way in every store', () => {
    const root = homes({ 'dev-a': [PROJECT] })
    const dirs = transcriptDirs(PROJECT, { configDir: '/tmp/cfg', deviceHomes: root })
    for (const dir of dirs) expect(dir.endsWith(encodeProjectPath(PROJECT))).toBe(true)
    expect(dirs).toHaveLength(2)
  })

  /**
   * One of those homes belongs to an agent, and that is a different question.
   *
   * A paired device's home is writable by sessions the person started, in
   * folders they granted. The copilot's home is in the same root — deliberately,
   * because that is what makes its own conversation visible to every reader —
   * but nobody paired it, it has no write access to any project, and its job is
   * to report on *other* sessions. So the one directory it can write was a way
   * to publish a conversation under any project's name.
   *
   * `copilot-transcript-forgery.test.ts` proves the write really happens inside
   * the real Seatbelt profile and then asks the readers. These are the same rule
   * at the unit it lives in.
   */
  const COPILOT = ON_WINDOWS ? 'I:\\copilot' : '/fake/user-data/copilot'
  const OTHER = ON_WINDOWS ? 'I:\\Someone Else' : '/fake/someone-else'

  it('consults a scoped home for its own folder and no other', () => {
    const root = homes({ copilot: [COPILOT, OTHER], 'dev-a': [OTHER] })
    const scope = {
      configDir: '/tmp/cfg',
      deviceHomes: root,
      homeScopes: [{ home: join(root, 'copilot'), folder: COPILOT }],
    }

    // Its own conversation: found, exactly as before.
    expect(transcriptDirs(COPILOT, scope)).toContain(
      join(root, 'copilot', '.claude', 'projects', encodeProjectPath(COPILOT)),
    )
    // A conversation it wrote under somebody else's project: never looked for.
    expect(transcriptDirs(OTHER, scope)).not.toContain(
      join(root, 'copilot', '.claude', 'projects', encodeProjectPath(OTHER)),
    )
  })

  it('leaves every unscoped home answering for every project', () => {
    // The half that must not move. A phone's session writes into that phone's
    // own home, and the desktop reading it is the entire reason this function
    // answers with a list.
    const root = homes({ copilot: [OTHER], 'dev-a': [OTHER] })
    const dirs = transcriptDirs(OTHER, {
      configDir: '/tmp/cfg',
      deviceHomes: root,
      homeScopes: [{ home: join(root, 'copilot'), folder: COPILOT }],
    })
    expect(dirs).toContain(join(root, 'dev-a', '.claude', 'projects', encodeProjectPath(OTHER)))
    expect(dirs).toContain(join('/tmp/cfg', 'projects', encodeProjectPath(OTHER)))
  })

  it('changes nothing at all when no scope has been installed', () => {
    // The default on any machine with no copilot, and in every test that has
    // not said otherwise. Absence of a scope must never mean absence of a store.
    const root = homes({ 'dev-a': [PROJECT] })
    expect(transcriptDirs(PROJECT, { configDir: '/tmp/cfg', deviceHomes: root, homeScopes: [] })).toEqual(
      transcriptDirs(PROJECT, { configDir: '/tmp/cfg', deviceHomes: root }),
    )
  })

  it('is read from the installed list when the caller does not pass one', () => {
    const root = homes({ copilot: [COPILOT, OTHER] })
    installDeviceHomes(root)
    installHomeScopes([{ home: join(root, 'copilot'), folder: COPILOT }])

    expect(transcriptDirs(OTHER, { configDir: '/tmp/cfg' })).toEqual([
      join('/tmp/cfg', 'projects', encodeProjectPath(OTHER)),
    ])
    expect(homeScopes()).toHaveLength(1)
  })

  it('still narrows when the folder is spelled with a trailing separator', () => {
    // `installHomeScopes` resolves what it is given and `configDirsFor` resolves
    // what it is asked, because the two sides are composed in different modules
    // — and a rule that stops applying because somebody wrote `foo/` instead of
    // `foo` is a rule that fails open and silently.
    const root = homes({ copilot: [COPILOT, OTHER] })
    const scope = {
      configDir: '/tmp/cfg',
      deviceHomes: root,
      homeScopes: [{ home: `${join(root, 'copilot')}${sep}`, folder: `${COPILOT}${sep}` }],
    }
    expect(transcriptDirs(OTHER, scope)).toHaveLength(1)
    expect(transcriptDirs(COPILOT, scope)).toHaveLength(2)
  })

  it('answers the same for configDirsFor as for the dirs it produces', () => {
    // They are one function with a `join` between them, and the watcher uses
    // the first to decide what to *subscribe* to while the readers use the
    // second to decide what to *list*. Two answers there would leave a watch
    // live on a store nothing reads — which is how a fabricated file gets
    // enqueued by a change event after being left out of the listing.
    const root = homes({ copilot: [COPILOT, OTHER], 'dev-a': [OTHER] })
    const scope = {
      configDir: '/tmp/cfg',
      deviceHomes: root,
      homeScopes: [{ home: join(root, 'copilot'), folder: COPILOT }],
    }
    for (const project of [COPILOT, OTHER, PROJECT]) {
      expect(transcriptDirs(project, scope), project).toEqual(
        configDirsFor(project, scope).map((dir) => join(dir, 'projects', encodeProjectPath(project))),
      )
    }
  })
})

/**
 * The guard behind `chat:load` and `cost:session`, which take a path from the
 * renderer and read whatever file it names.
 *
 * It lives here because there stopped being one store: the same rule had been
 * written out three times — in `cost-ipc.ts`, `chat-transcript.ts` and
 * `session-insights.ts` — each saying "under `~/.claude/projects`", and widening
 * three copies by hand is three chances for one of them to widen the wrong way.
 * The wrong way here is an arbitrary file read reachable from page code.
 */
describe('isTranscriptPath', () => {
  afterEach(() => resetDeviceHomes())

  const CFG = ON_WINDOWS ? 'I:\\cfg' : '/tmp/cfg'
  const inside = join(CFG, 'projects', 'enc', 'sess.jsonl')

  it('accepts a transcript in the profile store', () => {
    expect(isTranscriptPath(inside, { configDir: CFG, deviceHomes: null })).toBe(true)
  })

  it('accepts one in a confined session own store', () => {
    const root = mkdtempSync(join(tmpdir(), 'device-homes-'))
    mkdirSync(join(root, 'dev-a', '.claude', 'projects'), { recursive: true })
    const path = join(root, 'dev-a', '.claude', 'projects', 'enc', 'sess.jsonl')
    // The whole point: this is a real transcript that is not under `~/.claude`,
    // and it used to be refused as an escape attempt.
    expect(isTranscriptPath(path, { configDir: CFG, deviceHomes: root })).toBe(true)
  })

  it('accepts a sub-agent transcript one level down', () => {
    const path = join(CFG, 'projects', 'enc', 'sub', 'sess.jsonl')
    expect(isTranscriptPath(path, { configDir: CFG, deviceHomes: null })).toBe(true)
  })

  it('refuses everything outside the stores, however it is spelled', () => {
    const cases = [
      ['', 'empty'],
      [join(CFG, 'projects'), 'the root itself'],
      [`${CFG}-elsewhere/projects/enc/x.jsonl`, 'a sibling whose name starts the same'],
      [join(CFG, 'projects', '..', '..', 'secrets.jsonl'), 'a traversal out'],
      [join(CFG, 'projects', 'enc', 'sess.txt'), 'not a transcript'],
      [join(CFG, 'settings.json'), 'a config file beside the store'],
    ] as const
    for (const [path, why] of cases) {
      expect(isTranscriptPath(path, { configDir: CFG, deviceHomes: null }), why).toBe(false)
    }
  })

  it('refuses a device home that is not one of ours', () => {
    // The stores are enumerated from the app's own directory rather than
    // pattern-matched, so a path that merely *looks* like a device home is not
    // one. Otherwise the widening would have handed page code any file under
    // any directory called `.claude/projects` anywhere on the disk.
    const root = mkdtempSync(join(tmpdir(), 'device-homes-'))
    mkdirSync(join(root, 'dev-a', '.claude', 'projects'), { recursive: true })
    const elsewhere = join(tmpdir(), 'not-ours', '.claude', 'projects', 'enc', 'x.jsonl')
    expect(isTranscriptPath(elsewhere, { configDir: CFG, deviceHomes: root })).toBe(false)
  })
})

describe('parseUsage', () => {
  it('reads the full modern shape', () => {
    const parsed = parseUsage({
      input_tokens: 2,
      output_tokens: 2540,
      cache_creation_input_tokens: 21_857,
      cache_read_input_tokens: 30_415,
      cache_creation: { ephemeral_1h_input_tokens: 21_857, ephemeral_5m_input_tokens: 0 },
      service_tier: 'standard',
      speed: 'standard',
    })
    expect(parsed).toEqual({
      input: 2,
      output: 2540,
      cacheWrite5m: 0,
      cacheWrite1h: 21_857,
      cacheRead: 30_415,
    })
  })

  it('attributes an unexplained cache write to the cheaper 5-minute rate', () => {
    // Older transcripts carry only the flat total. Guessing 1-hour would
    // inflate the bill; 5-minute is the documented default TTL.
    const parsed = parseUsage({ cache_creation_input_tokens: 1000 })
    expect(parsed?.cacheWrite5m).toBe(1000)
    expect(parsed?.cacheWrite1h).toBe(0)
  })

  it('reconciles a partial breakdown against the declared total', () => {
    const parsed = parseUsage({
      cache_creation_input_tokens: 1000,
      cache_creation: { ephemeral_1h_input_tokens: 600 },
    })
    expect(parsed?.cacheWrite1h).toBe(600)
    expect(parsed?.cacheWrite5m).toBe(400)
    expect(promptTokens(parsed!)).toBe(1000)
  })

  it('never invents negative tokens when the breakdown exceeds the total', () => {
    const parsed = parseUsage({
      cache_creation_input_tokens: 100,
      cache_creation: { ephemeral_1h_input_tokens: 500 },
    })
    expect(parsed?.cacheWrite5m).toBe(0)
    expect(parsed?.cacheWrite1h).toBe(500)
  })

  it('treats missing fields as zero and non-objects as absent', () => {
    expect(parseUsage({})).toEqual({
      input: 0,
      output: 0,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: 0,
    })
    expect(parseUsage(null)).toBeNull()
    expect(parseUsage('nope')).toBeNull()
    expect(parseUsage([1, 2])).toBeNull()
  })
})

/** Build an `assistant` JSONL line in the exact shape Claude Code writes. */
function assistantLine(options: {
  messageId: string
  model?: string
  input?: number
  output?: number
  write1h?: number
  read?: number
  uuid?: string
  timestamp?: string
  sidechain?: boolean
  speed?: string
}): string {
  return JSON.stringify({
    parentUuid: 'parent',
    isSidechain: options.sidechain ?? false,
    type: 'assistant',
    uuid: options.uuid ?? `${options.messageId}-${Math.random()}`,
    requestId: `req_${options.messageId}`,
    timestamp: options.timestamp ?? '2026-08-11T11:33:22.579Z',
    cwd: '/Users/apple/ClaudeAsad',
    sessionId: 'sess-1',
    message: {
      id: options.messageId,
      model: options.model ?? 'claude-opus-5',
      role: 'assistant',
      type: 'message',
      content: [{ type: 'text', text: 'hi' }],
      usage: {
        input_tokens: options.input ?? 0,
        output_tokens: options.output ?? 0,
        cache_creation_input_tokens: options.write1h ?? 0,
        cache_read_input_tokens: options.read ?? 0,
        cache_creation: {
          ephemeral_1h_input_tokens: options.write1h ?? 0,
          ephemeral_5m_input_tokens: 0,
        },
        service_tier: 'standard',
        speed: options.speed ?? 'standard',
      },
    },
  })
}

describe('parseEventLine', () => {
  it('extracts an assistant request', () => {
    const event = parseEventLine(
      assistantLine({ messageId: 'msg_1', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
    )
    expect(event?.type).toBe('assistant')
    expect(event?.messageId).toBe('msg_1')
    expect(event?.model).toBe('claude-opus-5')
    expect(event?.usage?.cacheWrite1h).toBe(21_857)
    expect(event?.sessionId).toBe('sess-1')
    expect(event?.cwd).toBe('/Users/apple/ClaudeAsad')
    expect(event?.timestamp).toBe(Date.parse('2026-08-11T11:33:22.579Z'))
  })

  it('flags fast-mode requests so they keep their own bucket', () => {
    expect(parseEventLine(assistantLine({ messageId: 'm', speed: 'fast' }))?.speed).toBe('fast')
    expect(parseEventLine(assistantLine({ messageId: 'm' }))?.speed).toBeUndefined()
  })

  it('flags sub-agent work', () => {
    expect(parseEventLine(assistantLine({ messageId: 'm', sidechain: true }))?.isSidechain).toBe(
      true,
    )
  })

  it('extracts a compaction boundary and the prompt size that triggered it', () => {
    const line = JSON.stringify({
      type: 'system',
      subtype: 'compact_boundary',
      content: 'Conversation compacted',
      timestamp: '2026-06-06T13:16:47.913Z',
      uuid: 'u1',
      compactMetadata: { trigger: 'auto', preTokens: 984_388, durationMs: 119_071 },
    })
    const event = parseEventLine(line)
    expect(event?.type).toBe('system')
    expect(event?.compactedFrom).toBe(984_388)
  })

  it('ignores every line that carries no usage', () => {
    expect(parseEventLine('')).toBeNull()
    expect(parseEventLine('   ')).toBeNull()
    expect(
      parseEventLine(JSON.stringify({ type: 'queue-operation', operation: 'enqueue' })),
    ).toBeNull()
    expect(
      parseEventLine(JSON.stringify({ type: 'user', message: { role: 'user', content: 'hi' } })),
    ).toBeNull()
    expect(parseEventLine(JSON.stringify({ type: 'system', subtype: 'api_error' }))).toBeNull()
  })

  it('survives a torn trailing line without throwing', () => {
    // The file is being appended to while we read it; a half-written last line
    // is normal, not an error.
    expect(parseEventLine('{"type":"assistant","message":{"id":"m","usa')).toBeNull()
    expect(parseEventLine('not json at all')).toBeNull()
    expect(parseEventLine('[1,2,3]')).toBeNull()
  })
})

describe('SessionAggregator', () => {
  function feed(aggregator: SessionAggregator, lines: string[]): void {
    for (const line of lines) {
      const event = parseEventLine(line)
      if (event) aggregator.add(event)
    }
  }

  it('counts a multi-block request exactly once', () => {
    // This is the whole ballgame. One API request emits one JSONL line per
    // content block (thinking, text, each tool_use) and every line repeats the
    // same usage object verbatim. Verified across 133 real transcripts: 2,801
    // multi-line requests, all byte-identical, up to 19 lines for one request.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'msg_1', uuid: 'a', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
      assistantLine({ messageId: 'msg_1', uuid: 'b', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
      assistantLine({ messageId: 'msg_1', uuid: 'c', input: 2, output: 2540, write1h: 21_857, read: 30_415 }),
    ])

    const summary = aggregator.summary()
    expect(summary.requests).toBe(1)
    expect(summary.usage.output).toBe(2540)
    expect(summary.usage.cacheWrite1h).toBe(21_857)
    expect(summary.usage.cacheRead).toBe(30_415)
  })

  it('accumulates genuinely distinct requests', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'msg_1', output: 1000 }),
      assistantLine({ messageId: 'msg_2', output: 1000 }),
    ])
    const summary = aggregator.summary()
    expect(summary.requests).toBe(2)
    expect(summary.usage.output).toBe(2000)
  })

  it('is idempotent when the same lines are replayed', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    const lines = [assistantLine({ messageId: 'msg_1', uuid: 'a', output: 1000 })]
    feed(aggregator, lines)
    feed(aggregator, lines)
    expect(aggregator.summary().requests).toBe(1)
  })

  it('splits usage per model', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000 }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5-20251001', output: 1_000_000 }),
    ])
    const summary = aggregator.summary()
    expect(summary.models).toContain('claude-opus-5')
    expect(summary.models).toContain('claude-haiku-4-5')
    expect(summary.usageByModel['claude-opus-5'].output).toBe(1_000_000)
    expect(summary.usageByModel['claude-haiku-4-5'].output).toBe(1_000_000)
  })

  it('takes context from the latest prompt, never the running total', () => {
    // Summing prompts counts the same cached prefix once per turn and reports
    // an occupancy many times the real one.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', read: 100_000, output: 10 }),
      assistantLine({ messageId: 'm2', read: 150_000, output: 10 }),
      assistantLine({ messageId: 'm3', read: 200_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.tokens).toBe(200_000)
    expect(summary.context?.window).toBe(1_000_000)
    expect(summary.context?.percent).toBeCloseTo(20, 10)
  })

  it('treats the first prompt as the fixed prefix and warns when it is bloated', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', write1h: 60_000, output: 10 }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5', read: 65_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.preContextTokens).toBe(60_000) // 30% of Haiku's 200k window
    expect(summary.warnings.some((w) => w.kind === 'pre-context')).toBe(true)
  })

  it('keeps tokens from a request with no model id, under its own bucket', () => {
    // Regression: every bucket is keyed on the model id, so a usage record with
    // no model silently dropped its tokens out of the session total while still
    // counting as a request.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    const line = JSON.stringify({
      type: 'assistant',
      uuid: 'u1',
      timestamp: '2026-08-11T10:00:00.000Z',
      isSidechain: false,
      message: { id: 'm1', role: 'assistant', usage: { input_tokens: 500, output_tokens: 700 } },
    })
    const event = parseEventLine(line)
    expect(event?.model).toBeUndefined()
    aggregator.add(event!)

    const summary = aggregator.summary()
    expect(summary.usage.input).toBe(500)
    expect(summary.usage.output).toBe(700)
    // Visible under a sentinel key rather than dropped — a bucket that cannot
    // be named still has to be counted, or the total stops matching the
    // requests it is made of.
    expect(summary.usageByModel[UNKNOWN_MODEL].output).toBe(700)
    expect(summary.models).toEqual([UNKNOWN_MODEL])
  })

  it('still ignores synthetic messages entirely', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    aggregator.add(
      parseEventLine(
        JSON.stringify({
          type: 'assistant',
          uuid: 'u1',
          isSidechain: false,
          message: {
            id: 'm1',
            model: '<synthetic>',
            role: 'assistant',
            usage: { input_tokens: 0, output_tokens: 0 },
          },
        }),
      )!,
    )
    expect(aggregator.summary().models).toEqual([])
  })

  it('keeps a fast-mode request in its own bucket', () => {
    // Regression: `speed: fast` was parsed off the wire and then dropped on the
    // floor by the aggregator, so a fast session was indistinguishable from a
    // standard one in every table that reads `usageByModel`.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000, speed: 'fast' }),
    ])
    expect(aggregator.summary().models).toEqual(['claude-opus-5-fast'])
  })

  it('keeps fast and standard requests to one model in separate buckets', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', output: 1_000_000 }),
      assistantLine({ messageId: 'm2', model: 'claude-opus-5', output: 1_000_000, speed: 'fast' }),
    ])
    const summary = aggregator.summary()
    expect(summary.models.sort()).toEqual(['claude-opus-5', 'claude-opus-5-fast'])
    expect(summary.usage.output).toBe(2_000_000)
  })

  it('does not let a sub-agent model pick the context window', () => {
    // Regression: the window came from whichever model spoke last, including a
    // sidechain. A Haiku Task finishing after an Opus turn pinned a 200k window
    // onto the main thread's 1M-token conversation and reported a 150k prompt
    // as "75% full" with a critical bloat warning.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', read: 100_000, output: 10 }),
      assistantLine({
        messageId: 'm2',
        model: 'claude-haiku-4-5',
        read: 20_000,
        output: 10,
        sidechain: true,
      }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.window).toBe(1_000_000)
    expect(summary.context?.tokens).toBe(100_000)
    expect(summary.context?.percent).toBeCloseTo(10, 10)
    expect(summary.context?.level).toBe('ok')
    expect(summary.warnings).toEqual([])
  })

  it('does not let a sub-agent prompt widen the main thread window', () => {
    // The high-water mark only promotes a window when the *main thread* proves
    // it is bigger; a 900k sub-agent prompt lives in its own context.
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', read: 50_000, output: 10 }),
      assistantLine({
        messageId: 'm2',
        model: 'claude-opus-5',
        read: 900_000,
        output: 10,
        sidechain: true,
      }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.window).toBe(200_000)
    expect(summary.context?.percent).toBeCloseTo(25, 10)
  })

  it('still resolves a window when every request is a sub-agent one', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-opus-5', read: 1000, output: 10, sidechain: true }),
    ])
    const summary = aggregator.summary()
    // No main-thread prompt, so no context reading — but the tokens still count.
    expect(summary.context).toBeNull()
    expect(summary.requests).toBe(1)
    expect(summary.usage.output).toBe(10)
  })

  it('does not let a sub-agent prompt masquerade as the main thread context', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', read: 500_000, output: 10 }),
      assistantLine({ messageId: 'm2', read: 20_000, output: 10, sidechain: true }),
    ])
    const summary = aggregator.summary()
    expect(summary.context?.tokens).toBe(500_000)
    expect(summary.sidechainRequests).toBe(1)
    // Sub-agent spend is still real spend and still counted.
    expect(summary.requests).toBe(2)
  })

  it('counts compactions and lets them widen an understated window', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', model: 'claude-haiku-4-5', read: 1000, output: 10 }),
      JSON.stringify({
        type: 'system',
        subtype: 'compact_boundary',
        timestamp: '2026-06-06T13:16:47.913Z',
        compactMetadata: { trigger: 'auto', preTokens: 984_388 },
      }),
      assistantLine({ messageId: 'm2', model: 'claude-haiku-4-5', read: 50_000, output: 10 }),
    ])
    const summary = aggregator.summary()
    expect(summary.compactions).toBe(1)
    // Haiku's table window is 200k, but a 984k prompt proves otherwise.
    expect(summary.context?.window).toBe(1_000_000)
    // Post-compaction the live prompt is small again.
    expect(summary.context?.tokens).toBe(50_000)
  })

  it('records the session id, cwd and activity span', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({ messageId: 'm1', timestamp: '2026-08-11T10:00:00.000Z' }),
      assistantLine({ messageId: 'm2', timestamp: '2026-08-11T11:00:00.000Z' }),
    ])
    const summary = aggregator.summary()
    expect(summary.sessionId).toBe('sess-1')
    expect(summary.cwd).toBe('/Users/apple/ClaudeAsad')
    expect(summary.startedAt).toBe(Date.parse('2026-08-11T10:00:00.000Z'))
    expect(summary.lastActivityAt).toBe(Date.parse('2026-08-11T11:00:00.000Z'))
  })

  it('reports the same totals no matter when it is asked', () => {
    /*
     * This test used to be called "prices against when the work ran, not when
     * the panel was opened", and it existed because rates were time-boxed: a
     * session run under an introductory rate had to keep costing what it cost.
     * `summary()` took an `at` for exactly that, and nothing else used it.
     *
     * With the rate card gone there is no clock in the answer at all, which is
     * the stronger property and the one worth pinning: two reads of the same
     * aggregator, any distance apart, are identical objects.
     */
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [
      assistantLine({
        messageId: 'm1',
        model: 'claude-sonnet-5',
        output: 1_000_000,
        timestamp: '2026-08-11T10:00:00.000Z',
      }),
    ])
    expect(aggregator.summary()).toEqual(aggregator.summary())
    expect(aggregator.summary().usage.output).toBe(1_000_000)
  })

  it('starts empty and reports no context before the first request', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    expect(aggregator.isEmpty).toBe(true)
    const summary = aggregator.summary()
    expect(summary.context).toBeNull()
    expect(summary.usage).toEqual({
      input: 0,
      output: 0,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: 0,
    })
    expect(summary.warnings).toEqual([])
  })

  it('clears everything on reset, so a replaced file cannot double-count', () => {
    const aggregator = new SessionAggregator('/tmp/sess-1.jsonl')
    feed(aggregator, [assistantLine({ messageId: 'm1', output: 1000 })])
    aggregator.reset()
    expect(aggregator.isEmpty).toBe(true)
    // The dedup set is cleared too, so the same ids can be re-read.
    feed(aggregator, [assistantLine({ messageId: 'm1', output: 1000 })])
    expect(aggregator.summary().requests).toBe(1)
  })

  it('derives a session id from the filename when the transcript has none', () => {
    const aggregator = new SessionAggregator('/tmp/749c33cd-a336.jsonl')
    expect(aggregator.summary().sessionId).toBe('749c33cd-a336')
  })
})

describe('listTranscripts', () => {
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

  /**
   * Two clocks per transcript, and the difference is load-bearing.
   *
   * Resuming appends to an existing conversation rather than starting a new
   * file — a transcript on this machine was born on 1 June and still being
   * written to on 13 August — so "last written" says nothing about when the
   * conversation began. Ranking by it alone is how a session eight minutes old
   * came to be shown a stranger's two-hour, $18 conversation: the stranger was
   * simply the busier writer. `createdAt` is the field that can rule that out.
   */
  it('reports when a conversation began, not only when it was last written', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-list-'))
    appendFileSync(join(dir, 'older.jsonl'), '{}\n')
    await sleep(30)
    appendFileSync(join(dir, 'newer.jsonl'), '{}\n')
    await sleep(30)
    // The older conversation is the one still being typed into.
    appendFileSync(join(dir, 'older.jsonl'), '{}\n')

    const files = await listTranscripts(dir)
    const older = files.find((f) => f.sessionId === 'older')
    const newer = files.find((f) => f.sessionId === 'newer')
    if (!older || !newer) throw new Error('both transcripts should be listed')

    // Sorted by last write, which is the older conversation.
    expect(files[0].sessionId).toBe('older')
    expect(older.modifiedAt).toBeGreaterThan(newer.modifiedAt)
    // But it plainly began first, and that is what tells them apart.
    expect(older.createdAt).toBeLessThan(newer.createdAt)
    expect(older.createdAt).toBeLessThanOrEqual(older.modifiedAt)
  })

  it('never reports a birth time later than the last write', async () => {
    // Filesystems without a birth time report 0 or the epoch, and a copied file
    // can report one later than its preserved mtime. Either would make every
    // transcript look like it began after every session and be excluded.
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-birth-'))
    appendFileSync(join(dir, 'a.jsonl'), '{}\n')
    const [file] = await listTranscripts(dir)
    expect(file.createdAt).toBeGreaterThan(0)
    expect(file.createdAt).toBeLessThanOrEqual(file.modifiedAt)
  })
})
