import { describe, expect, it, vi } from 'vitest'
import { ConsentBroker, DEFAULT_MAX_PENDING, type ConsentOutcome, type ConsentRequest } from './consent'

/**
 * Every way a question can end.
 *
 * This is the file that would fail if somebody made the gate open by default,
 * so it is written as a list of the conditions the app is *not* in: no window,
 * a window that never answers, a window that closes, a shutdown, a caller that
 * hangs up, and too many questions at once. Only one route reaches
 * `granted: true`, and it needs a person.
 *
 * Timeouts here are single-digit milliseconds rather than the real two minutes.
 * That is a real timer on a real clock, just a short one — the alternative,
 * waiting out the production value, would make this file take four minutes and
 * teach nothing extra.
 */

function ask(): { broker: ConsentBroker; seen: ConsentRequest[]; settled: Array<[string, ConsentOutcome]> } {
  const seen: ConsentRequest[] = []
  const settled: Array<[string, ConsentOutcome]> = []
  const broker = new ConsentBroker({
    ask: (request) => {
      seen.push(request)
      return true
    },
    settled: (id, outcome) => settled.push([id, outcome]),
    timeoutMs: 5,
  })
  return { broker, seen, settled }
}

const question = { tool: 'settings.write', tier: 'alter' as const, summary: 'Change the theme', args: {} }

describe('nobody to ask', () => {
  it('refuses when delivery fails, without waiting for a timeout', async () => {
    const broker = new ConsentBroker({ ask: () => false, timeoutMs: 60_000 })
    const started = Date.now()
    const outcome = await broker.request(question)

    expect(outcome).toMatchObject({ granted: false, reason: 'no-approver' })
    // The point of the assertion is not the number: it is that a machine with
    // no window open does not hold a tool call for two minutes to tell it so.
    expect(Date.now() - started).toBeLessThan(1000)
  })

  it('refuses when the delivery callback throws, and does not propagate it', async () => {
    const broker = new ConsentBroker({
      ask: () => {
        throw new Error('the window went away mid-send')
      },
      timeoutMs: 5,
    })
    await expect(broker.request(question)).resolves.toMatchObject({
      granted: false,
      reason: 'no-approver',
    })
  })

  it('forgets the question it could not deliver', async () => {
    const broker = new ConsentBroker({ ask: () => false })
    await broker.request(question)
    // An undelivered question left in the map would show up in a window that
    // opened afterwards, as a dialog for a call that already returned.
    expect(broker.list()).toEqual([])
  })
})

describe('nobody answers', () => {
  it('refuses on timeout', async () => {
    const { broker, settled } = ask()
    await expect(broker.request(question)).resolves.toMatchObject({
      granted: false,
      reason: 'timeout',
    })
    expect(settled[0][1]).toMatchObject({ granted: false, reason: 'timeout' })
  })

  it('stops accepting an answer once it has timed out', async () => {
    const { broker, seen } = ask()
    const pending = broker.request(question)
    await pending
    // The dialog is still on screen in the renderer; the person clicks Allow.
    // It must not land. Otherwise a change happens after the model was told it
    // did not, which is the worst of both outcomes.
    expect(broker.respond(seen[0].id, true, 'window')).toBe(false)
  })
})

describe('the window goes away', () => {
  it('refuses everything outstanding at once', async () => {
    const { broker } = ask()
    const one = broker.request(question)
    const two = broker.request({ ...question, summary: 'Change the sound' })
    broker.approverGone()

    expect(await one).toMatchObject({ granted: false, reason: 'approver-gone' })
    expect(await two).toMatchObject({ granted: false, reason: 'approver-gone' })
    expect(broker.list()).toEqual([])
  })
})

describe('the app is closing', () => {
  it('refuses what is outstanding and everything asked afterwards', async () => {
    const { broker } = ask()
    const pending = broker.request(question)
    broker.stop()

    expect(await pending).toMatchObject({ granted: false, reason: 'shutting-down' })
    await expect(broker.request(question)).resolves.toMatchObject({
      granted: false,
      reason: 'shutting-down',
    })
  })
})

