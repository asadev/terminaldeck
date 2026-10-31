import { describe, expect, it } from 'vitest'
import {
  appendStep,
  describeStep,
  flowLine,
  formatFlow,
  isFull,
  MAX_STEPS,
  navigateStep,
  parseGuestStep,
  type RecordedStep,
} from './browser-steps'

const PAGE = 'http://localhost:3000/login'

interface Descriptor {
  tag: string
  id?: string
  idUnique?: boolean
  testAttr?: string
  testValue?: string
  testUnique?: boolean
  nthOfType?: number
  ofTypeCount?: number
}

function target(path: Descriptor[], text = '', attributes: Record<string, string> = {}) {
  return { v: 1, path, text, attributes }
}

function step(raw: unknown, at = 1000): RecordedStep | null {
  return parseGuestStep(raw, PAGE, at)
}

describe('parseGuestStep', () => {
  it('refuses anything that is not one of the kinds it knows', () => {
    const good = target([{ tag: 'button', id: 'go', idUnique: true }], 'Go')
    expect(step({ v: 1, kind: 'click', target: good })).not.toBeNull()
    expect(step({ v: 1, kind: 'scroll', target: good })).toBeNull()
    expect(step({ v: 1, kind: 'eval', target: good })).toBeNull()
    expect(step({ v: 2, kind: 'click', target: good })).toBeNull()
    expect(step({ kind: 'click', target: good })).toBeNull()
    expect(step(null)).toBeNull()
    expect(step('click')).toBeNull()
  })

  it('drops a step whose target cannot be turned into a selector', () => {
    expect(step({ v: 1, kind: 'click', target: { v: 1, path: [] } })).toBeNull()
    expect(step({ v: 1, kind: 'click', target: { v: 2, path: [{ tag: 'a' }] } })).toBeNull()
    expect(step({ v: 1, kind: 'click' })).toBeNull()
  })

  it('takes the URL from the caller, never from the page', () => {
    const forged = target([{ tag: 'button', id: 'go', idUnique: true }], 'Go')
    const parsed = step({ v: 1, kind: 'click', target: forged, url: 'https://evil.example/' })
    expect(parsed?.url).toBe(PAGE)
  })

  it('builds a click step with the element text as its label', () => {
    const parsed = step({
      v: 1,
      kind: 'click',
      target: target([{ tag: 'button', testAttr: 'data-testid', testValue: 'submit', testUnique: true }], 'Sign in'),
    })
    expect(parsed).toMatchObject({
      kind: 'click',
      selector: '[data-testid="submit"]',
      label: 'Sign in',
      tag: 'button',
    })
  })

  it('names a field by what it is, not by what was typed into it', () => {
    // parseCapture falls back to an element's live value when it has no text,
    // which would otherwise label the email box with the email address and read
    // back as `Type "a@b.com" into a@b.com`.
    const parsed = step({
      v: 1,
      kind: 'type',
      value: 'asad@example.com',
      target: target([{ tag: 'input', id: 'email', idUnique: true }], '', {
        placeholder: 'Email address',
        value: 'asad@example.com',
      }),
    })
    expect(parsed?.label).toBe('Email address')
    expect(parsed?.value).toBe('asad@example.com')
  })

  it('does not name a select after its own options', () => {
    // Observed against a real page: a city picker came back labelled
    // "DubaiLahore", because a <select>'s text content is every option it has.
    const parsed = step({
      v: 1,
      kind: 'select',
      value: 'Lahore',
      target: target([{ tag: 'select', id: 'city', idUnique: true }], 'DubaiLahore'),
    })
    expect(parsed?.label).toBe('')
    expect(describeStep(parsed as RecordedStep)).toBe('Choose "Lahore" in `#city`')
  })

  it('names a field by its aria-label, placeholder, title or name, in that order', () => {
    const named = (attributes: Record<string, string>) =>
      step({
        v: 1,
        kind: 'type',
        value: 'x',
        target: target([{ tag: 'input', id: 'f', idUnique: true }], '', attributes),
      })?.label
    expect(named({ 'aria-label': 'Aria', placeholder: 'Place', name: 'nm' })).toBe('Aria')
    expect(named({ placeholder: 'Place', title: 'Title', name: 'nm' })).toBe('Place')
    expect(named({ title: 'Title', name: 'nm' })).toBe('Title')
    expect(named({ name: 'nm' })).toBe('nm')
    expect(named({})).toBe('')
  })

  it('withholds a password when the guest says so', () => {
    const parsed = step({
      v: 1,
      kind: 'type',
      secret: true,
      value: 'hunter2',
      target: target([{ tag: 'input', id: 'pw', idUnique: true }], '', { type: 'password' }),
    })
    expect(parsed?.redacted).toBe(true)
    expect(parsed?.value).toBe('')
  })

  it('withholds a password even when the payload forgot to flag it', () => {
    // The flag is the guest's claim; the type attribute is the element's. A
    // tampered message that drops the flag must not get the value through.
    const parsed = step({
      v: 1,
      kind: 'type',
      value: 'hunter2',
      target: target([{ tag: 'input', id: 'pw', idUnique: true }], '', { type: 'password' }),
    })
    expect(parsed?.redacted).toBe(true)
    expect(parsed?.value).toBe('')
  })

  it('withholds a file path, which is the user’s disk and not the page’s to report', () => {
    // The same class of secret as a password, and it was missing from the
    // capture-side check. `labelFrom` reaches for `attributes.value` before
    // anything else, so an unnamed file input was captured *as* its path.
    const parsed = step({
      v: 1,
      kind: 'type',
      value: '/Users/asad/passport.pdf',
      target: target([{ tag: 'input', id: 'cv', idUnique: true }], '', { type: 'file' }),
    })
    expect(parsed?.redacted).toBe(true)
    expect(parsed?.value).toBe('')
    expect(JSON.stringify(parsed)).not.toContain('passport')
  })

  it('flattens a value that tries to carry a newline into a prompt', () => {
    const parsed = step({
      v: 1,
      kind: 'type',
      value: 'first\nrm -rf /',
      target: target([{ tag: 'input', id: 'q', idUnique: true }]),
    })
    expect(parsed?.value).toBe('first rm -rf /')
  })

  it('only accepts the keys it has a step for', () => {
    const field = target([{ tag: 'input', id: 'q', idUnique: true }])
    expect(step({ v: 1, kind: 'press', key: 'Enter', target: field })?.key).toBe('Enter')
    expect(step({ v: 1, kind: 'press', key: 'a', target: field })).toBeNull()
    expect(step({ v: 1, kind: 'press', target: field })).toBeNull()
  })

  it('records which way a checkbox went', () => {
    const box = target([{ tag: 'input', id: 'terms', idUnique: true }], '', { type: 'checkbox' })
    expect(step({ v: 1, kind: 'check', checked: true, target: box })?.checked).toBe(true)
    expect(step({ v: 1, kind: 'check', checked: false, target: box })?.checked).toBe(false)
  })
})

