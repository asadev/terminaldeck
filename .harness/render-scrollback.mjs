/**
 * Render a harness session's raw PTY stream the way the desktop renders it.
 *
 *   node .harness/render-scrollback.mjs 127.0.0.1:8921 SOME-MARKER
 *
 * `/scrollback` hands back the bytes the shell wrote, escapes and all, so
 * `grep` over it is not a reading of what is on the screen. A shell repaints its
 * input line with carriage returns and erase-to-end-of-line, writing the same
 * characters several times — a substring search answers "no" for text plainly
 * visible. Feeding the stream through the emulator the app itself uses is the
 * only reading that matches what a person sees.
 *
 * ## zsh will still defeat this, and that is not a bug here
 *
 * `zle` does not merely repaint a long line, it *windows* it: past the right
 * edge it erases and redraws a moving view of the buffer, so the whole input is
 * never on screen at once and no terminal width reconstructs it. That is real
 * zsh behaviour and a phone's terminal is narrow. To assert on a literal, run
 * the harness against a shell with no line editor:
 *
 *   TD_FORCE_SHELL=1 SHELL=/bin/sh scripts/remote-host.sh --name inspect …
 *
 * `providers.ts` reads `$SHELL`, so that is the whole of it.
 */

import headless from '@xterm/headless'

const { Terminal } = headless

const control = process.argv[2] ?? '127.0.0.1:8921'
const needle = process.argv[3] ?? ''

const answer = await fetch(`http://${control}/scrollback`)
const sessions = await answer.json()

for (const session of sessions) {
  const term = new Terminal({ cols: 200, rows: 60, allowProposedApi: true })
  await new Promise((settle) => term.write(session.text, settle))

  const lines = []
  for (let y = 0; y < term.buffer.active.length; y += 1) {
    const line = term.buffer.active.getLine(y)
    if (line) lines.push(line.translateToString(true))
  }
  const screen = lines.join('\n').replace(/\n+$/, '')

  process.stdout.write(`\n=== ${session.id}  (${session.title})  ${session.cwd}\n`)
  process.stdout.write(`${screen}\n`)
  if (needle) {
    const hit = screen.includes(needle)
    process.stdout.write(`\nMARKER ${JSON.stringify(needle)} PRESENT: ${hit}\n`)
    if (hit) {
      const line = screen.split('\n').find((l) => l.includes(needle)) ?? ''
      process.stdout.write(`LINE: ${line}\n`)
      // The safety property: the line is sitting at a prompt, not submitted.
      process.stdout.write(`SUBMITTED (a line exists after it): ${
        screen.split('\n').indexOf(line) < screen.split('\n').length - 1
      }\n`)
    }
  }
}
