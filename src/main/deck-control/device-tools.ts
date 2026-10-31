import { roundForTools, type AnnotationRound } from '../../shared/annotate'
import { centreOf, findNodes, nodeName, plainRole, type DeviceNode, type FindQuery } from '../../shared/device-tree'
import { stateWords, type DeviceEntry } from '../devices/inventory'
import type { DeviceDetails, Orientation, TreeAnswer } from '../devices/session'
import { refuseAPathOnTheWrongComputer } from './browser-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { emptySummary, withEmptiness } from './empty-result'
import { Refused } from './surface'

/**
 * The `devices.*` tools: phones and simulators, driven from outside the window.
 *
 * ## What this is for
 *
 * Asad, for this release: *"Everything that I can do manually should be able to
 * do through the MCP."* The Simulators page lets a person list devices, start
 * one, look at its screen, tap, swipe, type, press its buttons, turn it, and
 * annotate what is wrong. A copilot in another application can now do every one
 * of those through here, and read back what a person annotated — which is the
 * half that matters most, because Annotate exists so a person can point at a
 * screen and an agent can act on exactly what they pointed at.
 *
 * ## Why every call goes through `DeviceManager`, and never past it
 *
 * The page and these tools are two callers of one object. `manager.ts` says so
 * in its own header and this file keeps it true: {@link DeviceToolDeps} is a
 * list of plain functions that `devices/tool-deps.ts` closes over the same
 * manager the `devices:*` channels use. There is no second engine client, no
 * second idea of which device is open, and no second idle timer — a model
 * driving a simulator nobody put on screen keeps it open exactly as a window
 * watching it would. The deps are an interface rather than an import so the
 * whole surface is driven from a test with no engine and no Electron, the shape
 * `workerTools(deps)` and `browserTools(drive)` already use.
 *
 * ## Coordinates
 *
 * Fractions of the screen, 0..1 both ways, whichever way up the device is. That
 * is the engine's own unit (`session.ts`), the unit a tree node's frame comes in
 * (`device-tree.ts`), and therefore the unit a model can carry from a
 * `devices.tree` answer straight into a `devices.tap` without a conversion it
 * could get wrong. A value outside 0..1 is **refused rather than clamped**,
 * unlike the page's channel: the page sends a mouse position that is a fraction
 * by construction, whereas a model sending `x: 540` has sent pixels, and
 * clamping that to the right-hand edge would tap something it never meant.
 *
 * ## Finding an element, once
 *
 * `devices.tap` and `devices.find` resolve a name with `findNodes` from
 * `shared/device-tree.ts` — the function Annotate uses in the window — so the
 * element a model taps by name is the element the same words would have found
 * on the Simulators page. A tap by name that matches nothing, or several
 * different things, **taps nothing** and says what it did find: a tap is an
 * effect on a real screen, and the wrong button pressed confidently is worse
 * than a turn spent choosing.
 *
 * ## When the engine cannot run here
 *
 * The engine is Apple-silicon-only (`engine.ts`). On any other computer every
 * tool that needs it refuses, in its precheck, with the engine's own sentence —
 * before a budget is spent and before anything is attempted — so a model learns
 * on its first call that this is a fact about the computer and not a fault to
 * retry. Two tools answer instead of refusing, on purpose:
 *
 *  - `devices.list` answers *empty, and here is why*. It is the first reach, and
 *    a refusal there reads as "the tool is broken"; an empty list with the
 *    reason on it reads as what it is.
 *  - `devices.annotations` does not need the engine at all. The store holds
 *    browser-page rounds as well as device ones, and a browser round made on an
 *    Intel Mac is still a round a person made and an agent should be able to
 *    read.
 *
 * ## The log
 *
 * Typed text is logged as its length and nothing else — `redactArgs`, the same
 * `[N characters]` shape `browser.step` writes — because the field with focus
 * may be a password, and the row has to stay readable as a record that
 * something was typed without being a copy of it.
 */

/* --------------------------------------------------------------- the deps -- */

/**
 * Everything these tools need, as plain functions.
 *
 * `devices/tool-deps.ts` builds one from the running `DeviceManager`; a test
 * builds one from fakes. This file never imports the manager, so nothing here
 * can reach an engine except through what it was handed.
 */
export interface DeviceToolDeps {
  /** Null when this computer can run the engine, otherwise the plain sentence why not. */
  unavailable(): string | null
  list(): Promise<DeviceEntry[]>
  boot(id: string): Promise<{ ok: true; id: string } | { ok: false; message: string }>
  shutDown(id: string): Promise<{ ok: true } | { ok: false; message: string }>
  /** Open the device — or find it already open — and answer its details. */
  open(id: string): Promise<DeviceDetails>
  screenshot(id: string): Promise<{ path: string; width: number; height: number }>
  tap(id: string, x: number, y: number, holdMs?: number): Promise<void>
  swipe(id: string, from: { x: number; y: number }, to: { x: number; y: number }, durationMs?: number): Promise<void>
  type(id: string, text: string): Promise<void>
  key(id: string, key: string, modifiers?: string[]): Promise<void>
  button(id: string, button: string): Promise<void>
  rotate(id: string, to?: Orientation): Promise<Orientation>
  tree(id: string, scope?: TreeScope): Promise<TreeAnswer>
  /** Annotation rounds, newest first. */
  rounds(): AnnotationRound[]
}

export type TreeScope = 'interactive' | 'visible' | 'full'

/* ------------------------------------------------------------ the bounds -- */

/*
 * The vocabulary of `devices/ipc.ts`, restated rather than imported.
 *
 * That file imports Electron at its top, so importing it here would make this
 * whole surface untestable without an app — the one property the deps
 * interface exists to buy. `device-tools.test.ts` reads `ipc.ts` as text and
 * fails if any of these drifts from it, so the page and the tools cannot come
 * to disagree about what a device id looks like or which keys exist.
 */

/** Exactly `ipc.ts`'s `ID`. An id ends up as an argument to `xcrun` and `adb`. */
export const DEVICE_ID = /^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$/

export const DEVICE_BUTTONS = ['home', 'back', 'overview', 'lock', 'volume-up', 'volume-down', 'action'] as const

export const DEVICE_KEYS = [
  'delete',
  'return',
  'enter',
  'tab',
  'escape',
  'arrow-up',
  'arrow-down',
  'arrow-left',
  'arrow-right',
  'select-all',
] as const

export const DEVICE_MODIFIERS = ['command', 'shift', 'option', 'control'] as const

export const ORIENTATIONS: readonly Orientation[] = [
  'portrait',
  'landscape-left',
  'landscape-right',
  'portrait-upside-down',
]

/** `ipc.ts` refuses more than this on `devices:type`. The same ceiling, so neither path can do more. */
export const MAX_TYPE_CHARS = 2_000

/** `ipc.ts` caps a hold here. */
export const MAX_HOLD_MS = 5_000

/** `session.ts` turns a tap into a long press from this hold upwards. Stated so the description can say it. */
export const LONG_PRESS_MS = 400

/** `ipc.ts`'s swipe bounds and default. */
const MIN_SWIPE_MS = 50
const MAX_SWIPE_MS = 5_000
const DEFAULT_SWIPE_MS = 300

/**
 * How many elements a tree answer lists.
 *
 * The engine reads up to 1,500 nodes, and a busy screen's list at that length is
 * forty thousand tokens a model pays for to find one button. A hundred and fifty
 * named elements is more than any phone screen shows at once; `limit` raises it
 * for the screen that genuinely has more, and `truncated` always says when the
 * answer is not the whole of it.
 */