describe('the caller hangs up', () => {
  it('refuses immediately when the signal is already aborted', async () => {
    const { broker, seen } = ask()
    const controller = new AbortController()
    controller.abort()

    await expect(broker.request({ ...question, signal: controller.signal })).resolves.toMatchObject({
      granted: false,
      reason: 'caller-gone',
    })
    // Never delivered: there is nobody left to answer it, so putting a dialog
    // on somebody's screen would be asking about a call that no longer exists.
    expect(seen).toEqual([])
  })

  it('cancels a live question when the connection drops', async () => {
    const { broker, seen } = ask()
    const controller = new AbortController()
    const pending = broker.request({ ...question, signal: controller.signal, tool: 'settings.write' })
    expect(seen).toHaveLength(1)

    controller.abort()
    expect(await pending).toMatchObject({ granted: false, reason: 'caller-gone' })

    /*
     * The whole reason this exists: the person clicks Allow a second later,
     * after their client gave up. It must change nothing. A `false` here is the
     * difference between "the model was told no and nothing happened" and "the
     * model was told no and the setting changed anyway".
     */
    expect(broker.respond(seen[0].id, true, 'window')).toBe(false)
  })
})

describe('too many at once', () => {
  it('refuses past the cap rather than stacking dialogs', async () => {
    const broker = new ConsentBroker({ ask: () => true, timeoutMs: 60_000 })
    const held = Array.from({ length: DEFAULT_MAX_PENDING }, () => broker.request(question))
    expect(broker.list()).toHaveLength(DEFAULT_MAX_PENDING)

    await expect(broker.request(question)).resolves.toMatchObject({
      granted: false,
      reason: 'too-many-pending',
    })

    broker.stop()
    await Promise.all(held)
  })
})

describe('a person answers', () => {
  it('grants, and records who and when', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, tool: 'settings.write' })
    const accepted = broker.respond(seen[0].id, true, 'window')

    expect(accepted).toBe(true)
    expect(await pending).toMatchObject({ granted: true, by: 'window' })
  })

  it('declines, and says so distinctly from a timeout', async () => {
    const { broker, seen } = ask()
    const pending = broker.request(question)
    broker.respond(seen[0].id, false, 'window')

    // A decline and a timeout are different instructions to the model: one
    // means stop asking, the other means the person is away.
    expect(await pending).toMatchObject({ granted: false, reason: 'declined', by: 'window' })
  })

  it('treats anything that is not a literal yes as no', async () => {
    // `respond` takes a boolean, so this is about the layer above: `index.ts`
    // compares against `true`. Pinned here because the failure — a dialog that
    // sent `undefined` through a wiring mistake reading as approval — is
    // silent.
    const { broker, seen } = ask()
    const pending = broker.request(question)
    broker.respond(seen[0].id, (undefined as unknown as boolean) === true, 'window')
    expect(await pending).toMatchObject({ granted: false, reason: 'declined' })
  })

  it('answers a second time to nothing', async () => {
    const { broker, seen } = ask()
    const pending = broker.request(question)
    expect(broker.respond(seen[0].id, true, 'window')).toBe(true)
    expect(broker.respond(seen[0].id, false, 'window')).toBe(false)
    expect(await pending).toMatchObject({ granted: true })
  })

  it('survives a settled-subscriber that throws', async () => {
    const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const seen: ConsentRequest[] = []
    const broker = new ConsentBroker({
      ask: (request) => {
        seen.push(request)
        return true
      },
      settled: () => {
        throw new Error('the pane blew up')
      },
      timeoutMs: 5,
    })
    const pending = broker.request(question)
    broker.respond(seen[0].id, true, 'window')
    // The answer was already delivered before the subscriber ran; a broken
    // Activity pane cannot turn an approval into a refusal.
    expect(await pending).toMatchObject({ granted: true })
    errors.mockRestore()
  })
})

describe('what a window that opens late can see', () => {
  it('lists what is still outstanding, with the deadline attached', async () => {
    const broker = new ConsentBroker({ ask: () => true, timeoutMs: 60_000 })
    const pending = broker.request(question)
    const [live] = broker.list()

    expect(live.tool).toBe('settings.write')
    expect(live.summary).toBe('Change the theme')
    // The dialog needs to be able to show how long is left, or a question that
    // vanishes mid-read looks like a bug rather than a deadline.
    expect(live.expiresAt).toBeGreaterThan(live.requestedAt)

    broker.stop()
    await pending
  })
})

/* ----------------------------------------------------- who may answer what */

/**
 * **A question may only be answered by the surface that raised it, or by the
 * desktop.**
 *
 * The rule `COPILOT-REMOTE.md` §4.2 flags as the non-obvious one, and it lives
 * here rather than in a transport for the reason `control.ts` gives about its own
 * gate: a rule enforced in one transport is a rule the next transport does not
 * have. It became load-bearing the day a connected device could answer at all —
 * before that there was one approver and nothing to get wrong.
 *
 * The desktop is exempt because the desktop is the machine: somebody standing at
 * it can already do by hand whatever they would be approving, so refusing them
 * the dialog would protect nothing and would strand every question raised by a
 * device that has since walked out of the building.
 */
