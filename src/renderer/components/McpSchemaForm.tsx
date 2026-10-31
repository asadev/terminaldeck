import { useEffect, useId, useMemo, useRef, useState } from 'react'
import './McpInspector.css'

/**
 * A form built from a tool's JSON Schema.
 *
 * The governing rule is that the panel must never break because a server sent
 * something odd. MCP tool schemas come from whatever code the server author
 * wrote; they are frequently partial and occasionally nonsense. So every
 * unrecognised shape degrades one step — an unknown property type becomes a
 * text box, an unrepresentable property becomes a JSON box, and a schema that
 * is not an object at all becomes a single JSON box for the whole argument set.
 * At no point does the user lose the ability to call the tool.
 */

/* ------------------------------------------------------------------ model -- */

export type FieldKind = 'string' | 'number' | 'integer' | 'boolean' | 'enum' | 'array' | 'object' | 'json'

export interface EnumOption {
  value: unknown
  label: string
}

export interface SchemaField {
  name: string
  kind: FieldKind
  description: string | null
  required: boolean
  /** True when the schema declared no type and we guessed text. */
  inferred: boolean
  options: EnumOption[] | null
  /** Element kind for arrays of primitives; null when the array is JSON-edited. */
  itemKind: FieldKind | null
  itemOptions: EnumOption[] | null
  /** Nested fields for an object property we could describe. */
  fields: SchemaField[] | null
  defaultValue: unknown
}

export interface SchemaDescription {
  fields: SchemaField[]
  /**
   * Non-null when the whole schema was unusable and the caller should edit raw
   * JSON instead. `fields: []` with a null fallback means "takes no arguments".
   */
  fallback: string | null
}

/** Objects nested deeper than this are edited as JSON — past three levels a
 * generated form is harder to read than the JSON it stands in for. */
const MAX_DEPTH = 3

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** JSON Schema allows `type: ['string', 'null']`; take the first real type. */
function readType(raw: Record<string, unknown>): string | null {
  const type = raw.type
  if (typeof type === 'string') return type
  if (Array.isArray(type)) {
    const first = type.find((entry) => typeof entry === 'string' && entry !== 'null')
    return typeof first === 'string' ? first : null
  }
  return null
}

function label(value: unknown): string {
  if (typeof value === 'string') return value
  return JSON.stringify(value) ?? String(value)
}

/**
 * Enumerations arrive three ways in the wild: a bare `enum`, a union of
 * `const`s under `anyOf`/`oneOf`, or a single `const`. All three are a picker.
 */
function readOptions(raw: Record<string, unknown>): EnumOption[] | null {
  if (Array.isArray(raw.enum) && raw.enum.length > 0) {
    return raw.enum.map((value) => ({ value, label: label(value) }))
  }
  if ('const' in raw) return [{ value: raw.const, label: label(raw.const) }]

  const union = Array.isArray(raw.anyOf) ? raw.anyOf : Array.isArray(raw.oneOf) ? raw.oneOf : null
  if (!union || union.length === 0) return null
  const consts: EnumOption[] = []
  for (const member of union) {
    if (!isRecord(member)) return null
    if ('const' in member) consts.push({ value: member.const, label: label(member.const) })
    else if (Array.isArray(member.enum)) consts.push(...member.enum.map((v) => ({ value: v, label: label(v) })))
    else if (readType(member) === 'null') continue
    else return null
  }
  return consts.length > 0 ? consts : null
}

const PRIMITIVE_ITEM_KINDS = new Set<FieldKind>(['string', 'number', 'integer', 'boolean', 'enum'])

