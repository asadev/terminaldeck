/**
 * The one character that says which profile is on.
 *
 *   > *"we should keep vertical with maybe profile icon like this. So we can
 *   > have these profiles over here as icon, so we can switch between profiles
 *   > also if we want to."*
 *
 * The button he asked for arrived drawing a generic outline person, and drew the
 * identical person whatever profile was active: with `Default` on and with
 * `Work` on, the toolbar was pixel-for-pixel the same and only the hover text
 * differed. So the half of his sentence that says *switch* worked and the half
 * that says *see* did not — in Chrome the point of that icon is that it answers
 * the question without being clicked.
 *
 * A letter rather than a colour because a name is what the app already has and a
 * palette is what it would have to invent; `--bind-1…4` are spoken for by
 * session bindings, and a second meaning on the same four colours is how two
 * facts come to be told in one paint.
 *
 * ## And a chosen character, when there is one
 *
 * The letter is still the default and still comes from the name. What is new is
 * that a profile may carry one of its own — *"they should have proper settings,
 * proper section, just like Google Chrome"*, said with Chrome's flyout open, and
 * every row of that flyout leads with a picture. `BrowserProfile.avatar` is why
 * it is a character rather than an image, and it changes nothing here beyond
 * where the character comes from: an unset avatar is the empty string, which is
 * exactly the badge this file has always drawn.
 */

/**
 * The character a profile is badged with: its own if it has one, otherwise the
 * first character of its name, uppercased — or nothing.
 *
 * Nothing, and not a `?`, for the empty name: the panel reads the active
 * profile asynchronously, so the button renders once before the answer arrives,
 * and an empty badge that fills in is a circle that settles rather than a
 * question mark that flickers into a letter.
 *
 * A chosen avatar is NOT uppercased. It is already one code point, chosen
 * deliberately, and `'🦊'.toUpperCase()` is the identity for an emoji but not for
 * every character somebody might pick — `ß` would become `SS`, which is two
 * characters in a circle sized for one.
 *
 * Split by code point rather than by `charAt`, so a name that begins with an
 * emoji or an astral character gives back that character instead of half of it.
 */
export function profileInitial(name: string, avatar = ''): string {
  const chosen = avatar.trim()
  if (chosen !== '') {
    const glyph = [...chosen][0]
    if (glyph !== undefined) return glyph
  }
  const trimmed = name.trim()
  if (trimmed === '') return ''
  const first = [...trimmed][0]
  return first === undefined ? '' : first.toUpperCase()
}
