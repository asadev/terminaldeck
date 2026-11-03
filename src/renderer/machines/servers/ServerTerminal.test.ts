import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { MOST_HELD_BYTES, ShellFrames } from './ServerTerminal'

/**
 * The race between a shell's first bytes and the shell's own name.
 *
 * Found by looking at it: the terminal opened, painted nothing, and only came
 * to life once something was typed — which reads as a terminal that failed to
 * open. The far side attaches its output listener the moment the shell exists,
 * so the login banner and the prompt are already on their way while the id that
 * names that shell is still travelling back the other way.
 *
 * These are the two bytes-losing directions and the leak, pinned.
 */

const frame = (shellId: string, data: string) => ({ shellId, data })

describe('output that arrives before the shell has a name', () => {
  it('holds it, and writes it once the name arrives', () => {
    const frames = new ShellFrames()
    // The prompt: the single most important thing this terminal ever paints,
    // and the thing a naive filter drops.
    expect(frames.arrived(frame('s1 abc', 'admin@shop:~$ '))).toBe('')
    expect(frames.settled('s1 abc')).toBe('admin@shop:~$ ')
  })

  it('writes what it held in the order it arrived', () => {
    const frames = new ShellFrames()
    frames.arrived(frame('s1 abc', 'one\n'))
    frames.arrived(frame('s1 abc', 'two\n'))
    expect(frames.settled('s1 abc')).toBe('one\ntwo\n')
  })

  it('throws away what belonged to a different shell', () => {
    // Two panes, or one that was closed and reopened. A frame from the shell
    // that is going away must not be painted into the one that is arriving.
    const frames = new ShellFrames()
    frames.arrived(frame('s1 old', 'stale\n'))
    frames.arrived(frame('s1 new', 'fresh\n'))
    expect(frames.settled('s1 new')).toBe('fresh\n')
  })

  it('passes frames straight through once the name is known', () => {
    const frames = new ShellFrames()
    frames.settled('s1 abc')
    expect(frames.arrived(frame('s1 abc', 'hello'))).toBe('hello')
    expect(frames.arrived(frame('s1 other', 'not mine'))).toBe('')
  })
})

describe('when the name never arrives', () => {
  it('lets go rather than holding a shell nobody opened', () => {
    const frames = new ShellFrames()
    frames.arrived(frame('s1 abc', 'output'))
    frames.give()
    // Nothing held, and nothing written afterwards either: this pane has no
    // shell, and the screen says so instead.
    expect(frames.settled('s1 abc')).toBe('')
  })

  it('stops holding past its cap, so a chatty shell cannot fill memory', () => {
    /*
     * A shell that answers a quarter of a megabyte before it answers its own
     * name is one we have already lost. The cap is not about the common case —
     * it is about the case where the reply never comes at all, where an
     * unbounded buffer is a leak that grows for as long as the pane is open.
     */
    const frames = new ShellFrames(10)
    frames.arrived(frame('s1 abc', '1234567890'))
    frames.arrived(frame('s1 abc', 'dropped'))
    expect(frames.settled('s1 abc')).toBe('1234567890')
  })

  it('has a cap large enough for anything a shell says while starting', () => {
    expect(MOST_HELD_BYTES).toBeGreaterThan(64 * 1024)
  })
})

describe('a terminal opened to run an agent', () => {
  /*
   * Source assertions, because the promise is a wiring one: the account chip's
   * row says "New terminal running Claude Code", and the only thing that can
   * regress is whether the command actually reaches the far shell — after the
   * open answers, to the server rather than to the local xterm, and Enter
   * included. A render test cannot see any of that without a live bridge.
   */
  const source = readFileSync(join(__dirname, 'ServerTerminal.tsx'), 'utf8')

  it('types the command into the far shell, never into the local emulator', () => {
    expect(source).toContain('void bridge.writeToServerShell(opened, `${runCommand}\\r`)')
    // And only when there is one: a plain terminal stays a plain prompt.
    expect(source).toContain("if (runCommand !== null && runCommand !== '')")
  })

  it('types it once, when the open answers — never on a re-render', () => {
    // The same once-only rule `startIn` carries: a change to the prop must not
    // tear down a live terminal or type into one twice.
    const write = source.indexOf('void bridge.writeToServerShell(opened, `${runCommand}\\r`)')
    const settled = source.indexOf('frames.settled(opened)')
    expect(settled).toBeGreaterThan(-1)
    // After the held backlog is drained, so the prompt precedes the echo.
    expect(write).toBeGreaterThan(settled)
  })
})
