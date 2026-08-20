import { describe, expect, it } from 'vitest'
import { profileInitial } from './profile-badge'

describe('the profile badge', () => {
  it('is the name’s first letter, uppercased', () => {
    expect(profileInitial('Default')).toBe('D')
    expect(profileInitial('work')).toBe('W')
  })

  it('is empty before the active profile has been read', () => {
    // The button renders once before the answer arrives. A `?` that turns into
    // a `D` a frame later is a glyph that flickers; an empty circle settles.
    expect(profileInitial('')).toBe('')
    expect(profileInitial('   ')).toBe('')
  })

  it('ignores leading space rather than badging it', () => {
    expect(profileInitial('  Work')).toBe('W')
  })

  it('takes a whole code point, not half of a surrogate pair', () => {
    // A profile can be called anything. `charAt(0)` on an emoji name gives back
    // a lone surrogate, which draws as a replacement box.
    expect(profileInitial('🦊 Fox')).toBe('🦊')
    expect(profileInitial('Ünal')).toBe('Ü')
  })
})
