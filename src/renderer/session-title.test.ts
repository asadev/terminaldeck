import { describe, expect, it } from 'vitest'
import {
  cleanTitleText,
  deriveSessionTitle,
  folderName,
  isUsableTitle,
  MAX_TITLE_LENGTH,
  stripAnsi,
  titleFromOutput,
  titleFromTranscript,
  truncateOnWordBoundary,
} from './session-title'

/**
 * The transcript fixtures below are the real line shapes Claude Code writes,
 * taken from `~/.claude/projects` on this machine — including the awkward ones
 * (a bare-string prompt, a `tool_result`-only user line, the local-command
 * caveat). Inventing the shapes would have tested the parser against a guess.
 */
const line = (value: unknown): string => JSON.stringify(value)

const customTitle = (title: string): string => line({ type: 'custom-title', customTitle: title, sessionId: 's1' })
const aiTitle = (title: string): string => line({ type: 'ai-title', aiTitle: title, sessionId: 's1' })

const userPrompt = (content: unknown, extra: Record<string, unknown> = {}): string =>
  line({
    parentUuid: null,
    isSidechain: false,
    type: 'user',
    message: { role: 'user', content },
    promptSource: 'sdk',
    cwd: '/Users/apple/Projects/terminaldeck',
    sessionId: 's1',
    ...extra,
  })

describe('stripAnsi', () => {
  it('removes colour runs but keeps the text', () => {
    expect(stripAnsi('\x1b[32m❯ 1. Yes, I trust this folder\x1b[0m')).toBe(
      '❯ 1. Yes, I trust this folder',
    )
  })

  it('removes OSC title sequences', () => {
    expect(stripAnsi('\x1b]0;claude\x07ready')).toBe('ready')
    expect(stripAnsi('\x1b]2;title\x1b\\done')).toBe('done')
  })

  it('leaves carriage returns alone for callers that split on them', () => {
    expect(stripAnsi('a\rb')).toBe('a\rb')
  })

  it('is a no-op on plain text', () => {
    expect(stripAnsi('nothing to strip')).toBe('nothing to strip')
  })
})

describe('truncateOnWordBoundary', () => {
  it('returns short text untouched, with no ellipsis', () => {
    expect(truncateOnWordBoundary('short one', 40)).toBe('short one')
  })

  it('returns text of exactly the budget untouched', () => {
    const exact = 'x'.repeat(20)
    expect(truncateOnWordBoundary(exact, 20)).toBe(exact)
  })

  it('breaks between words rather than mid-word', () => {
    const result = truncateOnWordBoundary('set up the deployment pipeline for staging', 20)
    expect(result).toBe('set up the…')
    expect(result.endsWith('…')).toBe(true)
  })

  it('sees a space sitting exactly on the budget', () => {
    // The ellipsis takes the tenth character, so index 9 is the last position
    // a break can land on and still fit.
    expect(truncateOnWordBoundary('aaaa bbbb cccc', 10)).toBe('aaaa bbbb…')
  })

  it('hard-cuts when honouring the boundary would waste the budget', () => {
    // The only space is at index 2 of a 40-character budget — breaking there
    // would leave a two-character title.
    const result = truncateOnWordBoundary(`ab ${'c'.repeat(60)}`, 40)
    expect(result).toBe(`ab ${'c'.repeat(36)}…`)
  })

  it('hard-cuts text with no spaces at all', () => {
    expect(truncateOnWordBoundary('z'.repeat(50), 10)).toBe(`${'z'.repeat(9)}…`)
  })

  it('drops punctuation left dangling by the cut', () => {
    expect(truncateOnWordBoundary('fix the parser, then ship it please', 16)).toBe('fix the parser…')
  })

  it('yields nothing for a zero or negative budget', () => {
    expect(truncateOnWordBoundary('anything', 0)).toBe('')
    expect(truncateOnWordBoundary('anything', -5)).toBe('')
  })

  // REGRESSION: the ellipsis used to be appended on top of the budget, so a
  // title cut to fit a 40-character tab came back 41 characters long and the
  // tab clipped the very character marking the cut.
  it('never exceeds the budget it was given', () => {
    for (const max of [1, 2, 3, 7, 9, 10, 16, 20, 40]) {
      for (const text of [
        'z'.repeat(80),
        'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii',
        'Build luxury car rental website with WebGL 3D experience',
        `ab ${'c'.repeat(60)}`,
      ]) {
        const result = truncateOnWordBoundary(text, max)
        expect(result.length, `${JSON.stringify(text)} @ ${max}`).toBeLessThanOrEqual(max)
      }
    }
  })

  // REGRESSION: a head that was entirely dangling punctuation was stripped to
  // nothing, leaving a tab labelled '…'.
  it('never collapses to a bare ellipsis', () => {
    expect(truncateOnWordBoundary('.'.repeat(60), 40)).toBe(`${'.'.repeat(39)}…`)
    expect(truncateOnWordBoundary('-'.repeat(60), 12)).toBe(`${'-'.repeat(11)}…`)
  })
})

