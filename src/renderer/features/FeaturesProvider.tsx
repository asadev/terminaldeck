import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import type { WidgetType } from '../dashboard/layout'
import type { SectionId } from '../settings/settings-schema'
import type { PanelId } from '../shell/panels'
import {
  featureOwningCommand,
  featureOwningControl,
  featureOwningPanel,
  featureOwningSection,
  featureOwningSetting,
  featureOwningWidget,
  type ControlId,
  type FeatureId,
} from './registry'
import {
  defaultFeatureState,
  isOn,
  offCommands,
  readFeatureState,
  statusOf,
  withStatus,
  writeFeatureState,
  type FeatureState,
  type FeatureStatus,
} from './state'

/**
 * What every part of the window asks before it draws something optional.
 *
 * The questions are deliberately about *surfaces* rather than about features:
 * the sidebar asks whether a panel is live, the palette asks whether a command
 * is live, the chat box asks whether a control is live. None of them holds a
 * feature id, so none of them can fall out of step with the registry when a
 * surface changes hands — and none of them grows its own idea of what "off"
 * means.
 *
 * Every `…On` question answers **true for anything no feature owns**, which is
 * what makes core surfaces free: nothing has to be registered to keep working,
 * and adding a feature is the only way to make something optional.
 */
export interface FeatureControls {
  state: FeatureState
  /** On, off, or not installed. The store is the only caller that needs all three. */
  status(id: FeatureId): FeatureStatus
  /** Installed and switched on — what everything that draws something asks. */
  on(id: FeatureId): boolean

  panelOn(id: PanelId): boolean
  widgetOn(type: WidgetType): boolean
  commandOn(id: string): boolean
  controlOn(id: ControlId): boolean
  sectionOn(id: SectionId): boolean
  settingOn(id: string): boolean

  /** The feature a command belongs to, for offering it where it would have been. */
  featureForCommand(id: string): FeatureId | null
  /** The feature a sidebar view belongs to, for the same reason. */
  featureForPanel(id: PanelId): FeatureId | null

  install(id: FeatureId): void
  uninstall(id: FeatureId): void
  setEnabled(id: FeatureId, enabled: boolean): void
  /** Back to what a fresh install has. */
  resetToDefaults(): void
}

/**
 * The shipped defaults, used by anything rendered outside a provider.
 *
 * That is not a fallback for the running app — `App.tsx` mounts the provider and
 * `features.wiring.test.ts` pins it there, because a provider that can be
 * forgotten is this repository's own favourite bug. It is for the render tests,
 * which mount a single component with no tree above it: the honest answer for
 * one of those is what a fresh install would show.
 */
const FeaturesContext = createContext<FeatureControls | null>(null)

function controlsFor(
  state: FeatureState,
  write: {
    install(id: FeatureId): void
    uninstall(id: FeatureId): void
    setEnabled(id: FeatureId, enabled: boolean): void
    resetToDefaults(): void
  },
): FeatureControls {
  const owned = (owner: FeatureId | null): boolean => owner === null || isOn(state, owner)
  return {
    state,
    status: (id) => statusOf(state, id),
    on: (id) => isOn(state, id),
    panelOn: (id) => owned(featureOwningPanel(id)),
    widgetOn: (type) => owned(featureOwningWidget(type)),
    commandOn: (id) => owned(featureOwningCommand(id)),
    controlOn: (id) => owned(featureOwningControl(id)),
    sectionOn: (id) => owned(featureOwningSection(id)),
    settingOn: (id) => owned(featureOwningSetting(id)),
    featureForCommand: featureOwningCommand,
    featureForPanel: featureOwningPanel,
    ...write,
  }
}

const DEFAULTS: FeatureControls = controlsFor(defaultFeatureState(), {
  // Outside a provider there is nothing to write to. Silent rather than
  // throwing: a test rendering one component in isolation should not have to
  // know that a button it never presses would have needed a store.
  install: () => {},
  uninstall: () => {},
  setEnabled: () => {},
  resetToDefaults: () => {},
})

export function useFeatures(): FeatureControls {
  return useContext(FeaturesContext) ?? DEFAULTS
}

/* ------------------------------------------------------------- the menu -- */

