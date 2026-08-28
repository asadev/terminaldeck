import { gzipSync } from 'node:zlib'

/**
 * Building the archives the store's own tests read, byte by byte.
 *
 * The same reason `browser-extension-zip.fixture.ts` exists for zips: the cases
 * worth testing are the ones no honest tool will produce on request — a name
 * that climbs out of the folder, a symlink, a header that lies about its size —
 * and an unpacker tested only against archives a real tool wrote is an unpacker
 * tested against the half of the input space that was never the problem.
 *
 * Unreachable from the app on purpose, and listed as such.
 */

const BLOCK = 512

export interface TarEntry {
  name: string
  body?: string
  /** `0` file, `5` folder, `2` symlink, `1` hard link, `3` device, `x`/`g` pax, `L` long name. */
  type?: string
  mode?: number
  /** Written into the size field in place of the real length, to lie with. */
  statedSize?: number
}

function header(entry: TarEntry, size: number): Buffer {
  const block = Buffer.alloc(BLOCK, 0)
  block.write(entry.name.slice(0, 100), 0, 'utf8')
  block.write(`${(entry.mode ?? 0o644).toString(8).padStart(7, '0')}\0`, 100, 'ascii')
  block.write('0000000\0', 108, 'ascii')
  block.write('0000000\0', 116, 'ascii')
  block.write(`${size.toString(8).padStart(11, '0')}\0`, 124, 'ascii')
  block.write('00000000000\0', 136, 'ascii')
  block.write(entry.type ?? '0', 156, 'ascii')
  block.write('ustar\0', 257, 'ascii')
  block.write('00', 263, 'ascii')

  // Taken with the checksum field itself read as spaces, which is why it is
  // filled with spaces first and written last.
  block.write('        ', 148, 'ascii')
  let sum = 0
  for (const byte of block) sum += byte
  block.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148, 'ascii')
  return block
}

/** A tar, then a gzip of it — the shape a repository serves an archive in. */
export function tarGz(entries: readonly TarEntry[], options: { corruptChecksum?: boolean } = {}): Buffer {
  const blocks: Buffer[] = []
  for (const entry of entries) {
    const body = Buffer.from(entry.body ?? '', 'utf8')
    const head = header(entry, entry.statedSize ?? body.length)
    if (options.corruptChecksum === true) head.write('000000\0 ', 148, 'ascii')
    blocks.push(head)
    if (body.length > 0) {
      const padded = Buffer.alloc(Math.ceil(body.length / BLOCK) * BLOCK, 0)
      body.copy(padded)
      blocks.push(padded)
    }
  }
  blocks.push(Buffer.alloc(BLOCK * 2, 0))
  return gzipSync(Buffer.concat(blocks))
}

/** One pax record, in the `<length> <key>=<value>\n` form the format defines. */
export function paxRecord(key: string, value: string): string {
  const body = ` ${key}=${value}\n`
  let length = body.length + 1
  if (String(length).length + body.length > length) length = String(length + 1).length + body.length
  return `${length}${body}`
}
