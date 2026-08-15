import { mkdirSync, mkdtempSync, writeFileSync, utimesSync } from 'node:fs'
import { mkdtemp, rm, writeFile, appendFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  ChatReader,
  collapseChat,
  mayCarryChat,
  newestChatTranscript,
  parseChatLine,
  readChatTranscript,
  type ChatLine,
} from './chat-transcript'
import {
  encodeProjectPath,
  installDeviceHomes,
  isTranscriptPath,
  resetDeviceHomes,
} from './transcript'

/**
 * Fixtures are cut from real lines in `~/.claude/projects` on this machine, with
 * the text shortened and the ids renamed. The field sets are verbatim, because
 * every bug this module can have is a field it read too loosely: `isMeta` alone
 * leaves slash-command plumbing on screen, and treating an array-form `user`
 * line as a prompt turns tool output into things the user never said.
 */

const SESSION = 'a365c25c-ac46-4297-99f9-4beca7005eef'

function line(overrides: Record<string, unknown>): string {
  return JSON.stringify({
    parentUuid: null,
    isSidechain: false,
    userType: 'external',
    cwd: '/Users/apple/Projects/terminaldeck',
    sessionId: SESSION,
    version: '2.1.209',
    gitBranch: 'main',
    ...overrides,
  })
}

function prompt(text: string, overrides: Record<string, unknown> = {}): string {
  return line({
    type: 'user',
    promptId: 'p-1',
    message: { role: 'user', content: text },
    uuid: 'u-prompt-1',
    timestamp: '2026-08-12T09:00:00.000Z',
    permissionMode: 'default',
    origin: { kind: 'human' },
    promptSource: 'sdk',
    entrypoint: 'claude-desktop',
    ...overrides,
  })
}

function reply(
  text: string,
  overrides: Record<string, unknown> = {},
  messageOverrides: Record<string, unknown> = {},
): string {
  return line({
    type: 'assistant',
    uuid: 'u-reply-1',
    timestamp: '2026-08-12T09:00:04.000Z',
    requestId: 'req_1',
    message: {
      id: 'msg_A',
      role: 'assistant',
      model: 'claude-opus-5',
      content: [{ type: 'text', text }],
      usage: { input_tokens: 4, output_tokens: 120, cache_read_input_tokens: 51_000 },
      ...messageOverrides,
    },
    ...overrides,
  })
}

/** The array form: a tool result, which the CLI writes with `role: 'user'`. */
function toolResult(id: string, output: string): string {
  return line({
    type: 'user',
    parentUuid: 'u-reply-1',
    promptId: 'p-1',
    message: {
      role: 'user',
      content: [{ tool_use_id: id, type: 'tool_result', content: output }],
    },
    uuid: `u-result-${id}`,
    timestamp: '2026-08-12T09:00:06.000Z',
    toolUseResult: { stdout: output },
  })
}

function texts(source: string[]): string[] {
  return collapseChat(
    source.map(parseChatLine).filter((l): l is ChatLine => l !== null),
  ).map((m) => `${m.role}: ${m.text}`)
}

/* ------------------------------------------------------------ the rules -- */

