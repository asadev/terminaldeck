/**
 * Getting a phone's sentence *submitted* at an agent CLI's prompt.
 *
 * ## The defect this module is the fix for
 *
 * A phone could connect to the copilot, start a run, and send a message — and
 * never once get an answer. The message crossed the wire, reached this machine,
 * and was written into the run's pty. It then sat in the CLI's input box,
 * typed and unsubmitted, for as long as anybody cared to look at it. Measured
 * on 2026-08-20 by driving the browser client against a real run: `ps` showed
 * the run alive throughout, the copilot's own pane on the Mac showed
 * `❯ Reply with exactly PONG` in its prompt, and the phone showed "Sending…"
 * until it was reloaded.
 *
 * The write was `${text}\n`. Two things are wrong with it and each one alone is
 * enough to lose the turn:
 *
 *  1. **A newline is not Return.** A terminal sends `\r` for the Return key —
 *     that is what the key is — and an agent CLI reading its own keys in raw
 *     mode gets `\n` as an ordinary character. `\r` is the submit.
 *
 *  2. **One chunk is a paste.** The CLI classifies each stdin chunk before it
 *     looks at the keys in it, and a chunk of about 64 bytes or more is pasted
 *     text, where a carriage return is a *newline* rather than a submit. So
 *     `write(text + '\r')` also does nothing at all for any message longer than
 *     half a line.
 *
 * The window that already knew this is `renderer/chat/attach/mentions.ts`,
 * whose `terminalWrites` splits the same two writes for the same reason and was
 * measured at the same 50ms. The desktop's own composer has been sending
 * messages correctly the whole time; the phone's path is the one that never
 * learned. This module is that knowledge on the main-process side of the
 * boundary, where the phone's path lives — the renderer's copy cannot be
 * imported here, and one of the two had to be reachable from `index.ts`.
 *
 * ## Why the gap is a scheduled second write and not a longer string
 *
 * Because the chunk is the unit the CLI classifies. Anything that produces one
 * `write()` call — a longer string, a `\r\n`, a repeat — is one chunk and is
 * read as a paste. The only thing that makes the Return arrive *as a key* is
 * that it is alone in its own read, which means a real gap on the clock.
 */

/**
 * How long to wait between the two writes.
 *
 * Measured, and the measurement is `mentions.ts`'s: written back to back they
 * are read as one chunk and nothing is sent; 30ms apart submits. 50 leaves room
 * for a slower machine and is still far below anything a person notices — a
 * phone's message is already a round trip old by the time it gets here.
 */
export const SUBMIT_GAP_MS = 50

/** The two writes a run must receive, in order, for one message to be sent. */
export function submitWrites(text: string): [string, string] {
  return [text, '\r']
}

/** Deferring the second write. `setTimeout` in the app; a fake clock in a test. */
export type Defer = (ms: number, run: () => void) => void

/**
 * Type a sentence into a run and submit it.
 *
 * The first write is synchronous, so a caller that reports success is reporting
 * something that has already happened to the pty; only the Return is deferred.
 * A `write` that throws on the first call therefore throws to the caller — which
 * is what `CopilotRuns.say` turns into "the copilot did not take that message"
 * — while a failure on the deferred Return has nobody left to tell and is
 * swallowed rather than left to reach an unhandled rejection.
 */
export function typeAndSubmit(
  write: (data: string) => void,
  text: string,
  defer: Defer = (ms, run) => {
    setTimeout(run, ms).unref?.()
  },
  gapMs: number = SUBMIT_GAP_MS,
): void {
  const [typed, submit] = submitWrites(text)
  write(typed)
  defer(gapMs, () => {
    try {
      write(submit)
    } catch (error) {
      console.error('[remote] could not submit a copilot message:', error)
    }
  })
}
