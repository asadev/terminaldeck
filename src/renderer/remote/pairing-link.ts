/**
 * WHICH pairing link to hand a person, and what to call it on screen.
 *
 * The link FORMAT is not here. It moved to `src/shared/pairing-link.ts` when the
 * iOS harness needed to mint a real link and could not import the renderer — a
 * contract four programs have to agree on does not belong behind a boundary only
 * the window can cross. See that file's header.
 *
 * What is left here is the part that is genuinely presentation: which of the two
 * routes to offer, and the sentence describing it, both of which depend on the
 * platform the person is looking at. Everything the format needs is re-exported
 * below so that this module is still the one import a panel needs.
 */

import { detectPlatform, thisMachine, type UiPlatform } from '../platform'
import {
  directPairingLink,
  isDirectUrl,
  isHostId,
  isHostKey,
  isRelayUrl,
  relayPairingLink,
  type RelayIdentity,
} from '../../shared/pairing-link'

export {
  MAX_TOKEN_LENGTH,
  PAIRING_LINK_PREFIX,
  PAIRING_LINK_VERSION,
  directPairingLink,
  isDirectUrl,
  isHostId,
  isHostKey,
  isPairingToken,
  isRelayUrl,
  relayPairingLink,
  type RelayIdentity,
} from '../../shared/pairing-link'

/* -------------------------------------------------------------------------- */
/* Which link to hand over                                                     */
/* -------------------------------------------------------------------------- */

export type PairPath = 'relay' | 'direct'

export interface PairingRoute {
  kind: PairPath
  /** The name on the button that selects it. */
  label: string
  /** What choosing it costs and buys, in one line. */
  note: string
  link: string
}

/** The parts of the remote status a link can be built from. */
export interface PairingSources {
  relay: { url: string; hostId: string; publicKey: string; connected: boolean } | null
  url: string | null
}

/**
 * How each path is named and what choosing it means, in one line each.
 *
 * A function of the platform rather than a constant: both notes name the
 * machine the reader is sitting at, and on a Windows host "this Mac" is simply
 * false. This copy never leaves the machine — it sits under the QR code on the
 * desktop — so naming the platform is right here, unlike anything sealed and
 * sent to a phone.
 */
function routeCopy(platform: UiPlatform): Record<PairPath, Omit<PairingRoute, 'link'>> {
  const machine = thisMachine(platform)
  return {
    relay: {
      kind: 'relay',
      label: 'Through the relay',
      note: `The phone will reach ${machine} from any network, sealed end to end.`,
    },
    direct: {
      kind: 'direct',
      label: 'Direct on your tailnet',
      note: `One hop and no third party — but this phone will only reach ${machine} from your tailnet.`,
    },
  }
}

/**
 * Which paths could carry a code right now, best first.
 *
 * The relay comes first when it is connected, and that ordering is a decision
 * about the phone's future rather than about this minute: the code a phone reads
 * is the endpoint it keeps. Pair over the tailnet and the phone can reach this
 * Mac from the tailnet and nowhere else, which is a surprise waiting at an
 * airport. Pair over the relay and it works from both, at the cost of one hop.
 *
 * A relay that is not connected is not a path. Handing over a code for a route
 * that is down produces a phone that scans, waits, and fails — and this panel's
 * one rule is that it never claims a connection that does not exist.
 *
 * Separate from `pairingRoutes` because the Pair button has to know whether
 * pressing it can lead anywhere *before* there is a token to build a link from.
 */
export function pairingPaths(sources: PairingSources): PairPath[] {
  const paths: PairPath[] = []
  const relay = sources.relay
  if (
    relay !== null &&
    relay.connected &&
    isHostId(relay.hostId) &&
    isHostKey(relay.publicKey) &&
    isRelayUrl(relay.url)
  ) {
    paths.push('relay')
  }
  if (sources.url !== null && isDirectUrl(sources.url)) paths.push('direct')
  return paths
}

/** Every path above, with the link a phone would read, best first. */
export function pairingRoutes(
  sources: PairingSources,
  token: string,
  platform: UiPlatform = detectPlatform(),
): PairingRoute[] {
  const copy = routeCopy(platform)
  return pairingPaths(sources).flatMap((kind): PairingRoute[] => {
    const link =
      kind === 'relay'
        ? relayPairingLink(sources.relay as RelayIdentity, token)
        : directPairingLink(sources.url as string, token)
    return link === null ? [] : [{ ...copy[kind], link }]
  })
}

/**
 * The route to show, honouring the choice while it is still a real one.
 *
 * A path can vanish while a code is on screen — the relay drops, Tailscale is
 * switched off — and the selected one then has to fall back rather than leave a
 * link that no longer goes anywhere on a screen somebody is photographing.
 */
export function chooseRoute(
  routes: readonly PairingRoute[],
  preferred: PairPath | null,
): PairingRoute | null {
  return routes.find((route) => route.kind === preferred) ?? routes[0] ?? null
}
