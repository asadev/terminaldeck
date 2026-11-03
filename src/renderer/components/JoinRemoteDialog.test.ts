import { describe, expect, it } from 'vitest'
import {
  formatJoinCode,
  JOIN_CODE_ALPHABET,
  JOIN_CODE_LENGTH,
  JOIN_PIN_LENGTH,
  normalizeJoinCode,
  normalizeJoinPin,
  REMOTE_SESSIONS_AVAILABLE,
  validateJoinCode,
  validateJoinPin,
  validateJoinRequest,
} from './JoinRemoteDialog'

/**
 * The format rules, which are the only part of remote sessions that exists.
 * Locked down now because the transport will be written against them later,
 * and a code the UI accepted but the transport rejects is worse than either.
 */

describe('the alphabet', () => {
  it('drops the four characters Crockford drops', () => {
    for (const character of 'ILOU') expect(JOIN_CODE_ALPHABET).not.toContain(character)
  })

  it('has no duplicates', () => {
    expect(new Set(JOIN_CODE_ALPHABET).size).toBe(JOIN_CODE_ALPHABET.length)
  })
})

describe('normalizeJoinCode', () => {
  it('accepts a code with the dash', () => {
    expect(normalizeJoinCode('A1B2-C3D4')).toBe('A1B2C3D4')
  })

  it('accepts a code with spaces, and lower case', () => {
    expect(normalizeJoinCode(' a1b2 c3d4 ')).toBe('A1B2C3D4')
  })

  it('reads the glyphs the alphabet does not contain', () => {
    // Someone reading a code off a screen types what they see.
    expect(normalizeJoinCode('O0I1L2')).toBe('001112')
  })

  it('leaves U alone so it can be reported as wrong', () => {
    expect(normalizeJoinCode('UUUU')).toBe('UUUU')
  })
})

describe('formatJoinCode', () => {
  it('groups a full code into fours', () => {
    expect(formatJoinCode('A1B2C3D4')).toBe('A1B2-C3D4')
  })

  it('does not add a trailing dash to a partial code', () => {
    expect(formatJoinCode('A1B2')).toBe('A1B2')
    expect(formatJoinCode('A1B2C')).toBe('A1B2-C')
  })

  it('is idempotent', () => {
    expect(formatJoinCode(formatJoinCode('a1b2c3d4'))).toBe('A1B2-C3D4')
  })
})

describe('validateJoinCode', () => {
  it('accepts a well-formed code', () => {
    const check = validateJoinCode('A1B2-C3D4')
    expect(check.ok).toBe(true)
    if (check.ok) expect(check.value).toBe('A1B2C3D4')
  })

  it('says nothing useful is there for an empty field', () => {
    const check = validateJoinCode('   ')
    expect(check.ok).toBe(false)
    if (!check.ok) expect(check.problem).toBe('empty')
  })

  it('names the offending character rather than counting length', () => {
    const check = validateJoinCode('UUUUUUUU')
    expect(check.ok).toBe(false)
    if (!check.ok) {
      expect(check.problem).toBe('invalid-characters')
      expect(check.message).toContain('U')
    }
  })

  it('reports a bad character even when the length is wrong too', () => {
    // Telling someone they need three more characters, when the ones they have
    // are not valid, sends them the wrong way.
    const check = validateJoinCode('AU')
    if (!check.ok) expect(check.problem).toBe('invalid-characters')
  })

  it('lists each bad character once', () => {
    const check = validateJoinCode('UUUU')
    if (!check.ok) expect(check.message.match(/U/g)).toHaveLength(1)
  })

  it('counts down the characters still missing', () => {
    const check = validateJoinCode('A1B2C3D')
    expect(check.ok).toBe(false)
    if (!check.ok) {
      expect(check.problem).toBe('too-short')
      expect(check.message).toContain('1 more character ')
    }
  })

  it('pluralises the countdown', () => {
    const check = validateJoinCode('A1')
    if (!check.ok) expect(check.message).toContain('6 more characters')
  })

  it('rejects a code that is too long', () => {
    const check = validateJoinCode('A1B2C3D4E')
    expect(check.ok).toBe(false)
    if (!check.ok) {
      expect(check.problem).toBe('too-long')
      expect(check.message).toContain(String(JOIN_CODE_LENGTH))
    }
  })
})

describe('validateJoinPin', () => {
  it('accepts six digits', () => {
    const check = validateJoinPin('012345')
    expect(check.ok).toBe(true)
    if (check.ok) expect(check.value).toBe('012345')
  })

  it('keeps a leading zero', () => {
    const check = validateJoinPin('000123')
    if (check.ok) expect(check.value).toBe('000123')
  })

  it('ignores separators the host might read out', () => {
    const check = validateJoinPin('012 345')
    expect(check.ok).toBe(true)
  })

  it('reports an empty field as empty', () => {
    const check = validateJoinPin('')
    if (!check.ok) expect(check.problem).toBe('empty')
  })

  it('counts down the digits still missing', () => {
    const check = validateJoinPin('01234')
    if (!check.ok) {
      expect(check.problem).toBe('too-short')
      expect(check.message).toContain('1 more digit ')
    }
  })

  it('rejects more than six digits', () => {
    const check = validateJoinPin('0123456')
    if (!check.ok) {
      expect(check.problem).toBe('too-long')
      expect(check.message).toContain(String(JOIN_PIN_LENGTH))
    }
  })

  it('drops letters rather than reading them as digits', () => {
    expect(normalizeJoinPin('12a34b')).toBe('1234')
  })
})

describe('validateJoinRequest', () => {
  it('needs both halves', () => {
    expect(validateJoinRequest('A1B2-C3D4', '012345')).toBe(true)
    expect(validateJoinRequest('A1B2-C3D4', '01234')).toBe(false)
    expect(validateJoinRequest('A1B2-C3D', '012345')).toBe(false)
  })
})

describe('honesty', () => {
  it('reports that remote sessions cannot be joined', () => {
    // If this ever flips, the transport has to exist — the dialog's button is
    // wired to it, and nothing else in this build opens a connection.
    expect(REMOTE_SESSIONS_AVAILABLE).toBe(false)
  })
})
