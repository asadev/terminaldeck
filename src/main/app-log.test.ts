import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * What has to hold for a log that runs for months unattended: it never grows
 * past its cap, it never throws into the code that is trying to report a
 * problem, and a rotation that just happened does not make the last few minutes
 * of history disappear — which is precisely when someone is reading it.
 */

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return {
    app: { getPath: () => j(tmp(), `terminaldeck-app-log-test-${process.pid}`, 'userData') },
    shell: { openPath: async () => '' },
  }
})

const { AppLog, createAppLog, formatLine } = await import('./app-log')

const ROOT = join(tmpdir(), `terminaldeck-app-log-test-${process.pid}`)

beforeEach(() => {
  rmSync(ROOT, { recursive: true, force: true })
  mkdirSync(ROOT, { recursive: true })
})

afterAll(() => rmSync(ROOT, { recursive: true, force: true }))

function log(overrides: Partial<ConstructorParameters<typeof AppLog>[0]> = {}) {
  return createAppLog({ dir: join(ROOT, 'logs'), maxBytes: 4096, keep: 2, ...overrides })
}

describe('formatLine', () => {
  it('renders one line per entry, whatever the message contains', () => {
    const line = formatLine({ at: Date.parse('2026-08-12T09:00:00Z'), level: 'warn', scope: 'git', message: 'a\r\nb' })
    expect(line).toBe('2026-08-12T09:00:00.000Z WARN  [git] a b')
  })

  it('truncates a runaway line rather than letting it become the whole file', () => {
    const line = formatLine({ at: 0, level: 'info', scope: 's', message: 'x'.repeat(10_000) })
    expect(line.length).toBeLessThan(4100)
    expect(line).toContain('truncated')
  })

  it('survives data it cannot serialise', () => {
    const cyclic: Record<string, unknown> = {}
    cyclic.self = cyclic
    expect(formatLine({ at: 0, level: 'error', scope: 's', message: 'm', data: cyclic })).toContain(
      'unserialisable',
    )
  })
})

describe('rotation', () => {
  it('caps the live file and keeps the previous generation', () => {
    const subject = log()
    for (let i = 0; i < 200; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)

    expect(statSync(subject.file).size).toBeLessThanOrEqual(4096)
    expect(existsSync(`${subject.file}.1`)).toBe(true)
  })

  it('never keeps more generations than it was told to', () => {
    const subject = log({ keep: 1 })
    for (let i = 0; i < 500; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)

    expect(existsSync(`${subject.file}.1`)).toBe(true)
    expect(existsSync(`${subject.file}.2`)).toBe(false)
  })

  it('total size stays inside the cap times the generations kept', () => {
    const subject = log({ keep: 2 })
    for (let i = 0; i < 800; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)

    const total = subject.status().files.reduce((sum, file) => sum + file.bytes, 0)
    expect(total).toBeLessThanOrEqual(4096 * 3)
  })

  it('reaches back into the previous generation when the live file is short', () => {
    const subject = log()
    for (let i = 0; i < 60; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)

    const tail = subject.tail(50)
    expect(tail.length).toBe(50)
    // Rotation happened, so a naive tail would return only the handful of
    // lines written since — the history the reader actually wants is in .1.
    expect(readFileSync(subject.file, 'utf8').split('\n').filter(Boolean).length).toBeLessThan(50)
  })
})

describe('tail', () => {
  it('returns the most recent lines, oldest first', () => {
    const subject = log()
    subject.info('a', 'first')
    subject.warn('b', 'second')
    subject.error('c', 'third')

    const tail = subject.tail(2)
    expect(tail).toHaveLength(2)
    expect(tail[0]).toContain('second')
    expect(tail[1]).toContain('third')
  })

  it('is empty rather than throwing before anything has been written', () => {
    expect(log().tail()).toEqual([])
  })

  /**
   * `slice(-n)` is the trap: `slice(-0)` and `slice(NaN)` both mean "everything".
   * The bundle passes this count straight through from the renderer, so an
   * out-of-range number quietly turned "the last 200 lines" into the entire log
   * across every generation — the opposite of what was asked for, in the one
   * artefact written to be pasted somewhere public.
   */
  it('returns nothing when asked for nothing, rather than everything', () => {
    const subject = log()
    for (let i = 0; i < 50; i += 1) subject.info('bulk', `line ${i}`)

    expect(subject.tail(0)).toEqual([])
    expect(subject.tail(-5)).toEqual([])
    expect(subject.tail(Number.NaN)).toEqual([])
    expect(subject.tail(3)).toHaveLength(3)
  })

  it('never returns more than it was asked for, however large the ask', () => {
    const subject = log()
    for (let i = 0; i < 50; i += 1) subject.info('bulk', `line ${i}`)
    expect(subject.tail(1e9)).toHaveLength(50)
  })
})

describe('resilience', () => {
  it('does not throw when the log directory cannot be created', () => {
    // A file where the directory should be — the same shape as a read-only
    // volume or a sandbox denial, and logging must not take the app down.
    const blocked = join(ROOT, 'blocked')
    writeFileSync(blocked, 'not a directory')
    const subject = createAppLog({ dir: join(blocked, 'logs') })
    expect(() => subject.error('boot', 'something failed')).not.toThrow()
    expect(subject.tail()).toEqual([])
  })

  it('clears every generation', () => {
    const subject = log()
    for (let i = 0; i < 200; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)
    subject.clear()

    expect(existsSync(subject.file)).toBe(false)
    expect(existsSync(`${subject.file}.1`)).toBe(false)
    expect(subject.tail()).toEqual([])
  })

  it('reports its own size and generations', () => {
    const subject = log()
    subject.info('a', 'first')
    const status = subject.status()
    expect(status.bytes).toBeGreaterThan(0)
    expect(status.files[0].name).toContain('.log')
    expect(status.maxBytes).toBe(4096)
  })

  /**
   * `join` drops a trailing separator, so naming a file by slicing `dir.length`
   * characters off the front ate the first character of every filename — the
   * live log was reported as `awl.log`.
   */
  it('names its files correctly when the directory was given with a trailing slash', () => {
    const subject = createAppLog({ dir: `${join(ROOT, 'trailing')}/`, maxBytes: 4096, keep: 2 })
    subject.info('a', 'first')
    expect(subject.status().files[0].name).toBe(basename(subject.file))
  })

  it('reports the live file’s size, not a rotated generation’s', () => {
    const subject = log()
    for (let i = 0; i < 200; i += 1) subject.info('bulk', `line ${i} ${'y'.repeat(100)}`)
    // Remove the live file only; `.1` survives and used to be reported as it.
    rmSync(subject.file, { force: true })

    expect(existsSync(`${subject.file}.1`)).toBe(true)
    expect(subject.status().bytes).toBe(0)
  })
})
