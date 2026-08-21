import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { captureRoot } from './browser-capture-store'
import { coveragePath, ledgerPath, runDir } from './browser-scrape-paths'
import {
  assetFactsFor,
  captureFactsFor,
  clearCaptureFor,
  clearLedgersFor,
  lastCheckFor,
  noteAssetBatch,
  noteRunProfile,
  resetScrapeStatusForTests,
  runOwnerPath,
  runsFor,
} from './browser-scrape-status'

/**
 * The measured half, and the one rule it exists to keep: **a number is measured
 * or it says nobody counted.**
 *
 * The hardest case is in here on purpose — a profile with one closed capture run
 * and one still open answers `null` for all three counts, not the sum of the one
 * that finished. A partial total presented as the total is what shipped 7% of a
 * dataset as complete.
 */

let dir = ''

function closedRun(profileId: string, runId: string, counts: Record<string, number>, shortfall = ''): void {
  const folder = join(captureRoot(dir), profileId, runId)
  mkdirSync(folder, { recursive: true })
  writeFileSync(join(folder, 'capture.jsonl'), '')
  writeFileSync(
    join(folder, 'capture-summary.json'),
    JSON.stringify({ entries: 0, bodies: 0, lost: 0, tooLarge: 0, overBudget: 0, unfinished: 0, failed: 0, notRequested: 0, bytes: 0, shortfall, ...counts }),
  )
}

/** A run that was armed and never closed — with or without a manifest yet. */
function openRun(profileId: string, runId: string, manifest = true): void {
  const folder = join(captureRoot(dir), profileId, runId)
  mkdirSync(join(folder, 'bodies'), { recursive: true })
  if (manifest) writeFileSync(join(folder, 'capture.jsonl'), '{"n":1}\n')
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-scrape-status-'))
  resetScrapeStatusForTests()
})

afterEach(() => {
  resetScrapeStatusForTests()
  rmSync(dir, { recursive: true, force: true })
})

describe('what a profile has captured', () => {
  it('says nothing at all rather than zero, when it has never captured', () => {
    expect(captureFactsFor(dir, 'work')).toBeNull()
  })

  it('adds up the runs that closed, off their own summaries', () => {
    closedRun('work', 'run-1', { entries: 40, bytes: 1_000 })
    closedRun('work', 'run-2', { entries: 2, bytes: 30, tooLarge: 5 }, 'bodies not kept: 5 over the bound')
    expect(captureFactsFor(dir, 'work')).toEqual({
      recorded: 42,
      bytes: 1_030,
      dropped: 5,
      droppedReason: 'bodies not kept: 5 over the bound',
    })
  })

  it('counts zero dropped as a measurement, because only a store that counted can say it', () => {
    closedRun('work', 'run-1', { entries: 9, bytes: 12 })
    expect(captureFactsFor(dir, 'work')?.dropped).toBe(0)
    expect(captureFactsFor(dir, 'work')?.droppedReason).toBe('')
  })

  it('refuses to total anything while a run is still open', () => {
    closedRun('work', 'run-1', { entries: 40, bytes: 1_000 })
    // No manifest yet: `CaptureStore` does not write one until the first
    // response arrives, and a run armed a second ago is still a run.
    openRun('work', 'run-2', false)
    // Not 40. Nobody has the total yet, and 40 would read as one.
    expect(captureFactsFor(dir, 'work')).toEqual({
      recorded: null,
      bytes: null,
      dropped: null,
      droppedReason: '',
    })
  })

  it('throws away only this profile’s runs, and says how many went', () => {
    closedRun('work', 'run-1', { entries: 1 })
    closedRun('work', 'run-2', { entries: 1 })
    closedRun('personal', 'run-3', { entries: 1 })
    expect(clearCaptureFor(dir, 'work')).toBe(2)
    expect(captureFactsFor(dir, 'work')).toBeNull()
    expect(captureFactsFor(dir, 'personal')?.recorded).toBe(1)
  })

  it('answers zero for a clear that had nothing to clear, rather than claiming one', () => {
    expect(clearCaptureFor(dir, 'work')).toBe(0)
  })
})

describe('whose run is whose', () => {
  it('writes the owner into the run’s own folder, once', () => {
    noteRunProfile(dir, 'run-a', 'work')
    noteRunProfile(dir, 'run-a', 'work')
    expect(existsSync(runOwnerPath(dir, 'run-a'))).toBe(true)
    expect(runsFor(dir, 'work')).toEqual(['run-a'])
    expect(runsFor(dir, 'personal')).toEqual([])
  })

  it('leaves a run nobody named out of every per-profile answer', () => {
    mkdirSync(runDir(dir, 'orphan'), { recursive: true })
    expect(runsFor(dir, 'work')).toEqual([])
  })
})

