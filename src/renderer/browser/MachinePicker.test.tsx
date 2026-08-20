import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { MachinePicker } from './MachinePicker'
import { THIS_MACHINE, type MachineChoice } from './machines-bridge'

/**
 * The dropdown he asked for, held to its closed state.
 *
 * There is no DOM in this project's test run, so the popup cannot be opened
 * here — what it contains is decided by `machineChoices`, which
 * `machines-bridge.test.ts` holds row by row. What is left, and what this file
 * pins, is the part that is on screen all the time: a control that names the
 * machine it is pointing at, in words, and that says so to a screen reader as
 * well as in a tooltip.
 */

const OFFICE: MachineChoice = {
  kind: 'device',
  id: 'mach-1',
  name: 'office-pc',
  noun: 'PC',
  ports: [{ port: 5173, process: 'node', guessed: false, ours: false }],
  unreachable: null,
  detail: null,
}

describe('the machine picker', () => {
  it('says this machine, and does not wear the accent, until it is pointed elsewhere', () => {
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[OFFICE]} selected={THIS_MACHINE} onSelect={() => {}} />,
    )
    expect(markup).toContain('This machine')
    expect(markup).toContain('aria-label="Addresses open on This machine. Choose a machine."')
    // The accent is otherwise reserved for selection and focus. It is spent here
    // only while the browser is doing something worth being reminded of.
    expect(markup).not.toContain('data-on')
  })

  it('names the chosen machine, and lights up while it is chosen', () => {
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[OFFICE]} selected="mach-1" onSelect={() => {}} />,
    )
    expect(markup).toContain('office-pc')
    expect(markup).toContain('data-on="true"')
    expect(markup).toContain('aria-label="Addresses open on office-pc. Choose a machine."')
  })

  it('says which question it answers, in the words the menu uses', () => {
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[OFFICE]} selected="mach-1" onSelect={() => {}} />,
    )
    /*
     * Only localhost moves, and the hover says so by naming the thing that
     * moves. It used to say it in two sentences — *"localhost in the address bar
     * means office-pc. Its ports are opened here, in this window."* — on a bar
     * where Asad had just had every hover cut to its name: *"when I hover, it
     * should show the title, like shade, inspect, record. Instead of this line,
     * show only the name."* Four words, and they are the menu's own heading, so
     * opening the control confirms the hover rather than restating it.
     */
    expect(markup).toContain('title="Open localhost on office-pc"')
    expect(markup).not.toContain('Its ports are opened here')
  })

  it('is a real button with a menu behind it, never a label', () => {
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[OFFICE]} selected={THIS_MACHINE} onSelect={() => {}} />,
    )
    expect(markup).toContain('aria-haspopup="menu"')
    expect(markup).toContain('aria-expanded="false"')
    expect(markup).toContain('<button')
  })

  /**
   * A server draws the same control, in the same words.
   *
   * Asserted by comparing the two renders rather than by matching strings,
   * because the requirement is a *sameness* rather than a particular sentence:
   * *"shape of the application should not be changing for local and remote
   * devices."* A future change that gave servers their own label, their own
   * glyph or their own row would pass a string test written about servers and
   * fail this one.
   */
  it('draws a server exactly as it draws a computer somebody sits at', () => {
    const server: MachineChoice = { ...OFFICE, kind: 'server', id: 's1', noun: 'server' }
    const asServer = renderToStaticMarkup(
      <MachinePicker machines={[server]} selected="s1" onSelect={() => {}} />,
    )
    const asDevice = renderToStaticMarkup(
      <MachinePicker machines={[OFFICE]} selected="mach-1" onSelect={() => {}} />,
    )
    expect(asServer).toBe(asDevice)
  })

  it('still points at a machine that has gone, so what happened can be read', () => {
    // The selection is given back by the workspace, which also names the state
    // in the notice band. Until it does, the button names what it names — a
    // picker that silently re-labelled itself would lose the only evidence of
    // what happened.
    const gone: MachineChoice = { ...OFFICE, unreachable: 'Not connected' }
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[gone]} selected="mach-1" onSelect={() => {}} />,
    )
    expect(markup).toContain('office-pc')
  })

  /**
   * The paragraph that was in `f_125.jpg`, and the ceiling that keeps it out.
   *
   * The menu printed three lines under a greyed row — *"DESKTOP-DDGMNCV is not
   * sharing what it is serving with this desktop. Either it is running an older
   * version, or this desktop is a guest there…"* — which is the habit he has
   * struck out more times than any other, and it was defending a refusal that
   * has since been fixed rather than reworded.
   *
   * Pinned as a *shape* rather than as the absence of those particular words,
   * because a reworded paragraph would pass a string test and fail a person.
   */
  it('puts no sentence in the menu, whatever a row has to say', () => {
    const gone: MachineChoice = {
      ...OFFICE,
      unreachable: 'Cannot connect',
      detail: 'The relay refused the credential.',
    }
    const markup = renderToStaticMarkup(<MachinePicker machines={[gone]} selected="" onSelect={() => {}} />)
    // The closed control is all a DOM-less render can show, and the detail must
    // not be in it at all — it is a `title` on a row inside the popup, which is
    // only built when somebody opens it.
    expect(markup).not.toContain('The relay refused the credential')
    expect(markup).not.toContain('older version')

    /*
     * And the popup itself, which no render in this project can reach, held
     * structurally instead — the same trick `plain-words.test.ts` uses one
     * folder over, and for the same reason: copy comes back one element at a
     * time, added by somebody who has a good reason for that one.
     *
     * A row is a button and a label at the end of it. A paragraph in this file
     * is somebody explaining again.
     */
    const source = readFileSync(join(__dirname, 'MachinePicker.tsx'), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/^[ \t]*\/\/.*$/gm, '')
    // One paragraph in the file, and it is the menu's three-word heading.
    // Anything else is a row that has started explaining itself.
    const paragraphs = [...source.matchAll(/<p[\s>][^>]*>/g)].map((match) => match[0])
    expect(paragraphs).toEqual(['<p className="bw-menu-title">'])
    expect(source).not.toContain('bw-menu-note')
  })
})
