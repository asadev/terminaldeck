import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { mkdtempSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ActionRow } from './action-log'
import { keyRig, type KeyRig } from './key-door.fixture'
import { CHANNEL_KEY_ENV, CHANNEL_SERVER_NAME, CHANNEL_URL_ENV, channelBridgeSource, writeChannelBridge } from './notify-channel'
import { NotifyDetector } from './notify-detect'
import { NotificationHub, REAL_CLOCK } from './notify-hub'
import { notifyTools } from './notify-tools'
import { openStandaloneDeckControlServer, type StandaloneDeckControlServer } from './server'
import { tiersFor } from './access-keys'
import { BRAND } from '../../shared/brand'

/**
 * The Claude Code channel bridge, run for real.
 *
 * The script this app writes into `<userData>` is started here the way Claude
 * Code starts it — `node <file>`, the key and the address in its environment,
 * MCP over stdin and stdout — against a real loopback tool server. The test
 * plays Claude Code's half: it sends `initialize`, checks the bridge declares
 * the `claude/channel` capability and never negotiates the protocol revision
 * that loses channel delivery, then makes a session finish a turn and reads the
 * `notifications/claude/channel` message that comes out.
 *
 * What it cannot prove is Claude Code putting that message in front of its
 * model; that is Claude Code's documented behaviour for a server loaded with
 * `--dangerously-load-development-channels`, and the setup text says so.
 */

let dir = ''
let rig: KeyRig
let hub: NotificationHub
let detector: NotifyDetector
let server: StandaloneDeckControlServer | null = null
let child: ChildProcessWithoutNullStreams | null = null

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-notify-channel-'))
  let detectorRef: NotifyDetector | null = null
  let hubRef: NotificationHub | null = null
  rig = keyRig(dir, {
    extraTools: notifyTools({ hub: () => hubRef }),
    onRow: (row: ActionRow) => detectorRef?.noteRow(row),
  })
  hub = new NotificationHub({ dir: null, settings: (keyId) => rig.keys.notifySettings(keyId), clock: REAL_CLOCK })
  hubRef = hub
  detector = new NotifyDetector({
    surface: rig.app.surface,
    starterOf: (sessionId) => rig.control.starterOf(sessionId),
    enqueue: (keyId, event) => hub.enqueue(keyId, event),
    clock: REAL_CLOCK,
  })
  detectorRef = detector
})

afterEach(async () => {
  child?.kill()
  child = null
  await server?.stop()
  server = null
  detector.stop()
  hub.stop()
  rig.door.stop()
  rmSync(dir, { recursive: true, force: true })
})

function linesOf(proc: ChildProcessWithoutNullStreams): () => Promise<Record<string, unknown>> {
  const queue: Array<Record<string, unknown>> = []
  let waiting: ((message: Record<string, unknown>) => void) | null = null
  createInterface({ input: proc.stdout }).on('line', (line) => {
    const message = JSON.parse(line) as Record<string, unknown>
    if (waiting) {
      const take = waiting
      waiting = null
      take(message)
    } else queue.push(message)
  })
  return () =>
    new Promise((resolve, reject) => {
      const ready = queue.shift()
      if (ready) return resolve(ready)
      const timer = setTimeout(() => reject(new Error('the bridge said nothing')), 8_000)
      waiting = (message) => {
        clearTimeout(timer)
        resolve(message)
      }
    })
}

describe('the Claude Code channel bridge', () => {
  it('is named the same on the setup page as here, so the two lines it hands out agree', () => {
    // Read as text: the renderer's copy cannot be imported into the main
    // process's project, and the two must spell the name the same way.
    const page = readFileSync(join(__dirname, '../../renderer/settings/sections/ai-apps-setup.ts'), 'utf8')
    expect(CHANNEL_SERVER_NAME).toBe(`${BRAND.id}-notify`)
    expect(page).toContain('export const CHANNEL_SERVER = `${BRAND.id}-notify`')
    expect(channelBridgeSource()).toContain(CHANNEL_URL_ENV)
    expect(channelBridgeSource()).toContain(CHANNEL_KEY_ENV)
  })

  it('is rewritten into the app’s folder with the product’s own name, and no key in it', () => {
    const file = writeChannelBridge(dir)
    const text = readFileSync(file, 'utf8')
    expect(text).toBe(channelBridgeSource())
    expect(text).toContain('claude/channel')
    expect(text).not.toMatch(/ak_[A-Za-z0-9_-]{20,}/)
  })

  it('declares the channel, stays off the protocol that loses it, and turns a finished turn into a channel message', async () => {
    const a = rig.key('work', { name: 'Claude Code' })
    server = await openStandaloneDeckControlServer({ control: rig.control, keys: rig.door })
    const caller = { kind: 'key' as const, keyId: a.id, keyName: 'Claude Code', tiers: tiersFor('work') }
    const started = await rig.control.call('sessions.start', { cwd: '/work/api' }, { caller })
    const sessionId = (started.value as { session: { id: string } }).session.id

    const file = writeChannelBridge(dir)
    child = spawn(process.execPath, [file], {
      env: { ...process.env, [CHANNEL_URL_ENV]: server.endpoint.url, [CHANNEL_KEY_ENV]: a.key },
    })
    const next = linesOf(child)
    child.stdin.write(
      `${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2026-07-28', capabilities: {}, clientInfo: { name: 'claude-code', version: '2' } } })}\n`,
    )
    const init = (await next()) as { result: { protocolVersion: string; capabilities: { experimental: Record<string, unknown> } } }
    expect(init.result.capabilities.experimental['claude/channel']).toEqual({})
    expect(init.result.protocolVersion).not.toBe('2026-07-28')
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`)

    // The bridge parks its long-poll on this Mac; then the session finishes a turn.
    const waiters = (hub as unknown as { waiters: Set<unknown> }).waiters
    for (let i = 0; i < 400 && waiters.size === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10))
    expect(waiters.size).toBe(1)
    detector.noteStatus(sessionId, 'working')
    detector.noteStatus(sessionId, 'completed')

    const pushed = (await next()) as { method: string; params: { content: string; meta: Record<string, string> } }
    expect(pushed.method).toBe('notifications/claude/channel')
    expect(pushed.params.content).toContain('finished its turn')
    expect(pushed.params.meta).toMatchObject({ session_id: sessionId, kind: 'finished' })
    // Meta keys are identifiers only, or Claude Code drops them silently.
    for (const key of Object.keys(pushed.params.meta)) expect(key).toMatch(/^[A-Za-z0-9_]+$/)

    // It acknowledges what it emitted on its next wait.
    const id = pushed.params.meta.notification_id
    for (let i = 0; i < 400 && hub.list(a.id).some((n) => n.id === id); i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
    expect(hub.list(a.id).map((n) => n.id)).not.toContain(id)
  }, 15_000)
})