export const DEFAULT_TREE_NODES = 150
export const MAX_TREE_NODES = 400

/** Matches `devices.find` hands back. A query matching more than this wants narrowing, not reading. */
export const MAX_FIND_MATCHES = 20

/** Candidates a refused tap names. Enough to choose from, few enough to read. */
export const MAX_CANDIDATES = 5

export const MAX_ROUNDS = 10

/** Longest a name or value is quoted at. `devices.find` can always look closer. */
const MAX_QUOTED = 200

/**
 * Two matches this close are one place on the glass.
 *
 * A button and the text inside it both answer to "Save", and their centres are
 * the same point to within a rounding error. Tapping either is the same tap, so
 * refusing the call as "ambiguous" would be refusing over a difference that does
 * not exist on the screen. Half a percent is well under a fingertip on any
 * device and well over the float noise between a frame and its child's.
 */
const SAME_PLACE = 0.005

/* ---------------------------------------------------------- the arguments -- */

function shown(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value.length > 60 ? `${value.slice(0, 60)}…` : value)
  return String(value)
}

function deviceIdOf(args: Record<string, unknown>): string {
  const value = args.deviceId
  if (typeof value !== 'string' || !DEVICE_ID.test(value)) {
    throw new Refused(
      'not-permitted',
      `deviceId ${shown(value)} is not a device this app listed. Call devices.list first and pass one of its ids ` +
        '(they look like ios:…, android:… or avd:…).',
    )
  }
  return value
}

/**
 * Refuse before anything else when this computer cannot run the engine.
 *
 * In the precheck rather than the handler for the reason `catalogue.ts` gives
 * for prechecks at all: a call that could never have happened must not consume
 * a change budget, and must not read as a fault worth another try.
 */
function requireEngine(deps: DeviceToolDeps, tool: string): void {
  const reason = deps.unavailable()
  if (reason === null) return
  throw new Refused(
    'not-permitted',
    `${reason} ${tool} cannot work on this computer, and nothing else here drives a phone or a simulator — ` +
      'do not retry. Say what you would have done instead.',
  )
}

