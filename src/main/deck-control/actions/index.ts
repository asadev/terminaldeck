/**
 * Every action a person can take, joined from the seven areas. See `./types.ts`.
 */

import { agentsCoverage } from './agents'
import { browserCoverage } from './browser'
import { devicesCoverage } from './devices'
import { fixedCoverage } from './fixed'
import { machinesCoverage } from './machines'
import { memoryCoverage } from './memory'
import { sessionsCoverage } from './sessions'
import type { CoverageMap } from './types'

export type { Coverage, CoverageMap } from './types'

/** Kept apart so the test can say which area a channel was listed in twice. */
export const COVERAGE_AREAS: Readonly<Record<string, CoverageMap>> = Object.freeze({
  sessions: sessionsCoverage,
  machines: machinesCoverage,
  agents: agentsCoverage,
  browser: browserCoverage,
  devices: devicesCoverage,
  fixed: fixedCoverage,
  memory: memoryCoverage,
})
