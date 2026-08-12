import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  describeSchema,
  initialValues,
  McpSchemaForm,
  missingRequired,
  optionValueAt,
  pruneArguments,
  selectIndexOf,
} from './McpSchemaForm'

/**
 * There is no DOM environment in this project's test setup, so the rendering
 * checks go through static markup. That is enough for what matters here: that a
 * missing, malformed or exotic schema still produces a usable form instead of
 * throwing and taking the whole inspector panel down with it.
 */

/** The shape a zod-backed MCP server actually emits. */
const REAL_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string', description: 'Absolute path to read' },
    limit: { type: 'integer', default: 100 },
    recursive: { type: 'boolean' },
    mode: { type: 'string', enum: ['text', 'binary'] },
    tags: { type: 'array', items: { type: 'string' } },
  },
  required: ['path'],
  additionalProperties: false,
}

describe('describeSchema', () => {
  it('reads a well-formed schema', () => {
    const { fields, fallback } = describeSchema(REAL_SCHEMA)
    expect(fallback).toBeNull()
    expect(fields.map((f) => `${f.name}:${f.kind}`)).toEqual([
      'path:string',
      'limit:integer',
      'recursive:boolean',
      'mode:enum',
      'tags:array',
    ])
    expect(fields[0].required).toBe(true)
    expect(fields[1].required).toBe(false)
    expect(fields[1].defaultValue).toBe(100)
    expect(fields[3].options?.map((o) => o.label)).toEqual(['text', 'binary'])
    expect(fields[4].itemKind).toBe('string')
  })

  it('falls back for a schema that is missing entirely', () => {
    expect(describeSchema(undefined).fallback).toBeTruthy()
    expect(describeSchema(null).fallback).toBeTruthy()
    expect(describeSchema(undefined).fields).toEqual([])
  })

  it('falls back for a schema that is not an object', () => {
    expect(describeSchema('a string').fallback).toBeTruthy()
    expect(describeSchema([1, 2, 3]).fallback).toBeTruthy()
    expect(describeSchema({ type: 'string' }).fallback).toContain('string')
  })

  it('falls back when the property list is malformed', () => {
    expect(describeSchema({ type: 'object', properties: ['path'] }).fallback).toBeTruthy()
  })

  it('reports a no-argument tool as no fields rather than a failure', () => {
    const described = describeSchema({ type: 'object' })
    expect(described.fields).toEqual([])
    expect(described.fallback).toBeNull()
  })

  it('gives a JSON box to a property that is not an object', () => {
    const { fields } = describeSchema({ type: 'object', properties: { broken: 'nope' } })
    expect(fields[0].kind).toBe('json')
  })

  it('treats a nullable union type as its real type', () => {
    const { fields } = describeSchema({ type: 'object', properties: { note: { type: ['string', 'null'] } } })
    expect(fields[0].kind).toBe('string')
  })

  it('treats an undeclared type as text, and says so', () => {
    const { fields } = describeSchema({ type: 'object', properties: { thing: { description: 'anything' } } })
    expect(fields[0].kind).toBe('string')
    expect(fields[0].inferred).toBe(true)
  })

  it('reads an enum expressed as a union of consts', () => {
    const { fields } = describeSchema({
      type: 'object',
      properties: { level: { anyOf: [{ const: 'low' }, { const: 'high' }] } },
    })
    expect(fields[0].kind).toBe('enum')
    expect(fields[0].options?.map((o) => o.value)).toEqual(['low', 'high'])
  })

  it('keeps non-string enum values intact instead of stringifying them', () => {
    const { fields } = describeSchema({ type: 'object', properties: { n: { enum: [1, 2, null] } } })
    expect(fields[0].options?.map((o) => o.value)).toEqual([1, 2, null])
  })

  it('lays out a nested object as nested fields', () => {
    const { fields } = describeSchema({
      type: 'object',
      properties: {
        filter: { type: 'object', properties: { since: { type: 'string' } }, required: ['since'] },
      },
    })
    expect(fields[0].kind).toBe('object')
    expect(fields[0].fields?.[0]).toMatchObject({ name: 'since', kind: 'string', required: true })
  })

  it('edits an object with no described properties as JSON', () => {
    const { fields } = describeSchema({ type: 'object', properties: { blob: { type: 'object' } } })
    expect(fields[0].kind).toBe('json')
  })

  it('edits an array of objects as JSON rather than as rows', () => {
    const { fields } = describeSchema({
      type: 'object',
      properties: { items: { type: 'array', items: { type: 'object', properties: { a: { type: 'string' } } } } },
    })
    expect(fields[0].kind).toBe('array')
    expect(fields[0].itemKind).toBeNull()
  })

  it('stops descending once the nesting gets silly', () => {
    // Five levels of objects. The form must bottom out in a JSON box rather
    // than recursing until the render blows the stack.
    const deep = {
      type: 'object',
      properties: {
        a: {
          type: 'object',
          properties: {
            b: {
              type: 'object',
              properties: {
                c: { type: 'object', properties: { d: { type: 'object', properties: { e: { type: 'string' } } } } },
              },
            },
          },
        },
      },
    }

    let fields = describeSchema(deep).fields
    let depth = 0
    while (fields[0]?.kind === 'object' && fields[0].fields) {
      fields = fields[0].fields
      depth += 1
    }
    expect(depth).toBe(3)
    expect(fields[0].name).toBe('d')
    expect(fields[0].kind).toBe('json')
  })
})