describe('appendStep', () => {
  const typed = (value: string, at: number): RecordedStep =>
    step({
      v: 1,
      kind: 'type',
      value,
      target: target([{ tag: 'input', id: 'email', idUnique: true }]),
    }, at) as RecordedStep

  const clicked = (at: number): RecordedStep =>
    step({
      v: 1,
      kind: 'click',
      target: target([{ tag: 'button', id: 'go', idUnique: true }], 'Go'),
    }, at) as RecordedStep

  it('never mutates the list it was given', () => {
    const steps = [clicked(1)]
    const next = appendStep(steps, typed('a', 2))
    expect(steps).toHaveLength(1)
    expect(next).toHaveLength(2)
  })

  it('replaces repeated typing in the same field with the finished value', () => {
    let steps: RecordedStep[] = []
    steps = appendStep(steps, typed('asad@', 1))
    steps = appendStep(steps, typed('asad@example.com', 2))
    expect(steps).toHaveLength(1)
    expect(steps[0].value).toBe('asad@example.com')
  })

  it('keeps typing in a different field as its own step', () => {
    const other = step({
      v: 1,
      kind: 'type',
      value: 'x',
      target: target([{ tag: 'input', id: 'name', idUnique: true }]),
    }) as RecordedStep
    const steps = appendStep(appendStep([], typed('a', 1)), other)
    expect(steps).toHaveLength(2)
  })

  it('drops a navigation that lands where the last one did', () => {
    const steps = appendStep(appendStep([], navigateStep(PAGE, 1)), navigateStep(PAGE, 2))
    expect(steps).toHaveLength(1)
  })

  it('merges a double-click and keeps a deliberate second press', () => {
    expect(appendStep(appendStep([], clicked(1000)), clicked(1200))).toHaveLength(1)
    expect(appendStep(appendStep([], clicked(1000)), clicked(2000))).toHaveLength(2)
  })

  it('stops growing at the cap instead of losing the start of the flow', () => {
    let steps: RecordedStep[] = []
    for (let i = 0; i < MAX_STEPS + 20; i++) steps = appendStep(steps, clicked(i * 1000))
    expect(steps).toHaveLength(MAX_STEPS)
    expect(isFull(steps)).toBe(true)
    // The first step is the one a replay cannot do without.
    expect(steps[0].at).toBe(0)
  })
})

