import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  artifactPreviews,
  contentTypeFor,
  rangeFor,
  segmentsOf,
  type ArtifactPreviews,
} from './artifact-preview'

/**
 * The preview server, over a real socket against a real folder.
 *
 * Everything here goes through `fetch`, deliberately. What this module has to
 * be right about is what a **browser** sees — a status, a `Content-Type`, a
 * redirect it will follow, a range a `<video>` asked for — and the only way to
 * be sure of any of those is to ask it the way a browser asks. Reaching inside
 * for the handler would test the code and not the contract, and the contract is
 * the thing a `WKWebView` on somebody's phone depends on.
 *
 * `announce` is stubbed to nothing: the real one forces a `lsof` scan so that
 * `remote/tunnel.ts` will dial the port, and spawning a process per case would
 * make this suite slower than the feature.
 */

let root = ''
let previews: ArtifactPreviews

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'deck-preview-'))
  await mkdir(join(root, 'demo'), { recursive: true })
  await writeFile(join(root, 'demo', 'index.html'), '<h1>hi</h1><script src="app.js"></script>')
  await writeFile(join(root, 'demo', 'app.js'), 'console.log(1)')
  await writeFile(join(root, 'demo', 'shot.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]))
  await writeFile(join(root, 'secrets.txt'), 'top')
  previews = artifactPreviews({ announce: async () => {} })
})

afterEach(async () => {
  previews.stopAll()
  await rm(root, { recursive: true, force: true })
})

/** `http://127.0.0.1:<port>/<path>` — the address the phone builds. */
function at(port: number, path: string): string {
  return `http://127.0.0.1:${port}${path}`
}

describe('what a request may name', () => {
  it('refuses a walk out of the root rather than tidying it away', () => {
    // Refused, not dropped: dropping a `..` answers a different question from
    // the one that was asked as though it were the same one.
    expect(segmentsOf('/a/../b')).toBeNull()
    expect(segmentsOf('/a/%2e%2e/b')).toBeNull()
    expect(segmentsOf('/a%00b')).toBeNull()
    expect(segmentsOf('/a/%2fetc/passwd')).toBeNull()
    expect(segmentsOf('relative')).toBeNull()
    expect(segmentsOf('/a/%zz')).toBeNull()
  })

  it('decodes a segment and keeps the empty ones out', () => {
    expect(segmentsOf('/s/demo//index.html')).toEqual(['s', 'demo', 'index.html'])
    expect(segmentsOf('/s/design%20notes/read%20me.md')).toEqual([
      's',
      'design notes',
      'read me.md',
    ])
    expect(segmentsOf('/')).toEqual([])
  })
})

describe('what a browser is told a file is', () => {
  it('names the types a browser renders and refuses to guess at the rest', () => {
    expect(contentTypeFor('/x/index.html')).toBe('text/html; charset=utf-8')
    expect(contentTypeFor('/x/logo.PNG')).toBe('image/png')
    expect(contentTypeFor('/x/clip.mp4')).toBe('video/mp4')
    expect(contentTypeFor('/x/paper.pdf')).toBe('application/pdf')
    // Unknown is not text. A browser handed `text/plain` for a database file
    // paints a screen of replacement characters.
    expect(contentTypeFor('/x/app.sqlite')).toBe('application/octet-stream')
    expect(contentTypeFor('/x/Makefile')).toBe('application/octet-stream')
  })
})

describe('ranges', () => {
  it('reads the one shape a media element sends', () => {
    expect(rangeFor(undefined, 100)).toBe('whole')
    expect(rangeFor('bytes=0-', 100)).toEqual({ start: 0, end: 99 })
    expect(rangeFor('bytes=10-19', 100)).toEqual({ start: 10, end: 19 })
    // Past the end is clamped; a player asks for more than is there on the last
    // chunk of every file.
    expect(rangeFor('bytes=90-200', 100)).toEqual({ start: 90, end: 99 })
    expect(rangeFor('bytes=-20', 100)).toEqual({ start: 80, end: 99 })
  })

  it('refuses one it cannot satisfy instead of quietly sending the whole file', () => {
    // A player told 200 when it asked for a range stops seeking.
    expect(rangeFor('bytes=200-', 100)).toBe('unsatisfiable')
    expect(rangeFor('bytes=20-10', 100)).toBe('unsatisfiable')
    expect(rangeFor('bytes=', 100)).toBe('unsatisfiable')
    // Multipart is not refused — it is answered whole, which is legal.
    expect(rangeFor('bytes=0-1,4-5', 100)).toBe('whole')
  })
})