describe('initialValues', () => {
  it('seeds only the fields that declared a default', () => {
    expect(initialValues(describeSchema(REAL_SCHEMA).fields)).toEqual({ limit: 100 })
  })

  it('seeds nested defaults', () => {
    const { fields } = describeSchema({
      type: 'object',
      properties: { filter: { type: 'object', properties: { since: { type: 'string', default: 'today' } } } },
    })
    expect(initialValues(fields)).toEqual({ filter: { since: 'today' } })
  })
})

describe('pruneArguments', () => {
  it('drops blanks so an untouched optional is not sent as an empty string', () => {
    expect(pruneArguments({ path: '/tmp', note: '', limit: undefined, recursive: false, count: 0 })).toEqual({
      path: '/tmp',
      recursive: false,
      count: 0,
    })
  })

  it('drops an object that pruned down to nothing', () => {
    expect(pruneArguments({ filter: { since: '' }, path: '/tmp' })).toEqual({ path: '/tmp' })
  })

  it('keeps an empty array, which is a real value', () => {
    expect(pruneArguments({ tags: [] })).toEqual({ tags: [] })
  })

  it('drops the empty rows out of an array instead of sending them as null', () => {
    // "Add item" appends an undefined row. `JSON.stringify` renders that as
    // `null`, so a half-filled list reached the server as ["a", null] and was
    // rejected by any `items: {type: 'string'}` schema, with an error pointing
    // at nothing the user could see.
    expect(pruneArguments({ tags: ['a', undefined, 'b'] })).toEqual({ tags: ['a', 'b'] })
    expect(JSON.stringify(pruneArguments({ tags: ['a', undefined] }))).toBe('{"tags":["a"]}')
  })

  it('leaves everything else in an array exactly as typed', () => {
    // Arrays of objects are edited as raw JSON. Pruning inside them would
    // quietly rewrite what the user wrote.
    const typed = { rows: [{ a: '', b: 0 }, [], null, false, ''] }
    expect(pruneArguments(typed)).toEqual(typed)
  })
})