describe('what a conversation includes', () => {
  it('keeps a typed prompt and the prose reply, in order', () => {
    expect(texts([prompt('Add a chat toggle'), reply('Done — the toggle sits in the header.')])).toEqual([
      'you: Add a chat toggle',
      'agent: Done — the toggle sits in the header.',
    ])
  })

  it('never shows the array-form user line, whatever it carries', () => {
    const conversation = texts([
      prompt('list the files'),
      reply('Reading the directory now.'),
      toolResult('toolu_01Qc23ik', 'total 6296\ndrwxr-xr-x@ 32 apple staff 1024 Jun 10 23:22 .'),
      reply('Twelve files, nothing unexpected.'),
    ])
    expect(conversation).toEqual([
      'you: list the files',
      // Both replies are one turn: the tool call between them is gone, so
      // leaving two bubbles would only show the seam.
      'agent: Reading the directory now.\n\nTwelve files, nothing unexpected.',
    ])
    expect(conversation.join('\n')).not.toContain('drwxr-xr-x')
  })

  it('drops tool output even when the result block sits beside a text block', () => {
    // Real shape: `[Request interrupted by user]` arrives as an array-form user
    // line with a text block and no isMeta — 156 of them in one sweep here.
    const interrupted = line({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] },
      uuid: 'u-int-1',
      timestamp: '2026-08-12T09:00:07.000Z',
    })
    expect(texts([prompt('go'), interrupted])).toEqual(['you: go'])
  })

  it('keeps a pasted-image prompt, which is the one genuine array-form user line', () => {
    const pasted = line({
      type: 'user',
      message: {
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0…' } },
          { type: 'text', text: 'this is how it looks on home' },
        ],
      },
      uuid: 'u-img-1',
      timestamp: '2026-08-12T09:01:00.000Z',
      origin: { kind: 'human' },
    })
    expect(texts([pasted])).toEqual(['you: this is how it looks on home'])
  })

  it('drops thinking and tool_use blocks but keeps the text beside them', () => {
    const thinking = reply('', { uuid: 'u-think' }, {
      content: [{ type: 'thinking', thinking: 'The user wants a toggle…', signature: 'Es4B' }],
    })
    const toolUse = reply('', { uuid: 'u-tool' }, {
      content: [{ type: 'tool_use', id: 'toolu_1', name: 'Read', input: { file_path: '/x' } }],
    })
    expect(texts([prompt('go'), thinking, toolUse, reply('Read it.', { uuid: 'u-say' })])).toEqual([
      'you: go',
      'agent: Read it.',
    ])
  })

  it('drops isMeta, sidechain, compaction summaries and API-error notices', () => {
    const meta = prompt('Approach this as the design lead at a small studio…', {
      uuid: 'u-meta',
      isMeta: true,
      origin: undefined,
    })
    const sidechain = reply('Sub-agent reporting in.', { uuid: 'u-side', isSidechain: true })
    const summary = prompt('This session is being continued from a previous conversation…', {
      uuid: 'u-summary',
      isCompactSummary: true,
    })
    const apiError = reply('API Error: Connection closed mid-response.', {
      uuid: 'u-err',
      isApiErrorMessage: true,
    }, { model: '<synthetic>' })
    expect(texts([meta, sidechain, summary, apiError, prompt('carry on'), reply('Carrying on.')])).toEqual([
      'you: carry on',
      'agent: Carrying on.',
    ])
  })

  it('drops a <synthetic> reply even when isApiErrorMessage is false', () => {
    // Found by sweeping this machine's store: 96 lines saying "No response
    // requested." — written by the CLI, `model: '<synthetic>'`, and explicitly
    // `isApiErrorMessage: false`, so the flag alone left every one of them on
    // screen as something the agent said.
    const synthetic = reply(
      'No response requested.',
      { uuid: 'u-syn', isApiErrorMessage: false },
      { model: '<synthetic>', stop_reason: 'stop_sequence' },
    )
    expect(texts([prompt('ping'), synthetic, reply('Real answer.', { uuid: 'u-real' }, { id: 'msg_R' })])).toEqual([
      'you: ping',
      'agent: Real answer.',
    ])
  })

  it('drops a CLI tag carried in the array form of a human-stamped line', () => {
    // The array branch trusts `origin: human`, which is the only marker a
    // pasted-image prompt has. A slash command recorded in that shape would
    // otherwise skip the tag gate the string form gets.
    const wrapped = line({
      type: 'user',
      uuid: 'u-arr-cmd',
      timestamp: '2026-08-12T09:02:03.000Z',
      origin: { kind: 'human' },
      message: {
        role: 'user',
        content: [{ type: 'text', text: '<command-name>/compact</command-name>\n<command-args></command-args>' }],
      },
    })
    expect(texts([wrapped, prompt('and now the real one')])).toEqual(['you: and now the real one'])
  })

  it('drops slash-command plumbing, which carries no isMeta and no origin', () => {
    const slash = line({
      type: 'user',
      uuid: 'u-cmd',
      timestamp: '2026-08-12T09:02:00.000Z',
      message: {
        role: 'user',
        content:
          '<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>claude-fable-5</command-args>',
      },
    })
    const stdout = line({
      type: 'user',
      uuid: 'u-out',
      timestamp: '2026-08-12T09:02:01.000Z',
      message: { role: 'user', content: '<local-command-stdout>Set model to claude-fable-5</local-command-stdout>' },
    })
    const notification = line({
      type: 'user',
      uuid: 'u-note',
      timestamp: '2026-08-12T09:02:02.000Z',
      origin: { kind: 'task-notification' },
      message: { role: 'user', content: '<task-notification>\n<task-id>wdtmjatgv</task-id>\n</task-notification>' },
    })
    expect(texts([slash, stdout, notification, prompt('ok now build it')])).toEqual(['you: ok now build it'])
  })

  it('strips a system reminder stapled onto a real prompt', () => {
    const stapled = prompt('ship it\n<system-reminder>Remember to run the tests.</system-reminder>')
    expect(texts([stapled])).toEqual(['you: ship it'])
  })

  it('keeps a prompt that merely mentions a tag name', () => {
    // Anchored matching: this repo's own prompts talk about `<command-name>`.
    expect(texts([prompt('what does <command-name> mean in the transcript?')])).toEqual([
      'you: what does <command-name> mean in the transcript?',
    ])
  })
})

