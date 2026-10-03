import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ScreenPlayer } from './screen-player'
import type { DeviceDetails, DevicesBridge } from './devices-bridge'

/**
 * A device's screen, live, and driven with the mouse and the keyboard.
 *
 * ## Pictures
 *
 * The engine's H.264 stream, decoded in hardware and painted at this display's
 * density — `screen-player.ts` holds all of it, including the measurements that
 * made it replace a JPEG per change. This component sizes the canvas to fit the
 * stage and hands the player that size.
 *
 * ## The mouse is a finger
 *
 * Where the device can take a held, moving touch (every iOS Simulator), a press
 * is a finger going down, a drag is the finger moving, and a release is it
 * lifting — so scrolling a list follows the pointer exactly as it would on
 * glass. Where it cannot, a press-and-release is a tap, a long press is a long
 * press, and a drag becomes one swipe from where it started to where it ended.
 * The scroll wheel scrolls, as a short swipe in the wheel's direction.
 *
 * Every touch is sent the moment it happens — never queued behind the one
 * before it waiting for an answer, which is what made a drag lag in 0.16.1.
 * Order is still kept: messages from this window reach the main process in the
 * order they were sent, and the main process writes each to the engine in the
 * turn it arrives (`manager.ts`, `session.ts`). Moves go at most once per
 * animation frame.
 *
 * ## The keyboard is the device's keyboard
 *
 * Once the screen has focus — a click on it gives it focus — typing goes to the
 * device: printable characters are batched into one `type` call, and Return,
 * Delete, Tab and the arrows are sent as keys. ⌘V types what is on this Mac's
 * clipboard. Nothing is sent while the screen does not have focus, so typing in
 * the rest of the window is never intercepted.
 */

interface Props {
  bridge: DevicesBridge
  device: DeviceDetails
  /** Turned off while Annotate holds a frozen picture: nothing should move it. */
  live: boolean
  onFirstFrame?(): void
}

const KEY_NAMES: Record<string, string> = {
  Enter: 'return',
  Backspace: 'delete',
  Tab: 'tab',
  ArrowUp: 'arrow-up',
  ArrowDown: 'arrow-down',
  ArrowLeft: 'arrow-left',
  ArrowRight: 'arrow-right',
}

/** A press shorter and smaller than this is a tap, not a drag. */
const TAP_TRAVEL = 0.015
const LONG_PRESS_MS = 500

