import { readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

/**
 * Every connection checks that the server is the same one as last time.
 *
 * ## Why this is a structural scan and not an exercised path
 *
 * Because the hole it guards is not the connection that exists today. It is the
 * *second* one somebody adds in eight months — a quick reconnect for the
 * copilot, a separate client for file transfer, a health check — written by
 * somebody who has not read `connection.ts`'s header and has no reason to
 * suspect the option is load-bearing. A test that opens a connection and
 * watches it refuse a changed key proves the path it walks and says nothing at
 * all about the path that has not been written yet.
 *
 * So this reads the source. It walks the TypeScript syntax tree of every file
 * in this feature and asserts two things:
 *
 *  1. **Only `connection.ts` may reach the transport at all.** One door.
 *  2. **Every call to `connect(...)` passes `hostVerifier`.** Not "the file
 *     mentions hostVerifier somewhere" — the specific call.
 *
 * The type declaration in `ssh2.d.ts` makes the option required as well, so a
 * forgetful call does not compile. That is the fence; this is the alarm on the
 * fence, because a future author can widen a declaration file without ever
 * realising what it was for.
 *
 * ## Why there is no "connect anyway" button
 *
 * The whole value of the check is that it is not click-through. This
 * repository has already written the argument down in `deck-control/catalogue.ts`:
 * a refusal that arrives after a run of harmless confirmations *"has already
 * trained them to click yes."* A person who is offered a button that makes the
 * warning disappear will press it, and then the check has cost them a dialog
 * and protected nothing. Undoing a recorded identity is a deliberate act on the
 * server's own page, and it says what it means.
 */

const DIR = resolve(__dirname)

const sources = readdirSync(DIR)
  .filter((name) => name.endsWith('.ts') && !name.endsWith('.test.ts') && !name.endsWith('.d.ts'))
  .map((name) => ({
    name,
    text: readFileSync(join(DIR, name), 'utf8'),
  }))

function parse(name: string, text: string): ts.SourceFile {
  return ts.createSourceFile(name, text, ts.ScriptTarget.ES2022, true)
}

/** Every module specifier imported by this file. */
function importsOf(file: ts.SourceFile): string[] {
  const out: string[] = []
  const walk = (node: ts.Node): void => {
    if (
      (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier !== undefined &&
      ts.isStringLiteral(node.moduleSpecifier)
    ) {
      out.push(node.moduleSpecifier.text)
    }
    if (
      ts.isCallExpression(node) &&
      node.expression.kind === ts.SyntaxKind.ImportKeyword &&
      node.arguments.length > 0 &&
      ts.isStringLiteral(node.arguments[0])
    ) {
      out.push((node.arguments[0] as ts.StringLiteral).text)
    }
    ts.forEachChild(node, walk)
  }
  walk(file)
  return out
}

/** Every `…connect(…)` call, with the property names of its object argument. */
function connectCalls(file: ts.SourceFile): { line: number; properties: string[] }[] {
  const out: { line: number; properties: string[] }[] = []
  const walk = (node: ts.Node): void => {
    if (ts.isCallExpression(node)) {
      const callee = node.expression
      const name = ts.isPropertyAccessExpression(callee)
        ? callee.name.text
        : ts.isIdentifier(callee)
          ? callee.text
          : ''
      if (name === 'connect') {
        const argument = node.arguments[0]
        const properties: string[] = []
        if (argument !== undefined && ts.isObjectLiteralExpression(argument)) {
          for (const property of argument.properties) {
            if (property.name !== undefined && ts.isIdentifier(property.name)) {
              properties.push(property.name.text)
            }
          }
        }
        out.push({
          line: file.getLineAndCharacterOfPosition(node.getStart()).line + 1,
          properties,
        })
      }
    }
    ts.forEachChild(node, walk)
  }
  walk(file)
  return out
}

describe('the transport has exactly one door', () => {
  it('is only reached from connection.ts, and from the key reader', () => {
    const reaching = sources
      .filter(({ name, text }) => importsOf(parse(name, text)).includes('ssh2'))
      .map(({ name }) => name)
      .sort()
    // `credentials.ts` is the one other file, and only for `utils.parseKey` —
    // reading a key file, which touches no socket. Anything else appearing here
    // is a second connection path, and a second connection path is the thing
    // this whole file exists to catch.
    expect(reaching).toEqual(['connection.ts', 'credentials.ts'])
  })

  it('constructs a client nowhere but connection.ts', () => {
    // Wider than the import check above and deliberately so: a file could reach
    // the library through a dynamic path, an alias, or a re-export. What it
    // cannot do is build a client without naming the class.
    const constructing = sources
      .filter(({ text }) => /new Client\b/.test(text.replace(/\/\*[\s\S]*?\*\//g, '')))
      .map(({ name }) => name)
    expect(constructing).toEqual(['connection.ts'])
  })

  it('opens no socket from the key reader', () => {
    const credentials = sources.find(({ name }) => name === 'credentials.ts')
    expect(credentials).toBeDefined()
    expect(credentials?.text).not.toMatch(/new Client\b/)
    expect(connectCalls(parse('credentials.ts', credentials?.text ?? ''))).toEqual([])
  })
})

describe('every connection checks the identity', () => {
  it('passes hostVerifier at every single call, not merely somewhere in the file', () => {
    for (const { name, text } of sources) {
      for (const call of connectCalls(parse(name, text))) {
        expect(
          call.properties,
          `${name}:${call.line} connects without checking who answered`,
        ).toContain('hostVerifier')
      }
    }
  })

  it('has a call to check, so that an empty scan cannot pass by accident', () => {
    // A structural test that finds nothing passes, which makes it worthless the
    // day somebody renames the method. This is the guard on the guard.
    const connection = sources.find(({ name }) => name === 'connection.ts')
    expect(connectCalls(parse('connection.ts', connection?.text ?? '')).length).toBeGreaterThan(0)
  })

  it('offers nothing that would let a person click past a changed identity', () => {
    const connection = sources.find(({ name }) => name === 'connection.ts')?.text ?? ''
    // No option that turns the check off, under any of the names it has had in
    // other tools.
    expect(connection).not.toMatch(/strictHostKeyChecking/i)
    expect(connection).not.toMatch(/insecure/i)
    expect(connection).not.toMatch(/skipHostKey/i)
    expect(connection).not.toMatch(/acceptNew/i)
  })

  it('records an identity only when there was not one already', () => {
    // The overwrite is the whole vulnerability: a verifier that remembers
    // whatever it is shown agrees with everything and has checked nothing.
    const store = readFileSync(join(DIR, 'store.ts'), 'utf8')
    expect(store).toMatch(/if \(server === null \|\| server\.hostKey !== null\) return false/)
  })
})
