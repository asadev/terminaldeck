import { describe, expect, it } from 'vitest'
import { checkArgs } from './schema'
import { advertiseTool, buildCatalogue, type JsonSchema } from './catalogue'
import { Refused } from './surface'

/**
 * The schema a tool advertises, held to be the boundary it looks like.
 *
 * The call these tests come from reported success at doing nothing:
 * `browser_step` takes `value`, a caller passed `text`, and every layer ignored
 * the argument it did not know until the driver typed the empty string it was
 * left with. Nothing in the chain was wrong on its own; there was simply no
 * place where the published document was checked against the call.
 */

function refusalFor(schema: JsonSchema, args: Record<string, unknown>): string {
  try {
    checkArgs(schema, args)
  } catch (error) {
    if (error instanceof Refused) return error.message
    throw error
  }
  return ''
}

const STEP: JsonSchema = {
  type: 'object',
  properties: {
    verb: { type: 'string', enum: ['click', 'type', 'press'] },
    selector: { type: 'string' },
    value: { type: 'string' },
    timeoutMs: { type: 'number' },
  },
  required: ['verb', 'selector'],
  additionalProperties: false,
}

describe('an argument the tool does not take', () => {
  it('is refused, and the tool’s real arguments are named', () => {
    const message = refusalFor(STEP, { verb: 'type', selector: '#q', text: 'hello' })
    expect(message).toContain('text')
    // The mistake is a near-miss — right shape, one wrong word — so the list of
    // real names is what turns the retry into the right call.
    expect(message).toContain('value')
    expect(message).toContain('selector')
  })

  it('is named before anything else, because the name is the mistake', () => {
    // `value` is missing *because* `text` was sent. Reporting the missing one
    // first would send the caller looking for a second problem it does not have.
    expect(refusalFor(STEP, { verb: 'type', selector: '#q', text: 'hi' })).toContain(
      'is not an argument',
    )
  })

  it('says so once for each, when there are several', () => {
    const message = refusalFor(STEP, { verb: 'click', selector: '#a', bypass: true, approved: true })
    expect(message).toContain('bypass')
    expect(message).toContain('approved')
    expect(message).toContain('are not arguments')
  })

  it('is allowed through when the schema does not close the object', () => {
    // Only what the schema states. A validator that refused on a schema saying
    // nothing about extra keys would be refusing calls the document permits.
    expect(() => checkArgs({ type: 'object', properties: {} }, { anything: 1 })).not.toThrow()
  })

  it('treats an explicit undefined as absent, because that is what crosses the wire', () => {
    expect(() =>
      checkArgs(STEP, { verb: 'click', selector: '#a', text: undefined }),
    ).not.toThrow()
  })
})

describe('a value of the wrong shape', () => {
  it('is refused with what it is and what it should be', () => {
    expect(refusalFor(STEP, { verb: 'click', selector: 7 })).toBe('selector must be string, not integer')
  })

  it('refuses an integer that is not one', () => {
    const schema: JsonSchema = { type: 'object', properties: { n: { type: 'integer' } } }
    expect(refusalFor(schema, { n: 1.5 })).toContain('must be integer')
    expect(() => checkArgs(schema, { n: 4 })).not.toThrow()
  })

  it('refuses the numbers JSON cannot carry back', () => {
    const schema: JsonSchema = { type: 'object', properties: { n: { type: 'number' } } }
    // `NaN` serialises to null, so a tool that accepted one would be acting on
    // a value its own result could not report.
    expect(refusalFor(schema, { n: Number.NaN })).toContain('must be number')
    expect(refusalFor(schema, { n: Number.POSITIVE_INFINITY })).toContain('must be number')
  })

  it('does not read null as absent', () => {
    // A caller that sent null sent something. Reading it as "unset" is how a
    // required argument goes missing without anybody being told.
    expect(refusalFor(STEP, { verb: 'click', selector: null })).toContain('must be string')
  })

  it('refuses a value outside the enum, and lists the ones there are', () => {
    const message = refusalFor(STEP, { verb: 'hover', selector: '#a' })
    expect(message).toContain('click')
    expect(message).toContain('press')
    expect(message).toContain('hover')
  })

  it('checks each entry of an array against its items', () => {
    const schema: JsonSchema = {
      type: 'object',
      properties: { steps: { type: 'array', items: { type: 'string' } } },
    }
    expect(refusalFor(schema, { steps: ['a', 2] })).toBe('steps[1] must be string, not integer')
    expect(() => checkArgs(schema, { steps: ['a', 'b'] })).not.toThrow()
  })

  it('never puts a whole value in the sentence', () => {
    const long = 'x'.repeat(400)
    const message = refusalFor(STEP, { verb: long, selector: '#a' })
    expect(message.length).toBeLessThan(200)
    expect(message).not.toContain(long)
  })
})

describe('a required argument that is not there', () => {
  it('is refused, by name', () => {
    expect(refusalFor(STEP, { verb: 'click' })).toBe('selector is required')
  })

  it('names every missing one at once', () => {
    expect(refusalFor(STEP, {})).toBe('verb, selector are required')
  })
})

describe('a keyword this does not understand', () => {
  it('is ignored rather than guessed at', () => {
    // Inventing a meaning for `format` would refuse calls the advertised schema
    // permits — the same lie as letting a bad one through, pointed the other way.
    const schema: JsonSchema = {
      type: 'object',
      properties: { at: { type: 'string', format: 'date-time', pattern: '^z' } },
    }
    expect(() => checkArgs(schema, { at: 'not a date' })).not.toThrow()
  })
})

describe('every tool in the shipped catalogue', () => {
  it('advertises a closed object, so the check above applies to all of them', () => {
    for (const spec of buildCatalogue()) {
      expect(spec.inputSchema.type, spec.id).toBe('object')
      expect(spec.inputSchema.additionalProperties, spec.id).toBe(false)
    }
  })

  it('accepts an empty call or refuses it for a named argument, never for a shape', () => {
    // Nothing here should throw anything but a `Refused`: a validator that blew
    // up on a real schema would take the whole call down before its row was
    // written, which is the one failure an audit log may not have.
    for (const spec of buildCatalogue()) {
      try {
        checkArgs(spec.inputSchema, {})
      } catch (error) {
        expect(error, spec.id).toBeInstanceOf(Refused)
      }
    }
  })

  it('is checked against the same schema the model was handed', () => {
    // `advertiseTool` is what crosses the wire. If the two ever diverged, this
    // validator would be enforcing a document nobody was given.
    for (const spec of buildCatalogue()) {
      expect(advertiseTool(spec).inputSchema, spec.id).toBe(spec.inputSchema)
    }
  })
})