describe('serving a project', () => {
  it('serves a page and its siblings from one origin', async () => {
    const { port, secret } = await previews.serve(root)

    const page = await fetch(at(port, `/${secret}/demo/index.html`))
    expect(page.status).toBe(200)
    expect(page.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(await page.text()).toContain('<h1>hi</h1>')

    // The whole reason this is a server: the page's own relative `app.js`
    // resolves against the origin it was loaded from.
    const script = await fetch(at(port, `/${secret}/demo/app.js`))
    expect(script.status).toBe(200)
    expect(script.headers.get('content-type')).toBe('text/javascript; charset=utf-8')
  })

  it('hands over real bytes for an image, which the file frame cannot', async () => {
    const { port, secret } = await previews.serve(root)
    const answer = await fetch(at(port, `/${secret}/demo/shot.png`))

    expect(answer.status).toBe(200)
    expect(answer.headers.get('content-type')).toBe('image/png')
    expect(new Uint8Array(await answer.arrayBuffer())).toEqual(
      new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]),
    )
  })

  it('answers a range with 206 and the range it sent', async () => {
    const { port, secret } = await previews.serve(root)
    const answer = await fetch(at(port, `/${secret}/demo/shot.png`), {
      headers: { range: 'bytes=2-4' },
    })

    expect(answer.status).toBe(206)
    expect(answer.headers.get('content-range')).toBe('bytes 2-4/8')
    expect(answer.headers.get('content-length')).toBe('3')
    expect(new Uint8Array(await answer.arrayBuffer())).toEqual(new Uint8Array([0x4e, 0x47, 0]))
  })

  it('sends a token to the file it names, so relative URLs resolve from there', async () => {
    const { port, secret } = await previews.serve(root)
    previews.link(root, 'demo/index.html', 'demo/index.html')

    const hop = await fetch(at(port, `/${secret}/~/demo%2Findex.html`), { redirect: 'manual' })
    expect(hop.status).toBe(302)
    expect(hop.headers.get('location')).toBe(`/${secret}/demo/index.html`)

    const followed = await fetch(at(port, `/${secret}/~/demo%2Findex.html`))
    expect(followed.url).toBe(at(port, `/${secret}/demo/index.html`))
    expect(await followed.text()).toContain('app.js')
  })

  it('serves a folder as its index and never as a listing', async () => {
    const { port, secret } = await previews.serve(root)

    expect((await fetch(at(port, `/${secret}/demo/`))).status).toBe(200)
    // The project root has no index. A generated listing would make this a file
    // browser for the whole project for anything on the machine that learned
    // the secret.
    const bare = await fetch(at(port, `/${secret}/`))
    expect(bare.status).toBe(404)
    expect(await bare.text()).not.toContain('secrets.txt')
  })

  it('drops the query, which belongs to the page rather than to the file', async () => {
    const { port, secret } = await previews.serve(root)
    const answer = await fetch(at(port, `/${secret}/demo/index.html?tab=two#top`))
    expect(answer.status).toBe(200)
  })
})

describe('what it will not serve', () => {
  it('answers the same 404 for a wrong secret as for a missing file', async () => {
    const { port, secret } = await previews.serve(root)

    const wrong = await fetch(at(port, '/not-the-secret/demo/index.html'))
    const missing = await fetch(at(port, `/${secret}/demo/nothing.html`))
    // Identical, on purpose: a local process probing this port must not be able
    // to tell the two apart and walk the difference into a directory listing.
    expect(wrong.status).toBe(404)
    expect(missing.status).toBe(404)
    expect(await wrong.text()).toBe(await missing.text())
  })

  it('refuses a walk out of the root, and a link that points out of it', async () => {
    await symlink('/etc/passwd', join(root, 'demo', 'escape'))
    const { port, secret } = await previews.serve(root)

    expect((await fetch(at(port, `/${secret}/../secrets.txt`))).status).toBe(404)
    // The case a string comparison of the joined path misses, which is why both
    // sides are `realpath`ed.
    expect((await fetch(at(port, `/${secret}/demo/escape`))).status).toBe(404)
  })

  it('answers only GET and HEAD', async () => {
    const { port, secret } = await previews.serve(root)

    const head = await fetch(at(port, `/${secret}/demo/app.js`), { method: 'HEAD' })
    expect(head.status).toBe(200)
    expect(head.headers.get('content-length')).toBe('14')

    const posted = await fetch(at(port, `/${secret}/demo/app.js`), { method: 'POST' })
    expect(posted.status).toBe(405)
    expect(posted.headers.get('allow')).toBe('GET, HEAD')
  })
})

describe('its lifetime', () => {
  it('serves one root once, however many times it is asked', async () => {
    const first = await previews.serve(root)
    const again = await previews.serve(root)

    // Two prototypes in one project are one server — and one origin, which is
    // what makes a relative `../shared/app.css` between them resolve.
    expect(again).toEqual(first)
    expect(previews.current(root)).toEqual(first)
  })

  it('closes the least recently used root rather than refusing a fifth', async () => {
    const roots: string[] = []
    for (let index = 0; index < 5; index += 1) {
      const folder = await mkdtemp(join(tmpdir(), 'deck-preview-many-'))
      roots.push(folder)
      await previews.serve(folder)
    }

    // The first is gone and the four newest are up. Refusing the fifth would be
    // a *Run it* that stops working after the fourth project of the day with
    // nothing on screen saying why.
    expect(previews.current(roots[0])).toBeNull()
    for (const folder of roots.slice(1)) expect(previews.current(folder)).not.toBeNull()
    for (const folder of roots) await rm(folder, { recursive: true, force: true })
  })

  it('stops answering once it is stopped', async () => {
    const { port, secret } = await previews.serve(root)
    expect((await fetch(at(port, `/${secret}/demo/app.js`))).status).toBe(200)

    previews.stop(root)
    expect(previews.current(root)).toBeNull()
    await expect(fetch(at(port, `/${secret}/demo/app.js`))).rejects.toThrow()
  })
})