function describeField(name: string, raw: unknown, required: boolean, depth: number): SchemaField {
  const base: SchemaField = {
    name,
    kind: 'json',
    description: null,
    required,
    inferred: false,
    options: null,
    itemKind: null,
    itemOptions: null,
    fields: null,
    defaultValue: undefined,
  }
  // A property that is not an object (`"path": "a string"`) is malformed; a
  // JSON box still lets the call be made.
  if (!isRecord(raw)) return base

  const description = typeof raw.description === 'string' && raw.description.length > 0 ? raw.description : null
  const defaultValue = 'default' in raw ? raw.default : undefined
  const options = readOptions(raw)
  const type = readType(raw)

  if (options) {
    return { ...base, kind: 'enum', description, defaultValue, options }
  }

  if (type === 'boolean') return { ...base, kind: 'boolean', description, defaultValue }
  if (type === 'number' || type === 'integer') return { ...base, kind: type, description, defaultValue }
  if (type === 'string') return { ...base, kind: 'string', description, defaultValue }

  if (type === 'array' || (!type && 'items' in raw)) {
    const items = isRecord(raw.items) ? raw.items : null
    const itemOptions = items ? readOptions(items) : null
    const itemType = items ? readType(items) : null
    const itemKind: FieldKind = itemOptions
      ? 'enum'
      : itemType === 'number' || itemType === 'integer'
        ? itemType
        : itemType === 'boolean'
          ? 'boolean'
          : itemType === 'string'
            ? 'string'
            : 'json'
    return {
      ...base,
      kind: 'array',
      description,
      defaultValue,
      itemKind: PRIMITIVE_ITEM_KINDS.has(itemKind) ? itemKind : null,
      itemOptions,
    }
  }

  if (type === 'object' || (!type && isRecord(raw.properties))) {
    const nested = describeSchema(raw, depth + 1)
    // No describable properties, or too deep to render: JSON box.
    if (nested.fallback || nested.fields.length === 0) {
      return { ...base, kind: 'json', description, defaultValue }
    }
    return { ...base, kind: 'object', description, defaultValue, fields: nested.fields }
  }

  if (!type) {
    // No declared type at all. Text is what nearly every such argument turns
    // out to be, and a JSON box would force the user to quote a bare word.
    return { ...base, kind: 'string', description, defaultValue, inferred: true }
  }

  return { ...base, description, defaultValue }
}

/** Turn a tool's `inputSchema` into a list of controls. Never throws. */
export function describeSchema(schema: unknown, depth = 0): SchemaDescription {
  if (schema === null || schema === undefined) {
    return { fields: [], fallback: 'This tool did not describe its arguments.' }
  }
  if (!isRecord(schema)) {
    return { fields: [], fallback: 'This tool’s schema is not an object.' }
  }
  if (depth > MAX_DEPTH) {
    return { fields: [], fallback: 'Nested too deeply to lay out as a form.' }
  }

  const declared = readType(schema)
  if (declared && declared !== 'object') {
    return { fields: [], fallback: `This tool’s schema describes a ${declared}, not an argument object.` }
  }

  const properties = schema.properties
  if (properties === undefined) {
    // `{ type: 'object' }` with nothing else is a tool that takes no arguments.
    return { fields: [], fallback: declared === 'object' ? null : 'This tool did not list any arguments.' }
  }
  if (!isRecord(properties)) {
    return { fields: [], fallback: 'This tool’s argument list is malformed.' }
  }

  const required = new Set(
    Array.isArray(schema.required) ? schema.required.filter((name): name is string => typeof name === 'string') : [],
  )

  return {
    fields: Object.entries(properties).map(([name, raw]) => describeField(name, raw, required.has(name), depth)),
    fallback: null,
  }
}

/* ----------------------------------------------------------------- values -- */

/** Seed a form from the schema's declared defaults. */
export function initialValues(fields: SchemaField[]): Record<string, unknown> {
  const values: Record<string, unknown> = {}
  for (const field of fields) {
    if (field.defaultValue !== undefined) values[field.name] = field.defaultValue
    else if (field.kind === 'object' && field.fields) {
      const nested = initialValues(field.fields)
      if (Object.keys(nested).length > 0) values[field.name] = nested
    }
  }
  return values
}

/**
 * Strip the blanks before sending.
 *
 * An optional string left empty must not be sent as `""` — servers that treat
 * "provided but empty" differently from "not provided" are common, and a form
 * that silently sends every field would break them.
 */
export function pruneArguments(values: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined || value === '') continue
    if (Array.isArray(value)) {
      out[key] = pruneArray(value)
      continue
    }
    if (isRecord(value)) {
      const nested = pruneArguments(value)
      if (Object.keys(nested).length > 0) out[key] = nested
      continue
    }
    out[key] = value
  }
  return out
}

