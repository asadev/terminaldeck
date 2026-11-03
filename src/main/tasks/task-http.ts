/**
 * The task API as plain web requests, for a CRM on this Mac.
 *
 *   POST /tasks                          create
 *   GET  /tasks/<externalTaskId>         read
 *   GET  /tasks/<externalTaskId>/result  result
 *   POST /tasks/<externalTaskId>/assign | /cancel | /comments | /status
 *
 * `Authorization: Bearer <access key>`, the same key the CRM's connection is
 * made for. Served by the deck-control server, so loopback only and never with
 * an `Origin` header, like everything else there. From the internet the same
 * operations are MCP tools through the relay (`task-tools.ts`); the relay
 * carries MCP and nothing else, and widening it is a server change this does
 * not make.
 *
 * Answers are JSON. A refusal is a 4xx with `{"error":{"code","message"}}`;
 * everything accepted, ignored or repeated is a 200 with what happened.
 */

import type { ApiAnswer, ApiCode, TaskApi } from './task-api'

export interface TaskHttpRequest {
  method: string
  path: string
  authorization: string | undefined
  body: string
}

export interface TaskHttpAnswer {
  status: number
  body: unknown
}

export type TaskHttpHandler = (request: TaskHttpRequest) => Promise<TaskHttpAnswer>

const STATUS_OF: Record<ApiCode, number> = {
  disabled: 403,
  not_allowed: 403,
  folder_not_allowed: 403,
  not_mine: 409,
  too_many_hops: 409,
  not_found: 404,
  bad_request: 400,
}

function refused(code: ApiCode | 'unauthorized' | 'no_route', message: string, status: number): TaskHttpAnswer {
  return { status, body: { error: { code, message } } }
}

function answerOf(answer: ApiAnswer): TaskHttpAnswer {
  return answer.ok ? { status: 200, body: answer.value } : refused(answer.code, answer.message, STATUS_OF[answer.code])
}

export function taskHttpHandler(deps: {
  api(): TaskApi | null
  /** The access key's id for a bearer token, or null. */
  keyOf(authorization: string | undefined): string | null
}): TaskHttpHandler {
  return async (request) => {
    const api = deps.api()
    if (api === null) return refused('no_route', 'CRM tasks are not running on this computer right now.', 503)
    const keyId = deps.keyOf(request.authorization)
    if (keyId === null) return refused('unauthorized', 'A valid access key is required.', 403)
    const parts = request.path.split('/').filter((part) => part !== '').map((part) => decodeURIComponent(part))
    if (parts[0] !== 'tasks' || parts.length > 3) return refused('no_route', 'There is no such task route.', 404)
    let body: Record<string, unknown> = {}
    if (request.method === 'POST') {
      try {
        const parsed: unknown = request.body === '' ? {} : JSON.parse(request.body)
        if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('not an object')
        body = parsed as Record<string, unknown>
      } catch {
        return refused('bad_request', 'The body has to be a JSON object.', 400)
      }
    }
    const externalTaskId = parts[1]
    const withId = externalTaskId === undefined ? body : { ...body, externalTaskId }
    const route = `${request.method} ${parts.length === 1 ? '' : parts.length === 2 ? ':id' : `:id/${parts[2]}`}`
    switch (route) {
      case 'POST ':
        return answerOf(await api.create(keyId, body))
      case 'GET :id':
        return answerOf(api.read(keyId, withId))
      case 'GET :id/result':
        return answerOf(api.result(keyId, withId))
      case 'POST :id/assign':
        return answerOf(await api.assign(keyId, withId))
      case 'POST :id/cancel':
        return answerOf(await api.cancel(keyId, withId))
      case 'POST :id/comments':
        return answerOf(await api.comment(keyId, withId))
      case 'POST :id/status':
        return answerOf(await api.status(keyId, withId))
      default:
        return refused('no_route', 'There is no such task route.', 404)
    }
  }
}
