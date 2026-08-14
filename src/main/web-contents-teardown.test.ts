import { EventEmitter } from 'node:events'
import { describe, expect, it, vi } from 'vitest'
import type { WebContents } from 'electron'
import {
  offWebContentsDestroyed,
  onWebContentsDestroyed,
  pendingTeardowns,
} from './web-contents-teardown'

/**
 * A WebContents is an EventEmitter with an `isDestroyed()`, and those are the
 * only two things this module touches — so the real one is not needed, and a
 * fake lets `listenerCount` be asserted directly. Counting listeners is the
 * whole point: the bug being prevented is a count, not a behaviour.
 */
class FakeWebContents extends EventEmitter {
  private dead = false

  isDestroyed(): boolean {
    return this.dead
  }

  die(): void {
    this.dead = true
    this.emit('destroyed')
  }
}

function fake(): { contents: WebContents; fakeContents: FakeWebContents } {
  const fakeContents = new FakeWebContents()
  return { contents: fakeContents as unknown as WebContents, fakeContents }
}

describe('one listener per WebContents, however many owners', () => {
  it('attaches exactly one destroyed listener for many registrations', () => {
    const { contents, fakeContents } = fake()

    for (const key of ['plan-limit', 'cost', 'mcp', 'git-watch', 'file-search']) {
      onWebContentsDestroyed(contents, key, () => undefined)
    }

    // The whole reason this module exists: eleven owners used to mean eleven
    // listeners on one emitter, and Node warns past ten.
    expect(fakeContents.listenerCount('destroyed')).toBe(1)
    expect(pendingTeardowns(contents)).toEqual([
      'cost',
      'file-search',
      'git-watch',
      'mcp',
      'plan-limit',
    ])
  })

  it('stays at one registration when the same key registers repeatedly', () => {
    const { contents, fakeContents } = fake()

    // `plan:watch` runs once per session and `cost:watch` once per project, so
    // this is the ordinary case, not an edge one. Before the key existed, each
    // call added a listener and the count grew with how much of the app you had
    // open.
    for (let i = 0; i < 50; i++) {
      onWebContentsDestroyed(contents, 'plan-limit', () => undefined)
    }

    expect(fakeContents.listenerCount('destroyed')).toBe(1)
    expect(pendingTeardowns(contents)).toEqual(['plan-limit'])
  })

  it('keeps the most recent callback for a key', () => {
    const { contents } = fake()
    const first = vi.fn()
    const second = vi.fn()

    onWebContentsDestroyed(contents, 'cost', first)
    onWebContentsDestroyed(contents, 'cost', second)
    ;(contents as unknown as FakeWebContents).die()

    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledTimes(1)
  })

  it('runs every owner when the contents dies, and forgets them', () => {
    const { contents } = fake()
    const plan = vi.fn()
    const cost = vi.fn()

    onWebContentsDestroyed(contents, 'plan-limit', plan)
    onWebContentsDestroyed(contents, 'cost', cost)
    ;(contents as unknown as FakeWebContents).die()

    expect(plan).toHaveBeenCalledTimes(1)
    expect(cost).toHaveBeenCalledTimes(1)
    expect(pendingTeardowns(contents)).toEqual([])
  })

  it('keeps separate contents separate', () => {
    const a = fake()
    const b = fake()
    const onA = vi.fn()
    const onB = vi.fn()

    onWebContentsDestroyed(a.contents, 'cost', onA)
    onWebContentsDestroyed(b.contents, 'cost', onB)
    a.fakeContents.die()

    expect(onA).toHaveBeenCalledTimes(1)
    expect(onB).not.toHaveBeenCalled()
  })
})

describe('the awkward cases', () => {
  it('runs immediately against contents that is already destroyed', () => {
    const { contents, fakeContents } = fake()
    fakeContents.die()

    const callback = vi.fn()
    onWebContentsDestroyed(contents, 'cost', callback)

    // `once('destroyed')` on a dead emitter never fires, so registering a moment
    // too late would hold the resource forever.
    expect(callback).toHaveBeenCalledTimes(1)
    expect(fakeContents.listenerCount('destroyed')).toBe(0)
  })

  it('lets one owner throw without stopping the others', () => {
    const { contents, fakeContents } = fake()
    const console_ = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const after = vi.fn()

    onWebContentsDestroyed(contents, 'throws', () => {
      throw new Error('teardown went wrong')
    })
    onWebContentsDestroyed(contents, 'after', after)

    // Teardown is when the app can least afford a throw: the remaining owners
    // still hold watchers, child processes and timers.
    expect(() => fakeContents.die()).not.toThrow()
    expect(after).toHaveBeenCalledTimes(1)
    expect(console_).toHaveBeenCalled()
    console_.mockRestore()
  })

  it('survives an owner that unregisters another mid-teardown', () => {
    const { contents, fakeContents } = fake()
    const sibling = vi.fn()

    // Real shape, not a contrivance: releasing a shared entry can drop the
    // siblings that shared it, and mutating a Set while iterating it skips
    // entries.
    onWebContentsDestroyed(contents, 'first', () => offWebContentsDestroyed(contents, 'sibling'))
    onWebContentsDestroyed(contents, 'sibling', sibling)

    expect(() => fakeContents.die()).not.toThrow()
    expect(sibling).toHaveBeenCalledTimes(1)
  })

  it('drops a registration on request without disturbing the rest', () => {
    const { contents, fakeContents } = fake()
    const gone = vi.fn()
    const kept = vi.fn()

    onWebContentsDestroyed(contents, 'gone', gone)
    onWebContentsDestroyed(contents, 'kept', kept)
    offWebContentsDestroyed(contents, 'gone')
    fakeContents.die()

    expect(gone).not.toHaveBeenCalled()
    expect(kept).toHaveBeenCalledTimes(1)
  })
})
