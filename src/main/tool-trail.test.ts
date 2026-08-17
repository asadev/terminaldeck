/**
 * The trail reader, against real JSONL rather than a fixture object.
 *
 * Two callers now depend on this — the copilot's `sessions.result` and the
 * `loop` alert — and they depend on it agreeing with itself: an alert that
 * fires while the tool that is asked about it says "nothing wrong" is worse
 * than neither existing. So the tests here are about the properties both rely
 * on, not about the parsing, which is `session-insights.test.ts`'s job.
 */

import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { assessProgress } from './deck-control/progress'
import { emptyTrail, readToolTrail, TRAIL_WINDOW_BYTES } from './tool-trail'

const temps: string[] = []

afterAll(async () => {
  await Promise.all(temps.map((dir) => rm(dir, { recursive: true, force: true }).catch(() => undefined)))
})

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-trail-'))
  temps.push(dir)
  return dir
}

/** One tool call and its result, in the shape the CLI writes them. */
function callLines(index: number, name: string, failed: boolean): string[] {
  const at = new Date(Date.parse('2026-08-17T09:00:00.000Z') + index * 1000).toISOString()
  return [
    JSON.stringify({
      type: 'assistant',
      sessionId: 's',
      requestId: `req-${index}`,
      timestamp: at,
      message: {
        role: 'assistant',
        model: 'claude-opus-5',
        usage: { input_tokens: 10, output_tokens: 5 },
        content: [{ type: 'tool_use', id: `tu-${index}`, name, input: {} }],
      },
    }),
    JSON.stringify({
      type: 'user',
      sessionId: 's',
      timestamp: at,
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: `tu-${index}`, is_error: failed, content: 'x' }],
      },
    }),
  ]
}

describe('readToolTrail', () => {
  it('pairs each call with its result, and marks the failures', async () => {
    const dir = await tempDir()
    const path = join(dir, 'a.jsonl')
    await writeFile(
      path,
      [...callLines(0, 'Bash', true), ...callLines(1, 'Read', false)].join('\n') + '\n',
      'utf8',
    )

    const trail = await readToolTrail(path, TRAIL_WINDOW_BYTES)
    expect(trail.events.map((event) => [event.name, event.failed])).toEqual([
      ['Bash', true],
      ['Read', false],
    ])
    expect(trail.partial).toBe(false)
  })

  it('reads a tail, and says that it did', async () => {
    /*
     * The whole reason this function exists instead of `readInsightLines`. A
     * caller has to be able to tell "there were no tool calls" from "there were
     * no tool calls *in the part I read*", because `assessProgress` gives those
     * two different verdicts and one of them is a claim about the session.
     */
    const dir = await tempDir()
    const path = join(dir, 'big.jsonl')
    const lines: string[] = []
    for (let index = 0; index < 200; index += 1) lines.push(...callLines(index, 'Bash', true))
    await writeFile(path, lines.join('\n') + '\n', 'utf8')

    const whole = await readToolTrail(path, TRAIL_WINDOW_BYTES)
    expect(whole.partial).toBe(false)
    expect(whole.events).toHaveLength(200)

    const tail = await readToolTrail(path, 4096)
    expect(tail.partial).toBe(true)
    expect(tail.fromByte).toBeGreaterThan(0)
    expect(tail.events.length).toBeLessThan(200)
    // The torn first line is dropped by `JSON.parse`, not by a hand-rolled
    // scan, so the first surviving event is a whole one.
    expect(tail.events.every((event) => event.name === 'Bash')).toBe(true)
  })

  it('answers an empty trail for a path that is missing, a directory, or unreadable', async () => {
    const dir = await tempDir()
    // A scan reads a set of transcripts. One bad path must cost that path its
    // answer and nothing else — the alerts scanner would otherwise lose a whole
    // project's alerts to a file deleted between the listing and the read.
    expect(await readToolTrail(join(dir, 'nope.jsonl'), TRAIL_WINDOW_BYTES)).toEqual(emptyTrail())
    await mkdir(join(dir, 'folder'))
    expect(await readToolTrail(join(dir, 'folder'), TRAIL_WINDOW_BYTES)).toEqual(emptyTrail())
  })

  it('feeds a verdict that is unknown rather than healthy when there is nothing there', async () => {
    const dir = await tempDir()
    const path = join(dir, 'empty.jsonl')
    await writeFile(path, '', 'utf8')

    const report = assessProgress(await readToolTrail(path, TRAIL_WINDOW_BYTES))
    expect(report.verdict).toBe('unknown')
    expect(report.unknownReason).not.toBeNull()
  })
})