function optText(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

/**
 * One coordinate, as a fraction of the screen.
 *
 * Refused outside 0..1 rather than clamped — see the header. The sentence names
 * the likely mistake, because a model that sent pixels needs to be told they
 * were pixels, not merely that the number was wrong.
 */
function fraction(where: string, value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${where} must be a number from 0 to 1`)
  }
  if (value < 0 || value > 1) {
    throw new Refused(
      'not-permitted',
      `${where} is ${value}, and positions are fractions of the screen from 0 to 1 — 0.5 is the middle.` +
        (value > 1
          ? ' That looks like pixels: divide by the screen’s width or height, or take a centre from devices.tree.'
          : ''),
    )
  }
  return value
}

function pointOf(where: string, raw: unknown): { x: number; y: number } {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new Refused('not-permitted', `${where} must be an object like {"x": 0.5, "y": 0.5}`)
  }
  const point = raw as Record<string, unknown>
  const strangers = Object.keys(point).filter((key) => key !== 'x' && key !== 'y')
  if (strangers.length > 0) {
    throw new Refused('not-permitted', `${where} takes only x and y, not ${strangers.join(', ')}`)
  }
  return { x: fraction(`${where}.x`, point.x), y: fraction(`${where}.y`, point.y) }
}

function percent(value: number): string {
  return `${Math.round(value * 100)}%`
}

function idWords(args: Record<string, unknown>): string {
  return typeof args.deviceId === 'string' ? args.deviceId : 'a device'
}

/* --------------------------------------------------------- the elements -- */

/**
 * One element, as a tool result.
 *
 * No `ref`: it is valid for the snapshot it came from only (`device-tree.ts`),
 * and a model that kept one would be holding a handle that silently points at
 * nothing by its next call. A name, an identifier and a centre are what survive
 * a re-read, so they are what is handed out.
 *
 * Compact on purpose — a field is written only when it says something. That is
 * why `enabled` appears only as `enabled: false`: nearly every element on a
 * screen is enabled, and a hundred and fifty `"enabled": true` are a few
 * thousand characters that tell a model nothing it would act on, whereas the
 * one greyed-out button is the one it must not keep tapping.
 */
export interface ElementView {
  depth?: number
  role?: string
  name?: string
  identifier?: string
  value?: string
  /** A password field. Its value is never read, here or anywhere else. */
  secret?: true
  enabled?: false
  focused?: true
  frame?: { x: number; y: number; width: number; height: number }
  /** Exactly what `devices.tap` takes. Absent when the element is off the screen. */
  centre?: { x: number; y: number }
  /** Its centre is outside the screen — scrolled away. Swipe to it before tapping. */
  offScreen?: true
  component?: string
  /** `src/Home.tsx:42:7` — React Native in development only. */
  source?: string
}

function round3(value: number): number {
  return Math.round(value * 1000) / 1000
}

function clip(value: string): string {
  const one = value.replace(/\s+/g, ' ').trim()
  return one.length > MAX_QUOTED ? `${one.slice(0, MAX_QUOTED - 1)}…` : one
}

export function elementView(node: DeviceNode): ElementView {
  const out: ElementView = {}
  const role = plainRole(node.role)
  if (role !== '') out.role = role
  const identifier = node.identifier || node.testID || ''
  const name = clip(nodeName(node))
  // `nodeName` falls back to the identifier when a node has no words of its
  // own; writing the same string twice would only make the row longer.
  if (name !== '' && name !== identifier) out.name = name
  if (identifier !== '') out.identifier = clip(identifier)
  if (node.valueRedacted === true) {
    out.secret = true
  } else if (node.value !== undefined && node.value !== '') {
    const value = clip(node.value)
    // A static text's value is usually its label again.
    if (value !== name) out.value = value
  }
  if (node.enabled === false) out.enabled = false
  if (node.focused === true) out.focused = true
  const rect = node.frame?.normalized
  if (rect && rect.width > 0 && rect.height > 0) {
    out.frame = { x: round3(rect.x), y: round3(rect.y), width: round3(rect.width), height: round3(rect.height) }
    /*
     * A centre only when it is on the screen. `centreOf` clamps to the edge —
     * right for the page, which only ever asks about what it is showing — and
     * an element scrolled a screen away would be handed a centre on the bottom
     * edge that a model would then tap. `offScreen` says it exists and where
     * its frame is, and that reaching it is a swipe first.
     */
    if (onScreen(node)) {
      const centre = centreOf(node) as { x: number; y: number }
      out.centre = { x: round3(centre.x), y: round3(centre.y) }
    } else {
      out.offScreen = true
    }
  }
  if (node.component) out.component = node.component
  if (node.sourceLocation) {
    const { file, line, column } = node.sourceLocation
    out.source = `${file}${line ? `:${line}` : ''}${line && column ? `:${column}` : ''}`
  }
  return out
}

/**
 * Roles that are scaffolding, in `plainRole`'s words.
 *
 * The same idea as `SCAFFOLD` in `device-tree.ts` — the application, its
 * window, the anonymous groups and layouts between them — asked a different
 * question. There it decides which element a point *means*; here it decides
 * which unnamed elements are worth a row. An unnamed button is worth one (an
 * icon with no label is exactly what a model needs a centre for); an unnamed
 * group is the space between buttons.
 */
const SCAFFOLD_WORDS = new Set([
  '',
  'application',
  'window',
  'group',
  'unknown',
  'other',
  'scroll area',
  'layout area',
  'frame layout',
  'linear layout',
  'relative layout',
  'constraint layout',
  'view',
  'view group',
])

function named(node: DeviceNode): boolean {
  return Boolean(
    node.label || node.title || node.text || node.identifier || node.testID || node.placeholder || node.value,
  )
}

function worthARow(node: DeviceNode): boolean {
  return named(node) || !SCAFFOLD_WORDS.has(plainRole(node.role))
}

/**
 * The tree as a list, in reading order, with a depth on each row.
 *
 * A list rather than the nested tree, and the choice is about what reads it. A
 * model looking for one button scans names; nested JSON makes it walk brackets
 * to do that and pays for every level of them, while a list with `depth` keeps
 * the structure for the turn that wants it — a row at depth 3 under a row at
 * depth 2 is inside it — at the cost of one small number. Depth counts only the
 * rows that are listed, so skipping the anonymous groups between a cell and its
 * table does not leave gaps a reader has to explain.
 *
 * Hidden elements are left out with everything under them: a hidden parent's
 * children are not on the screen either, whatever their own flags say.
 */
function listElements(root: DeviceNode, limit: number): { rows: ElementView[]; total: number } {
  const rows: ElementView[] = []
  let total = 0
  const visit = (node: DeviceNode, depth: number, level: number): void => {
    // The same bound `flatten` keeps: this tree arrived from another process.
    if (level > 200 || node.hidden === true) return
    const listed = worthARow(node)
    if (listed) {
      total += 1
      if (rows.length < limit) rows.push({ depth, ...elementView(node) })
    }
    for (const child of node.children ?? []) visit(child, listed ? depth + 1 : depth, level + 1)
  }
  visit(root, 0, 0)
  return { rows, total }
}

function sourceOf(tree: TreeAnswer['tree']): 'react-native-fiber' | 'accessibility' {
  return tree.source === 'react-native-fiber' ? 'react-native-fiber' : 'accessibility'
}

/* ----------------------------------------------------------- the selector -- */

/** What `findNodes` takes. One name for it here, because a tap and a find both carry one. */
type Selector = FindQuery

/** The selector half of a tap or a find, or null when none was given. */
function selectorOf(args: Record<string, unknown>): Selector | null {
  const name = optText(args, 'name')
  const identifier = optText(args, 'identifier')
  const role = optText(args, 'role')
  const partial = args.partial === true
  if (name === null && identifier === null && role === null) {
    if (args.partial !== undefined) throw new Refused('not-permitted', 'partial goes with a name')
    return null
  }
  return {
    ...(name === null ? {} : { name }),
    ...(identifier === null ? {} : { identifier }),
    ...(role === null ? {} : { role }),
    ...(partial ? { partial: true } : {}),
  }
}

/** `button "Save"`, `element containing "sav"`, `text field with identifier email`. */
function selectorWords(selector: Selector): string {
  const parts: string[] = [selector.role ? clip(selector.role).slice(0, 40) : 'element']
  if (selector.name) parts.push(`${selector.partial ? 'containing ' : ''}"${clip(selector.name).slice(0, 60)}"`)
  if (selector.identifier) parts.push(`with identifier ${clip(selector.identifier).slice(0, 60)}`)
  return parts.join(' ')
}

/**
 * The tree with every hidden element taken out, and everything inside one.
 *
 * `findNodes` walks every node, and a hidden sheet's buttons are not marked
 * hidden themselves — the sheet is. Searching the pruned copy is what keeps a
 * tap by name from pressing a button the person cannot see, and keeps
 * `devices.find` from offering one. The same bound `flatten` keeps, because
 * this tree arrived from another process.
 */
function shownOnly(node: DeviceNode, level = 0): DeviceNode | null {
  if (level > 200 || node.hidden === true) return null
  const children = (node.children ?? [])
    .map((child) => shownOnly(child, level + 1))
    .filter((child): child is DeviceNode => child !== null)
  const copy: DeviceNode = { ...node }
  delete copy.children
  if (children.length > 0) copy.children = children
  return copy
}

/** Nodes matching a selector, among only what is shown. */
function findShown(root: DeviceNode, selector: Selector): DeviceNode[] {
  const shown = shownOnly(root)
  return shown === null ? [] : findNodes(shown, selector)
}

/** A match a finger can land on: shown, with a frame, and its centre on the screen. */
function onScreen(node: DeviceNode): boolean {
  const rect = node.frame?.normalized
  if (node.hidden === true || !rect || rect.width <= 0 || rect.height <= 0) return false
  const x = rect.x + rect.width / 2
  const y = rect.y + rect.height / 2
  return x >= 0 && x <= 1 && y >= 0 && y <= 1
}

/** Collapse matches that are one place on the glass. See {@link SAME_PLACE}. */
function distinctPlaces(nodes: DeviceNode[]): DeviceNode[] {
  const kept: DeviceNode[] = []
  for (const node of nodes) {
    const centre = centreOf(node)
    if (centre === null) continue
    const same = kept.some((other) => {
      const there = centreOf(other)
      return there !== null && Math.abs(there.x - centre.x) <= SAME_PLACE && Math.abs(there.y - centre.y) <= SAME_PLACE
    })
    // Reading order puts the container first, which is the better thing to
    // name: "button Save" rather than the text inside it.
    if (!same) kept.push(node)
  }
  return kept
}

function candidateLine(node: DeviceNode): string {
  const view = elementView(node)
  const head = [view.role ?? 'element', view.name ? `"${view.name.slice(0, 60)}"` : ''].filter(Boolean).join(' ')
  const id = view.identifier ? ` (identifier ${view.identifier.slice(0, 60)})` : ''
  const at = view.centre ? ` at x ${view.centre.x}, y ${view.centre.y}` : ' with no position on the screen'
  return `${head}${id}${at}`
}

/**
 * The one element a tap by name means, or a refusal naming what there was.
 *
 * Exactly one distinct place, or nothing is tapped. The refusal lists up to
 * {@link MAX_CANDIDATES} things with their centres, so the next call can be the
 * right one — a tap by centre, or the same tap with an identifier added —
 * rather than a second guess at the spelling.
 */
function resolveOne(root: DeviceNode, selector: Selector): DeviceNode {
  const all = findNodes(root, selector)
  const places = distinctPlaces(findShown(root, selector).filter(onScreen))
  if (places.length === 1) return places[0]
  const wanted = selectorWords(selector)
  if (places.length > 1) {
    throw new Refused(
      'not-permitted',
      `${places.length} different elements on the screen match the ${wanted}: ` +
        `${places.slice(0, MAX_CANDIDATES).map(candidateLine).join('; ')}. ` +
        'Nothing was tapped. Add an identifier or a role to pick one, or tap its centre with x and y.',
    )
  }
  if (all.length > 0) {
    throw new Refused(
      'not-permitted',
      `The ${wanted} is in the screen’s tree but not somewhere a finger can reach — it is hidden or scrolled ` +
        'away. Nothing was tapped. Scroll with devices.swipe and try again.',
    )
  }
  // Nothing by that name. A near miss is the usual cause, so say what is close.
  const near =
    selector.name !== undefined && selector.partial !== true
      ? distinctPlaces(findShown(root, { ...selector, partial: true }).filter(onScreen))
      : []
  throw new Refused(
    'not-permitted',
    `Nothing on the screen matches the ${wanted}. Nothing was tapped. ` +
      (near.length > 0
        ? `Close: ${near.slice(0, MAX_CANDIDATES).map(candidateLine).join('; ')}.`
        : 'Names are matched whole and ignoring case; call devices.tree to see what is there.'),
  )
}

/* ------------------------------------------------------------- the screen -- */

/**
 * Refuse a picture to a caller on another computer — with advice that fits.
 *
 * The decision is `browser-tools.ts`'s, called rather than restated, so the two
 * picture tools can never disagree about who is "on the wrong computer". The
 * sentence is not, because its advice is about a browser — *"Use browser.read"*
 * — and a model told that about a phone would go and read a web page. The
 * shape is kept so the two refusals read as the same rule.
 */
function refuseAPictureOnTheWrongComputer(context: ToolContext): void {
  try {
    refuseAPathOnTheWrongComputer(context, 'devices.screenshot')
  } catch (error) {
    if (!(error instanceof Refused)) throw error
    throw new Refused(
      error.reason,
      'devices.screenshot writes the picture on the computer the device is attached to, so the path it ' +
        'answers with is not a file you can open. Use devices.tree: the element list is what tells you what ' +
        'to tap, and a picture is not.',
    )
  }
}

/* ------------------------------------------------------------- the schemas -- */

const DEVICE_ID_PROPERTY: JsonSchema = {
  type: 'string',
  description: 'The device’s id from devices.list, such as ios:… or android:….',
}

const ONLY_DEVICE: JsonSchema = {
  type: 'object',
  properties: { deviceId: DEVICE_ID_PROPERTY },
  required: ['deviceId'],
  additionalProperties: false,
}

const SELECTOR_PROPERTIES: Record<string, JsonSchema> = {
  name: {
    type: 'string',
    description: 'What the element says or is labelled, matched whole and ignoring case unless partial is true.',
  },
  identifier: { type: 'string', description: 'Its accessibility identifier or test id.' },
  role: { type: 'string', description: 'Plain words such as button or text field, or the platform’s own role.' },
  partial: { type: 'boolean', description: 'Match name anywhere inside the element’s text.' },
}

const POINT: JsonSchema = {
  type: 'object',
  description: 'A point as fractions of the screen: {"x": 0..1 from the left, "y": 0..1 from the top}.',
  properties: { x: { type: 'number' }, y: { type: 'number' } },
}

const TAP_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    x: { type: 'number', description: 'Across, from 0 (left edge) to 1 (right edge).' },
    y: { type: 'number', description: 'Down, from 0 (top edge) to 1 (bottom edge).' },
    ...SELECTOR_PROPERTIES,
    holdMs: {
      type: 'number',
      description: `Hold this long. ${LONG_PRESS_MS} or more is a long press; at most ${MAX_HOLD_MS}.`,
    },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const DIRECTIONS = ['up', 'down', 'left', 'right'] as const
type Direction = (typeof DIRECTIONS)[number]

const SWIPE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    from: POINT,
    to: POINT,
    durationMs: {
      type: 'number',
      description: `How long the finger takes, ${MIN_SWIPE_MS} to ${MAX_SWIPE_MS}. Default ${DEFAULT_SWIPE_MS}.`,
    },
    direction: {
      type: 'string',
      enum: [...DIRECTIONS],
      description: 'Instead of from and to: the way the finger travels. up shows what is further down a list.',
    },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const TYPE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    text: { type: 'string', description: `Typed into the focused field. Up to ${MAX_TYPE_CHARS} characters.` },
    key: { type: 'string', enum: [...DEVICE_KEYS], description: 'A key pressed after the text, if any.' },
    modifiers: {
      type: 'array',
      items: { type: 'string', enum: [...DEVICE_MODIFIERS] },
      description: 'Held while key is pressed.',
    },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const BUTTON_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    button: { type: 'string', enum: [...DEVICE_BUTTONS] },
    rotate: { type: 'string', enum: [...ORIENTATIONS], description: 'Turn the device to this orientation.' },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const SCOPES: readonly TreeScope[] = ['interactive', 'visible', 'full']

const TREE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    scope: {
      type: 'string',
      enum: [...SCOPES],
      description: 'interactive: only what can be acted on. visible (default): what is on screen. full: also what is scrolled away.',
    },
    limit: {
      type: 'integer',
      description: `Most elements listed. Default ${DEFAULT_TREE_NODES}, at most ${MAX_TREE_NODES}.`,
    },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const FIND_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    deviceId: DEVICE_ID_PROPERTY,
    ...SELECTOR_PROPERTIES,
    scope: { type: 'string', enum: [...SCOPES], description: 'As in devices.tree. Default visible.' },
  },
  required: ['deviceId'],
  additionalProperties: false,
}

const ANNOTATION_KINDS = ['device', 'browser'] as const

const ANNOTATIONS_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    count: { type: 'integer', description: `How many rounds, newest first. Default 1, at most ${MAX_ROUNDS}.` },
    kind: {
      type: 'string',
      enum: [...ANNOTATION_KINDS],
      description: 'Only rounds made on a device screen, or only on a browser page.',
    },
  },
  additionalProperties: false,
}

const NO_ARGS: JsonSchema = { type: 'object', properties: {}, additionalProperties: false }

/* -------------------------------------------------------- argument shapes -- */

type TapTarget = { kind: 'point'; x: number; y: number } | { kind: 'selector'; selector: Selector }

function tapTargetOf(args: Record<string, unknown>): TapTarget {
  const hasX = args.x !== undefined && args.x !== null
  const hasY = args.y !== undefined && args.y !== null
  const selector = selectorOf(args)
  if ((hasX || hasY) && selector !== null) {
    throw new Refused('not-permitted', 'Give x and y, or a name/identifier/role — not both.')
  }
  if (hasX !== hasY) throw new Refused('not-permitted', 'A position needs both x and y.')
  if (hasX) return { kind: 'point', x: fraction('x', args.x), y: fraction('y', args.y) }
  if (selector === null) {
    throw new Refused(
      'not-permitted',
      'Say where to tap: x and y as fractions of the screen, or the name, identifier or role of the element.',
    )
  }
  return { kind: 'selector', selector }
}

function holdOf(args: Record<string, unknown>): number | undefined {
  const raw = args.holdMs
  if (raw === undefined || raw === null) return undefined
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0) {
    throw new Refused('not-permitted', 'holdMs must be a number of milliseconds')
  }
  return Math.min(Math.trunc(raw), MAX_HOLD_MS)
}

/**
 * Where a direction puts the finger.
 *
 * The finger's own travel, never the content's — the one reading of "up" that
 * does not depend on which way somebody thinks of scrolling. Up drags from three
 * quarters of the way down to one quarter, which moves a list up and shows what
 * is below it. Both ends stay a quarter in from the edges, well clear of the
 * system's own edge gestures (home, notifications, back), which start within a
 * few points of the bezel and would take the swipe for themselves.
 */
export function directionPath(direction: Direction): { from: { x: number; y: number }; to: { x: number; y: number } } {
  switch (direction) {
    case 'up':
      return { from: { x: 0.5, y: 0.75 }, to: { x: 0.5, y: 0.25 } }
    case 'down':
      return { from: { x: 0.5, y: 0.25 }, to: { x: 0.5, y: 0.75 } }
    case 'left':
      return { from: { x: 0.75, y: 0.5 }, to: { x: 0.25, y: 0.5 } }
    case 'right':
      return { from: { x: 0.25, y: 0.5 }, to: { x: 0.75, y: 0.5 } }
  }
}

function swipePathOf(args: Record<string, unknown>): {
  from: { x: number; y: number }
  to: { x: number; y: number }
  durationMs: number
  direction: Direction | null
} {
  const raw = args.durationMs
  let durationMs = DEFAULT_SWIPE_MS
  if (raw !== undefined && raw !== null) {
    if (typeof raw !== 'number' || !Number.isFinite(raw)) {
      throw new Refused('not-permitted', 'durationMs must be a number of milliseconds')
    }
    durationMs = Math.min(Math.max(Math.trunc(raw), MIN_SWIPE_MS), MAX_SWIPE_MS)
  }
  const direction = typeof args.direction === 'string' ? (args.direction as Direction) : null
  const hasPoints = args.from !== undefined || args.to !== undefined
  if (direction !== null && hasPoints) {
    throw new Refused('not-permitted', 'Give a direction, or from and to — not both.')
  }
  if (direction !== null) return { ...directionPath(direction), durationMs, direction }
  if (args.from === undefined || args.to === undefined) {
    throw new Refused(
      'not-permitted',
      'Say how to swipe: from and to as {x, y} fractions of the screen, or a direction (up, down, left, right).',
    )
  }
  return { from: pointOf('from', args.from), to: pointOf('to', args.to), durationMs, direction: null }
}

function typingOf(args: Record<string, unknown>): { text: string | null; key: string | null; modifiers: string[] } {
  const text = optText(args, 'text')
  const key = optText(args, 'key')
  const modifiers = Array.isArray(args.modifiers) ? args.modifiers.filter((m): m is string => typeof m === 'string') : []
  if (text === null && key === null) {
    throw new Refused('not-permitted', 'Give text to type, a key to press, or both.')
  }
  if (text !== null && text.length > MAX_TYPE_CHARS) {
    throw new Refused(
      'not-permitted',
      `text is ${text.length} characters and at most ${MAX_TYPE_CHARS} are typed at once. Send it in parts.`,
    )
  }
  if (modifiers.length > 0 && key === null) {
    throw new Refused('not-permitted', 'modifiers are held while a key is pressed, so they need a key.')
  }
  return { text, key, modifiers }
}

function buttonOf(args: Record<string, unknown>): { button: string } | { rotate: Orientation } {
  const button = optText(args, 'button')
  const rotate = optText(args, 'rotate')
  if (button !== null && rotate !== null) throw new Refused('not-permitted', 'Give button or rotate, not both.')
  if (button !== null) return { button }
  if (rotate !== null) return { rotate: rotate as Orientation }
  throw new Refused('not-permitted', `Give a button (${DEVICE_BUTTONS.join(', ')}) or rotate (${ORIENTATIONS.join(', ')}).`)
}

/** An Android id that is not an emulator's is a phone on a cable — the same test `inventory.ts` makes. */
function isPhoneOnACable(id: string): boolean {
  return id.startsWith('android:') && !id.startsWith('android:emulator-')
}

function scopeOf(args: Record<string, unknown>): TreeScope {
  return typeof args.scope === 'string' && (SCOPES as readonly string[]).includes(args.scope)
    ? (args.scope as TreeScope)
    : 'visible'
}

function intIn(args: Record<string, unknown>, key: string, fallback: number, max: number): number {
  const raw = args[key]
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return fallback
  return Math.min(Math.max(Math.trunc(raw), 1), max)
}

/** A row of `devices.list`, in the words a model should read. */
function deviceRow(entry: DeviceEntry): Record<string, unknown> {
  return {
    id: entry.id,
    name: entry.name,
    platform: entry.platform,
    kind: entry.kind,
    state: stateWords(entry.state),
    usable: entry.available,
    runtime: entry.runtime,
    canStart: entry.canBoot,
    canShutDown: entry.canShutDown,
    buttons: entry.buttons,
    keys: entry.keys,
    text: entry.text,
    canRotate: entry.canRotate,
    ...(entry.note === '' ? {} : { note: entry.note }),
    ...(entry.checking
      ? {
          checking: true,
          checkingNote:
            'The device engine was slow to answer, so this row comes from the simulator’s own record and is being ' +
            'checked again. It can still be opened.',
        }
      : {}),
  }
}

/* --------------------------------------------------------------- the tools -- */

export function deviceTools(deps: DeviceToolDeps): ToolSpec[] {
  const listTool: ToolSpec = {
    id: 'devices.list',
    wire: 'devices_list',
    tier: 'read',
    title: 'List phones and simulators',
    description:
      'Every iOS Simulator and Android emulator on this computer, running or not, and every Android phone ' +
      'plugged in by USB. Each row has the id every other devices tool takes, its name, platform, kind ' +
      '(simulator, emulator or physical), its state in words, whether it is usable right now, its OS version, ' +
      'whether devices.open can start it, and which hardware buttons, named keys and text it accepts (text: ' +
      'unicode, ascii or none). Call this first. Positions in every devices tool are fractions of the screen, ' +
      '0 to 1, x from the left and y from the top.',
    index:
      'The iOS Simulators, Android emulators and USB Android phones on this computer, with the id every devices tool takes. Call first.',
    inputSchema: NO_ARGS,
    summary: () => 'List the phones and simulators on this computer',
    run: async (): Promise<ToolOutput> => {
      const reason = deps.unavailable()
      const entries = reason === null ? await deps.list() : []
      const devices = entries.map(deviceRow)
      const usable = entries.filter((entry) => entry.available).length
      return {
        value: withEmptiness(
          { available: reason === null, devices, usable },
          {
            produced: devices.length,
            whenNone:
              reason !== null
                ? `${reason} No phone or simulator can be listed or driven from this computer.`
                : 'this computer has no iOS Simulator, no Android emulator and no Android phone plugged in. ' +
                  'Simulators come with Xcode and emulators with Android Studio; a phone needs USB debugging ' +
                  'turned on and this computer allowed on it.',
          },
        ),
        summary: { devices: devices.length, usable, ...emptySummary(devices.length) },
      }
    },
  }

  const openTool: ToolSpec = {
    id: 'devices.open',
    wire: 'devices_open',
    tier: 'act',
    title: 'Start and open a device',
    description:
      'Get a device ready to drive: starts a simulator or emulator that is off — that can take a minute or ' +
      'more — and opens it so later taps, typing and screen reads answer quickly. Returns its details (name, ' +
      'screen size in points, buttons, keys, text it accepts, whether it rotates) and the id to use from now ' +
      'on: an Android emulator listed as avd:<name> while it was off becomes android:emulator-<port> once it ' +
      'runs. A phone on a cable cannot be started from here. Every other devices tool opens a running device ' +
      'by itself, so this is only needed for one that is off.',
    index:
      'Start a simulator or emulator that is off and open it for driving; answers the id to use from then on.',
    inputSchema: ONLY_DEVICE,
    precheck: (args) => {
      requireEngine(deps, 'devices.open')
      deviceIdOf(args)
    },
    summary: (args) => `Start and open device ${idWords(args)}`,
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const entry = (await deps.list()).find((one) => one.id === id)
      if (entry === undefined) {
        throw new Refused(
          'not-permitted',
          `There is no device ${id} on this computer right now — it may have been deleted, unplugged, or ` +
            'started under a new id. Call devices.list for the current ids.',
        )
      }
      if (entry.state === 'unauthorized' || entry.state === 'offline') {
        throw new Refused(
          'not-permitted',
          `${entry.name} is ${stateWords(entry.state)}. ${entry.note || 'It cannot be opened until that changes.'}`,
        )
      }
      let useId = id
      let started = false
      if (entry.state === 'shutdown') {
        if (!entry.canBoot) {
          throw new Refused('not-permitted', `${entry.name} is off and cannot be started from here.`)
        }
        const booted = await deps.boot(id)
        // A device that would not start is a fault, not a rule: it is the
        // platform's own sentence and trying again later is reasonable.
        if (!booted.ok) throw new Error(booted.message)
        useId = booted.id
        started = true
      }
      const device = await deps.open(useId)
      const renamed = useId !== id
      return {
        value: withEmptiness(
          {
            id: useId,
            started,
            device,
            ...(renamed
              ? {
                  note:
                    `${entry.name} is running now as ${useId}. Use that id for every call from here on; ` +
                    `${id} named it only while it was off.`,
                }
              : {}),
          },
          // A device that opened is the thing this call is for.
          { produced: 1, whenNone: '' },
        ),
        summary: { id: useId, started, ...(renamed ? { was: id } : {}), ...emptySummary(1) },
      }
    },
  }

  const shutdownTool: ToolSpec = {
    id: 'devices.shutdown',
    wire: 'devices_shutdown',
    /*
     * `act`, like stopping a session: visible on the Simulators page and undone
     * by `devices.open`. What it costs is whatever an app on the simulator had
     * not saved, which is the same cost the person's own Shut Down button has.
     */
    tier: 'act',
    title: 'Shut a simulator down',
    description:
      'Shut down a running iOS Simulator or Android emulator, as its own Shut Down would; anything unsaved in ' +
      'its apps is lost. It never works on a phone plugged in by USB — a person turns their phone off on the ' +
      'phone. devices.open starts it again.',
    index:
      'Shut down a running iOS Simulator or Android emulator; a phone on a cable is never powered off from here.',
    inputSchema: ONLY_DEVICE,
    precheck: (args) => {
      requireEngine(deps, 'devices.shutdown')
      const id = deviceIdOf(args)
      // A rule, so it is refused before anything is attempted rather than left
      // to `inventory.ts` to decline after the engine was asked.
      if (isPhoneOnACable(id)) {
        throw new Refused(
          'not-permitted',
          `${id} is a phone on a cable. A phone is turned off on the phone itself; this app never powers a ` +
            'person’s phone down.',
        )
      }
    },
    summary: (args) => `Shut down ${idWords(args)}`,
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      if (id.startsWith('avd:')) {
        return {
          value: withEmptiness(
            {
              id,
              shutDown: false,
              alreadyOff: true,
              note:
                `${id} names an emulator that was off when it was listed. If it has been started since, it has an ` +
                'android:emulator-… id now — call devices.list.',
            },
            { produced: 0, whenNone: 'it was already off, so there was nothing to shut down.' },
          ),
          summary: { id, alreadyOff: true, ...emptySummary(0) },
        }
      }
      const answer = await deps.shutDown(id)
      if (!answer.ok) throw new Error(answer.message)
      return {
        value: withEmptiness({ id, shutDown: true }, { produced: 1, whenNone: '' }),
        summary: { id, ...emptySummary(1) },
      }
    },
  }

  const screenshotTool: ToolSpec = {
    id: 'devices.screenshot',
    wire: 'devices_screenshot',
    // `read`, as `browser.screenshot` is: it changes nothing on the device, and
    // the file it writes is a copy of what is already on the screen.
    tier: 'read',
    title: 'Photograph a device screen',
    description:
      'A full-resolution PNG of the device’s screen, saved in the Pictures folder of the computer running ' +
      'this app. Returns the path and the size in pixels, never the image. To decide what to tap use ' +
      'devices.tree or devices.find — they give names and positions; a picture is for a person to look at, ' +
      'or for checking how something looks.',
    index:
      'Save a full-resolution PNG of a device’s screen to the Pictures folder; answers the path and size, not the image.',
    inputSchema: ONLY_DEVICE,
    precheck: (args, context) => {
      requireEngine(deps, 'devices.screenshot')
      deviceIdOf(args)
      refuseAPictureOnTheWrongComputer(context)
    },
    summary: (args) => `Photograph the screen of ${idWords(args)}`,
    run: async (args, context): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const shot = await deps.screenshot(id)
      /*
       * A caller from off this computer — an assistant reaching in over the
       * relay — gets the picture saved, because the person may well want it in
       * their Pictures folder, and gets told the path is not one it can open.
       * Refusing would take away the half that is useful; staying silent would
       * send it off to read a file that is not there.
       */
      const away = context.caller.kind === 'remote'
      return {
        value: {
          deviceId: id,
          ...shot,
          ...(away
            ? {
                note:
                  'The picture is saved on the computer the device is attached to, where the person can find it ' +
                  'in Pictures. The path is not a file you can open from where you are; devices.tree is how to ' +
                  'read the screen.',
              }
            : {}),
        },
        summary: { deviceId: id, width: shot.width, height: shot.height },
      }
    },
  }

  const tapTool: ToolSpec = {
    id: 'devices.tap',
    wire: 'devices_tap',
    tier: 'act',
    // Input to a device: its own budget, never the shared thirty — see
    // `Budgets.deviceInput` in `control.ts`.
    spends: 'device-input',
    title: 'Tap a device screen',
    description:
      'Tap one point, or tap an element found by name. Give x and y — fractions of the screen, 0 to 1, x ' +
      'across from the left and y down from the top, whichever way up the device is — or give name, ' +
      'identifier and/or role, and the screen is read fresh and the one element that matches is tapped at its ' +
      'centre. If nothing matches, or several different elements do, nothing is tapped and the answer lists up ' +
      `to ${MAX_CANDIDATES} candidates with their centres. holdMs of ${LONG_PRESS_MS} or more makes it a long ` +
      `press (at most ${MAX_HOLD_MS}). Returns where it tapped and what was there.`,
    index:
      'Tap a device screen at a position, or on an element found by name or identifier; holdMs makes it a long press.',
    inputSchema: TAP_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.tap')
      deviceIdOf(args)
      tapTargetOf(args)
      holdOf(args)
    },
    summary: (args) => {
      const hold = holdOf(args)
      const verb = hold !== undefined && hold >= LONG_PRESS_MS ? 'Long-press' : 'Tap'
      const target = tapTargetOf(args)
      return target.kind === 'point'
        ? `${verb} ${idWords(args)} at ${percent(target.x)} across, ${percent(target.y)} down`
        : `${verb} the ${selectorWords(target.selector)} on ${idWords(args)}`
    },
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const target = tapTargetOf(args)
      const holdMs = holdOf(args)
      let point = target.kind === 'point' ? { x: target.x, y: target.y } : null
      let element: ElementView | null = null
      if (target.kind === 'selector') {
        // Fresh every time: a tree from an earlier call describes a screen
        // that may have moved since, and the tap lands on this one.
        const answer = await deps.tree(id, 'visible')
        const node = resolveOne(answer.tree.root, target.selector)
        // `resolveOne` only returns a node with a centre on the screen.
        point = centreOf(node) as { x: number; y: number }
        element = elementView(node)
      }
      const at = point as { x: number; y: number }
      await deps.tap(id, at.x, at.y, holdMs)
      const longPress = holdMs !== undefined && holdMs >= LONG_PRESS_MS
      return {
        value: withEmptiness(
          {
            deviceId: id,
            tapped: { x: round3(at.x), y: round3(at.y) },
            longPress,
            ...(holdMs === undefined ? {} : { holdMs }),
            element,
          },
          { produced: 1, whenNone: '' },
        ),
        summary: {
          deviceId: id,
          x: round3(at.x),
          y: round3(at.y),
          ...(element?.name ? { element: element.name } : {}),
          ...(longPress ? { longPress } : {}),
          ...emptySummary(1),
        },
      }
    },
  }

  const swipeTool: ToolSpec = {
    id: 'devices.swipe',
    wire: 'devices_swipe',
    tier: 'act',
    // Input to a device, like `devices.tap`.
    spends: 'device-input',
    title: 'Swipe on a device screen',
    description:
      'Drag a finger across the screen. Give from and to, each {x, y} as fractions of the screen (0 to 1, x ' +
      `from the left, y from the top), with an optional durationMs (default ${DEFAULT_SWIPE_MS}; slower is a ` +
      'drag, faster a flick). Or give direction for an ordinary scroll: direction is the way the finger ' +
      'travels, so up drags from low on the screen to high, moving the content up to show what is further ' +
      'down a list; down goes back towards the top; left and right page sideways the same way.',
    index:
      'Swipe or scroll on a device screen, between two points or simply up, down, left or right.',
    inputSchema: SWIPE_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.swipe')
      deviceIdOf(args)
      swipePathOf(args)
    },
    summary: (args) => {
      const path = swipePathOf(args)
      if (path.direction !== null) return `Swipe ${path.direction} on ${idWords(args)}`
      return (
        `Swipe on ${idWords(args)} from ${percent(path.from.x)}, ${percent(path.from.y)} ` +
        `to ${percent(path.to.x)}, ${percent(path.to.y)}`
      )
    },
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const path = swipePathOf(args)
      await deps.swipe(id, path.from, path.to, path.durationMs)
      return {
        value: withEmptiness(
          {
            deviceId: id,
            from: path.from,
            to: path.to,
            durationMs: path.durationMs,
            ...(path.direction === null ? {} : { direction: path.direction }),
          },
          { produced: 1, whenNone: '' },
        ),
        summary: { deviceId: id, ...(path.direction === null ? {} : { direction: path.direction }), ...emptySummary(1) },
      }
    },
  }

  const typeTool: ToolSpec = {
    id: 'devices.type',
    wire: 'devices_type',
    tier: 'act',
    // Input to a device, like `devices.tap`.
    spends: 'device-input',
    title: 'Type on a device',
    description:
      'Type text into whatever field has focus on the device, and/or press one named key — return, enter, ' +
      'delete, tab, escape, the arrows or select-all — with optional modifiers. Tap the field with devices.tap ' +
      'first. The text is typed before the key is pressed, so {text, key: "return"} fills a field and submits ' +
      'it. Only the text’s length is written to the activity log, never the text, so a password can be typed. ' +
      `Up to ${MAX_TYPE_CHARS} characters at once. Some devices take plain ASCII only; devices.list says which.`,
    index:
      'Type text into the focused field on a device and/or press a key such as return; the text itself is never logged.',
    inputSchema: TYPE_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.type')
      deviceIdOf(args)
      typingOf(args)
    },
    /*
     * Length only, in both places a person reads. `browser.step` set the shape
     * and the reason: the row must say that something was typed — a row that
     * says nothing cannot be told from one where nothing happened — and must not
     * be a copy of it.
     */
    redactArgs: (args) => {
      const out = { ...args }
      if (typeof args.text === 'string') out.text = `[${args.text.length} characters]`
      return out
    },
    summary: (args) => {
      const typing = typingOf(args)
      const parts: string[] = []
      if (typing.text !== null) parts.push(`type ${typing.text.length} characters`)
      if (typing.key !== null) {
        parts.push(`press ${[...typing.modifiers, typing.key].join('+')}`)
      }
      const words = parts.join(' and ')
      return `${words.charAt(0).toUpperCase()}${words.slice(1)} on ${idWords(args)}`
    },
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const typing = typingOf(args)
      const device = await deps.open(id)
      if (typing.text !== null) {
        if (device.text === 'none') {
          throw new Refused(
            'not-permitted',
            `${device.name} does not accept typed text. Nothing was typed. Tap its on-screen keyboard instead.`,
          )
        }
        if (device.text === 'ascii' && [...typing.text].some((char) => (char.codePointAt(0) ?? 0) > 0x7f)) {
          throw new Refused(
            'not-permitted',
            `${device.name} accepts plain ASCII text only, and this text has other characters in it. Nothing ` +
              'was typed.',
          )
        }
      }
      if (typing.key !== null && device.keys.length > 0 && !device.keys.includes(typing.key)) {
        throw new Refused(
          'not-permitted',
          `${device.name} cannot be sent ${typing.key}. It takes: ${device.keys.join(', ')}. Nothing was typed.`,
        )
      }
      if (typing.text !== null) await deps.type(id, typing.text)
      if (typing.key !== null) await deps.key(id, typing.key, typing.modifiers)
      return {
        value: withEmptiness(
          {
            deviceId: id,
            // The count, never the text — the result is logged as well.
            typedCharacters: typing.text?.length ?? 0,
            ...(typing.key === null ? {} : { pressed: typing.key }),
            ...(typing.modifiers.length === 0 ? {} : { modifiers: typing.modifiers }),
          },
          { produced: 1, whenNone: '' },
        ),
        summary: {
          deviceId: id,
          chars: typing.text?.length ?? 0,
          ...(typing.key === null ? {} : { key: typing.key }),
          ...emptySummary(1),
        },
      }
    },
  }

  const buttonTool: ToolSpec = {
    id: 'devices.button',
    wire: 'devices_button',
    tier: 'act',
    // Input to a device, like `devices.tap`.
    spends: 'device-input',
    title: 'Press a button or rotate a device',
    description:
      `Press a hardware button — ${DEVICE_BUTTONS.join(', ')} — or turn the device to an orientation: ` +
      `${ORIENTATIONS.join(', ')}. Give one of button or rotate. Not every device has every button or can ` +
      'turn: devices.list shows what each has, and a button it does not have is refused rather than pressed. ' +
      'Returns what was pressed, or the orientation it is in now.',
    index:
      'Press a hardware button (home, back, lock, volume and so on) on a device, or turn it to portrait or landscape.',
    inputSchema: BUTTON_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.button')
      deviceIdOf(args)
      buttonOf(args)
    },
    summary: (args) => {
      const what = buttonOf(args)
      return 'button' in what ? `Press ${what.button} on ${idWords(args)}` : `Turn ${idWords(args)} to ${what.rotate}`
    },
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const what = buttonOf(args)
      const device = await deps.open(id)
      if ('button' in what) {
        // "When known": an empty list is a device the engine said nothing
        // about, and refusing there would be refusing on a guess.
        if (device.buttons.length > 0 && !device.buttons.includes(what.button)) {
          throw new Refused(
            'not-permitted',
            `${device.name} has no ${what.button} button. It has: ${device.buttons.join(', ')}. Nothing was pressed.`,
          )
        }
        await deps.button(id, what.button)
        return {
          value: withEmptiness({ deviceId: id, pressed: what.button }, { produced: 1, whenNone: '' }),
          summary: { deviceId: id, button: what.button, ...emptySummary(1) },
        }
      }
      if (!device.canRotate) {
        throw new Refused('not-permitted', `${device.name} does not turn from here. It was left as it is.`)
      }
      const orientation = await deps.rotate(id, what.rotate)
      return {
        value: withEmptiness({ deviceId: id, orientation }, { produced: 1, whenNone: '' }),
        summary: { deviceId: id, orientation, ...emptySummary(1) },
      }
    },
  }

  const treeTool: ToolSpec = {
    id: 'devices.tree',
    wire: 'devices_tree',
    tier: 'read',
    title: 'Read what is on a device screen',
    description:
      'What the device is showing, as a list of elements in reading order: each with its role in plain words, ' +
      'its name, its accessibility identifier or test id, its value (never a password’s — that is marked ' +
      'secret), enabled: false when it is greyed out, and its frame and centre as fractions of the screen (0 to ' +
      '1, x from the left, y from the top) — the centre is exactly what devices.tap takes, and an element ' +
      'scrolled off the screen is marked offScreen instead of having one. depth says how ' +
      'deeply it sits inside the rows above it. A React Native app in development also names each element’s ' +
      'component and source file. Also says which app and screen are in front. scope: interactive lists only ' +
      'what can be acted on, visible (default) what is on screen, full also what is scrolled away. At most ' +
      `limit elements (default ${DEFAULT_TREE_NODES}); truncated says when there were more.`,
    index:
      'Read what is on a device screen: each element’s role, name, identifier and centre to tap, and the app in front.',
    inputSchema: TREE_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.tree')
      deviceIdOf(args)
    },
    summary: (args) => `Read the screen of ${idWords(args)}`,
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const limit = intIn(args, 'limit', DEFAULT_TREE_NODES, MAX_TREE_NODES)
      const answer = await deps.tree(id, scopeOf(args))
      const { rows, total } = listElements(answer.tree.root, limit)
      const cut = total > rows.length
      const truncated = cut || answer.tree.truncated
      const notes: string[] = []
      if (cut) notes.push(`Showing ${rows.length} of ${total} elements; pass a larger limit (at most ${MAX_TREE_NODES}) or use devices.find.`)
      if (answer.tree.truncated) notes.push('The device itself stopped reading the screen early; it has more than it described.')
      if (answer.fallback !== '') notes.push(`The React Native tree was not used: ${answer.fallback}`)
      return {
        value: withEmptiness(
          {
            deviceId: id,
            source: sourceOf(answer.tree),
            foreground: answer.foreground,
            capturedAt: answer.tree.capturedAt,
            elements: rows,
            shown: rows.length,
            total,
            truncated,
            ...(notes.length === 0 ? {} : { note: notes.join(' ') }),
          },
          {
            produced: rows.length,
            whenNone:
              'the screen described itself with no element worth listing — it may still be loading, or the app ' +
              'draws everything itself, as a game or a map does. devices.screenshot shows it, and devices.tap ' +
              'can still tap a position.',
          },
        ),
        summary: { deviceId: id, shown: rows.length, total, truncated, ...emptySummary(rows.length) },
      }
    },
  }

  const findTool: ToolSpec = {
    id: 'devices.find',
    wire: 'devices_find',
    tier: 'read',
    title: 'Find elements on a device screen',
    description:
      'Find elements on the screen by name, identifier and/or role, and get each match’s centre and frame, so ' +
      'you can tap it by its centre or by the same name with devices.tap. name is matched against what the ' +
      'element says and its accessibility label, whole and ignoring case unless partial is true. role takes ' +
      `plain words (button, text field) or the platform’s own (AXButton). At most ${MAX_FIND_MATCHES} matches. ` +
      'A match scrolled off the screen is marked offScreen and has no centre: swipe to it first.',
    index:
      'Find elements on a device screen by name, identifier or role, with the centre of each one to tap.',
    inputSchema: FIND_SCHEMA,
    precheck: (args) => {
      requireEngine(deps, 'devices.find')
      deviceIdOf(args)
      if (selectorOf(args) === null) {
        throw new Refused('not-permitted', 'Give a name, an identifier or a role to look for.')
      }
    },
    summary: (args) => {
      const selector = selectorOf(args)
      return `Find ${selector === null ? 'elements' : selectorWords(selector)} on ${idWords(args)}`
    },
    run: async (args): Promise<ToolOutput> => {
      const id = deviceIdOf(args)
      const selector = selectorOf(args) as Selector
      const answer = await deps.tree(id, scopeOf(args))
      const found = findShown(answer.tree.root, selector)
      const matches = found.slice(0, MAX_FIND_MATCHES).map(elementView)
      return {
        value: withEmptiness(
          {
            deviceId: id,
            source: sourceOf(answer.tree),
            foreground: answer.foreground,
            matches,
            count: found.length,
            truncated: found.length > matches.length,
          },
          {
            produced: matches.length,
            whenNone:
              `nothing on the screen matches the ${selectorWords(selector)}. Names are matched whole and ignoring ` +
              'case — try partial: true, or devices.tree to see what is there. It may also be scrolled away: ' +
              'scope full includes that.',
          },
        ),
        summary: { deviceId: id, count: found.length, ...emptySummary(matches.length) },
      }
    },
  }

  const annotationsTool: ToolSpec = {
    id: 'devices.annotations',
    wire: 'devices_annotations',
    tier: 'read',
    title: 'Read what a person annotated',
    description:
      'What a person marked with Annotate — on a phone or simulator screen, or on a browser page; both kinds ' +
      'are kept here. Each round says where it was made (the device and app, or the page address), the path of ' +
      'the picture with numbered markers drawn on it, which session it was sent to if any, the one note the ' +
      'person wrote about the whole round (it refers to markers by number, "#2"), and each marker by its ' +
      'number with the element it is on — its name, identifier, component and source file when known — and ' +
      'its rectangle as fractions of the picture. Newest first. count (default 1, at most ' +
      `${MAX_ROUNDS}) and kind (device or browser) narrow it. Only rounds made since the app last started.`,
    index:
      'Read what a person marked with Annotate on a device screen or a browser page: the numbered elements, their one note, the marked picture.',
    inputSchema: ANNOTATIONS_SCHEMA,
    summary: (args) => {
      const count = intIn(args, 'count', 1, MAX_ROUNDS)
      const kind = typeof args.kind === 'string' ? ` ${args.kind}` : ''
      return count === 1 ? `Read the newest${kind} annotation round` : `Read the newest ${count}${kind} annotation rounds`
    },
    run: async (args): Promise<ToolOutput> => {
      const count = intIn(args, 'count', 1, MAX_ROUNDS)
      const kind = typeof args.kind === 'string' ? args.kind : null
      const all = deps.rounds()
      const matching = kind === null ? all : all.filter((round) => round.where.kind === kind)
      const rounds = matching.slice(0, count).map(roundForTools)
      const other = all.length - matching.length
      return {
        value: withEmptiness(
          { rounds, total: matching.length },
          {
            produced: rounds.length,
            whenNone:
              all.length === 0
                ? 'nobody has annotated anything since the app started. A person makes a round with Annotate, ' +
                  'on the Simulators page or in the browser, and it appears here as soon as it is saved.'
                : `nobody has annotated a ${kind === 'device' ? 'device screen' : 'browser page'} since the app ` +
                  `started; there ${other === 1 ? 'is 1 round' : `are ${other} rounds`} on ` +
                  `${kind === 'device' ? 'browser pages' : 'device screens'} — leave kind out to read them.`,
          },
        ),
        summary: { rounds: rounds.length, total: matching.length, ...emptySummary(rounds.length) },
      }
    },
  }

  return [
    listTool,
    openTool,
    shutdownTool,
    screenshotTool,
    tapTool,
    swipeTool,
    typeTool,
    buttonTool,
    treeTool,
    findTool,
    annotationsTool,
  ]
}