/**
 * The half of the bridge this provider needs, declared where it is used.
 *
 * `preload/contract.test.ts` reads every `*Bridge*` interface in the renderer
 * and fails the build when the preload stops exposing one of its methods, which
 * is the guard that matters here: nothing on screen changes if this call
 * quietly stops existing. The native menu would simply go on offering an
 * uninstalled feature, in the one surface no component test can see.
 */
interface MenuBridge {
  setHiddenMenuCommands(commands: string[]): void
}

/**
 * Read defensively, like every other bridge in this app: these components are
 * rendered to a string in their own tests, where there is no `window` at all —
 * and a build whose preload predates this method must not take the window down
 * over a menu.
 */
function menuBridge(): MenuBridge | null {
  if (typeof window === 'undefined') return null
  const deck = window.deck
  if (!deck || typeof deck.setHiddenMenuCommands !== 'function') return null
  return deck
}

export interface FeaturesProviderProps {
  children: ReactNode
  /**
   * Where the choices are kept. Passed in rather than read, so a test can drive
   * a whole tree through an install without a browser — and so the one place
   * that touches `localStorage` is this file.
   */
  storage?: Storage | null
  /** Starting state, for a test that wants a particular arrangement. */
  initial?: FeatureState
}

/**
 * Holds the feature state for the window, and writes every change straight to
 * storage.
 *
 * No save button and no draft: a switch in a store is a switch, and the app has
 * to look the way it looks the moment it is flipped. Reads happen once, during
 * the first render, for the reason `state.ts` gives at length — anything later
 * rearranges the window in front of the user on every launch.
 */
export function FeaturesProvider({ children, storage, initial }: FeaturesProviderProps) {
  /*
   * Resolved once. `undefined` is "not looked yet" and `null` is "looked, and
   * there is none" — without that distinction the expression re-evaluates on
   * every render, which means touching `globalThis.localStorage` on every
   * render, and outside a browser that is a warning per frame for an answer
   * that cannot change.
   */
  const store = useRef<Storage | null | undefined>(undefined)
  if (store.current === undefined) {
    store.current = storage !== undefined ? storage : (globalThis.localStorage ?? null)
  }
  const [state, setState] = useState<FeatureState>(
    () => initial ?? readFeatureState(store.current ?? null),
  )

  const put = useCallback((next: FeatureState) => {
    setState(next)
    writeFeatureState(next, store.current ?? null)
  }, [])

  /*
   * Tell the application menu what to stop offering.
   *
   * Memoised on `state` rather than rebuilt per render, because the array
   * identity is the effect's dependency: `offCommands` returns a fresh array
   * every call, and pushing on every render would rebuild the whole native menu
   * bar — which closes any menu the person has open at that instant. `state` is
   * a `useState` value, so this fires when a feature is installed, uninstalled
   * or switched, and at no other time. `menu.ts` compares the list it is sent
   * against the one it holds as a second line of defence.
   *
   * On mount as well as on change, deliberately. The menu is built before the
   * window has finished loading and therefore starts out offering everything;
   * this first push is what corrects it, and a window whose owner never opens
   * the store needs it exactly as much as one whose owner lives there.
   */
  const hiddenCommands = useMemo(() => offCommands(state), [state])
  useEffect(() => {
    menuBridge()?.setHiddenMenuCommands(hiddenCommands)
  }, [hiddenCommands])

  const controls = useMemo<FeatureControls>(
    () =>
      controlsFor(state, {
        /*
         * Installing turns it on. There is no "installed but off" landing state,
         * because nothing was downloaded and there is nothing to configure — the
         * whole point of the store is that installing *is* the feature
         * appearing, which is also what makes the confirmation able to say
         * where to go and look.
         */
        install: (id) => put(withStatus(state, id, 'on')),
        uninstall: (id) => put(withStatus(state, id, 'uninstalled')),
        setEnabled: (id, enabled) => put(withStatus(state, id, enabled ? 'on' : 'off')),
        resetToDefaults: () => put(defaultFeatureState()),
      }),
    [state, put],
  )

  return <FeaturesContext.Provider value={controls}>{children}</FeaturesContext.Provider>
}
