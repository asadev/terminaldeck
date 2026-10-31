import { hereOnly, oneOf, optBool, optStr, str, verbOf } from './area-shared'
import type { ToolContext, ToolOutput, ToolSpec } from './catalogue'
import type { ChannelCall } from './channel-tap'
import { Refused } from './surface'

/**
 * GitHub, as the Git panel shows it: the repository behind a folder, its pull
 * requests and checks, and this app's own GitHub sign-in.
 *
 * ## Two tools, split on the one line that matters
 *
 * Reading what GitHub says about a project is `read` — it is the panel a person
 * opens, and nothing it does changes anything anywhere. Connecting or
 * disconnecting this app's GitHub account is `alter`: it is a credential, and a
 * credential is the clearest case there is of a change nothing on screen would
 * announce.
 *
 * ## The sign-in code comes back, and why that is allowed
 *
 * GitHub's device flow hands out a short code a person types at github.com.
 * `github-auth.ts` describes it as *"Typed into GitHub by hand. Shown, never
 * logged."* It is returned here for the same reason a pairing code is: it is a
 * one-time code with a lifetime of minutes whose entire purpose is that a person
 * reads it, and the account it authorises is the person's own, approved on
 * github.com by them. It is kept out of the action log. The token GitHub issues
 * at the end never crosses into this file at all.
 *
 * ## Which folders
 *
 * The same rule every folder-taking tool here follows: a folder this app has
 * open — a project, or a live session's folder. Not any path on the disk.
 */

export type GitHubChannels = {
  'github:overview': { args: [string]; result: unknown }
  'github:refresh': { args: [string]; result: unknown }
  'github:repo': { args: [string]; result: unknown }
  'github:clear-cache': { args: [string]; result: unknown }
  'github:auth-status': { args: [string]; result: unknown }
  'github:auth-connect': { args: []; result: unknown }
  'github:auth-await': { args: [string]; result: unknown }
  'github:auth-cancel': { args: [string]; result: unknown }
  'github:auth-disconnect': { args: [string]; result: unknown }
}

export interface GitHubToolsDeps {
  call: ChannelCall<GitHubChannels>
}

/** Longest `wait` holds the call open for the person to finish at github.com. */
export const SIGN_IN_WAIT_MS = 120_000

const CONNECT_VERBS = ['connect', 'wait', 'cancel', 'disconnect'] as const

function knownFolder(context: ToolContext, folder: string): string {
  const open = new Set<string>()
  for (const project of context.surface.listProjects()) open.add(project.path)
  for (const session of context.surface.listSessions()) open.add(session.cwd)
  if (open.has(folder)) return folder
  throw new Refused(
    'not-permitted',
    `${folder} is not a folder this app has open. Use projects.list to see the folders you can ask about.`,
  )
}

/**
 * The sign-in state, with a waiting device code taken out.
 *
 * The code is a one-time door, and the rule for those is that only an `alter`
 * call hands one over — the call a person approved. A plain read that happened
 * to land while a sign-in was waiting would otherwise give it to whoever asked.
 * `github.connect` returns it to the turn that started the sign-in.
 */
export function withoutCode(state: unknown): unknown {
  if (typeof state !== 'object' || state === null) return state
  const pending = (state as { pending?: unknown }).pending
  if (typeof pending !== 'object' || pending === null) return state
  return { ...state, pending: { ...pending, userCode: '(shown in the app, and to the call that started it)' } }
}