/**
 * Drop the holes out of an array argument.
 *
 * "Add item" appends an empty row, and an untouched one holds `undefined`.
 * `JSON.stringify` renders that as `null`, so a half-filled list arrived at the
 * server as `["a", null]` — which a schema of `items: {type: 'string'}` rejects
 * with a type error that points at nothing the user can see. An array that
 * prunes down to empty is kept: unlike an object, `[]` is a real argument.
 */
function pruneArray(items: unknown[]): unknown[] {
  // Only `undefined` is removed, and nothing inside the surviving entries is
  // touched: `undefined` cannot come out of `JSON.parse`, so it is always our
  // own empty row and never something the user typed into a JSON box. Pruning
  // any further would quietly edit hand-written JSON.
  return items.filter((item) => item !== undefined)
}

/**
 * Which `<option>` is showing, given the current value.
 *
 * Options are addressed by index because an enum of numbers or objects cannot
 * round trip through a select's string value. Identity is tried first; the JSON
 * comparison is the fallback for a schema `default` that equals an option
 * without being the same reference, which otherwise left the select blank while
 * the value was in fact set.
 */
export function selectIndexOf(options: EnumOption[], value: unknown): number {
  if (value === undefined) return -1
  const identical = options.findIndex((option) => Object.is(option.value, value))
  if (identical >= 0) return identical
  let encoded: string
  try {
    encoded = JSON.stringify(value) ?? ''
  } catch {
    return -1
  }
  return options.findIndex((option) => {
    try {
      return JSON.stringify(option.value) === encoded
    } catch {
      return false
    }
  })
}

/**
 * Turn a select's raw string value back into the option it stands for.
 *
 * The empty string is the "not set" row, and it has to be checked before the
 * number conversion: `Number('')` is `0`, so the obvious `options[Number(raw)]`
 * silently answered "clear this field" with the *first* enum value — choosing
 * "Not set" set the field instead of unsetting it.
 */
export function optionValueAt(options: EnumOption[], raw: string): unknown {
  if (raw === '') return undefined
  const index = Number(raw)
  if (!Number.isInteger(index) || index < 0 || index >= options.length) return undefined
  return options[index].value
}

/** Required fields the user has not filled in, for a call button that explains itself. */
export function missingRequired(fields: SchemaField[], values: Record<string, unknown>): string[] {
  const missing: string[] = []
  for (const field of fields) {
    const value = values[field.name]
    if (field.kind === 'object' && field.fields) {
      const nested = isRecord(value) ? value : {}
      missing.push(...missingRequired(field.fields, nested).map((name) => `${field.name}.${name}`))
      continue
    }
    if (!field.required) continue
    // `false` and `0` are answers; only absence and empty text are not.
    if (value === undefined || value === null || value === '') missing.push(field.name)
    else if (Array.isArray(value) && value.length === 0) missing.push(field.name)
  }
  return missing
}

/* --------------------------------------------------------------- controls -- */

function coerceNumber(text: string, integer: boolean): number | undefined {
  if (text.trim() === '') return undefined
  const parsed = integer ? Number.parseInt(text, 10) : Number(text)
  return Number.isFinite(parsed) ? parsed : undefined
}

interface JsonBoxProps {
  id: string
  value: unknown
  disabled: boolean
  placeholder: string
  onValue(next: unknown): void
  onInvalid(message: string | null): void
}

/**
 * A JSON editor that keeps what the user typed.
 *
 * Parsing on every keystroke and writing the parsed value back would erase a
 * half-typed object the moment it stopped being valid, so the text lives here
 * and only valid text is published upward.
 */
function JsonBox({ id, value, disabled, placeholder, onValue, onInvalid }: JsonBoxProps) {
  const [text, setText] = useState(() => (value === undefined ? '' : JSON.stringify(value, null, 2)))
  const [error, setError] = useState<string | null>(null)

  const change = (next: string): void => {
    setText(next)
    if (next.trim() === '') {
      setError(null)
      onInvalid(null)
      onValue(undefined)
      return
    }
    try {
      const parsed: unknown = JSON.parse(next)
      setError(null)
      onInvalid(null)
      onValue(parsed)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Invalid JSON'
      setError(message)
      onInvalid(message)
    }
  }

  return (
    <>
      <textarea
        id={id}
        className="mcp-input mcp-input-json"
        rows={4}
        spellCheck={false}
        disabled={disabled}
        placeholder={placeholder}
        value={text}
        onChange={(event) => change(event.target.value)}
        aria-invalid={error !== null}
      />
      {error && <p className="mcp-field-error">{error}</p>}
    </>
  )
}

