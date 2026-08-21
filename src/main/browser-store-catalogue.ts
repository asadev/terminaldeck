import type { StoreCatalogue, StoreEntry } from './browser-store'

/**
 * The tools this store offers. One table, and nothing is offered that is not in
 * it.
 *
 * ## Why the table is in the app rather than fetched
 *
 * This is the supply-chain answer, and it is the same argument
 * `deck-control/session-tools.ts` makes about `SESSION_TOOLS`, one layer down:
 *
 *   > *"the list is written out rather than derived … derivation would mean a
 *   > seventh tool added to that file one day silently becoming something every
 *   > session on the machine could call. A grant is a thing somebody writes
 *   > down."*
 *
 * A store that fetched its own catalogue would be a store whose contents can be
 * changed by whoever serves that file, and every review of every entry would be
 * a review of a snapshot. So the catalogue is compiled into this app: adding a
 * tool is a change to this repository, and the **sha256 beside each entry is in
 * the app's own bytes**. That digest is what makes a fetched artifact verifiable
 * at all — nothing downloaded ever gets to say what it should hash to.
 *
 * ## Why every entry here is bundled tonight, and what that does not mean
 *
 * `browser-store.ts` implements both source kinds and both go through the same
 * verifier; `browser-store.test.ts` drives a `fetched` entry end to end,
 * including the wrong-length, wrong-digest and wrong-schema refusals. What is
 * missing is not the code, it is a **published registry** — nobody publishes
 * recipes in this format yet, and pinning a digest against a third party's file
 * that they can change at will would be pinning a promise nobody made. A
 * catalogue entry pointing at a URL that will drift or 404 is precisely the
 * control that looks like it works and does not.
 *
 * So the fetch path is real and exercised, and the day there is a registry the
 * change is a row in this table rather than a feature.
 *
 * ## What is deliberately absent
 *
 * A recipe for any particular website. They are the most useful thing this
 * format can hold and they are also the thing that cannot be shipped untested: a
 * recipe whose selectors were written from memory returns empty fields on the
 * real page, and an extractor that returns nothing looks exactly like a page
 * with nothing on it. Every entry below is a **convention** — `<article>`,
 * `srcset`, `rel=next`, JSON-LD — that pages declare on purpose, so where it is
 * absent the empty answer is the true one.
 */
/**
 * `page-images` — the recipe, verbatim.
 *
 * The direct repair for two numbers. **16,498 floor plans lost**, because
 * images were blocked to make a crawl faster, so lazy-loading never fired and
 * the real URLs were never revealed — this reads the lazy attributes whether or
 * not the loader ever ran. And **62,000 images taken at a 498-pixel preview**
 * when the 1920-pixel original was one path segment away — this returns every
 * candidate the page declares, with the width each one claims, and picks none of
 * them.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_IMAGES = `{
  "id": "page-images",
  "name": "Full-size images",
  "summary": "Every image URL a page offers, widest first, with nothing chosen for you.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "images",
      "selector": "img",
      "op": "image",
      "all": true
    },
    {
      "name": "picture_sources",
      "selector": "picture source",
      "op": "image",
      "all": true
    },
    {
      "name": "open_graph_image",
      "selector": "meta[property='og:image']",
      "op": "attribute",
      "attribute": "content"
    }
  ],
  "stated": {
    "name": "images_on_page",
    "selector": "img",
    "op": "count"
  }
}
`

/**
 * `page-data` — the recipe, verbatim.
 *
 * The highest-value target on a modern listing page and the least brittle:
 * a site redesign moves every selector and usually leaves the JSON-LD alone.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_DATA = `{
  "id": "page-data",
  "name": "Structured data",
  "summary": "The JSON-LD, OpenGraph and microdata a page publishes about itself.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "structured",
      "selector": "",
      "op": "data"
    },
    {
      "name": "canonical",
      "selector": "link[rel='canonical']",
      "op": "attribute",
      "attribute": "href"
    },
    {
      "name": "headline",
      "selector": "h1",
      "op": "text"
    }
  ]
}
`

/**
 * `page-links` — the recipe, verbatim.
 *
 * Absolute, always. A crawl that kept a relative href is a crawl that
 * eventually fetches the wrong host. The next-page link is what an orchestrator
 * outside this app walks a result set with — *"the orchestration can live
 * outside"*.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_LINKS = `{
  "id": "page-links",
  "name": "Links and pagination",
  "summary": "Every link on the page, made absolute, and the link to the next page.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "links",
      "selector": "a[href]",
      "op": "link",
      "all": true
    },
    {
      "name": "link_text",
      "selector": "a[href]",
      "op": "text",
      "all": true
    }
  ],
  "stated": {
    "name": "links_on_page",
    "selector": "a[href]",
    "op": "count"
  },
  "next": "a[rel='next'], link[rel='next'], [aria-label='Next'], .pagination a.next"
}
`

/**
 * `page-tables` — the recipe, verbatim.
 *
 * It names its own total: `rows_on_page` counts every row the page has, and
 * the result says how many came back beside it. A table read under a limit that
 * silently returned the first two hundred rows is the seven-per-cent bug with a
 * smaller number on it.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_TABLES = `{
  "id": "page-tables",
  "name": "Tables as rows",
  "summary": "Every table row on the page, cell by cell, ready to be written out as a sheet.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "headings",
      "selector": "table th",
      "op": "text",
      "all": true
    }
  ],
  "rows": {
    "selector": "table tr",
    "fields": [
      {
        "name": "cells",
        "selector": "th, td",
        "op": "text",
        "all": true
      }
    ]
  },
  "stated": {
    "name": "rows_on_page",
    "selector": "table tr",
    "op": "count"
  }
}
`

/**
 * `page-article` — the recipe, verbatim.
 *
 * Conventions rather than heuristics: `<article>`, `<h1>`, `<time datetime>`
 * and `rel=author` are what pages actually declare. Where a page declares none of
 * them the fields come back empty, which is the true answer — a tool that guessed
 * would return somebody's navigation menu as an article.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_ARTICLE = `{
  "id": "page-article",
  "name": "Article text",
  "summary": "The headline, byline, date and readable body of an article page.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "headline",
      "selector": "h1",
      "op": "text"
    },
    {
      "name": "byline",
      "selector": "[rel='author'], [itemprop='author'], .byline",
      "op": "text"
    },
    {
      "name": "published",
      "selector": "time[datetime]",
      "op": "attribute",
      "attribute": "datetime"
    },
    {
      "name": "body",
      "selector": "article, main, [role='main']",
      "op": "text"
    },
    {
      "name": "paragraphs",
      "selector": "article p, main p",
      "op": "text",
      "all": true
    }
  ]
}
`

/**
 * `page-feeds` — the recipe, verbatim.
 *
 * Where a crawl should have started. A page that declares a feed is a page
 * offering its own index, and reading that is cheaper and more complete than
 * walking its HTML.
 *
 * The bytes below are what the entry's digest is over, so an edit here without
 * an edit to that digest is caught by `browser-store-catalogue.test.ts` before
 * it can reach anybody's disk.
 */