export function gitHubTools(deps: GitHubToolsDeps): ToolSpec[] {
  const look: ToolSpec = {
    id: 'github.look',
    wire: 'github_look',
    tier: 'read',
    title: 'Read GitHub for a project',
    description:
      'What GitHub says about the repository behind one of this app’s project folders: the repository, open pull ' +
      'requests and their checks, and whether this app is signed in to GitHub and as whom. Answers from a short ' +
      'cache; set refresh true to ask GitHub again. Use projects.list for the folders.',
    index: 'The GitHub repository, pull requests, checks and sign-in for one of this app’s project folders.',
    inputSchema: {
      type: 'object',
      properties: {
        folder: { type: 'string', description: 'A project folder, from projects.list.' },
        refresh: { type: 'boolean', description: 'Ask GitHub again rather than answering from the cache. Default false.' },
      },
      required: ['folder'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Reading GitHub')
      knownFolder(context, str(args, 'folder'))
    },
    summary: (args) => `Read GitHub for ${optStr(args, 'folder') ?? '?'}`,
    run: async (args, context): Promise<ToolOutput> => {
      const folder = knownFolder(context, str(args, 'folder'))
      const refresh = optBool(args, 'refresh', false)
      // The cache cleared first, as the panel's own refresh does, so a refresh
      // cannot be answered by the very cache it was asked to look past.
      if (refresh) await deps.call('github:clear-cache', folder)
      const [repo, overview, signedIn] = await Promise.all([
        deps.call('github:repo', folder),
        deps.call(refresh ? 'github:refresh' : 'github:overview', folder),
        deps.call('github:auth-status', folder),
      ])
      return { value: { folder, repo, overview, signedIn: withoutCode(signedIn) }, summary: { folder, refresh } }
    },
  }

  const connect: ToolSpec = {
    id: 'github.connect',
    wire: 'github_connect',
    tier: 'alter',
    title: 'Sign this app in to GitHub, or out',
    description:
      'This app’s own GitHub sign-in. Every call asks the person first. do: "connect" starts a sign-in and returns ' +
      'a short code and the github.com address where the person types it; "wait" then waits (up to two minutes ' +
      'per call) for them to finish and returns the new state; "cancel" abandons a sign-in that is waiting; ' +
      '"disconnect" signs this app out of GitHub. folder is optional and only decides which repository the answer ' +
      'describes.',
    index: 'Sign this app in to or out of GitHub; returns the code to type at github.com.',
    inputSchema: {
      type: 'object',
      properties: {
        do: { type: 'string', enum: [...CONNECT_VERBS] },
        folder: { type: 'string', description: 'A project folder, for which repository the answer describes.' },
      },
      required: ['do'],
      additionalProperties: false,
    },
    precheck: (args, context) => {
      hereOnly(context.caller, 'Signing this app in to GitHub')
      oneOf(args, 'do', CONNECT_VERBS)
      const folder = optStr(args, 'folder')
      if (folder !== null) knownFolder(context, folder)
    },
    summary: (args) => {
      switch (verbOf(args)) {
        case 'connect':
          return 'Start signing this app in to GitHub'
        case 'wait':
          return 'Wait for the GitHub sign-in to finish'
        case 'cancel':
          return 'Cancel the GitHub sign-in that is waiting'
        default:
          return 'Sign this app out of GitHub'
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const verb = oneOf(args, 'do', CONNECT_VERBS)
      const folder = optStr(args, 'folder') ?? ''
      if (verb === 'connect') {
        const prompt = await deps.call('github:auth-connect')
        return {
          value: {
            prompt,
            note: 'Ask the person to open the address and type the code, then call this with do "wait".',
          },
          // The code is for the person; it stays out of the record.
          summary: { started: true },
        }
      }
      if (verb === 'wait') {
        /*
         * Raced against a ceiling, because the flow itself waits as long as
         * GitHub's code lives — about fifteen minutes — and a tool call held
         * open that long is a call the client has given up on. Losing the race
         * cancels nothing: the sign-in carries on, and the next `wait` picks it
         * up where this one let go.
         */
        let timer: ReturnType<typeof setTimeout> | undefined
        const ceiling = new Promise<null>((resolve) => {
          timer = setTimeout(() => resolve(null), SIGN_IN_WAIT_MS)
          timer.unref?.()
        })
        const state = await Promise.race([deps.call('github:auth-await', folder), ceiling])
        clearTimeout(timer)
        if (state === null) {
          return {
            value: { finished: false, note: 'Not finished yet. The code is still waiting at github.com; call wait again.' },
            summary: { finished: false },
          }
        }
        return { value: { finished: true, state }, summary: { finished: true } }
      }
      const state = await deps.call(verb === 'cancel' ? 'github:auth-cancel' : 'github:auth-disconnect', folder)
      return { value: { state }, summary: { verb } }
    },
  }

  return [look, connect]
}

export const GITHUB_TOOL_IDS = ['github.look', 'github.connect'] as const
