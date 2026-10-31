import type { AnnotateWhere, AnnotationRound } from '../../shared/annotate'

/**
 * A round from the window, rebuilt field by field.
 *
 * It is kept and later handed to a model, so nothing from the renderer is
 * stored as it arrived: strings are cut to a sane length, numbers are clamped,
 * and anything unexpected is dropped.
 */
export function readRound(raw: unknown): AnnotationRound {
  const r = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  const text = (value: unknown, max = 2_000): string => (typeof value === 'string' ? value.slice(0, max) : '')
  const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) ? value : 0)
  const whereRaw = (typeof r.where === 'object' && r.where !== null ? r.where : {}) as Record<string, unknown>
  const where: AnnotateWhere = {
    kind: whereRaw.kind === 'browser' ? 'browser' : 'device',
    place: text(whereRaw.place, 60),
    name: text(whereRaw.name, 200),
    ...(text(whereRaw.deviceId, 200) ? { deviceId: text(whereRaw.deviceId, 200) } : {}),
    ...(text(whereRaw.app, 200) ? { app: text(whereRaw.app, 200) } : {}),
    ...(text(whereRaw.screen, 200) ? { screen: text(whereRaw.screen, 200) } : {}),
    ...(text(whereRaw.url, 2_000) ? { url: text(whereRaw.url, 2_000) } : {}),
  }
  const frame = (typeof r.frame === 'object' && r.frame !== null ? r.frame : {}) as Record<string, unknown>
  const list = Array.isArray(r.annotations) ? r.annotations.slice(0, 50) : []
  return {
    id: text(r.id, 80) || `round-${Date.now()}`,
    createdAt: num(r.createdAt) || Date.now(),
    where,
    frame: { width: Math.max(0, Math.round(num(frame.width))), height: Math.max(0, Math.round(num(frame.height))) },
    note: text(r.note, 4_000),
    annotations: list.map((entry, index) => {
      const a = (typeof entry === 'object' && entry !== null ? entry : {}) as Record<string, unknown>
      const rect = (typeof a.rect === 'object' && a.rect !== null ? a.rect : {}) as Record<string, unknown>
      const clamp = (value: unknown): number => Math.min(Math.max(num(value), 0), 1)
      const el = typeof a.element === 'object' && a.element !== null ? (a.element as Record<string, unknown>) : null
      const source = el && typeof el.source === 'object' && el.source !== null ? (el.source as Record<string, unknown>) : null
      return {
        id: text(a.id, 80) || `a-${index}`,
        n: index + 1,
        rect: { x: clamp(rect.x), y: clamp(rect.y), width: clamp(rect.width), height: clamp(rect.height) },
        element: el
          ? {
              ...(text(el.role, 60) ? { role: text(el.role, 60) } : {}),
              ...(text(el.name, 300) ? { name: text(el.name, 300) } : {}),
              ...(text(el.identifier, 300) ? { identifier: text(el.identifier, 300) } : {}),
              ...(text(el.selector, 500) ? { selector: text(el.selector, 500) } : {}),
              ...(text(el.component, 200) ? { component: text(el.component, 200) } : {}),
              ...(source && text(source.file, 500)
                ? {
                    source: {
                      file: text(source.file, 500),
                      ...(num(source.line) > 0 ? { line: Math.round(num(source.line)) } : {}),
                      ...(num(source.column) > 0 ? { column: Math.round(num(source.column)) } : {}),
                    },
                  }
                : {}),
            }
          : null,
      }
    }),
  }
}
