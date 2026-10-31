import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { appTools, type AppToolDeps } from './app-tools'
import { fakeContext } from './agents-area.fixture'
import { ConsentBroker, type ConsentRequest } from './consent'
import { DeckControl } from './control'
import { mcpServerTools, type McpServerToolDeps } from './mcp-server-tools'
import { voiceTools, type VoiceToolDeps } from './voice-tools'

/**
 * The agents-area tools behind the real dispatcher.
 *
 * The factory tests prove each tool's own rules with fakes. This file proves
 * the two properties that only exist once a tool is inside `DeckControl`: a
 * key given to a tool never reaches the action log or the confirmation a
 * person reads, and an `alter` tool behaves like every other `alter` tool —
 * asked, and refused outright when nobody is there to ask.
 */

let dir = ''
let asked: ConsentRequest[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'agents-area-control-'))
  asked = []
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function build(answer: boolean): { control: DeckControl; settings: Record<string, unknown> } {
  const { context, record } = fakeContext()
  const consent = new ConsentBroker({
    ask: (request) => {
      asked.push(request)
      queueMicrotask(() => consent.respond(request.id, answer, 'window'))
      return true
    },
    timeoutMs: 50,
  })
  const voice: VoiceToolDeps = {
    providers: () => [],
    status: () => ({ hasKey: true }),
    save: async () => ({ ok: true, message: 'That key works.' }),
    forget: () => undefined,
    transcribe: async () => ({ ok: true, text: '', message: '' }),
  }
  const mcp = { add: async () => ({ ok: true, message: 'Added.' }) } as unknown as McpServerToolDeps
  const app = {} as AppToolDeps
  const control = new DeckControl({
    surface: context.surface,
    log: new ActionLog({ dir }),
    consent,
    extraTools: [...voiceTools(voice), ...mcpServerTools(mcp), ...appTools(app)],
  })
  return { control, settings: record.settings }
}

function logText(): string {
  return readFileSync(join(dir, 'actions.jsonl'), 'utf8')
}

describe('a credential given to a tool', () => {
  it('reaches neither the action log nor the dialog', async () => {
    const { control } = build(true)
    const result = await control.call('voice_save_key', { provider: 'groq', key: 'gsk_live_do_not_log_me' })
    expect(result.ok).toBe(true)
    expect(asked).toHaveLength(1)
    expect(JSON.stringify(asked[0])).not.toContain('gsk_live')
    expect(logText()).not.toContain('gsk_live')
  })

  it('stays out of the log when it is an MCP server’s environment, one level down', async () => {
    const { control } = build(true)
    const result = await control.call('mcp_add', {
      name: 'github',
      scope: 'user',
      transport: 'stdio',
      command: 'npx -y srv',
      env: { GITHUB_PERSONAL_ACCESS_TOKEN: 'ghp_do_not_log_me' },
    })
    expect(result.ok).toBe(true)
    expect(logText()).not.toContain('ghp_do_not_log_me')
    expect(logText()).toContain('GITHUB_PERSONAL_ACCESS_TOKEN')
  })
})

describe('alter tools in this area are alter tools', () => {
  it('changes nothing when the person says no', async () => {
    const { control, settings } = build(false)
    const result = await control.call('settings_reset', {})
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('declined')
    expect(settings).toHaveProperty('appearance.density')
  })

  it('is refused outright for a run nobody is watching, with nobody asked', async () => {
    const { control, settings } = build(true)
    const result = await control.call('settings_reset', {}, { attended: false })
    expect(result.refusal).toBe('not-permitted-unattended')
    expect(asked).toHaveLength(0)
    expect(settings).toHaveProperty('appearance.density')
  })

  it('resets only what may be touched once the person says yes', async () => {
    const { control, settings } = build(true)
    const result = await control.call('settings_reset', {})
    expect(result.ok).toBe(true)
    expect(settings).toEqual({ 'remote.enabled': true, 'advanced.debugMode': false })
  })
})
