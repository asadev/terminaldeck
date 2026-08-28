import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/…' — see the note in `bridge.ts`.
import { KIND_NAMES, type ManifestAgent } from '../../shared/store-manifest'
import { PageEmpty } from '../components/PageEmpty'
import { panelSpec } from '../shell/panels'
import { StoreDetail } from '../store/StoreDetail'
import { StoreFilterBar } from '../store/StoreFilterBar'
import { withoutShelf } from '../store/store-nav'
import {
  facetControls,
  filtering,
  matchesFilter,
  NO_FILTER,
  shelve,
  withFacet,
  type StoreFacet,
  type StoreFacets,
  type StoreFilter,
} from '../store/storefront'
import {
  catalogueDate,
  COMMUNITY_FACETS,
  COMMUNITY_SHELVES,
  communityFacets,
  installable,
  NO_COMMUNITY,
  readCommunityResult,
  readCommunityView,
  type CommunityApi,
  type CommunityItem,
  type CommunityView,
} from './bridge'
import { CommunityRow } from './CommunityRow'
import { InstallSheet } from './InstallSheet'
import './community.css'

/**
 * The store's third department: things other people published.
 *
 * ## Why it is a department and not a second store
 *
 * `store/storefront.ts` spends its header on the argument, and this is the third
 * catalogue it has had to hold: the deciding — what a search matches, which
 * chips are worth drawing, what a shelf holds, when a control is not drawn at
 * all — happens once, over `StoreFacets`, and a department's whole job is to
 * translate its own rows into that shape. `bridge.ts` holds this one's
 * translator, and it is the only per-department code involved in searching or
 * filtering anything.
 *
 * So the page's one search box searches this too, the rail counts its shelves
 * beside the other two, and the empty states are the ones the page already
 * writes. Nothing about the two existing departments changes.
 *
 * ## The shelves are the kinds
 *
 * Somebody browsing a community store is looking for *skills*, or for *hooks* —
 * the kind is what they are shopping by, so the kind is the shelf and the
 * category becomes a facet like any other. `store-nav.ts` drops the ones with
 * nothing on them, so a catalogue of four skills draws one shelf and not seven
 * headings over six empty grids.
 *
 * ## Loading, and why the body is split out
 *
 * The container loads through effects, which SSR never runs, so a test that
 * rendered *it* would be asserting on an empty shell — the *"proof by a function
 * nothing calls"* this store has been audited for once already. {@link
 * CommunityBody} is what a person reads, and it is pure.
 */

/* --------------------------------------------------------------- container -- */

interface Props {
  api: CommunityApi
  filter: StoreFilter
  onFilter(next: StoreFilter): void
  /** The prefixed key of the row being read on its own, or `''`. */
  detail: string
  onDetail(key: string): void
  /** What this department found, for the page's rail. */
  onRows(rows: StoreFacets[]): void
}

