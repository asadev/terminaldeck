/**
 * A byte count as a person would say it.
 *
 * Shared rather than written where it is needed, because the same limit is
 * quoted to the same person from two processes: the main process refuses a file
 * over `MAX_UPLOAD_BYTES` and names the ceiling, and the window refuses a paste
 * over `MAX_PASTE_BYTES` and names that one. Two formatters would eventually
 * disagree about whether 1,048,576 bytes is "1 MB" or "1.0 MB", and a person
 * reading both would be reading a contradiction about the same product.
 *
 * Decimal units, which is what a phone's storage screen and every file size in
 * the Finder use — and matching `byteSize` in
 * `ios/TerminalDeck/Transfer/FileUpload.swift`, which quotes these same limits
 * on the other surface.
 *
 * Nothing here touches a node built-in or a DOM API, so it compiles in the main
 * process, the renderer and anything else that imports `src/shared`.
 */
export function byteSize(bytes: number): string {
  const units = ['bytes', 'KB', 'MB', 'GB']
  let value = bytes
  let unit = 0
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000
    unit += 1
  }
  if (unit === 0) return `${bytes} bytes`
  // One decimal below ten, none above: "3.4 MB" and "512 MB" are both how
  // somebody would say it, and "3 MB" loses a third of the number.
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`
}