export function DeviceScreen({ bridge, device, live, onFirstFrame }: Props) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  const stageRef = useRef<HTMLDivElement | null>(null)
  const [picture, setPicture] = useState<{ width: number; height: number } | null>(null)
  const [fit, setFit] = useState<{ width: number; height: number } | null>(null)
  const firstRef = useRef(onFirstFrame)
  firstRef.current = onFirstFrame

  const playerRef = useRef<ScreenPlayer | null>(null)

  // Pictures in, while live.
  useEffect(() => {
    if (!live) return
    const canvas = canvasRef.current
    if (!canvas) return
    const player = new ScreenPlayer(canvas, {
      // Watching again resends the decoder configuration and asks the engine
      // for a keyframe — the fresh start a decoder that fell behind needs.
      needKeyframe: () => void bridge.deviceWatch(device.id, true).catch(() => undefined),
      onPicture: (size) => {
        setPicture(size)
        firstRef.current?.()
      },
    })
    playerRef.current = player
    const off = bridge.onDeviceFrame((id, packet) => {
      if (id === device.id) player.push(packet)
    })
    void bridge.deviceWatch(device.id, true).catch(() => undefined)
    return () => {
      off()
      player.dispose()
      if (playerRef.current === player) playerRef.current = null
      void bridge.deviceWatch(device.id, false).catch(() => undefined)
    }
  }, [bridge, device.id, live])

  // The largest size that fits the stage, keeping the picture's shape.
  useLayoutEffect(() => {
    const stage = stageRef.current
    if (!stage || !picture) return
    const measure = (): void => {
      const box = stage.getBoundingClientRect()
      const scale = Math.min(box.width / picture.width, box.height / picture.height)
      if (Number.isFinite(scale) && scale > 0) {
        setFit({ width: Math.floor(picture.width * scale), height: Math.floor(picture.height * scale) })
      }
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(measure)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [picture])

  // The canvas's own pixels: its shown size times this display's density, so
  // a Retina panel gets one sharp resample instead of a blurry upscale. Asked
  // again when the window moves to a display of another density.
  useLayoutEffect(() => {
    if (!fit) return
    const apply = (): void => playerRef.current?.resize(fit, window.devicePixelRatio || 1)
    apply()
    const query = window.matchMedia?.(`(resolution: ${window.devicePixelRatio || 1}dppx)`)
    query?.addEventListener?.('change', apply)
    return () => query?.removeEventListener?.('change', apply)
  }, [fit])

  /* ---------------------------------------------------------------- input -- */

  // Sent at once; see the header for why order survives without a queue.
  const send = (step: () => Promise<unknown>): void => {
    void step().catch(() => undefined)
  }
  const press = useRef<{ x: number; y: number; at: number; moved: boolean; last: { x: number; y: number } } | null>(null)
  const moveFrame = useRef(0)

  const pointOf = (event: { clientX: number; clientY: number }): { x: number; y: number } | null => {
    const canvas = canvasRef.current
    if (!canvas) return null
    const box = canvas.getBoundingClientRect()
    if (box.width === 0 || box.height === 0) return null
    return {
      x: Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1),
      y: Math.min(Math.max((event.clientY - box.top) / box.height, 0), 1),
    }
  }

  const id = device.id

  const typed = useRef('')
  const typeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const flushTyping = (): void => {
    if (typeTimer.current) clearTimeout(typeTimer.current)
    typeTimer.current = null
    const text = typed.current
    typed.current = ''
    if (text !== '') send(() => bridge.deviceType(id, text))
  }

  const wheel = useRef({ dy: 0, dx: 0, timer: null as ReturnType<typeof setTimeout> | null })

  return (
    <div className="dv-screen-stage" ref={stageRef}>
      <canvas
        ref={canvasRef}
        className="dv-screen"
        data-ready={picture !== null || undefined}
        tabIndex={0}
        aria-label={`${device.name} screen. Click to tap, drag to swipe, type to type.`}
        style={fit ? { width: fit.width, height: fit.height } : undefined}
        onPointerDown={(event) => {
          if (!live || event.button !== 0) return
          const at = pointOf(event)
          if (!at) return
          event.currentTarget.setPointerCapture(event.pointerId)
          event.currentTarget.focus()
          press.current = { ...at, at: Date.now(), moved: false, last: at }
          if (device.rawTouch) send(() => bridge.deviceTouch(id, 'down', at.x, at.y))
        }}
        onPointerMove={(event) => {
          const held = press.current
          if (!held) return
          const at = pointOf(event)
          if (!at) return
          held.last = at
          if (Math.hypot(at.x - held.x, at.y - held.y) > TAP_TRAVEL) held.moved = true
          if (!device.rawTouch || moveFrame.current !== 0) return
          moveFrame.current = requestAnimationFrame(() => {
            moveFrame.current = 0
            const latest = press.current?.last
            if (latest) send(() => bridge.deviceTouch(id, 'move', latest.x, latest.y))
          })
        }}
        onPointerUp={(event) => {
          const held = press.current
          press.current = null
          if (!held) return
          const at = pointOf(event) ?? held.last
          if (moveFrame.current !== 0) {
            cancelAnimationFrame(moveFrame.current)
            moveFrame.current = 0
          }
          if (device.rawTouch) {
            send(() => bridge.deviceTouch(id, 'up', at.x, at.y))
            return
          }
          const heldFor = Date.now() - held.at
          if (held.moved) {
            send(() => bridge.deviceSwipe(id, { x: held.x, y: held.y }, at, Math.min(Math.max(heldFor, 150), 1_500)))
          } else {
            send(() => bridge.deviceTap(id, held.x, held.y, heldFor >= LONG_PRESS_MS ? heldFor : undefined))
          }
        }}
        onPointerCancel={() => {
          const held = press.current
          press.current = null
          if (held && device.rawTouch) send(() => bridge.deviceTouch(id, 'up', held.last.x, held.last.y))
        }}
        onWheel={(event) => {
          if (!live) return
          const state = wheel.current
          state.dy += event.deltaY
          state.dx += event.deltaX
          if (state.timer) return
          state.timer = setTimeout(() => {
            state.timer = null
            const dy = Math.max(-0.45, Math.min(0.45, state.dy / 900))
            const dx = Math.max(-0.45, Math.min(0.45, state.dx / 900))
            state.dy = 0
            state.dx = 0
            if (Math.abs(dy) < 0.02 && Math.abs(dx) < 0.02) return
            // Wheel down reads further down the page, which on glass is a
            // finger moving up — so the swipe runs against the wheel.
            const from = { x: 0.5, y: 0.5 }
            const to = { x: 0.5 - dx, y: 0.5 - dy }
            send(() => bridge.deviceSwipe(id, from, to, 220))
          }, 90)
        }}
        onKeyDown={(event) => {
          if (!live) return
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'v') {
            event.preventDefault()
            void navigator.clipboard
              ?.readText()
              .then((text) => {
                if (text) send(() => bridge.deviceType(id, text.slice(0, 2_000)))
              })
              .catch(() => undefined)
            return
          }
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'a' && device.keys.includes('select-all')) {
            event.preventDefault()
            flushTyping()
            send(() => bridge.deviceKey(id, 'select-all'))
            return
          }
          if (event.metaKey || event.ctrlKey || event.altKey) return
          const named = KEY_NAMES[event.key]
          if (named) {
            event.preventDefault()
            flushTyping()
            if (device.keys.includes(named)) send(() => bridge.deviceKey(id, named))
            else if (named === 'return') send(() => bridge.deviceType(id, '\n'))
            return
          }
          if (event.key.length === 1 && device.text !== 'none') {
            event.preventDefault()
            typed.current += event.key
            if (typeTimer.current) clearTimeout(typeTimer.current)
            typeTimer.current = setTimeout(flushTyping, 60)
          }
        }}
        onBlur={flushTyping}
      />
      {picture === null && <p className="dv-screen-wait">Starting the live picture…</p>}
    </div>
  )
}