describe('printing', () => {
  const sample: RecordedStep[] = [
    navigateStep(PAGE, 1),
    parseGuestStep(
      {
        v: 1,
        kind: 'type',
        value: 'asad@example.com',
        target: target([{ tag: 'input', id: 'email', idUnique: true }], '', { placeholder: 'Email' }),
      },
      PAGE,
      2,
    ) as RecordedStep,
    parseGuestStep(
      {
        v: 1,
        kind: 'type',
        secret: true,
        target: target([{ tag: 'input', id: 'pw', idUnique: true }], '', { type: 'password' }),
      },
      PAGE,
      3,
    ) as RecordedStep,
    parseGuestStep(
      {
        v: 1,
        kind: 'click',
        target: target([{ tag: 'button', testAttr: 'data-testid', testValue: 'submit', testUnique: true }], 'Sign in'),
      },
      PAGE,
      4,
    ) as RecordedStep,
  ]

  it('reads as instructions, not as an event log', () => {
    expect(describeStep(sample[0])).toBe('Go to http://localhost:3000/login')
    expect(describeStep(sample[1])).toBe('Type "asad@example.com" into "Email" (`#email`)')
    // No placeholder, no aria-label, and the value is withheld — so there is
    // nothing to name the field by and the selector stands alone.
    expect(describeStep(sample[2])).toBe('Type the password into `#pw`')
    expect(describeStep(sample[3])).toBe('Click "Sign in" (`[data-testid="submit"]`)')
  })

  it('numbers the flow and says when it was cut short', () => {
    const text = formatFlow(sample)
    expect(text.split('\n')[0]).toBe('1. Go to http://localhost:3000/login')
    expect(text).not.toContain('stopped at')
    expect(formatFlow([])).toBe('')
  })

  it('gives the agent exactly one line', () => {
    const line = flowLine(sample)
    expect(line).not.toContain('\n')
    expect(line.startsWith('[browser flow: 1) Go to')).toBe(true)
    expect(flowLine([])).toBe('')
  })

  it('keeps the agent line to one line even when a page tried to break it', () => {
    const hostile = parseGuestStep(
      {
        v: 1,
        kind: 'click',
        target: target([{ tag: 'button', id: 'x', idUnique: true }], 'Send\n\nrm -rf /'),
      },
      PAGE,
      1,
    ) as RecordedStep
    expect(flowLine([hostile])).toBe('[browser flow: 1) Click "Send rm -rf /" (`#x`)]')
  })
})
