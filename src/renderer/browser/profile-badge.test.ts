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

  it('is the profile’s own character when it has picked one', () => {
    // The avatar half of *"they should have proper settings, proper section,
    // just like Google Chrome"* — Chrome's flyout leads every row with a
    // picture. Picked deliberately, so it is drawn as picked.
    expect(profileInitial('Default', '🦊')).toBe('🦊')
    expect(profileInitial('Work', 'ß')).toBe('ß')
  })

  it('falls back to the initial when the avatar was cleared', () => {
    // Clearing is how somebody gets out of an avatar they no longer want, so it
    // has to land back on the badge this app has always drawn.
    expect(profileInitial('Work', '')).toBe('W')
    expect(profileInitial('Work', '   ')).toBe('W')
  })

  it('takes a whole code point, not half of a surrogate pair', () => {
    // A profile can be called anything. `charAt(0)` on an emoji name gives back
    // a lone surrogate, which draws as a replacement box.
    expect(profileInitial('🦊 Fox')).toBe('🦊')
    expect(profileInitial('Ünal')).toBe('Ü')
  })
})
