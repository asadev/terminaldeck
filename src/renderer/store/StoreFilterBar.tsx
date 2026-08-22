import './storefront.css'
import { ANY, type FacetControl, type StoreFacet, type StoreFilter } from './storefront'

/**
 * The browsing controls, once, for both stores.
 *
 * ## Why one component and not two that look alike
 *
 * Because two that look alike is how they stop looking alike. The browser store
 * shipped a search box and a row of category chips; the MCP store shipped
 * neither. The cheap fix was to copy the box across, and the copy would have
 * been the last moment the two agreed: the next person to make search
 * case-insensitive, or to add tags to it, or to stop drawing a chip that
 * filters to nothing, would have done it in one file and not the other, and
 * nobody would have noticed until somebody used both in the same afternoon.
 *
 * ## What it does not decide
 *
 * Anything. Every count, every option and every "should this be drawn at all"
 * answer arrives in {@link FacetControl}, computed by `storefront.ts`. This file
 * is markup and two event handlers, which is why the interesting behaviour is
 * testable without rendering anything.
 *
 * ## The counts are on the chips on purpose
 *
 * A chip that says *Blocking 6* answers "is it worth pressing" before it is
 * pressed. It is also the visible half of the rule the whole bar rests on: a
 * count is never zero, because an option that would leave nothing is not drawn.
 */

interface Props {
  /**
   * What the search box suggests. Each store's own — and optional, because a bar
   * drawn with `search` off has no box to put it in and a placeholder for a
   * control that is not there is a string nobody will ever read.
   */
  placeholder?: string
  /**
   * Whether this bar draws the search box.
   *
   * `false` on the store page, where **one** box searches both departments and
   * each department draws only its own chips. Two boxes on one screen is worse
   * than one in a way that is easy to underrate: the second one looks like it
   * searches the store and searches half of it, and whichever half a person
   * happens to type into decides what they conclude the store contains.
   *
   * The count and the Clear button stay either way. They are per-department
   * truths — *6 of 24* under **Browser extensions** means something the page's
   * own total cannot say — and Clear is the way out of a filter this bar set.
   */
  search?: boolean
  filter: StoreFilter
  /** Every facet worth drawing, from `facetControls`. */
  controls: readonly FacetControl[]
  /** How many rows survive the whole filter, for the summary line. */
  showing: number
  /** How many there are in total, so the summary can say "of". */
  total: number
  /** The class prefix of the store drawing it, so its own skin still applies. */
  idPrefix: string
  onQuery(next: string): void
  onFacet(facet: StoreFacet, value: string): void
  onClear(): void
  /** True when anything at all is filtered, from `filtering()`. */
  active: boolean
}

export function StoreFilterBar({
  placeholder = '',
  search = true,
  filter,
  controls,
  showing,
  total,
  idPrefix,
  onQuery,
  onFacet,
  onClear,
  active,
}: Props) {
  const searchId = `${idPrefix}-storefront-search`
  /*
   * A bar with nothing in it is not drawn at all.
   *
   * It can genuinely happen now that the store page carries the search box and
   * the shelves: a department with two rows that agree about everything has no
   * facet worth a chip, nothing typed and nothing filtered, and what was left
   * here was an empty flex container with a gap under a heading. That is the
   * same "control that does nothing" the whole bar is built around avoiding,
   * just spelled as furniture instead of as a button.
   */
  if (!search && controls.length === 0 && !active) return null
  return (
    <div className="storefront">
      <div className="storefront-top" data-searchless={search ? undefined : true}>
        {search && (
          <label className="storefront-search" htmlFor={searchId}>
            <span className="storefront-search-label">Search</span>
            <input
              id={searchId}
              type="search"
              value={filter.query}
              placeholder={placeholder}
              autoComplete="off"
              spellCheck={false}
              onChange={(event) => onQuery(event.target.value)}
            />
          </label>
        )}
        {/*
          The count, and the way out. Both only once something is filtered: a
          store that says "24 of 24" before anybody has touched it is noise, and
          a Clear button with nothing to clear is a control that does nothing.
        */}
        {active && (
          <div className="storefront-summary">
            <span className="storefront-count">
              {showing} of {total}
            </span>
            <button type="button" className="storefront-clear" onClick={onClear}>
              Clear
            </button>
          </div>
        )}
      </div>

      {controls.map((control) => (
        <div className="storefront-facet" key={control.facet}>
          {/*
            A `fieldset`/`legend` would be the textbook markup and is the wrong
            one here: these are buttons that filter a list already on screen, not
            a form being submitted, and `aria-pressed` on each chip is what
            carries the state. The label is a plain span with the group named on
            the list itself.
          */}
          <span className="storefront-facet-label" id={`${idPrefix}-facet-${control.facet}`}>
            {control.label}
          </span>
          <div
            className="storefront-chips"
            role="group"
            aria-labelledby={`${idPrefix}-facet-${control.facet}`}
          >
            <button
              type="button"
              className={control.value === ANY ? 'storefront-chip storefront-chip-on' : 'storefront-chip'}
              aria-pressed={control.value === ANY}
              onClick={() => onFacet(control.facet, ANY)}
            >
              {control.anyName}
              <span className="storefront-chip-count">{control.total}</span>
            </button>
            {control.options.map((option) => (
              <button
                key={option.id}
                type="button"
                className={control.value === option.id ? 'storefront-chip storefront-chip-on' : 'storefront-chip'}
                aria-pressed={control.value === option.id}
                onClick={() =>
                  onFacet(control.facet, control.value === option.id ? ANY : option.id)
                }
              >
                {option.name}
                <span className="storefront-chip-count">{option.count}</span>
              </button>
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}
