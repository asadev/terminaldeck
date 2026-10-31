/**
 * How values cross the bridge: JSON, with one addition for bytes.
 *
 * Electron's IPC uses the structured clone algorithm, so a handler may answer
 * with a `Uint8Array` and a push may carry one (a device frame is a JPEG). JSON
 * has no bytes, and its default for them is useless — a `Buffer` becomes
 * `{"type":"Buffer","data":[…]}` and a plain `Uint8Array` becomes an object
 * keyed `"0"`, `"1"`, … So bytes travel as `{"$bytes":"<base64>"}`, in both
 * directions, and everything else is ordinary JSON: `undefined` drops out of
 * objects and becomes `null` in arrays, a `Date` becomes its ISO string, and an
 * `Error` becomes `{ name, message }`.
 */

/** The one key a bytes value travels under. */
export const BYTES_KEY = '$bytes'

function bytesOf(value: unknown): Uint8Array | null {
  if (value instanceof Uint8Array) return value
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  return null
}

/**
 * `JSON.stringify` with bytes and errors made legible.
 *
 * The replacer reads `this[key]` rather than `value` because `Buffer` has a
 * `toJSON` that runs *before* the replacer sees it — by then the bytes are
 * already an array of numbers.
 */
export function encodeForWire(value: unknown): string {
  return JSON.stringify(value, function (this: Record<string, unknown>, key: string, current: unknown) {
    const original = this[key]
    const bytes = bytesOf(original)
    if (bytes !== null) return { [BYTES_KEY]: Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64') }
    if (original instanceof Error) return { name: original.name, message: original.message }
    if (typeof original === 'bigint') return original.toString()
    return current
  })
}

/** The inverse of the bytes half of {@link encodeForWire}, applied to a parsed body. */
export function decodeFromWire(value: unknown, depth = 0): unknown {
  if (depth > 64 || value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map((item) => decodeFromWire(item, depth + 1))
  const record = value as Record<string, unknown>
  const keys = Object.keys(record)
  if (keys.length === 1 && keys[0] === BYTES_KEY && typeof record[BYTES_KEY] === 'string') {
    return Buffer.from(record[BYTES_KEY] as string, 'base64')
  }
  const out: Record<string, unknown> = {}
  for (const key of keys) {
    // Assigning `__proto__` would replace this object's prototype, not add a key.
    if (key === '__proto__') continue
    out[key] = decodeFromWire(record[key], depth + 1)
  }
  return out
}
