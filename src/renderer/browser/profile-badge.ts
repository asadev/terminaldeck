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
 */

/**
 * The first character of a profile's name, uppercased — or nothing.
 *
 * Nothing, and not a `?`, for the empty name: the panel reads the active
 * profile asynchronously, so the button renders once before the answer arrives,
 * and an empty badge that fills in is a circle that settles rather than a
 * question mark that flickers into a letter.
 *
 * Split by code point rather than by `charAt`, so a name that begins with an
 * emoji or an astral character gives back that character instead of half of it.
 */
export function profileInitial(name: string): string {
  const trimmed = name.trim()
  if (trimmed === '') return ''
  const first = [...trimmed][0]
  return first === undefined ? '' : first.toUpperCase()
}
