import { describe, expect, it, vi } from 'vitest'
import { SUBMIT_GAP_MS, submitWrites, typeAndSubmit } from './copilot-say'

describe('submitWrites', () => {
  /*
   * The regression, stated as the two facts that were wrong at once. This file
   * exists because a phone could talk to the copilot for a whole evening and
   * never receive one answer, and both halves of the old `${text}\n` are here so
   * that neither can quietly come back.
   */
  it('submits with a carriage return, never a newline', () => {
    const [, submit] = submitWrites('hello')
    expect(submit).toBe('\r')
    expect(submit).not.toContain('\n')
  })

  it('keeps the sentence and the submit in separate writes', () => {
    // A CLI classifies each stdin *chunk* before it reads the keys in it, and a
    // chunk of ~64 bytes or more is pasted text where a Return is a newline. So
    // the Return has to be alone in its own read, which is what two writes are.
    const long = 'x'.repeat(400)
    const [typed, submit] = submitWrites(long)
    expect(typed).toBe(long)
    expect(submit).toBe('\r')
  })
})

describe('typeAndSubmit', () => {
  it('types now and submits after the gap', () => {
    const writes: string[] = []
    let deferred: (() => void) | null = null
    let waited = 0
    typeAndSubmit(
      (data) => writes.push(data),
      'do the thing',
      (ms, run) => {
        waited = ms
        deferred = run
      },
    )
    // Typed synchronously: a caller that reports success is reporting something
    // that has already reached the pty.
    expect(writes).toEqual(['do the thing'])
    expect(waited).toBe(SUBMIT_GAP_MS)
    deferred!()
    expect(writes).toEqual(['do the thing', '\r'])
  })

  it('throws to the caller when the sentence itself will not write', () => {
    // `CopilotRuns.say` turns this into a refusal the phone can read. A silent
    // failure here is exactly the shape of the bug this file is about.
    expect(() =>
      typeAndSubmit(
        () => {
          throw new Error('pty is gone')
        },
        'hello',
        (_ms, run) => run(),
      ),
    ).toThrow('pty is gone')
  })

  it('swallows a failure on the deferred Return', () => {
    // By then the caller has been answered and there is nobody to tell; an
    // exception out of a timer would be an unhandled rejection instead.
    const error = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    let calls = 0
    expect(() =>
      typeAndSubmit(
        () => {
          calls += 1
          if (calls === 2) throw new Error('pty closed between the two writes')
        },
        'hello',
        (_ms, run) => run(),
      ),
    ).not.toThrow()
    expect(calls).toBe(2)
    error.mockRestore()
  })
})
