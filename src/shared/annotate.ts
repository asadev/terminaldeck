/**
 * Annotate: point at things on a frozen picture, say what is wrong with each,
 * and hand all of it to an agent in one message.
 *
 * ## One Annotate, two places
 *
 * Asad, 2026-10-02: *"we have inspect mode — we will not call it inspect
 * anymore, we will call it Annotate, just like other AIs… And we will do it for
 * apps as well, for simulators as well."* So the browser's old Inspect and the
 * new phone and simulator screens share this file, the window's
 * `annotate/AnnotateSurface.tsx`, and the one message below. The only thing that
 * differs between the two is how an element is *found* under a click — the
 * page's DOM in the browser, the accessibility tree on a device — and that is a
 * function handed in, not a second mode.
 *
 * ## What an agent gets
 *
 * One line, because it is typed into a terminal where a newline submits the
 * prompt. In order: where this is (which device and app, or which address), the
 * picture with the numbered markers drawn on it — by the path the chosen
 * session's own machine knows it by — and then each note with the element it is
 * about. An element is named the way a person would say it, followed by what
 * finds it again in code: an accessibility identifier, a test id, a CSS
 * selector, and the component and source file when the app exposes them. A
 * position is always given as well, as percentages of the picture, so a note
 * on an element with no name at all still says *where*.
 *
 * Shared between the window and the main process: the window composes the
 * message, and the main process describes the last round to a model that asks
 * for it through `devices.annotations`. One function, so the two cannot drift.
 */

import type { NormRect, SourceLocation } from './device-tree'

/** Where a round of annotations was made. */
export interface AnnotateWhere {
  kind: 'device' | 'browser'
  /** What sort of screen: "iOS Simulator", "Android emulator", "Android phone", "browser page". */
  place: string
  /** The device's own name, or the page's title. May be empty. */
  name: string
  /** The device engine's id for it, `ios:<udid>` or `android:<serial>`. Devices only. */
  deviceId?: string
  /** The app in front: an iOS bundle id or an Android package. */
  app?: string
  /** A React Native route or an Android activity, when the app said which. */
  screen?: string
  /** The page's address. Browser only, and always the main process's copy. */
  url?: string
}

/** What finds an element again — in words for a person and in handles for code. */
export interface AnnotatedElement {
  /** A plain role (`button`) on a device, a tag (`<button>`) in the browser. */
  role?: string
  /** What it says, or what it is called for accessibility. */
  name?: string
  /** An accessibility identifier, a test id, or a DOM id. */
  identifier?: string
  /** Browser only: a CSS selector that finds exactly this element. */
  selector?: string
  /** React Native only. */
  component?: string
  componentPath?: string[]
  source?: SourceLocation
}

export interface Annotation {
  id: string
  /** The number on the marker, from 1. Renumbered when one is deleted. */
  n: number
  /** Normalised to the frozen picture: 0..1 both ways. */
  rect: NormRect
  /** Null for a point on blank space, which is still a place worth a note. */
  element: AnnotatedElement | null
  note: string
}

/** One frozen picture and everything pointed at on it. */
export interface AnnotationRound {
  id: string
  createdAt: number
  where: AnnotateWhere
  /** The picture's size in pixels. */
  frame: { width: number; height: number }
  annotations: Annotation[]
  /** Set once the marked picture has been written to disk. */
  picture?: { path: string; width: number; height: number }
  /** Set once it has been handed to a session. */
  sentTo?: { sessionId: string; label: string; at: number }
}

/* ------------------------------------------------------------- editing -- */

/** Add one, numbered after the last. */
export function addAnnotation(
  list: readonly Annotation[],
  entry: Omit<Annotation, 'n'>,
): Annotation[] {
  return [...list, { ...entry, n: list.length + 1 }]
}

/** Change one note; nothing else about it moves. */
export function editNote(list: readonly Annotation[], id: string, note: string): Annotation[] {
  return list.map((entry) => (entry.id === id ? { ...entry, note } : entry))
}

/**
 * Remove one and close the gap.
 *
 * Renumbered, because the markers on the picture are the numbers in the
 * message: a deleted #2 that left #1 and #3 behind would send an agent looking
 * for a second marker that is not drawn anywhere.
 */
export function removeAnnotation(list: readonly Annotation[], id: string): Annotation[] {
  return list.filter((entry) => entry.id !== id).map((entry, index) => ({ ...entry, n: index + 1 }))
}

/** Annotations with something to say. An empty note is a marker nobody finished. */
export function written(list: readonly Annotation[]): Annotation[] {
  return list.filter((entry) => entry.note.trim() !== '')
}

/* ------------------------------------------------------------ the words -- */