export function CommunityDepartment({ api, filter, onFilter, detail, onDetail, onRows }: Props) {
  const [view, setView] = useState<CommunityView>(NO_COMMUNITY)
  const [loaded, setLoaded] = useState(false)
  /** The row with something in flight, so its button can say so. */
  const [busy, setBusy] = useState('')
  /** Row id → the sentence the last action on that row produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  /** The row whose pre-install sheet is open, or `''`. */
  const [sheet, setSheet] = useState('')
  /**
   * Which agents are ticked in the sheet.
   *
   * Held here rather than inside the sheet so that a re-read of the catalogue —
   * which happens after every install and every remove — cannot quietly reset a
   * choice somebody made a moment ago.
   */
  const [chosen, setChosen] = useState<readonly ManifestAgent[]>([])

  const load = useCallback(async () => {
    if (!api.community) return
    try {
      setView(readCommunityView(await api.community()))
    } catch (error) {
      setView({
        ...NO_COMMUNITY,
        problem: error instanceof Error ? error.message : 'The catalogue could not be read.',
      })
    }
  }, [api])

  useEffect(() => {
    void load().then(() => setLoaded(true))
  }, [load])

  /*
   * Tell the page what is on the shelves whenever the view changes.
   *
   * Keyed on the view rather than on a derived array: a fresh array in the
   * dependency list is a new value every render, and the page would re-render
   * this component for ever.
   */
  useEffect(() => {
    onRows(view.items.map(communityFacets))
  }, [view, onRows])

  /**
   * One write, whichever it was, with the answer kept on the row.
   *
   * `answer` is a thunk rather than a channel name so that the two calls keep
   * their own argument lists — an install carries the agents somebody ticked and
   * a remove carries nothing, and a signature wide enough for both would be a
   * signature that lets one be called with the other's arguments.
   */
  const act = useCallback(
    async (id: string, shutsTheSheet: boolean, answer: () => Promise<unknown>) => {
      setBusy(id)
      try {
        const result = readCommunityResult(await answer())
        setSaid((was) => ({ ...was, [id]: result.message }))
        // Shut the sheet only on success, so a refusal is still on screen with
        // the choice that produced it rather than needing to be set up again.
        if (result.ok && shutsTheSheet) setSheet('')
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Off the disk, not off an assumption about what the call did.
        await load()
      }
    },
    [load],
  )

  const install = useCallback(
    (id: string, agents: readonly ManifestAgent[]) => {
      const call = api.communityInstall
      if (!call) return
      void act(id, true, () => call(id, { agents }))
    },
    [api, act],
  )

  const remove = useCallback(
    (id: string) => {
      const call = api.communityRemove
      if (!call) return
      void act(id, false, () => call(id))
    },
    [api, act],
  )

  /**
   * Open the pre-install sheet, with the honest answer already ticked.
   *
   * The agents that are both on this machine *and* named by the publisher — the
   * intersection, because ticking one the publisher never tested would be this
   * app making a claim on their behalf, and ticking one that is not installed
   * would be an install with nowhere to land.
   */
  const openSheet = useCallback(
    (item: CommunityItem) => {
      setSheet(item.id)
      setChosen(
        view.agents.filter((one) => one.found && item.agents.includes(one.id)).map((one) => one.id),
      )
    },
    [view],
  )

  /**
   * Ask the store again.
   *
   * This *is* `load()`, and deliberately: the main process fetches the catalogue
   * on every `community` call and falls back to the kept copy when it cannot
   * reach it, so there is nothing a separate refresh could do that reading the
   * list again does not. The only thing added here is the busy state, so the
   * button says `Checking…` while a real network call is out.
   */
  const refresh = useCallback(async () => {
    setBusy('catalogue')
    try {
      await load()
    } finally {
      setBusy('')
    }
  }, [load])

  if (!loaded) return null

  /*
   * One row on its own, resolved out of the same list the shelves are drawn
   * from — so a detail view cannot outlive the row it names. An item withdrawn
   * and dropped by a refresh finds nothing here and the page falls back to the
   * shelves rather than framing an empty space.
   */
  const open = view.items.find((one) => `c:${one.id}` === detail)
  if (open) {
    return (
      <StoreDetail backTo={KIND_NAMES[open.kind]} onBack={() => onDetail('')}>
        <ul className="cs-store-list">
          <CommunityRow
            item={open}
            busy={busy === open.id}
            said={said[open.id] ?? ''}
            onInstall={installable(open) ? () => openSheet(open) : undefined}
            onRemove={open.installedVersion === '' ? undefined : () => remove(open.id)}
          />
        </ul>
        <InstallSheet
          open={sheet === open.id}
          item={open}
          agents={view.agents}
          chosen={chosen}
          busy={busy === open.id}
          onChoose={setChosen}
          onClose={() => setSheet('')}
          onConfirm={() => install(open.id, chosen)}
        />
      </StoreDetail>
    )
  }

  const sheetItem = view.items.find((one) => one.id === sheet)

  return (
    <>
      <CommunityBody
        view={view}
        filter={filter}
        busy={busy}
        said={said}
        onFilter={onFilter}
        onOpenRow={onDetail}
        onRefresh={() => void refresh()}
        onInstall={(id) => {
          const item = view.items.find((one) => one.id === id)
          if (item) openSheet(item)
        }}
        onRemove={remove}
      />
      {sheetItem !== undefined && (
        <InstallSheet
          open
          item={sheetItem}
          agents={view.agents}
          chosen={chosen}
          busy={busy === sheetItem.id}
          onChoose={setChosen}
          onClose={() => setSheet('')}
          onConfirm={() => install(sheetItem.id, chosen)}
        />
      )}
    </>
  )
}

/* -------------------------------------------------------------------- body -- */

export interface CommunityBodyProps {
  view: CommunityView
  filter: StoreFilter
  /** The row with something in flight, or `'catalogue'` for a refresh. */
  busy: string
  said: Record<string, string>
  onFilter(next: StoreFilter): void
  /**
   * Open one row on its own, prefixed the way the page mints its keys.
   *
   * Optional, and the rows draw no way in without it — the standing
   * absent-not-disabled rule doing real work rather than ceremony: this body is
   * what the tests render, and a name that looked pressable with nowhere to go
   * would be the dead control this surface is written against.
   */
  onOpenRow?(key: string): void
  onRefresh(): void
  onInstall(id: string): void
  onRemove(id: string): void
}

/**
 * Everything a person reads, as a pure function of the loaded catalogue.
 *
 * The three states worth naming, and each is a real screen rather than an empty
 * grid:
 *
 *  - **A kept list.** Drawn in full, with *Catalogue from 29 August* beside the
 *    controls. Offline is not a reason to hide a shop somebody already has; it
 *    is a reason to say how old the list is.
 *  - **A refusal.** Separate from being offline, on purpose. *"You are offline"*
 *    and *"something served me a list I did not believe"* are opposite problems
 *    and only one of them fixes itself.
 *  - **Nothing at all.** `PageEmpty`, with the store's own mark from
 *    `panelSpec('store')`, saying which of the two it was.
 */