/* ------------------------------------------------------- dedupe & merge -- */

describe('dedupe and collapsing', () => {
  it('collapses a reply split over three blocks into one message', () => {
    // One request, three text blocks, written as three JSONL lines sharing a
    // message.id and repeating `usage` verbatim on each.
    const usage = { input_tokens: 4, output_tokens: 300, cache_read_input_tokens: 51_000 }
    const part = (text: string, uuid: string): string =>
      reply(text, { uuid, timestamp: '2026-08-12T09:03:00.000Z' }, { id: 'msg_split', usage })

    const messages = collapseChat(
      [prompt('explain the reader'), part('First.', 'u-1'), part('Second.', 'u-2'), part('Third.', 'u-3')]
        .map(parseChatLine)
        .filter((l): l is ChatLine => l !== null),
    )

    expect(messages).toHaveLength(2)
    expect(messages[1].role).toBe('agent')
    expect(messages[1].text).toBe('First.\n\nSecond.\n\nThird.')
  })

  it('deduplicates a reply replayed under the same message.id', async () => {
    // Compaction replays part of the conversation, so the same line arrives
    // twice — 49 duplicate uuids in one sweep of this machine's transcripts.
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-chat-'))
    const path = join(dir, `${SESSION}.jsonl`)
    const once = reply('Only once.', { uuid: 'u-dup' }, { id: 'msg_dup' })
    await writeFile(path, [prompt('hi'), once, once, once].join('\n') + '\n')

    const messages = await readChatTranscript(path)
    expect(messages.map((m) => m.text)).toEqual(['hi', 'Only once.'])
    await rm(dir, { recursive: true, force: true })
  })

  it('keeps two identical prompts, because typing "continue" twice is two turns', () => {
    expect(
      texts([prompt('continue', { uuid: 'u-a' }), reply('ok', { uuid: 'r-a' }, { id: 'm-a' }), prompt('continue', { uuid: 'u-b' })]),
    ).toEqual(['you: continue', 'agent: ok', 'you: continue'])
  })

  it('starts a new agent message after the user speaks again', () => {
    expect(
      texts([
        prompt('one', { uuid: 'u-1' }),
        reply('first answer', { uuid: 'r-1' }, { id: 'm-1' }),
        prompt('two', { uuid: 'u-2' }),
        reply('second answer', { uuid: 'r-2' }, { id: 'm-2' }),
      ]),
    ).toEqual(['you: one', 'agent: first answer', 'you: two', 'agent: second answer'])
  })
})

