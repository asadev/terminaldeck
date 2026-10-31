/**
 * Files dropped on the native window, handed to the page as Electron hands them.
 *
 * In Electron a file dropped on a terminal types its path at the prompt, and one
 * dropped on an attach area attaches it — both read the path behind each `File`
 * through `webUtils.getPathForFile` (the preload's `pathForDroppedFile`). A
 * WKWebView gives a page no paths at all, so the native side catches the drop
 * itself and sends the paths:
 *
 *     tdNative.run('drop-paths', { paths, x, y })      x, y in the page's own pixels
 *
 * and this replays it as the page would have seen it: a `File` per path, a
 * `dragenter`, `dragover` and `drop` on the element under that point — and
 * `getPathForFile` answering each of those files with its path. The page's own
 * handlers (`TerminalView`'s, the composer's) then do exactly what they do in
 * Electron; nothing in them knows the difference.
 */

interface DropTarget {
  dispatchEvent(event: unknown): boolean
}

export interface DropHost {
  document: { elementFromPoint(x: number, y: number): DropTarget | null }
  File: new (bits: unknown[], name: string) => object
  Event: new (type: string, init?: { bubbles?: boolean; cancelable?: boolean }) => object
  DataTransfer?: new () => { items: { add(file: object): unknown }; files: unknown; types: readonly string[] }
}

/** The last part of a path, which is what the page sees as the file's name. */
export function baseName(path: string): string {
  const parts = path.split(/[\\/]+/).filter((part) => part !== '')
  return parts.at(-1) ?? path
}

function transferFor(host: DropHost, files: readonly object[]): unknown {
  if (host.DataTransfer) {
    try {
      const transfer = new host.DataTransfer()
      for (const file of files) transfer.items.add(file)
      return transfer
    } catch {
      /* an engine that cannot build one: the plain stand-in below reads the same */
    }
  }
  return {
    files,
    items: files.map((file) => ({ kind: 'file', getAsFile: () => file })),
    types: ['Files'],
    dropEffect: 'copy',
    effectAllowed: 'all',
    getData: () => '',
    setData: () => undefined,
  }
}

export function createDrops(host: DropHost) {
  const paths = new WeakMap<object, string>()
  return {
    /** `webUtils.getPathForFile`: the path behind a file this replayed, '' for any other. */
    pathFor(file: unknown): string {
      return typeof file === 'object' && file !== null ? (paths.get(file) ?? '') : ''
    },
    /** `drop-paths`: true when there was something under the point to drop on. */
    deliver(arg: unknown): boolean {
      if (typeof arg !== 'object' || arg === null) return false
      const { paths: list, x, y } = arg as { paths?: unknown; x?: unknown; y?: unknown }
      if (!Array.isArray(list) || typeof x !== 'number' || typeof y !== 'number') return false
      const wanted = list.filter((path): path is string => typeof path === 'string' && path !== '')
      if (wanted.length === 0) return false
      const target = host.document.elementFromPoint(x, y)
      if (target === null) return false
      const files = wanted.map((path) => {
        const file = new host.File([], baseName(path))
        paths.set(file, path)
        return file
      })
      const transfer = transferFor(host, files)
      for (const type of ['dragenter', 'dragover', 'drop']) {
        const event = new host.Event(type, { bubbles: true, cancelable: true })
        Object.defineProperties(event, {
          dataTransfer: { value: transfer },
          clientX: { value: x },
          clientY: { value: y },
        })
        target.dispatchEvent(event)
      }
      return true
    },
  }
}