describe('the surface that may answer', () => {
  it('lets the surface that raised it answer', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, origin: 'device:phone-1' })
    expect(broker.respond(seen[0].id, true, 'device:phone-1')).toBe(true)
    expect(await pending).toMatchObject({ granted: true, by: 'device:phone-1' })
  })

  it('lets the desktop answer anything, including a device’s question', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, origin: 'device:phone-1' })
    expect(broker.respond(seen[0].id, true, 'window')).toBe(true)
    expect(await pending).toMatchObject({ granted: true, by: 'window' })
  })

  /**
   * The one that matters: device A cannot answer device B's question.
   *
   * Otherwise connecting two devices to one copilot makes either of them able to
   * approve the other's actions, which is a permission model with a shared
   * password. `false` is the same answer a settled id gets, deliberately — a
   * device probing for other devices' question ids must learn nothing from the
   * reply.
   */
  it('refuses another device, and says nothing more than a stale id would', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, origin: 'device:phone-1' })

    expect(broker.respond(seen[0].id, true, 'device:phone-2')).toBe(false)
    expect(broker.respond('never-existed', true, 'device:phone-2')).toBe(false)
    // Still live: the other device's tap changed nothing at all.
    expect(broker.list()).toHaveLength(1)

    broker.respond(seen[0].id, false, 'window')
    expect(await pending).toMatchObject({ granted: false, reason: 'declined' })
  })

  it('refuses a device on a question raised at the desk', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, origin: 'window' })
    expect(broker.respond(seen[0].id, true, 'device:phone-1')).toBe(false)
    broker.respond(seen[0].id, true, 'window')
    expect(await pending).toMatchObject({ granted: true })
  })

  /**
   * An unnamed origin is the window's, and the default is the **narrow** value.
   *
   * A caller that forgot to say where its question came from therefore loses the
   * ability to answer it from anywhere but the desk, which is the failure
   * direction this whole file stays in. Every caller that predates devices
   * answering anything is in exactly that position and is correct by default.
   */
  it('defaults an unnamed origin to the window', async () => {
    const { broker, seen } = ask()
    const pending = broker.request(question)
    expect(seen[0].origin).toBe('window')
    expect(broker.respond(seen[0].id, true, 'device:phone-1')).toBe(false)
    broker.respond(seen[0].id, true, 'window')
    await pending
  })

  it('says who may answer before a dialog is drawn', async () => {
    const { broker, seen } = ask()
    const pending = broker.request({ ...question, origin: 'device:phone-1' })
    // Asked so a transport can decide whether to *offer* an Allow button rather
    // than only whether to honour one. A control that is always refused is the
    // defect this repository has paid for twice.
    expect(broker.mayAnswer(seen[0].id, 'device:phone-1')).toBe(true)
    expect(broker.mayAnswer(seen[0].id, 'device:phone-2')).toBe(false)
    expect(broker.mayAnswer(seen[0].id, 'window')).toBe(true)
    expect(broker.mayAnswer('never-existed', 'window')).toBe(false)
    broker.stop()
    await pending
  })
})

describe('the surface that raised it goes away', () => {
  /**
   * Its questions are refused at once, with `caller-gone`.
   *
   * Not left for the desktop to answer, even though the desktop may answer
   * anything: the run that asked is about to be reaped, the person who asked is
   * gone, and an approval landing afterwards is a change nobody is waiting for.
   */
  it('refuses that surface’s questions and leaves the others alone', async () => {
    const { broker, seen } = ask()
    const mine = broker.request({ ...question, origin: 'device:phone-1' })
    const theirs = broker.request({ ...question, origin: 'window' })
    expect(seen).toHaveLength(2)

    broker.callerGone('device:phone-1')
    expect(await mine).toMatchObject({ granted: false, reason: 'caller-gone' })

    // The desk's question is untouched: a device leaving removed a watcher, not
    // an approver, for anything it did not raise.
    expect(broker.list()).toHaveLength(1)
    broker.respond(broker.list()[0].id, true, 'window')
    expect(await theirs).toMatchObject({ granted: true })
  })

  /**
   * `callerGone('window')` throws rather than quietly meaning "everything".
   *
   * It reads like a narrower call than `approverGone()` and is not, and a silent
   * alias is how somebody ends up refusing every device's question because a
   * renderer reloaded.
   */
  it('refuses to be used as the window’s version', () => {
    const { broker } = ask()
    expect(() => broker.callerGone('window')).toThrow(/approverGone/)
  })
})