describe('cleanTitleText', () => {
  it('collapses a multi-line prompt onto one line', () => {
    expect(cleanTitleText('build the\n  provider  picker\n\nplease')).toBe(
      'build the provider picker please',
    )
  })

  it('strips injected system reminders', () => {
    expect(cleanTitleText('<system-reminder>ignore this\nentirely</system-reminder> real ask')).toBe(
      'real ask',
    )
  })

  it('strips the local-command caveat block', () => {
    const raw = '<local-command-caveat>Caveat: messages below…</local-command-caveat> actual prompt'
    expect(cleanTitleText(raw)).toBe('actual prompt')
  })

  it('strips a slash-command envelope', () => {
    const raw =
      '<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>claude-opus-5</command-args>'
    expect(cleanTitleText(raw)).toBe('')
  })

  it('removes control characters rather than letting them reach a label', () => {
    expect(cleanTitleText('safe\u0000\u0007\u001b title')).toBe('safe title')
  })

  // Three live transcripts on this machine open with exactly this shape.
  it('drops a leading session id, which would eat the whole budget', () => {
    expect(
      cleanTitleText('b9977b73-3823-44e9-8120-b260e19018ff  read full context of this session'),
    ).toBe('read full context of this session')
  })

  it('leaves an id that is not at the start alone', () => {
    expect(cleanTitleText('resume b9977b73-3823-44e9-8120-b260e19018ff')).toBe(
      'resume b9977b73-3823-44e9-8120-b260e19018ff',
    )
  })
})

describe('isUsableTitle', () => {
  it('accepts an ordinary task description', () => {
    expect(isUsableTitle('add the provider picker')).toBe(true)
  })

  it('rejects text too short to say anything', () => {
    expect(isUsableTitle('')).toBe(false)
    expect(isUsableTitle('ok')).toBe(false)
  })

  it('rejects slash commands', () => {
    expect(isUsableTitle('/clear')).toBe(false)
    expect(isUsableTitle('/catchup now')).toBe(false)
  })

  it('rejects bracketed status lines', () => {
    expect(isUsableTitle('[Request interrupted by user]')).toBe(false)
  })

  it('rejects a leftover caveat', () => {
    expect(isUsableTitle('Caveat: The messages below were generated by the user')).toBe(false)
  })

  // Verified: Claude Code writes `customTitle: "New session"` before it has a
  // real one — two live transcripts here still carry it.
  it('rejects the placeholder titles the CLI writes', () => {
    expect(isUsableTitle('New session')).toBe(false)
    expect(isUsableTitle('untitled')).toBe(false)
  })
})

describe('folderName', () => {
  it('takes the last segment', () => {
    expect(folderName('/Users/apple/Projects/terminaldeck')).toBe('terminaldeck')
  })

  it('tolerates a trailing slash', () => {
    expect(folderName('/Users/apple/Projects/terminaldeck/')).toBe('terminaldeck')
  })

  it('falls back to the whole string when there is no segment', () => {
    expect(folderName('/')).toBe('/')
  })
})

