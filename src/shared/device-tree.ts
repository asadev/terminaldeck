/**
 * What is on a phone's screen, as a tree, and the three questions asked of it.
 *
 * Shared by both sides on purpose. The main process answers `devices.find` and
 * `devices.tree` for a model; the window answers "what did he just click on the
 * frozen picture" for Annotate. If those were two implementations they would
 * disagree about which element sits under a point — and the agent would be told
 * about a different button from the one the person pointed at, which is the
 * exact failure Annotate exists to remove.
 *
 * ## Where the tree comes from
 *
 * The device engine (`main/devices/`) reads it from the platform's own
 * accessibility service — the Simulator's, or UIAutomator on Android — or, for a
 * React Native app in development, from the running app's component tree. The
 * node below is the subset of the engine's node this app actually reads. Every
 * field is optional because every platform leaves different ones out.
 *
 * Coordinates are **normalised**: 0..1 across the screen in both directions,
 * whatever the device's pixel size and whichever way up it is. That is the unit
 * input is sent in, so a rectangle read here can be tapped without converting it.
 */

export interface NormRect {
  x: number
  y: number
  width: number
  height: number
}

export interface SourceLocation {
  file: string
  line?: number
  column?: number
}

export interface DeviceNode {
  /** Valid for the snapshot it came from only. Never stored past it. */
  ref: string
  role?: string
  label?: string
  value?: string
  /** True when the value is a password and was left out on purpose. */
  valueRedacted?: boolean
  identifier?: string
  title?: string
  placeholder?: string
  enabled?: boolean
  hidden?: boolean
  focused?: boolean
  /** React Native only — the component's name, its ancestry and its file. */
  component?: string
  componentPath?: string[]
  testID?: string
  text?: string
  sourceLocation?: SourceLocation
  frame?: { normalized: NormRect }
  children?: DeviceNode[]
}

export interface DeviceTree {
  /** Where it was read from — `core-simulator-ax`, `react-native-fiber`, … */
  source: string
  capturedAt: string
  root: DeviceNode
  nodeCount: number
  truncated: boolean
}

/** Every node, parents before children. */
export function flatten(root: DeviceNode): DeviceNode[] {
  const out: DeviceNode[] = []
  const visit = (node: DeviceNode, depth: number): void => {
    // A depth bound rather than trust: the tree arrives from another process,
    // and a cycle or a pathological nesting must not take the window with it.
    if (depth > 200) return
    out.push(node)
    for (const child of node.children ?? []) visit(child, depth + 1)
  }
  visit(root, 0)
  return out
}

function contains(rect: NormRect, x: number, y: number): boolean {
  return x >= rect.x && y >= rect.y && x <= rect.x + rect.width && y <= rect.y + rect.height
}

/**
 * Roles that are scaffolding rather than something a person points at.
 *
 * The application, its window and the anonymous groups between them cover the
 * whole screen. Picking one of those for a click on a button would describe the
 * screen instead of the button, so they lose to anything more specific — and
 * win only when nothing else is there.
 */
const SCAFFOLD = /^(AXApplication|AXWindow|AXGroup|AXUnknown|AXScrollArea|AXLayoutArea|AXOther|android\.widget\.FrameLayout|android\.widget\.LinearLayout|android\.view\.View(Group)?)$/

function hasName(node: DeviceNode): boolean {
  return Boolean(node.label || node.identifier || node.title || node.testID || node.text || node.value)
}

/**
 * The element a person meant by a point on the screen.
 *
 * The smallest named element whose frame holds the point. "Smallest" because
 * frames nest — a row holds its label holds nothing — and the innermost one is
 * the thing under the finger. "Named" because an unlabelled container inside a
 * labelled button is still the button to anybody looking at it. When nothing
 * named holds the point, the smallest of whatever does, so a click on blank
 * space still describes *where* it was rather than answering nothing.
 */
export function elementAt(root: DeviceNode, x: number, y: number): DeviceNode | null {
  let best: DeviceNode | null = null
  let bestArea = Infinity
  let fallback: DeviceNode | null = null
  let fallbackArea = Infinity
  for (const node of flatten(root)) {
    const rect = node.frame?.normalized
    if (!rect || rect.width <= 0 || rect.height <= 0 || node.hidden === true) continue
    if (!contains(rect, x, y)) continue
    const area = rect.width * rect.height
    const meaningful = hasName(node) && !SCAFFOLD.test(node.role ?? '')
    if (meaningful && area < bestArea) {
      best = node
      bestArea = area
    }
    if (area < fallbackArea) {
      fallback = node
      fallbackArea = area
    }
  }
  return best ?? fallback
}

/** A role a person can read: `AXButton` → `button`, `android.widget.TextView` → `text view`. */
export function plainRole(role: string | undefined): string {
  if (!role) return ''
  const bare = role.replace(/^AX/, '').replace(/^.*\./, '')
  return bare.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase()
}

/** The name a node goes by, the way a person would say it. */
export function nodeName(node: DeviceNode): string {
  return (node.label || node.title || node.text || node.identifier || node.testID || node.placeholder || '').trim()
}

export interface FindQuery {
  /** Matched against label, title, text, value and placeholder. */
  name?: string
  identifier?: string
  role?: string
  /** Substring rather than whole-string matching for `name`. */
  partial?: boolean
}

/**
 * Nodes matching a query, in reading order.
 *
 * Case-insensitive, and exact on the whole name unless `partial` is set — a
 * model asking for "Save" must not be handed "Save as…" and "Saved items" as if
 * they were the same button. Role matches either spelling: the raw `AXButton`
 * or the plain `button`.
 */
export function findNodes(root: DeviceNode, query: FindQuery): DeviceNode[] {
  const want = (value: string | undefined): string => (value ?? '').trim().toLowerCase()
  const name = want(query.name)
  const identifier = want(query.identifier)
  const role = want(query.role)
  return flatten(root).filter((node) => {
    if (identifier !== '' && want(node.identifier) !== identifier && want(node.testID) !== identifier) return false
    if (role !== '' && want(node.role) !== role && plainRole(node.role) !== role) return false
    if (name !== '') {
      const names = [node.label, node.title, node.text, node.value, node.placeholder].map(want)
      const hit = query.partial === true ? names.some((n) => n.includes(name)) : names.some((n) => n === name)
      if (!hit) return false
    }
    return identifier !== '' || role !== '' || name !== ''
  })
}

/** The centre of a node, which is where a tap on it goes. */
export function centreOf(node: DeviceNode): { x: number; y: number } | null {
  const rect = node.frame?.normalized
  if (!rect || rect.width <= 0 || rect.height <= 0) return null
  const clamp = (v: number): number => Math.min(Math.max(v, 0), 1)
  return { x: clamp(rect.x + rect.width / 2), y: clamp(rect.y + rect.height / 2) }
}
