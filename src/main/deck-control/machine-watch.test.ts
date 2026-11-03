import { afterEach, describe, expect, it, vi } from 'vitest'
import type { CopilotChatMessage } from '../remote/protocol'
import { createChannelTap, type ChannelTap, type TappableIpc } from './channel-tap'
import { answeredAfter, watchMachines, type MachineWatch } from './machine-watch'

let watch: MachineWatch | null = null

afterEach(() => {
  watch?.dispose()
  watch = null
  vi.useRealTimers()
})

/**
 * A tap on a stand-in `ipcMain` with the five channels the watch listens to
 * registered as no-ops — registered *through* the patched `handle`, which is
 * what `registerMachinesIpc` does — so a test makes the calls the window makes
 * and they go past the tap the same way.
 */
function tapped(): ChannelTap {
  const tap = createChannelTap()
  const ipc: TappableIpc = { handle: () => undefined, on: () => undefined }
  tap.attach(ipc)
  for (const channel of ['machines:attach', 'machines:resize', 'machines:detach', 'machines:close', 'machines:forget']) {
    ipc.handle(channel, () => true)
  }
  return tap
}

/** Play the window: an invocation goes past the tap, then the far machine's pushes arrive. */
function windowAttaches(tap: ChannelTap, machineId: string, sessionId: string, cols: number, rows: number): void {
  void tap.invoke('machines:attach', machineId, sessionId, cols, rows)
}

function output(tap: ChannelTap, machineId: string, sessionId: string, data: string, replay = false): void {
  tap.pushed('machines:output', [{ machineId, sessionId, data, replay }])
}

const message = (id: string, role: 'you' | 'agent', text: string): CopilotChatMessage => ({ id, role, text, at: 0 })

describe('a remote session’s screen', () => {
  it('is drawn at the size the window attached with', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    windowAttaches(tap, 'm1', 's1', 40, 5)
    output(tap, 'm1', 's1', 'hello from the office\r\n❯ ')
    const screen = await watch.screen('m1', 's1')
    expect(screen?.cols).toBe(40)
    expect(screen?.rows).toBe(5)
    expect(screen?.text).toContain('hello from the office')
    expect(screen?.live).toBe(true)
  })

  it('is nothing for a session nothing here has attached to', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    output(tap, 'm1', 's9', 'bytes nobody asked for')
    expect(await watch.screen('m1', 's9')).toBeNull()
  })

  it('starts again on a re-attach, because the far end replays everything', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    windowAttaches(tap, 'm1', 's1', 40, 5)
    output(tap, 'm1', 's1', 'first line')
    windowAttaches(tap, 'm1', 's1', 40, 5)
    output(tap, 'm1', 's1', 'first line', true)
    const text = (await watch.screen('m1', 's1'))?.text ?? ''
    // Once, not twice — the replay went into a fresh terminal.
    expect(text.match(/first line/g)?.length).toBe(1)
  })

  it('says when it is only the last screen seen', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    windowAttaches(tap, 'm1', 's1', 40, 5)
    output(tap, 'm1', 's1', 'still here')
    void tap.invoke('machines:detach', 'm1', 's1')
    const screen = await watch.screen('m1', 's1')
    expect(screen?.live).toBe(false)
    expect(screen?.text).toContain('still here')
    expect(watch.attached('m1', 's1')).toBe(false)
  })

  it('follows a resize', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    windowAttaches(tap, 'm1', 's1', 40, 5)
    void tap.invoke('machines:resize', 'm1', 's1', 100, 20)
    expect((await watch.screen('m1', 's1'))?.cols).toBe(100)
  })

  it('forgets a machine’s screens when the machine is forgotten', async () => {
    const tap = tapped()
    watch = watchMachines(tap)
    windowAttaches(tap, 'm1', 's1', 40, 5)
    void tap.invoke('machines:forget', 'm1')
    expect(await watch.screen('m1', 's1')).toBeNull()
  })

  it('keeps at most the bound, letting go of the one untouched longest', async () => {
    const tap = tapped()
    let clock = 0
    watch = watchMachines(tap, { maxScreens: 2, now: () => ++clock })
    windowAttaches(tap, 'm1', 'a', 40, 5)
    windowAttaches(tap, 'm1', 'b', 40, 5)
    output(tap, 'm1', 'a', 'a is busy')
    windowAttaches(tap, 'm1', 'c', 40, 5)
    expect(await watch.screen('m1', 'b')).toBeNull()
    expect(await watch.screen('m1', 'a')).not.toBeNull()
    expect(await watch.screen('m1', 'c')).not.toBeNull()
  })
})