interface PrimitiveProps {
  id: string
  kind: FieldKind
  options: EnumOption[] | null
  value: unknown
  required: boolean
  disabled: boolean
  onValue(next: unknown): void
}

function PrimitiveControl({ id, kind, options, value, required, disabled, onValue }: PrimitiveProps) {
  if (kind === 'boolean') {
    return (
      <input
        id={id}
        className="mcp-checkbox"
        type="checkbox"
        disabled={disabled}
        checked={value === true}
        onChange={(event) => onValue(event.target.checked)}
      />
    )
  }

  if (kind === 'enum' && options) {
    const index = selectIndexOf(options, value)
    return (
      <select
        id={id}
        className="mcp-input"
        disabled={disabled}
        value={index >= 0 ? String(index) : ''}
        onChange={(event) => onValue(optionValueAt(options, event.target.value))}
      >
        <option value="">{required ? 'Choose…' : 'Not set'}</option>
        {options.map((option, i) => (
          <option key={`${option.label}-${i}`} value={String(i)}>
            {option.label}
          </option>
        ))}
      </select>
    )
  }

  if (kind === 'number' || kind === 'integer') {
    return (
      <input
        id={id}
        className="mcp-input"
        type="number"
        step={kind === 'integer' ? 1 : 'any'}
        disabled={disabled}
        value={typeof value === 'number' ? String(value) : ''}
        onChange={(event) => onValue(coerceNumber(event.target.value, kind === 'integer'))}
      />
    )
  }

  return (
    <input
      id={id}
      className="mcp-input"
      type="text"
      disabled={disabled}
      value={typeof value === 'string' ? value : value === undefined ? '' : String(value)}
      onChange={(event) => onValue(event.target.value === '' ? undefined : event.target.value)}
    />
  )
}

interface ArrayProps {
  id: string
  field: SchemaField
  value: unknown
  disabled: boolean
  onValue(next: unknown): void
}

/** Repeatable rows for an array of primitives — a JSON box for anything else. */
function ArrayControl({ id, field, value, disabled, onValue }: ArrayProps) {
  const items = Array.isArray(value) ? value : []
  const kind = field.itemKind ?? 'string'

  const replace = (index: number, next: unknown): void => {
    const copy = [...items]
    copy[index] = next
    onValue(copy)
  }

  return (
    <div className="mcp-array">
      {items.map((item, index) => (
        <div className="mcp-array-row" key={index}>
          <PrimitiveControl
            id={`${id}-${index}`}
            kind={kind}
            options={field.itemOptions}
            value={item}
            required={false}
            disabled={disabled}
            onValue={(next) => replace(index, next)}
          />
          <button
            type="button"
            className="mcp-array-remove"
            disabled={disabled}
            aria-label={`Remove item ${index + 1}`}
            onClick={() => onValue(items.filter((_item, i) => i !== index))}
          >
            −
          </button>
        </div>
      ))}
      <button
        type="button"
        className="mcp-array-add"
        disabled={disabled}
        onClick={() => onValue([...items, kind === 'boolean' ? false : kind === 'string' ? '' : undefined])}
      >
        Add item
      </button>
    </div>
  )
}

interface FieldProps {
  field: SchemaField
  idPrefix: string
  value: unknown
  disabled: boolean
  onValue(next: unknown): void
  onInvalid(name: string, message: string | null): void
}