describe('enum select round trip', () => {
  const options = [
    { value: 'low', label: 'low' },
    { value: 'high', label: 'high' },
  ]

  it('reads the blank row as "clear", not as the first option', () => {
    // The bug: `Number('')` is 0, so `options[Number(raw)]` answered the
    // "Not set" row with the *first* enum value. Choosing "Not set" set the
    // field instead of unsetting it, and there was no way back to unset.
    expect(optionValueAt(options, '')).toBeUndefined()
    expect(optionValueAt(options, '0')).toBe('low')
    expect(optionValueAt(options, '1')).toBe('high')
  })

  it('refuses an index that is out of range or not an index at all', () => {
    expect(optionValueAt(options, '2')).toBeUndefined()
    expect(optionValueAt(options, '-1')).toBeUndefined()
    expect(optionValueAt(options, '1.5')).toBeUndefined()
    expect(optionValueAt(options, 'high')).toBeUndefined()
    expect(optionValueAt([], '0')).toBeUndefined()
  })

  it('keeps non-string enum values addressable by index', () => {
    const mixed = [
      { value: 1, label: '1' },
      { value: null, label: 'null' },
      { value: false, label: 'false' },
    ]
    expect(optionValueAt(mixed, '1')).toBeNull()
    expect(optionValueAt(mixed, '2')).toBe(false)
    expect(selectIndexOf(mixed, null)).toBe(1)
    expect(selectIndexOf(mixed, false)).toBe(2)
  })

  it('shows nothing selected when the value is unset', () => {
    expect(selectIndexOf(options, undefined)).toBe(-1)
    expect(selectIndexOf(options, 'nonsense')).toBe(-1)
  })

  it('still highlights a default that equals an option without being the same object', () => {
    const objects = [{ value: { mode: 'fast' }, label: 'fast' }]
    expect(selectIndexOf(objects, { mode: 'fast' })).toBe(0)
    expect(selectIndexOf(objects, { mode: 'slow' })).toBe(-1)
  })

  it('survives a value that cannot be serialised', () => {
    const circular: Record<string, unknown> = {}
    circular.self = circular
    expect(selectIndexOf(options, circular)).toBe(-1)
  })
})

describe('missingRequired', () => {
  const { fields } = describeSchema(REAL_SCHEMA)

  it('names a required field the user has not filled in', () => {
    expect(missingRequired(fields, {})).toEqual(['path'])
    expect(missingRequired(fields, { path: '' })).toEqual(['path'])
  })

  it('is satisfied by a real value', () => {
    expect(missingRequired(fields, { path: '/tmp' })).toEqual([])
  })

  it('accepts false and zero as answers', () => {
    const booleans = describeSchema({
      type: 'object',
      properties: { flag: { type: 'boolean' }, n: { type: 'number' } },
      required: ['flag', 'n'],
    }).fields
    expect(missingRequired(booleans, { flag: false, n: 0 })).toEqual([])
  })

  it('reports a missing nested requirement by its path', () => {
    const nested = describeSchema({
      type: 'object',
      properties: { filter: { type: 'object', properties: { since: { type: 'string' } }, required: ['since'] } },
    }).fields
    expect(missingRequired(nested, {})).toEqual(['filter.since'])
  })
})

describe('<McpSchemaForm>', () => {
  const noop = (): void => undefined

  it('renders a labelled control per property, marking the required one', () => {
    const html = renderToStaticMarkup(<McpSchemaForm schema={REAL_SCHEMA} values={{}} onChange={noop} />)

    expect(html).toContain('path')
    expect(html).toContain('aria-label="required"')
    expect(html).toContain('type="checkbox"')
    expect(html).toContain('<select')
    expect(html).toContain('Absolute path to read')
  })

  it('falls back to a JSON box instead of crashing on a malformed schema', () => {
    const html = renderToStaticMarkup(<McpSchemaForm schema={'not a schema'} values={{}} onChange={noop} />)

    expect(html).toContain('Enter the arguments as JSON')
    expect(html).toContain('<textarea')
  })

  it('says so when a tool takes no arguments', () => {
    const html = renderToStaticMarkup(<McpSchemaForm schema={{ type: 'object' }} values={{}} onChange={noop} />)
    expect(html).toContain('takes no arguments')
    expect(html).not.toContain('<input')
  })

  it('shows existing values rather than resetting them', () => {
    const html = renderToStaticMarkup(
      <McpSchemaForm schema={REAL_SCHEMA} values={{ path: '/etc/hosts', limit: 5 }} onChange={noop} />,
    )
    expect(html).toContain('/etc/hosts')
    expect(html).toContain('value="5"')
  })
})