describe('what a profile has fetched', () => {
  it('says nothing until something measured a batch or wrote a ledger', () => {
    expect(assetFactsFor(dir, 'work')).toBeNull()
  })

  it('adds up the batches this process was told about', () => {
    noteAssetBatch('work', {
      asked: 10,
      fetched: 6,
      skipped: 3,
      failed: 1,
      upgraded: 4,
      bytes: 99,
      fellBack: 2,
      ledgerWasWrong: 0,
    })
    noteAssetBatch('work', {
      asked: 2,
      fetched: 2,
      skipped: 0,
      failed: 0,
      upgraded: 0,
      bytes: 5,
      fellBack: 0,
      ledgerWasWrong: 0,
    })
    expect(assetFactsFor(dir, 'work')).toEqual({
      fetched: 8,
      upgraded: 4,
      fellBack: 2,
      skipped: 3,
      // Nothing wrote a ledger, so the rows are not a number anybody has.
      ledgerEntries: null,
    })
  })

  it('counts the rows in this profile’s ledgers off the files', () => {
    noteRunProfile(dir, 'run-a', 'work')
    mkdirSync(runDir(dir, 'run-a'), { recursive: true })
    writeFileSync(
      ledgerPath(dir, 'run-a'),
      [
        JSON.stringify({ url: 'a', fetchedUrl: 'a', ruleId: '', digest: 'sha256:1', bytes: 1, path: '/a', at: 1 }),
        JSON.stringify({ url: 'b', fetchedUrl: 'b', ruleId: '', digest: 'sha256:2', bytes: 1, path: '/b', at: 2 }),
        // The same URL again: a re-download appends, and the ledger is keyed on
        // the URL, so this is two rows and not three.
        JSON.stringify({ url: 'a', fetchedUrl: 'a', ruleId: '', digest: 'sha256:3', bytes: 1, path: '/a', at: 3 }),
      ].join('\n') + '\n',
    )
    expect(assetFactsFor(dir, 'work')?.ledgerEntries).toBe(2)
    // …and the tallies stay unmeasured, because nothing in this process counted.
    expect(assetFactsFor(dir, 'work')?.fetched).toBeNull()
  })

  it('empties this profile’s ledgers and leaves the files alone', () => {
    noteRunProfile(dir, 'run-a', 'work')
    mkdirSync(runDir(dir, 'run-a'), { recursive: true })
    writeFileSync(ledgerPath(dir, 'run-a'), '{"url":"a","fetchedUrl":"a","ruleId":"","digest":"sha256:1","bytes":1,"path":"/a","at":1}\n')
    writeFileSync(join(runDir(dir, 'run-a'), 'asset.jpg'), 'bytes')
    expect(clearLedgersFor(dir, 'work')).toBe(1)
    expect(existsSync(ledgerPath(dir, 'run-a'))).toBe(false)
    expect(existsSync(join(runDir(dir, 'run-a'), 'asset.jpg'))).toBe(true)
    expect(assetFactsFor(dir, 'work')).toBeNull()
  })
})

describe('the newest coverage check', () => {
  it('is nothing when no run of this profile ever checked itself', () => {
    expect(lastCheckFor(dir, 'work')).toBeNull()
  })

  it('is the newest by its own timestamp, across every run this profile owns', () => {
    noteRunProfile(dir, 'run-a', 'work')
    noteRunProfile(dir, 'run-b', 'work')
    mkdirSync(runDir(dir, 'run-a'), { recursive: true })
    mkdirSync(runDir(dir, 'run-b'), { recursive: true })
    writeFileSync(
      coveragePath(dir, 'run-a'),
      `${JSON.stringify({ verdict: 'short', stated: 340, captured: 300, at: 900, url: 'https://x.test/a' })}\n`,
    )
    writeFileSync(
      coveragePath(dir, 'run-b'),
      `${JSON.stringify({ verdict: 'complete', stated: 12, captured: 12, at: 100, url: 'https://x.test/b' })}\n`,
    )
    expect(lastCheckFor(dir, 'work')).toEqual({
      url: 'https://x.test/a',
      stated: 340,
      got: 300,
      at: 900,
    })
  })

  it('carries a stated total of null through, because that is the verdict nobody may call complete', () => {
    noteRunProfile(dir, 'run-a', 'work')
    mkdirSync(runDir(dir, 'run-a'), { recursive: true })
    writeFileSync(
      coveragePath(dir, 'run-a'),
      `${JSON.stringify({ verdict: 'unknown', stated: null, captured: 40, at: 5, url: '' })}\n`,
    )
    expect(lastCheckFor(dir, 'work')).toEqual({ url: '', stated: null, got: 40, at: 5 })
  })
})