describe('the far copilot’s conversation', () => {
  const chat = (tap: ChannelTap, machineId: string, run: string, messages: CopilotChatMessage[], reset = false): void =>
    tap.pushed('machines:copilot:chat', [{ machineId, chat: { t: 'copilot.chat', run, messages, ...(reset ? { reset: true } : {}) } }])

  it('merges by id, and a reset replaces everything', () => {
    const tap = createChannelTap()
    watch = watchMachines(tap)
    chat(tap, 'm1', 'r1', [message('1', 'you', 'hi'), message('2', 'agent', 'hel')], true)
    chat(tap, 'm1', 'r1', [message('2', 'agent', 'hello')])
    expect(watch.conversation('m1').messages.map((one) => one.text)).toEqual(['hi', 'hello'])
    chat(tap, 'm1', 'r2', [message('9', 'you', 'new run')], true)
    expect(watch.conversation('m1').messages.map((one) => one.id)).toEqual(['9'])
    expect(watch.conversation('m1').run).toBe('r2')
  })

  it('drops a late frame from a run that is over', () => {
    const tap = createChannelTap()
    watch = watchMachines(tap)
    chat(tap, 'm1', 'r2', [message('1', 'you', 'now')], true)
    chat(tap, 'm1', 'r1', [message('x', 'agent', 'an answer to something never asked in this run')])
    expect(watch.conversation('m1').messages.map((one) => one.id)).toEqual(['1'])
  })

  it('keeps the state it was pushed', () => {
    const tap = createChannelTap()
    watch = watchMachines(tap)
    tap.pushed('machines:copilot:state', [{ machineId: 'm1', state: { desk: 'running' } }])
    expect(watch.conversation('m1').state).toEqual({ desk: 'running' })
  })

  it('waits for an answer to what was said after the baseline, not the one already there', async () => {
    vi.useFakeTimers()
    const tap = createChannelTap()
    watch = watchMachines(tap)
    chat(tap, 'm1', 'r1', [message('1', 'you', 'old'), message('2', 'agent', 'old answer')], true)
    const answered = watch.replied('m1', '2', 10_000, 1000)
    // The old answer is last right now; that must not settle it.
    vi.advanceTimersByTime(1500)
    chat(tap, 'm1', 'r1', [message('3', 'you', 'new question')])
    chat(tap, 'm1', 'r1', [message('4', 'agent', 'the start of')])
    vi.advanceTimersByTime(500)
    chat(tap, 'm1', 'r1', [message('4', 'agent', 'the start of the new answer')])
    vi.advanceTimersByTime(1001)
    expect(await answered).toBe(true)
  })

  it('answers false at the ceiling when nothing came back', async () => {
    vi.useFakeTimers()
    const tap = createChannelTap()
    watch = watchMachines(tap)
    const answered = watch.replied('m1', null, 2000, 500)
    vi.advanceTimersByTime(2001)
    expect(await answered).toBe(false)
  })

  it('hears the next change, for a first read', async () => {
    const tap = createChannelTap()
    watch = watchMachines(tap)
    const changed = watch.nextChange('m1', 1000)
    tap.pushed('machines:copilot:state', [{ machineId: 'm1', state: { desk: 'stopped' } }])
    expect(await changed).toBe(true)
  })
})

describe('whether the agent has answered', () => {
  it('needs one of ours after the baseline, then the agent last', () => {
    const old = [message('1', 'you', 'q'), message('2', 'agent', 'a')]
    expect(answeredAfter(old, '2')).toBe(false)
    expect(answeredAfter([...old, message('3', 'you', 'q2')], '2')).toBe(false)
    expect(answeredAfter([...old, message('3', 'you', 'q2'), message('4', 'agent', 'a2')], '2')).toBe(true)
    // A baseline a reset removed counts everything as new.
    expect(answeredAfter([message('5', 'you', 'q'), message('6', 'agent', 'a')], 'gone')).toBe(true)
    expect(answeredAfter([message('5', 'you', 'q'), message('6', 'agent', '   ')], null)).toBe(false)
  })
})
