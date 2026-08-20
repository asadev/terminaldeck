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
  refusal: null,
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

  it('still points at a machine that has gone, so the sentence can be read', () => {
    // The selection is given back by the workspace, which also says why in the
    // notice band. Until it does, the button names what it names — a picker that
    // silently re-labelled itself would lose the only evidence of what happened.
    const gone: MachineChoice = { ...OFFICE, refusal: 'This desktop is not connected to office-pc right now.' }
    const markup = renderToStaticMarkup(
      <MachinePicker machines={[gone]} selected="mach-1" onSelect={() => {}} />,
    )
    expect(markup).toContain('office-pc')
  })
})