const PAGE_FEEDS = `{
  "id": "page-feeds",
  "name": "Feeds and sitemaps",
  "summary": "The feeds, canonical address and paging links a page declares in its head.",
  "version": "1.0.0",
  "grants": [
    "page-read"
  ],
  "origins": [
    "*"
  ],
  "fields": [
    {
      "name": "feeds",
      "selector": "link[rel='alternate'][type*='xml']",
      "op": "link",
      "all": true
    },
    {
      "name": "canonical",
      "selector": "link[rel='canonical']",
      "op": "link"
    },
    {
      "name": "previous_page",
      "selector": "link[rel='prev']",
      "op": "link"
    },
    {
      "name": "next_page",
      "selector": "link[rel='next']",
      "op": "link"
    }
  ],
  "next": "link[rel='next']"
}
`

/* ------------------------------------------------------------- the table -- */

export const BROWSER_TOOL_CATALOGUE: StoreCatalogue = Object.freeze<StoreEntry[]>([
  {
    id: 'page-images',
    name: 'Full-size images',
    summary: 'Every image URL a page offers, widest first, with nothing chosen for you.',
    homepage: 'https://developer.mozilla.org/docs/Web/HTML/Element/img',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_IMAGES },
    sha256: '7e5f266ec50bf32931cd23f893074be0702f531152eb4ebe6f3ba752499d8186',
  },
  {
    id: 'page-data',
    name: 'Structured data',
    summary: 'The JSON-LD, OpenGraph and microdata a page publishes about itself.',
    homepage: 'https://json-ld.org',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_DATA },
    sha256: '12b4c6d8be05c234b529592348b193be3fd32f46fa1d92408a3f72915b347b76',
  },
  {
    id: 'page-links',
    name: 'Links and pagination',
    summary: 'Every link on the page, made absolute, and the link to the next page.',
    homepage: 'https://developer.mozilla.org/docs/Web/HTML/Attributes/rel',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_LINKS },
    sha256: '6785089e8e6b8a56f5595dc8d1e0f8dff35d5b3d7f487a97743acdf068c80999',
  },
  {
    id: 'page-tables',
    name: 'Tables as rows',
    summary: 'Every table row on the page, cell by cell, ready to be written out as a sheet.',
    homepage: 'https://developer.mozilla.org/docs/Web/HTML/Element/table',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_TABLES },
    sha256: '9b5f55208be6504d0b11029f05554c46dd1ddd19f182d2dca77c7a904e89e7f9',
  },
  {
    id: 'page-article',
    name: 'Article text',
    summary: 'The headline, byline, date and readable body of an article page.',
    homepage: 'https://developer.mozilla.org/docs/Web/HTML/Element/article',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_ARTICLE },
    sha256: '7baf383d93c89f7266bfd6ff23118babc15b8420b98610d3439e1f274dda7ba8',
  },
  {
    id: 'page-feeds',
    name: 'Feeds and sitemaps',
    summary: 'The feeds, canonical address and paging links a page declares in its head.',
    homepage: 'https://www.rfc-editor.org/rfc/rfc5005',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    source: { kind: 'bundled', text: PAGE_FEEDS },
    sha256: 'e5f16e40f950038a1a50815fb7ea20b0830d25c83d57acfd565afb69c3b7467f',
  },
])
