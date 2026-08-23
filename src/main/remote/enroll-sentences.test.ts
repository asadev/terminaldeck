import { describe, expect, it } from 'vitest'
import {
  SIGN_IN_BAD_KEY,
  SIGN_IN_BUSY,
  SIGN_IN_NOT_SAVED,
  SIGN_IN_NO_ROOM,
  SIGN_IN_REFUSED,
  SIGN_IN_SLOW,
  signInNoSshd,
} from './enroll'
import { SIGN_IN_NOT_SERVED } from './server'

/**
 * One sentence, four meanings, and an evening lost to it.
 *
 * `server.ts` refuses an `enroll` frame with {@link SIGN_IN_NOT_SERVED} when
 * this host does not serve sign-in at all — the demo box, and nothing else
 * anybody owns. Until 2026-08-23 `enroll.ts` sent a byte-identical sentence for
 * three completely different things: a loopback probe that could not reach
 * sshd, a host out of device slots, and a device row that would not write.
 *
 * That is not a cosmetic duplication. Both go out as `code: 'unavailable'`, and
 * every client reads that pair as *the feature is not on that machine*: iOS
 * headlines it "That server does not offer sign-in", and the web client prints
 * an install command underneath. So a server running 0.10.1, connected to the
 * relay and serving sign-in correctly, spent an evening telling its owner that
 * it did not have the feature — because its sshd was on port 2222 and the probe
 * was dialling that port and finding nothing.
 *
 * The repair is not "we fixed the wording". It is that the wording cannot
 * collide again without this file going red. A sentence is a wire contract when
 * three clients decide what to offer from it.
 */
describe('the sign-in refusals', () => {
  const fromEnroll = {
    SIGN_IN_REFUSED,
    SIGN_IN_BAD_KEY,
    SIGN_IN_SLOW,
    SIGN_IN_BUSY,
    SIGN_IN_NO_ROOM,
    SIGN_IN_NOT_SAVED,
    'signInNoSshd(22)': signInNoSshd(22),
    'signInNoSshd(2222)': signInNoSshd(2222),
  }

  it('never says what a host with sign-in switched off says', () => {
    for (const [name, sentence] of Object.entries(fromEnroll)) {
      expect(sentence, name).not.toBe(SIGN_IN_NOT_SERVED)
    }
  })

  it('says something different for every different cause', () => {
    const all = [...Object.values(fromEnroll), SIGN_IN_NOT_SERVED]
    expect(new Set(all).size).toBe(all.length)
  })

  /**
   * The one refusal a remote caller may not be able to tell apart from another
   * is the pair this collapse exists for — a wrong password and a rate-limited
   * address — and that collapse is `enroll.ts`'s job, tested in its own file.
   * Everything here is the host describing its own configuration to its owner.
   */
  it('quotes nothing a caller sent', () => {
    for (const [name, sentence] of Object.entries(fromEnroll)) {
      expect(sentence, name).not.toMatch(/asad|hunter2|password:/i)
    }
  })

  it('names the port it dialled, so the fix is in the sentence', () => {
    expect(signInNoSshd(2222)).toContain('2222')
    expect(signInNoSshd(2222)).toContain('TERMINALDECK_SSHD_PORT')
    expect(signInNoSshd(22)).not.toContain('2222')
  })
})