/**
 * Flatten for a terminal: no controls, no line breaks, one space between words.
 *
 * The same rule as `oneLine` in the browser's `capture-text.ts`, restated here
 * because this file is shared with the main process and that one is not. An
 * ESC in a note would repaint the terminal it lands in; a newline would submit
 * half the message.
 */
export function flat(value: string): string {
  let out = ''
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0
    const control = code < 0x20 || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029
    out += control ? ' ' : char
  }
  return out.replace(/\s+/g, ' ').trim()
}

/** Longest a name or identifier is quoted at. The agent can always look closer. */
const MAX_QUOTED = 120

function clip(value: string, max = MAX_QUOTED): string {
  const one = flat(value)
  return one.length > max ? `${one.slice(0, max - 1)}…` : one
}

function percent(value: number): string {
  return `${Math.round(Math.min(Math.max(value, 0), 1) * 100)}%`
}

/** `button "Save" (id save-button, src/Home.tsx:42)` — or just the role, or nothing. */
export function describeElement(element: AnnotatedElement | null): string {
  if (element === null) return 'blank space'
  const head = [element.role ? clip(element.role, 40) : '', element.name ? `"${clip(element.name)}"` : '']
    .filter(Boolean)
    .join(' ')
  const handles: string[] = []
  if (element.identifier) handles.push(`id ${clip(element.identifier)}`)
  if (element.selector) handles.push(`selector ${clip(element.selector, 200)}`)
  if (element.component) handles.push(`component ${clip(element.component, 80)}`)
  if (element.source) {
    const { file, line, column } = element.source
    handles.push(`source ${clip(file, 200)}${line ? `:${line}` : ''}${line && column ? `:${column}` : ''}`)
  }
  const named = head || 'element'
  return handles.length > 0 ? `${named} (${handles.join(', ')})` : named
}

/** `the iOS Simulator "iPhone 17 Pro", app com.example.Shop, screen Checkout` */
export function describeWhere(where: AnnotateWhere): string {
  const parts: string[] = []
  if (where.kind === 'browser') {
    parts.push(where.url ? `the page ${clip(where.url, 300)}` : 'a browser page')
    if (where.name) parts.push(`titled "${clip(where.name)}"`)
    return parts.join(' ')
  }
  parts.push(`the ${clip(where.place, 40)}${where.name ? ` "${clip(where.name, 60)}"` : ''}`)
  if (where.app) parts.push(`app ${clip(where.app, 120)}`)
  if (where.screen) parts.push(`screen ${clip(where.screen, 120)}`)
  return parts.join(', ')
}

/**
 * The exact message a session receives.
 *
 * `picturePath` is the path the *session's* machine knows the marked picture by
 * — `session-transfer.ts` decides that at the moment of the press — and is empty
 * only when nothing could be written, in which case the message says so rather
 * than naming a file that does not exist. `instruction` is whatever the person
 * typed in the send box; it leads, because it is the sentence they chose to say
 * first.
 */
export function composeHandoff(round: AnnotationRound, picturePath: string, instruction = ''): string {
  const notes = written(round.annotations)
  const count = `${notes.length} note${notes.length === 1 ? '' : 's'}`
  const size = `${round.frame.width} x ${round.frame.height}`
  const picture = picturePath
    ? `picture with the numbered markers: ${picturePath} (${size})`
    : 'the picture could not be saved'
  const head = `[Annotate: ${count} on ${describeWhere(round.where)}; ${picture}]`
  const body = notes.map((entry) => {
    const { x, y, width, height } = entry.rect
    const at = `at ${percent(x)} across, ${percent(y)} down, ${percent(width)} x ${percent(height)}`
    return `#${entry.n} ${describeElement(entry.element)} ${at}: ${flat(entry.note)}`
  })
  const lead = flat(instruction)
  return [lead, head, ...body].filter(Boolean).join(' ')
}

/**
 * The same round as plain data for a model that asked for it.
 *
 * Structured rather than the sentence above, because a tool's caller can read
 * fields and should not have to parse prose. Unwritten markers are left out for
 * the same reason they are left out of the message.
 */
export function roundForTools(round: AnnotationRound): Record<string, unknown> {
  return {
    id: round.id,
    createdAt: new Date(round.createdAt).toISOString(),
    where: round.where,
    picture: round.picture ?? null,
    sentTo: round.sentTo ? { session: round.sentTo.label, at: new Date(round.sentTo.at).toISOString() } : null,
    annotations: written(round.annotations).map((entry) => ({
      n: entry.n,
      note: flat(entry.note),
      element: entry.element,
      described: describeElement(entry.element),
      rect: entry.rect,
    })),
  }
}
