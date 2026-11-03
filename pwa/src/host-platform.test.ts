import { describe, expect, it } from 'vitest'
import { asHostPlatform, machineNoun, readHostPlatform, type HostPlatform } from './host-platform'

/*
 * The table, pinned.
 *
 * There is one rule in this file that is not a matter of taste, and it is the
 * second test: **absent must never become "Mac".** A phone paired to a Windows
 * PC read "Running on the Mac" for exactly that reason — the noun was a
 * constant, and the constant said Mac — so a fallback that names any specific
 * machine reintroduces the defect the field was added to remove.
 */
describe('reading what the desktop says it is', () => {
  it('maps the three platforms Electron ships on', () => {
    expect(readHostPlatform('darwin')).toBe('mac')
    expect(readHostPlatform('win32')).toBe('windows')
    expect(readHostPlatform('linux')).toBe('linux')
  })

  it('never guesses a machine — absent and unrecognisable both read as unknown', () => {
    // `undefined` is a desktop older than the field; the rest are a desktop, a
    // proxy or a hand-edited store saying something this build has never heard
    // of. All of them are "I do not know", and none of them is a Mac.
    const strangers: unknown[] = [undefined, null, '', 'Darwin', 'macos', 'win64', 'freebsd', 7, {}, ['darwin']]
    for (const value of strangers) {
      expect(readHostPlatform(value), JSON.stringify(value)).toBe('unknown')
    }
  })
})

/*
 * Two alphabets, kept apart.
 *
 * `readHostPlatform` speaks the wire's (`win32`); `asHostPlatform` speaks this
 * client's own (`windows`). Merging them looks harmless and is not: the first
 * version of `loadCredential` read a stored `windows` with the wire mapping,
 * got `unknown`, and threw away the answer the phone had already learned.
 */
describe('reading back what this client wrote', () => {
  it('round-trips its own vocabulary', () => {
    for (const platform of ['mac', 'windows', 'linux', 'unknown'] as const) {
      expect(asHostPlatform(platform)).toBe(platform)
    }
  })

  it('does not accept the wire’s words, and does not invent a machine', () => {
    for (const value of ['darwin', 'win32', 'Windows', '', undefined, null, 3, {}]) {
      expect(asHostPlatform(value), JSON.stringify(value)).toBe('unknown')
    }
  })
})

describe('what to call it in a sentence', () => {
  it('uses the word the reader would use about their own machine', () => {
    expect(machineNoun('mac')).toBe('Mac')
    expect(machineNoun('windows')).toBe('PC')
    expect(machineNoun('linux')).toBe('machine')
    expect(machineNoun('unknown')).toBe('desktop')
  })

  it('composes into a sentence without an article of its own', () => {
    // Every call site writes "the ${noun}", so a noun carrying its own article
    // or a trailing full stop would produce "the the Mac" somewhere. Cheap to
    // pin, and the kind of thing a later edit does by accident.
    const every: HostPlatform[] = ['mac', 'windows', 'linux', 'unknown']
    for (const platform of every) {
      const noun = machineNoun(platform)
      expect(noun, platform).toMatch(/^[A-Za-z]+$/)
    }
  })
})
