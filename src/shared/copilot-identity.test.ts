import { describe, expect, it } from 'vitest'
import { BRAND } from './brand'
import {
  cleanIdentity,
  cleanIdentityValue,
  copilotIdentityBlock,
  copilotName,
  DEFAULT_COPILOT_NAME,
  IDENTITY_HEADING,
  MAX_ADDRESS_NOTE,
  MAX_COPILOT_NAME,
  NO_IDENTITY,
  readCopilotIdentity,
  withCopilotIdentity,
  type CopilotIdentity,
} from './copilot-identity'

/**
 * The setup flow's answers, pinned as a *format* rather than as a store.
 *
 * Everything below is a way this could quietly stop working while the app went
 * on compiling: a block that cannot be read back, a rename that leaves two
 * blocks disagreeing, an edit that eats the instructions underneath it, or —
 * the one this feature was warned about by name — a copilot's name reaching for
 * the product's constant.
 */

/** The file the app seeds, in the shape that matters here: a title, then prose. */
const SEEDED = `# ${BRAND.name} Copilot

You are a **developer's copilot**. The person you work for is shipping code.

## How to answer

Short. Lead with what needs them.
`

const answered: CopilotIdentity = {
  name: 'Nova',
  callThem: 'Asad',
  addressNote: 'short answers, no preamble',
}

describe('the block, written and read back', () => {
  it('round-trips every answer', () => {
    const file = withCopilotIdentity(SEEDED, answered)
    const read = readCopilotIdentity(file)
    expect(read.ran).toBe(true)
    expect(read.identity).toEqual(answered)
  })

  it('round-trips a name and nothing else', () => {
    const only = { name: 'Bolt', callThem: null, addressNote: null }
    expect(readCopilotIdentity(withCopilotIdentity(SEEDED, only)).identity).toEqual(only)
  })

  /*
   * The skipped-everything case is a finished run, not an absent one.
   *
   * If this ever came back `ran: false` the flow would reopen on every launch
   * for the one person who answered "no thanks" to all four questions, which is
   * the most annoying possible reading of "re-runnable".
   */
  it('records that the flow ran even when every question was skipped', () => {
    const file = withCopilotIdentity(SEEDED, NO_IDENTITY)
    const read = readCopilotIdentity(file)
    expect(read.ran).toBe(true)
    expect(read.identity).toEqual(NO_IDENTITY)
  })

  it('tells a skipped copilot not to name itself', () => {
    const block = copilotIdentityBlock(NO_IDENTITY)
    expect(block).toContain('They have not named you yet')
    expect(block).toContain('should not pick a name')
  })

  it('says nothing about a name it was not given', () => {
    expect(copilotIdentityBlock(NO_IDENTITY)).not.toContain('Your name is')
  })

  it('is absent from a file the flow has never touched', () => {
    const read = readCopilotIdentity(SEEDED)
    expect(read.ran).toBe(false)
    expect(read.identity).toEqual(NO_IDENTITY)
  })

  it('reads nothing out of a value that is not text', () => {
    expect(readCopilotIdentity(null).ran).toBe(false)
    expect(readCopilotIdentity(undefined).ran).toBe(false)
    expect(readCopilotIdentity(42).ran).toBe(false)
  })
})

describe('re-running the flow', () => {
  /*
   * The failure this prevents: two blocks in one file, telling the model two
   * different names, with the app printing whichever one it found first.
   */
  it('replaces the block rather than adding a second one', () => {
    const once = withCopilotIdentity(SEEDED, answered)
    const twice = withCopilotIdentity(once, { ...answered, name: 'Atlas' })
    expect(twice.split(IDENTITY_HEADING)).toHaveLength(2)
    expect(readCopilotIdentity(twice).identity.name).toBe('Atlas')
  })

  it('keeps everything the person wrote around it', () => {
    const twice = withCopilotIdentity(withCopilotIdentity(SEEDED, answered), NO_IDENTITY)
    expect(twice).toContain('## How to answer')
    expect(twice).toContain('Short. Lead with what needs them.')
    expect(twice).toContain("You are a **developer's copilot**.")
  })

  it('leaves the block where somebody moved it', () => {
    const moved = `# Title\n\nA paragraph of mine.\n\n${copilotIdentityBlock(answered)}\n## Mine\n\nMore.\n`
    const again = withCopilotIdentity(moved, { ...answered, name: 'Atlas' })
    expect(again.indexOf('A paragraph of mine.')).toBeLessThan(again.indexOf(IDENTITY_HEADING))
    expect(readCopilotIdentity(again).identity.name).toBe('Atlas')
    expect(again).toContain('## Mine')
  })

  /*
   * A `#` after the block is a person who reorganised their instructions. The
   * block has to stop there, or the second run would swallow the rest of their
   * file — which is the one destructive thing this module could do.
   */
  it('stops at the next heading of any level', () => {
    const file = `${copilotIdentityBlock(answered)}\n# Mine, promoted to a title\n\nKeep me.\n`
    const again = withCopilotIdentity(file, NO_IDENTITY)
    expect(again).toContain('# Mine, promoted to a title')
    expect(again).toContain('Keep me.')
  })
})