/* ------------------------------------------------------------- tailing -- */

describe('incremental tailing', () => {
  const dirs: string[] = []
  afterAll(async () => {
    for (const dir of dirs) await rm(dir, { recursive: true, force: true })
  })

  async function fixture(contents: string): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-chat-'))
    dirs.push(dir)
    const path = join(dir, `${SESSION}.jsonl`)
    await writeFile(path, contents)
    return path
  }

  it('reports only what changed on the second read', async () => {
    const path = await fixture([prompt('start'), reply('Working on it.')].join('\n') + '\n')
    const reader = new ChatReader(path)

    const first = await reader.readAll()
    expect(first.messages.map((m) => m.text)).toEqual(['start', 'Working on it.'])

    // Nothing appended: nothing to send.
    expect((await reader.readAll()).messages).toEqual([])

    await appendFile(path, reply('Finished.', { uuid: 'r-2' }, { id: 'msg_B' }) + '\n')
    const second = await reader.readAll()
    // Same turn, so it is the *same* message with more text on it — the view
    // merges by id rather than appending a second bubble.
    expect(second.messages).toHaveLength(1)
    expect(second.messages[0].id).toBe(reader.conversation[1].id)
    expect(second.messages[0].text).toBe('Working on it.\n\nFinished.')
    expect(reader.conversation).toHaveLength(2)
  })

  it('does not hand back an object that keeps mutating', async () => {
    const path = await fixture([prompt('start'), reply('One.')].join('\n') + '\n')
    const reader = new ChatReader(path)
    const [, agent] = (await reader.readAll()).messages

    await appendFile(path, reply('Two.', { uuid: 'r-2' }, { id: 'msg_B' }) + '\n')
    await reader.readAll()
    expect(agent.text).toBe('One.')
  })

  it('re-reads from the start when the file shrinks', async () => {
    const path = await fixture([prompt('first session'), reply('Hello.')].join('\n') + '\n')
    const reader = new ChatReader(path)
    await reader.readAll()

    await writeFile(path, prompt('reused id', { uuid: 'u-new' }) + '\n')
    const after = await reader.readAll()
    expect(after.reset).toBe(true)
    expect(reader.conversation.map((m) => m.text)).toEqual(['reused id'])
  })

  it('holds a half-written final line until the rest of it is appended', async () => {
    // A live transcript is appended to mid-line, so the last line of any read is
    // routinely a fragment. It has to be carried across the read, not parsed and
    // not dropped — dropping it loses the message the user is watching arrive.
    const whole = reply('Rest of it.', { uuid: 'r-3' }, { id: 'msg_C' })
    const cut = Math.floor(whole.length / 2)
    const path = await fixture([prompt('start'), reply('Partial')].join('\n') + '\n' + whole.slice(0, cut))

    const reader = new ChatReader(path)
    expect((await reader.readAll()).messages.map((m) => m.text)).toEqual(['start', 'Partial'])

    await appendFile(path, whole.slice(cut) + '\n')
    const after = await reader.readAll()
    expect(after.reset).toBe(false)
    expect(reader.conversation.map((m) => m.text)).toEqual(['start', 'Partial\n\nRest of it.'])
  })

  it('survives a torn line and a missing file', async () => {
    const path = await fixture('{"type":"user","message":\n' + prompt('after the mess') + '\n')
    expect((await readChatTranscript(path)).map((m) => m.text)).toEqual(['after the mess'])
    expect(await readChatTranscript(join(path, 'nope.jsonl'))).toEqual([])
  })
})

/* ---------------------------------------------------------------- gate -- */