export function CommunityBody({
  view,
  filter,
  busy,
  said,
  onFilter,
  onOpenRow,
  onRefresh,
  onInstall,
  onRemove,
}: CommunityBodyProps) {
  const facets = new Map(view.items.map((one) => [one.id, communityFacets(one)]))
  const facetsOf = (one: CommunityItem): StoreFacets => facets.get(one.id) ?? communityFacets(one)
  const kept = view.items.filter((one) => matchesFilter(facetsOf(one), filter))
  const shelves = shelve(kept, COMMUNITY_SHELVES, facetsOf, () => 0)
  const controls = facetControls([...facets.values()], filter, withoutShelf(COMMUNITY_FACETS))
  const isFiltering = filtering(filter)
  const dated = view.from === 'kept' ? catalogueDate(view.at) : ''

  /*
   * Nothing to show at all, and which of the two it was.
   *
   * Drawn instead of the shelves rather than above them: a filter bar over an
   * empty grid is furniture, and the reason there is nothing here has nothing to
   * do with what was typed.
   */
  if (view.items.length === 0 && view.problem !== '') {
    return (
      <PageEmpty
        icon={panelSpec('store').icon}
        title="Nothing has been fetched yet"
        action={{ label: 'Try again', onClick: onRefresh, busy: busy === 'catalogue' }}
      >
        {view.problem}
      </PageEmpty>
    )
  }

  return (
    <>
      {/*
        What this department is, in one line, and it is the positioning rather
        than an explanation of a control: everything under this heading is
        somebody else's work, and this app is the shelf it is standing on.
      */}
      <p className="cs-store-note">
        Published by other people. Terminal Deck lists them; it does not review, endorse or sell
        them.
      </p>

      {/*
        How old this list is, and — separately — why it could not be made newer.

        Two facts and two sentences, because they are different problems: a list
        from a fortnight ago is still the right list, and a list that was refused
        is a list somebody should know was refused. Both only when true.
      */}
      {(dated !== '' || view.because !== '' || view.stale !== '') && (
        <p className="cs-store-catalogue">
          {dated !== '' && <span className="cs-store-dated">Catalogue from {dated}</span>}
          {view.stale !== '' && <span className="cs-quiet">{view.stale}</span>}
          {view.because !== '' && <span className="cs-error">{view.because}</span>}
          {/* Always present, because the department is not drawn at all unless
              this build can ask again — see `communityAvailable`. */}
          <button
            type="button"
            className="cs-text-button"
            disabled={busy === 'catalogue'}
            onClick={onRefresh}
          >
            {busy === 'catalogue' ? 'Checking…' : 'Check again'}
          </button>
        </p>
      )}

      <StoreFilterBar
        idPrefix="cs"
        /* The page carries the one search box, over all three departments. A
           second box under this heading would search a third of a store while
           looking like it searched the whole thing. */
        search={false}
        filter={filter}
        controls={controls}
        showing={kept.length}
        total={view.items.length}
        active={isFiltering}
        onQuery={(next) => onFilter({ ...filter, query: next })}
        onFacet={(facet: StoreFacet, value) => onFilter(withFacet(filter, facet, value))}
        onClear={() => onFilter(NO_FILTER)}
      />

      {shelves.length === 0 ? (
        <p className="cs-quiet">
          {isFiltering ? 'Nothing here matches that.' : 'There is nothing in this department yet.'}
        </p>
      ) : (
        shelves.map((shelf) => (
          <section key={shelf.id} className="cs-store-section">
            <h3 className="cs-store-heading">{shelf.name}</h3>
            <ul className="cs-store-list">
              {shelf.rows.map((item) => (
                <CommunityRow
                  key={item.id}
                  item={item}
                  busy={busy === item.id}
                  said={said[item.id] ?? ''}
                  onOpen={onOpenRow === undefined ? undefined : () => onOpenRow(`c:${item.id}`)}
                  /* No Install anywhere on an off-site listing — not a disabled
                     one, not a hidden one. The row draws its own way out. */
                  onInstall={installable(item) ? () => onInstall(item.id) : undefined}
                  onRemove={item.installedVersion === '' ? undefined : () => onRemove(item.id)}
                />
              ))}
            </ul>
          </section>
        ))
      )}

      {/* Where the files are, because Remove says they are deleted and a person
          is entitled to go and look. */}
      {view.folder !== '' && (
        <p className="cs-store-note">
          What you install from here is kept in <code>{view.folder}</code>.
        </p>
      )}
    </>
  )
}
