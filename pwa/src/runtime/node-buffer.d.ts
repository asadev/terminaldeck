/**
 * `Buffer`, declared for a compiler that has been told there is no Node here.
 *
 * ## Why a browser client has a Buffer at all
 *
 * It has one because `src/shared/sealed.ts` has one, and that file is imported
 * rather than reimplemented — see `runtime/node-crypto.ts` for the whole
 * argument. Its public shape is `Buffer` in and `Buffer` out, and it is the same
 * shape the desktop's `relay-client.ts`, `host-identity.ts` and `store.ts` read;
 * changing it to `Uint8Array` for this client's benefit would be a change to the
 * main process, in a file whose bytes four platforms agree on.
 *
 * So the browser gets a Buffer. The runtime one comes from the `buffer` package
 * — the browserify implementation, twelve years old and in every bundle on the
 * web — injected per module by the small plugin in `pwa/vite.config.ts`. This
 * file is only its type.
 *
 * ## Why the package's own `index.d.ts` is not used
 *
 * It is wrong in the two places this code needs to be right. It types
 * `writeBigUInt64LE(value: number, …)` where the value is a `bigint` — that call
 * is the Noise nonce counter, the single field with no room for a mistake in it
 * — and it inherits `subarray(): Uint8Array` from `Uint8Array`, where every
 * caller in `sealed.ts` keeps using the result as a `Buffer`. Adopting those
 * types would mean editing shared code to work around a shim's declaration,
 * which is the tail wagging the dog.
 *
 * ## Why the surface below is deliberately small
 *
 * It is exactly what the shared crypto and this client use, and no more. That is
 * a feature: the day something in `src/shared/` reaches for a Buffer method the
 * browser bundle has never exercised, `npm --prefix pwa run typecheck` fails
 * here, loudly, instead of the browser finding out at a handshake. Adding a
 * member is one line — and it is one line somebody had to mean.
 *
 * Not visible to `pwa/tsconfig.node.json`, which compiles the Node-side files
 * (`vite.config.ts`, `tests/`) with `@types/node` and its own real `Buffer`.
 * Two global declarations of one name in one program is an error, so the two
 * configs are kept apart by their `include` lists rather than by luck.
 */

export {}

declare global {
  /** The encodings this client and the shared crypto actually name. */
  type BufferEncoding = 'utf8' | 'hex' | 'base64' | 'base64url' | 'latin1' | 'ascii'

  /*
   * `Uint8Array<ArrayBuffer>`, not `<ArrayBufferLike>`, and the difference is
   * not cosmetic. `Uint8Array.slice()` is declared as returning
   * `Uint8Array<ArrayBuffer>`, so a Buffer whose backing type were the looser
   * `ArrayBufferLike` would not be assignable to the very interface it extends,
   * and every `Buffer` handed to a `Uint8Array` parameter — which is most of
   * `@noble` — would fail to compile with a message about `SharedArrayBuffer`.
   * A Buffer never sits on shared memory here; nothing in this client allocates
   * one.
   */
  interface Buffer extends Uint8Array<ArrayBuffer> {
    subarray(start?: number, end?: number): Buffer
    slice(start?: number, end?: number): Buffer
    toString(encoding?: BufferEncoding, start?: number, end?: number): string
    equals(other: Uint8Array): boolean
    copy(target: Uint8Array, targetStart?: number, sourceStart?: number, sourceEnd?: number): number
    indexOf(value: string | number | Uint8Array, byteOffset?: number, encoding?: BufferEncoding): number
    /** The Noise nonce counter. `bigint`, not `number` — see the header. */
    writeBigUInt64LE(value: bigint, offset?: number): number
  }

  interface BufferConstructor {
    from(text: string, encoding?: BufferEncoding): Buffer
    from(data: ArrayLike<number> | ArrayBufferLike | Uint8Array): Buffer
    concat(list: readonly Uint8Array[], totalLength?: number): Buffer
    alloc(size: number, fill?: number): Buffer
    isBuffer(value: unknown): value is Buffer
  }

  const Buffer: BufferConstructor
}