describe('the pre-parse gate', () => {
  it('skips tool-result lines, which are the enormous ones', () => {
    expect(mayCarryChat(toolResult('toolu_1', 'x'.repeat(100)))).toBe(false)
  })

  it('lets prompts and replies through', () => {
    expect(mayCarryChat(prompt('hello'))).toBe(true)
    expect(mayCarryChat(reply('hi'))).toBe(true)
  })

  it('skips the bookkeeping lines that make up half a transcript', () => {
    expect(mayCarryChat(JSON.stringify({ type: 'attachment', attachment: { type: 'file' } }))).toBe(false)
    expect(mayCarryChat(JSON.stringify({ type: 'queue-operation', operation: 'add' }))).toBe(false)
    expect(mayCarryChat(JSON.stringify({ type: 'ai-title', aiTitle: 'Chat view' }))).toBe(false)
  })
})

/* ------------------------------------------------- where chat mode looks -- */

/**
 * The regression that made chat mode blank for a session started from a phone.
 *
 * Such a session runs confined, with a `HOME` of its own, and the CLI follows
 * `HOME` — so its conversation is written under `<deviceHome>/.claude/projects`
 * and not under the owner's `~/.claude` at all. This function was reading only
 * the profile's store, so it answered "no transcript" for a session that was
 * talking, and the view showed the empty state with nothing to explain it.
 *
 * Nothing here copies or links anything: the session writes where it was always
 * going to write, and `transcript.ts` is told where the homes are.
 */
describe('the transcript chat mode opens', () => {
  const made: string[] = []

  function scratch(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix))
    made.push(dir)
    return dir
  }

  afterAll(async () => {
    for (const dir of made) await rm(dir, { recursive: true, force: true })
  })

  const CWD = '/Users/apple/Projects/terminaldeck'

  it('finds a confined session, whose conversation is in its own store', async () => {
    const config = scratch('deck-chat-config-')
    const homes = scratch('deck-chat-homes-')
    installDeviceHomes(homes)
    try {
      const store = join(homes, 'dev-a', '.claude', 'projects', encodeProjectPath(CWD))
      mkdirSync(store, { recursive: true })
      const path = join(store, 'sess-phone.jsonl')
      writeFileSync(path, `${prompt('what is failing?')}\n${reply('the build.')}\n`)

      // The owner's own store exists and is empty for this project, which is the
      // shape that used to produce "no transcript at all".
      mkdirSync(join(config, 'projects', encodeProjectPath(CWD)), { recursive: true })
      expect(await newestChatTranscript(CWD)).toBe(path)
      // And the guard lets the reader open it, rather than treating a real
      // transcript outside `~/.claude` as an escape attempt.
      expect(isTranscriptPath(path)).toBe(true)
    } finally {
      resetDeviceHomes()
    }
  })

  it('still prefers whichever store was written to most recently', async () => {
    // Both stores hold a conversation for this project. "The live session" is a
    // question about time, not about which directory it happens to be in.
    const homes = scratch('deck-chat-homes-2-')
    installDeviceHomes(homes)
    try {
      const store = join(homes, 'dev-a', '.claude', 'projects', encodeProjectPath(CWD))
      mkdirSync(store, { recursive: true })
      const older = join(store, 'sess-old.jsonl')
      writeFileSync(older, `${prompt('yesterday')}\n`)
      utimesSync(older, new Date(1_700_000_000_000), new Date(1_700_000_000_000))

      const newer = join(store, 'sess-new.jsonl')
      writeFileSync(newer, `${prompt('today')}\n`)
      expect(await newestChatTranscript(CWD)).toBe(newer)
    } finally {
      resetDeviceHomes()
    }
  })

  it('answers nothing when there is no store at all, rather than throwing', async () => {
    // Every machine where nobody has paired a device, and every unit test.
    resetDeviceHomes()
    expect(await newestChatTranscript('/nowhere/at/all')).toBeNull()
  })
})