function Field({ field, idPrefix, value, disabled, onValue, onInvalid }: FieldProps) {
  const id = `${idPrefix}-${field.name}`

  return (
    <div className="mcp-field" data-kind={field.kind}>
      <label className="mcp-field-label" htmlFor={id}>
        <span className="mcp-field-name">{field.name}</span>
        {field.required && (
          <span className="mcp-field-required" aria-label="required">
            *
          </span>
        )}
        <span className="mcp-field-type">{field.inferred ? 'text (type not declared)' : field.kind}</span>
      </label>
      {field.description && <p className="mcp-field-description">{field.description}</p>}

      {field.kind === 'object' && field.fields ? (
        <div className="mcp-nested">
          <ObjectFields
            fields={field.fields}
            idPrefix={id}
            values={isRecord(value) ? value : {}}
            disabled={disabled}
            onValues={(next) => onValue(next)}
            onInvalid={(name, message) => onInvalid(`${field.name}.${name}`, message)}
          />
        </div>
      ) : field.kind === 'array' && field.itemKind ? (
        <ArrayControl id={id} field={field} value={value} disabled={disabled} onValue={onValue} />
      ) : field.kind === 'array' || field.kind === 'json' ? (
        <JsonBox
          id={id}
          value={value}
          disabled={disabled}
          placeholder={field.kind === 'array' ? '[]' : '{}'}
          onValue={onValue}
          onInvalid={(message) => onInvalid(field.name, message)}
        />
      ) : (
        <PrimitiveControl
          id={id}
          kind={field.kind}
          options={field.options}
          value={value}
          required={field.required}
          disabled={disabled}
          onValue={onValue}
        />
      )}
    </div>
  )
}

interface ObjectFieldsProps {
  fields: SchemaField[]
  idPrefix: string
  values: Record<string, unknown>
  disabled: boolean
  onValues(next: Record<string, unknown>): void
  onInvalid(name: string, message: string | null): void
}

export function ObjectFields({ fields, idPrefix, values, disabled, onValues, onInvalid }: ObjectFieldsProps) {
  return (
    <>
      {fields.map((field) => (
        <Field
          key={field.name}
          field={field}
          idPrefix={idPrefix}
          value={values[field.name]}
          disabled={disabled}
          onValue={(next) => onValues({ ...values, [field.name]: next })}
          onInvalid={onInvalid}
        />
      ))}
    </>
  )
}

/* ------------------------------------------------------------------- form -- */

export interface McpSchemaFormProps {
  /** The tool's `inputSchema`, exactly as the server sent it. */
  schema: unknown
  values: Record<string, unknown>
  onChange(next: Record<string, unknown>): void
  /** JSON boxes that currently hold unparseable text, so Run can be disabled. */
  onInvalidChange?(names: string[]): void
  disabled?: boolean
  idPrefix?: string
}

export function McpSchemaForm({
  schema,
  values,
  onChange,
  onInvalidChange,
  disabled = false,
  idPrefix,
}: McpSchemaFormProps) {
  const generatedId = useId()
  const prefix = idPrefix ?? generatedId
  const description = useMemo(() => describeSchema(schema), [schema])
  const [invalid, setInvalid] = useState<Record<string, string>>({})

  // The callback is reported through a ref rather than depended on directly:
  // a caller passing an inline lambda would otherwise change the effect's
  // identity on every render and re-notify forever.
  const notify = useRef(onInvalidChange)
  useEffect(() => {
    notify.current = onInvalidChange
  })
  useEffect(() => {
    notify.current?.(Object.keys(invalid))
  }, [invalid])

  const noteInvalid = (name: string, message: string | null): void => {
    setInvalid((current) => {
      if ((current[name] ?? null) === message) return current
      const next = { ...current }
      if (message) next[name] = message
      else delete next[name]
      return next
    })
  }

  if (description.fallback) {
    // The schema told us nothing usable. Hand over the whole argument object.
    return (
      <div className="mcp-form">
        <p className="mcp-form-note">{description.fallback} Enter the arguments as JSON.</p>
        <JsonBox
          id={`${prefix}-raw`}
          value={Object.keys(values).length > 0 ? values : undefined}
          disabled={disabled}
          placeholder='{ "key": "value" }'
          onValue={(next) => onChange(isRecord(next) ? next : {})}
          // Named for the reader, not for the code: this key is echoed back in
          // the caller's "fix the JSON in …" hint.
          onInvalid={(message) => noteInvalid('arguments', message)}
        />
      </div>
    )
  }

  if (description.fields.length === 0) {
    return (
      <div className="mcp-form">
        <p className="mcp-form-note">This tool takes no arguments.</p>
      </div>
    )
  }

  return (
    <div className="mcp-form">
      <ObjectFields
        fields={description.fields}
        idPrefix={prefix}
        values={values}
        disabled={disabled}
        onValues={onChange}
        onInvalid={noteInvalid}
      />
    </div>
  )
}