describe('titleFromTranscript', () => {
  it('finds nothing in an empty transcript', () => {
    expect(titleFromTranscript([])).toBeNull()
  })

  it('prefers the title the user set over everything else', () => {
    const result = titleFromTranscript([
      userPrompt('rebuild the whole cost pipeline'),
      aiTitle('Rebuild cost pipeline'),
      customTitle('Tailscale infrastructure requirements'),
    ])
    expect(result).toEqual({ title: 'Tailscale infrastructure requirements', source: 'custom' })
  })

  it('prefers the model-written title over the first prompt', () => {
    const result = titleFromTranscript([
      userPrompt('In this session we are going to work on a project i mean a website about cars'),
      aiTitle('Build luxury car rental website with WebGL 3D experience'),
    ])
    expect(result).toEqual({
      title: 'Build luxury car rental website with WebGL 3D experience',
      source: 'ai',
    })
  })

  it('takes the last title line, since the CLI rewrites them as it goes', () => {
    const result = titleFromTranscript([customTitle('first guess'), customTitle('renamed later')])
    expect(result?.title).toBe('renamed later')
  })

  it('does not let a placeholder custom title bury a real model-written one', () => {
    const result = titleFromTranscript([customTitle('New session'), aiTitle('Wire up the kanban board')])
    expect(result).toEqual({ title: 'Wire up the kanban board', source: 'ai' })
  })

  it('falls back to the first user prompt', () => {
    const result = titleFromTranscript([
      userPrompt('why pc is not connecting deskflow now'),
      userPrompt('and now fix it'),
    ])
    expect(result).toEqual({ title: 'why pc is not connecting deskflow now', source: 'prompt' })
  })

  it('reads text blocks out of an array-shaped message', () => {
    const result = titleFromTranscript([userPrompt([{ type: 'text', text: 'ship the unread badge' }])])
    expect(result?.title).toBe('ship the unread badge')
  })

  it('ignores tool results, which are most user-role lines by count', () => {
    const result = titleFromTranscript([
      userPrompt([{ type: 'tool_result', tool_use_id: 't1', content: 'exit 0' }]),
      userPrompt('the actual question'),
    ])
    expect(result?.title).toBe('the actual question')
  })

  it('ignores the CLI talking to itself', () => {
    const result = titleFromTranscript([
      userPrompt('<local-command-caveat>Caveat: …</local-command-caveat>', { isMeta: true }),
      userPrompt('the actual question'),
    ])
    expect(result?.title).toBe('the actual question')
  })

  it('ignores sub-agent prompts', () => {
    const result = titleFromTranscript([
      userPrompt('you are a subagent, do the thing', { isSidechain: true }),
      userPrompt('the actual question'),
    ])
    expect(result?.title).toBe('the actual question')
  })

  it('skips a slash command in favour of the next real prompt', () => {
    const result = titleFromTranscript([
      userPrompt('<command-name>/model</command-name><command-args>opus</command-args>'),
      userPrompt('now do the work'),
    ])
    expect(result?.title).toBe('now do the work')
  })

  it('survives the half-written last line every live transcript has', () => {
    const result = titleFromTranscript([userPrompt('a real prompt'), '{"type":"user","mess'])
    expect(result?.title).toBe('a real prompt')
  })

  it('skips lines too large to be worth parsing', () => {
    const huge = line({ type: 'user', message: { role: 'user', content: 'x'.repeat(300_000) } })
    expect(titleFromTranscript([huge])).toBeNull()
  })

  it('ignores lines that cannot hold a title without parsing them', () => {
    expect(titleFromTranscript([line({ type: 'assistant', message: { usage: {} } })])).toBeNull()
  })
})

describe('titleFromOutput', () => {
  it('reads the title Claude Code draws into its rule', () => {
    expect(titleFromOutput('──────────── wire up the kanban board ──')).toEqual({
      title: 'wire up the kanban board',
      source: 'output',
    })
  })

  it('reads a rule wrapped in colour codes', () => {
    expect(titleFromOutput('\x1b[90m───────── styled title here ──\x1b[0m')?.title).toBe(
      'styled title here',
    )
  })

  it('prefers a drawn rule over an echoed prompt', () => {
    const output = '> some earlier question\n───── the real title ──\n'
    expect(titleFromOutput(output)?.title).toBe('the real title')
  })

  it('falls back to an echoed prompt', () => {
    expect(titleFromOutput('> add the notification policy module\n')?.title).toBe(
      'add the notification policy module',
    )
  })

  it('ignores an empty prompt box', () => {
    expect(titleFromOutput('❯ \n>\n')).toBeNull()
  })

  it('ignores an echo too short to be a task', () => {
    expect(titleFromOutput('> ok\n')).toBeNull()
  })

  it('splits on carriage returns, which TUIs use to repaint', () => {
    expect(titleFromOutput('junk\r───── after a repaint ──\r')?.title).toBe('after a repaint')
  })

  it('finds nothing in ordinary output', () => {
    expect(titleFromOutput('npm run build\n✓ built in 1.2s\n')).toBeNull()
  })

  // REGRESSION: the rule is repainted with the current name on every frame, so
  // the scrollback holds every name the conversation has ever had. Taking the
  // first match froze the tab on the pre-rename title for the life of the
  // session.
  it('takes the newest drawn rule, since the CLI repaints it on rename', () => {
    const scrollback = '───── old name ──\nwork happens\n───── renamed to this ──\n'
    expect(titleFromOutput(scrollback)?.title).toBe('renamed to this')
  })

  it('still takes the oldest echoed prompt, which is the opening request', () => {
    // A prompt is echoed once when it is submitted, so unlike the rule the
    // first one is the stable label — the same rule the transcript follows.
    expect(titleFromOutput('> the opening request here\n> a later follow-up question\n')?.title).toBe(
      'the opening request here',
    )
  })

  // REGRESSION: this used to strip and split the entire retained buffer on
  // every call, and `deriveSessionTitle` is documented as cheap enough to
  // re-run per chunk.
  it('reads a huge scrollback without walking all of it', () => {
    const filler = 'some ordinary terminal output line here\n'.repeat(200_000) // ~8MB
    const started = performance.now()
    const result = titleFromOutput(`> the opening request here\n${filler}───── the live title ──\n`)
    const elapsed = performance.now() - started

    // Both ends are still found, and the cost does not scale with the middle.
    expect(result?.title).toBe('the live title')
    expect(elapsed).toBeLessThan(100)
  })
})