describe('where a first block goes', () => {
  it('sits under the document title', () => {
    const file = withCopilotIdentity(SEEDED, answered)
    expect(file.indexOf(`# ${BRAND.name} Copilot`)).toBeLessThan(file.indexOf(IDENTITY_HEADING))
    expect(file.indexOf(IDENTITY_HEADING)).toBeLessThan(file.indexOf('## How to answer'))
  })

  it('goes to the top of a file with no title', () => {
    const file = withCopilotIdentity('Just prose, no heading.\n', answered)
    expect(file.startsWith(IDENTITY_HEADING)).toBe(true)
    expect(file).toContain('Just prose, no heading.')
  })

  it('leaves exactly one blank line on each side', () => {
    const file = withCopilotIdentity(SEEDED, answered)
    expect(file).not.toContain('\n\n\n')
  })

  it('writes the same bytes for the same answers, however many times it runs', () => {
    const once = withCopilotIdentity(SEEDED, answered)
    expect(withCopilotIdentity(once, answered)).toBe(once)
  })
})

describe('values that would break the round trip', () => {
  it('drops the emphasis characters that would end the bold early', () => {
    const file = withCopilotIdentity(SEEDED, { ...answered, name: 'No**va' })
    expect(readCopilotIdentity(file).identity.name).toBe('Nova')
  })

  it('flattens a pasted multi-line answer onto one line', () => {
    const file = withCopilotIdentity(SEEDED, {
      ...answered,
      addressNote: 'keep it short\nand skip the preamble',
    })
    expect(readCopilotIdentity(file).identity.addressNote).toBe(
      'keep it short and skip the preamble',
    )
  })

  it('caps a name at the width the sidebar and the tab can actually draw', () => {
    const long = 'N'.repeat(MAX_COPILOT_NAME + 40)
    const file = withCopilotIdentity(SEEDED, { ...answered, name: long })
    expect(readCopilotIdentity(file).identity.name).toHaveLength(MAX_COPILOT_NAME)
  })

  it('caps the address line', () => {
    const long = 'a '.repeat(MAX_ADDRESS_NOTE)
    expect(cleanIdentityValue(long, MAX_ADDRESS_NOTE)?.length).toBeLessThanOrEqual(
      MAX_ADDRESS_NOTE,
    )
  })

  it('treats an empty box and a skipped question as the same answer', () => {
    expect(cleanIdentity({ name: '   ', callThem: '', addressNote: undefined })).toEqual(
      NO_IDENTITY,
    )
  })

  it('never lets a control character reach the file', () => {
    const file = withCopilotIdentity(SEEDED, { ...answered, name: 'No\u0000va\u001b' })
    expect(file).not.toMatch(/[\u0000-\u0008\u000b-\u001f\u007f]/)
    expect(readCopilotIdentity(file).identity.name).toBe('No va')
  })
})

describe('a file somebody has since edited by hand', () => {
  /*
   * Not an error, and not a repair. Their sentence still tells the model, which
   * is the reader that matters; the app falls back to its own word for it.
   */
  it('reports the flow as run and the name as unknown', () => {
    const file = `${IDENTITY_HEADING}\n\nYou are my copilot and I call you Nova.\n`
    const read = readCopilotIdentity(file)
    expect(read.ran).toBe(true)
    expect(read.identity.name).toBeNull()
    expect(copilotName(read.identity)).toBe(DEFAULT_COPILOT_NAME)
  })

  it('follows a name edited in place', () => {
    const file = withCopilotIdentity(SEEDED, answered).replace('**Nova**', '**Atlas**')
    expect(readCopilotIdentity(file).identity.name).toBe('Atlas')
  })

  /*
   * The stems are matched inside the block only. A person's own paragraph three
   * sections down that opens "Call them" is prose about a colleague, not an
   * answer, and reading it as one would rename them from a sentence about work.
   */
  it('ignores the stems outside the block', () => {
    const file = `${withCopilotIdentity(SEEDED, NO_IDENTITY)}\n## Reviews\n\nCall them **the reviewers** when you report back.\n`
    expect(readCopilotIdentity(file).identity.callThem).toBeNull()
  })
})

describe('the copilot’s name and the product’s name are different things', () => {
  /*
   * Warned about by name when this was specified: the repo reads the product's
   * name from `BRAND.name` and never spells it, and a copilot's name is the
   * opposite — user data, in app storage, absent until somebody types it. The
   * two must not meet.
   */
  it('never falls back to the product’s name', () => {
    expect(DEFAULT_COPILOT_NAME).not.toBe(BRAND.name)
    expect(copilotName(null)).toBe(DEFAULT_COPILOT_NAME)
    expect(copilotName(NO_IDENTITY)).toBe(DEFAULT_COPILOT_NAME)
  })

  it('prints the name somebody gave it', () => {
    expect(copilotName(answered)).toBe('Nova')
  })

  it('keeps the product’s name out of the block entirely', () => {
    expect(copilotIdentityBlock(answered)).not.toContain(BRAND.name)
    expect(copilotIdentityBlock(NO_IDENTITY)).not.toContain(BRAND.name)
  })
})