describe('deriveSessionTitle', () => {
  const cwd = '/Users/apple/Projects/terminaldeck'

  it('falls back to the folder name with nothing to go on', () => {
    expect(deriveSessionTitle({ cwd })).toEqual({ title: 'terminaldeck', source: 'folder' })
  })

  it('lets an explicit rename beat every other source', () => {
    const result = deriveSessionTitle({
      cwd,
      userTitle: 'my tab',
      transcriptLines: [customTitle('CLI title')],
      output: '───── output title ──',
    })
    expect(result).toEqual({ title: 'my tab', source: 'user' })
  })

  it('prefers the transcript over the terminal', () => {
    const result = deriveSessionTitle({
      cwd,
      transcriptLines: [aiTitle('from the transcript')],
      output: '───── from the terminal ──',
    })
    expect(result).toEqual({ title: 'from the transcript', source: 'ai' })
  })

  it('uses the terminal when the transcript yields nothing', () => {
    const result = deriveSessionTitle({
      cwd,
      transcriptLines: ['{"type":"assistant"}'],
      output: '───── from the terminal ──',
    })
    expect(result).toEqual({ title: 'from the terminal', source: 'output' })
  })

  it('truncates a long derived title on a word boundary', () => {
    const result = deriveSessionTitle({
      cwd,
      transcriptLines: [aiTitle('Build luxury car rental website with WebGL 3D experience')],
    })
    expect(result.title).toBe('Build luxury car rental website with…')
    expect(result.title.length).toBeLessThanOrEqual(MAX_TITLE_LENGTH)
  })

  it('honours a caller-supplied budget for a narrow tab', () => {
    const result = deriveSessionTitle({
      cwd,
      transcriptLines: [aiTitle('Build luxury car rental website')],
      maxLength: 12,
    })
    // 'Build luxury…' is thirteen characters and does not fit in twelve.
    expect(result.title).toBe('Build…')
    expect(result.title.length).toBeLessThanOrEqual(12)
  })

  it('ignores a rename that is only whitespace', () => {
    expect(deriveSessionTitle({ cwd, userTitle: '   ' })).toEqual({ title: 'terminaldeck', source: 'folder' })
  })

  it('falls back rather than showing junk a source produced', () => {
    // A transcript whose only prompt is a slash command has nothing usable.
    const result = deriveSessionTitle({
      cwd,
      transcriptLines: [userPrompt('<command-name>/clear</command-name>')],
    })
    expect(result).toEqual({ title: 'terminaldeck', source: 'folder' })
  })

  // REGRESSION: `folderName('')` is `''`, so a session restored with a missing
  // or whitespace cwd got a tab with nothing written on it — from the one
  // source whose whole job is to never fail.
  it('never returns a blank title, whatever the cwd is', () => {
    for (const broken of ['', '   ', '/', '//', '\n']) {
      const result = deriveSessionTitle({ cwd: broken })
      expect(result.title.trim(), JSON.stringify(broken)).not.toBe('')
    }
    expect(deriveSessionTitle({ cwd: '' })).toEqual({ title: 'Session', source: 'folder' })
  })
})
