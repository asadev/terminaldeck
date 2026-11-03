import SwiftUI

extension DeckPage {
    init<Content: View>(title: String, subtitle: String? = nil,
                        paper: Bool = false,
                        scrolls: Bool? = nil,
                        @ViewBuilder content: () -> Content) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: nil, switcher: nil, actions: nil, content: AnyView(content()))))
    }

    init<Content: View, Switcher: View>(title: String, subtitle: String? = nil,
                                      paper: Bool = false,
                                      scrolls: Bool? = nil,
                                      @ViewBuilder switcher: () -> Switcher,
                                      @ViewBuilder content: () -> Content) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: nil, switcher: AnyView(switcher()), actions: nil,
            content: AnyView(content()))))
    }

    init<Content: View, Actions: View>(title: String, subtitle: String? = nil,
                                     paper: Bool = false,
                                     scrolls: Bool? = nil,
                                     @ViewBuilder actions: () -> Actions,
                                     @ViewBuilder content: () -> Content) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: nil, switcher: nil, actions: AnyView(actions()),
            content: AnyView(content()))))
    }

    init<Content: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: nil, switcher: AnyView(switcher()), actions: AnyView(actions()),
            content: AnyView(content()))))
    }

    init<Content: View, Leading: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: AnyView(leading()), switcher: nil, actions: nil,
            content: AnyView(content()))))
    }

    init<Content: View, Leading: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil,
        paper: Bool = false, scrolls: Bool? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.init(deckContent: AnyView(DeckPageContainer(
            title: title, subtitle: subtitle, paper: paper,
            scrolls: scrolls, leading: AnyView(leading()),
            switcher: AnyView(switcher()), actions: AnyView(actions()),
            content: AnyView(content()))))
    }
}

private struct DeckPageContainer: View {
    let title: String
    let subtitle: String?
    let paper: Bool
    let scrolls: Bool?
    let leading: AnyView?
    let switcher: AnyView?
    let actions: AnyView?
    let content: AnyView

    private var ownsScroll: Bool { scrolls ?? true }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle,
                       leadingContent: leading, switcherContent: switcher, actionsContent: actions)
                .layoutPriority(1)
            if ownsScroll {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DeckTokens.Metrics.sectionGap) {
                        content
                    }
                        .frame(maxWidth: 1120, alignment: .leading)
                        .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
                        .padding(.top, DeckTokens.Metrics.pageTop)
                        .padding(.bottom, DeckTokens.Metrics.pageBottom)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .frame(minWidth: 0, maxWidth: .infinity,
                       minHeight: 0, maxHeight: .infinity, alignment: .top)
            } else {
                // Forms, Lists and split panes own their scrolling. No second scroll.
                content
                    .frame(maxWidth: 1120, minHeight: 0,
                           maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
                    .frame(minWidth: 0, maxWidth: .infinity,
                           minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity,
               minHeight: 0, maxHeight: .infinity, alignment: .top)
        .font(DeckTokens.Typography.body)
        .background(paper ? DeckTokens.paper : DeckTokens.page, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .clipped()
    }
}

/// The page's own fixed header, below the app's tab strip. Its column width
/// matches the content. The switch remains centred even with unequal side text.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var leadingContent: AnyView? = nil
    var switcherContent: AnyView? = nil
    var actionsContent: AnyView? = nil

    init(title: String, subtitle: String? = nil, leadingContent: AnyView? = nil,
         switcherContent: AnyView? = nil, actionsContent: AnyView? = nil) {
        self.title = title; self.subtitle = subtitle
        self.leadingContent = leadingContent
        self.switcherContent = switcherContent; self.actionsContent = actionsContent
    }

    init<Switcher: View>(title: String, subtitle: String? = nil,
                         @ViewBuilder switcher: () -> Switcher) {
        self.init(title: title, subtitle: subtitle,
                  switcherContent: AnyView(switcher()))
    }

    init<Actions: View>(title: String, subtitle: String? = nil,
                        @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle,
                  actionsContent: AnyView(actions()))
    }

    init<Switcher: View, Actions: View>(title: String, subtitle: String? = nil,
                                       @ViewBuilder switcher: () -> Switcher,
                                       @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle,
                  switcherContent: AnyView(switcher()), actionsContent: AnyView(actions()))
    }

    init<Leading: View>(title: String, subtitle: String? = nil,
                        @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle,
                  leadingContent: AnyView(leading()))
    }

    init<Leading: View, Switcher: View, Actions: View>(
        title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading,
        @ViewBuilder switcher: () -> Switcher,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(title: title, subtitle: subtitle,
                  leadingContent: AnyView(leading()),
                  switcherContent: AnyView(switcher()), actionsContent: AnyView(actions()))
    }

    /// `subtitleLines` 2: the no-switch header's narrow form, where the subtitle wraps instead of the actions being cut.
    private func titleBlock(subtitleLines: Int = 1) -> some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            if let leadingContent {
                // Agent consumers keep the tile neutral and the glyph in
                // their agent's colour. Other leading content keeps v1 colours.
                // Sizes to its content (a back button + avatar is wider); at least 30×30.
                HStack(spacing: DeckTokens.Spacing.s8) { leadingContent }
                    .frame(minWidth: 30, minHeight: 30)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DeckTokens.Typography.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DeckTokens.Typography.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: subtitleLines > 1)
                        .help(subtitle)
                }
            }
        }
        .frame(minWidth: 0,
               maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actionsSlot: some View {
        if let actionsContent {
            // One subview for the layout: a multi-view builder is a TupleView inside AnyView,
            // which the header layout would otherwise see as several slots (L2-PAGES report).
            HStack(spacing: DeckTokens.Spacing.s8) { actionsContent }.lineLimit(1)
        } else {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private func oneRow(_ switcher: AnyView?) -> some View {
        DeckPageHeaderLayout {
            titleBlock()
            if let switcher { HStack(spacing: DeckTokens.Spacing.s8) { switcher } } else { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
            actionsSlot
        }
        .frame(height: DeckTokens.Metrics.pageHeader)
    }

    var body: some View {
        Group {
            if let switcherContent {
                // Wide page: one row, switch in the centre. Narrow page: the switch moves to
                // its own centred row under the title so no view name is cut short.
                ViewThatFits(in: .horizontal) {
                    oneRow(switcherContent)
                    VStack(spacing: 0) {
                        HStack(spacing: DeckTokens.Spacing.s12) {
                            titleBlock()
                            actionsSlot.fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: DeckTokens.Metrics.pageHeader)
                        switcherContent
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, DeckTokens.Spacing.s8)
                    }
                }
            } else {
                // No switch: one row when the title and every action fit at full width. Narrower (the Devices
                // window at its default 760 pt, review install-24): the actions keep their whole labels and the
                // subtitle wraps to a second line; the header grows a little instead of cutting a button short.
                ViewThatFits(in: .horizontal) {
                    oneRow(nil)
                    HStack(spacing: DeckTokens.Spacing.s16) {
                        titleBlock(subtitleLines: 2)
                        // Measured first: whole labels whenever the row can hold them; cut only if it truly cannot.
                        actionsSlot.layoutPriority(1)
                    }
                    .padding(.vertical, DeckTokens.Spacing.s4)
                    .frame(minHeight: DeckTokens.Metrics.pageHeader)
                }
            }
        }
        .frame(maxWidth: 1120)
        .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
        .frame(maxWidth: .infinity)
    }
}

/// Equal side slots keep the middle at the actual page centre. Side content
/// gets its ideal width up to a third of the available column; the middle gets
/// the rest, retaining the switcher's measured minimum click-target width.
private struct DeckPageHeaderLayout: Layout {
    private func finiteLength(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        // A zero proposal probes the true minimum width. Nil and infinity ask
        // for an ideal width; return finite measured dimensions, never infinity.
        let widths = subviews.map { finiteLength($0.sizeThatFits(.unspecified).width) }
        if widths.count == 3, widths[1] == 0 {
            // No switch: nothing to centre. Ideal = title and actions side by side at full width.
            let probe = ProposedViewSize(width: 0, height: DeckTokens.Metrics.pageHeader)
            let minimum = finiteLength(subviews[0].sizeThatFits(probe).width) + DeckTokens.Spacing.s16
                + finiteLength(subviews[2].sizeThatFits(probe).width)
            let ideal = max(minimum, widths[0] + DeckTokens.Spacing.s16 + widths[2])
            let resultWidth = proposal.width.map { $0.isFinite ? max(minimum, finiteLength($0)) : ideal } ?? ideal
            return CGSize(width: resultWidth, height: DeckTokens.Metrics.pageHeader)
        }
        let middleMinimum = subviews.count == 3
            ? finiteLength(subviews[1].sizeThatFits(ProposedViewSize(
                width: 0, height: DeckTokens.Metrics.pageHeader)).width) : 0
        let middle = widths.count == 3 ? max(middleMinimum, widths[1]) : 0
        // Same rule as placement: the title may truncate to 160 pt while the switch stays centred.
        let side = widths.count == 3 ? max(min(widths[0], 160), widths[2]) : 0
        let minimumProposal = ProposedViewSize(width: 0, height: DeckTokens.Metrics.pageHeader)
        let sideMinimum = subviews.count == 3
            ? max(finiteLength(subviews[0].sizeThatFits(minimumProposal).width),
                  finiteLength(subviews[2].sizeThatFits(minimumProposal).width)) : 0
        let gaps: CGFloat = middle > 0 ? 2 * DeckTokens.Spacing.s16 : 0
        let minimum = finiteLength(2 * sideMinimum + middleMinimum + gaps)
        let ideal = max(minimum, finiteLength(2 * side + middle + gaps))
        let resultWidth: CGFloat
        if let width = proposal.width, width.isFinite {
            resultWidth = max(minimum, finiteLength(width))
        } else {
            resultWidth = ideal
        }
        return CGSize(width: resultWidth, height: DeckTokens.Metrics.pageHeader)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        guard subviews.count == 3, bounds.width.isFinite, bounds.width >= 0,
              bounds.height.isFinite, bounds.height >= 0,
              bounds.minX.isFinite, bounds.minY.isFinite else { return }
        let width = bounds.width
        let probe = ProposedViewSize(width: 0, height: DeckTokens.Metrics.pageHeader)
        let leftIdeal = finiteLength(subviews[0].sizeThatFits(.unspecified).width)
        let midIdeal = finiteLength(subviews[1].sizeThatFits(.unspecified).width)
        let rightIdeal = finiteLength(subviews[2].sizeThatFits(.unspecified).width)
        let midMin = finiteLength(subviews[1].sizeThatFits(probe).width)
        let rightMin = finiteLength(subviews[2].sizeThatFits(probe).width)
        let gap: CGFloat = midIdeal > 0 ? DeckTokens.Spacing.s16 : 0
        // The title may truncate to this before the switch leaves the centre.
        let titleFloor = min(leftIdeal, 160)
        let sideNeeded = max(rightIdeal, titleFloor)
        var left: CGFloat, mid: CGFloat, right: CGFloat, midX: CGFloat
        if midIdeal == 0 {
            // No switch (review install-24, Devices header): the actions keep their whole labels while the title
            // keeps at least its floor; the title takes the rest. Never "a third each" for a centre that is not there.
            let between = DeckTokens.Spacing.s16
            right = min(rightIdeal, max(rightMin, width - titleFloor - between))
            left = max(0, width - right - between)
            mid = 0; midX = bounds.minX + left + between / 2
        } else if midIdeal + 2 * (sideNeeded + gap) <= width {
            // Centred switch; both sides share what is left equally.
            mid = midIdeal
            let side = (width - mid - 2 * gap) / 2
            left = side; right = side
            midX = bounds.midX
        } else {
            // Narrow page: actions keep their width, the switch keeps its own as long as it
            // can, then the title gives way. The switch sits right after the title.
            right = min(rightIdeal, max(rightMin, width / 3))
            mid = max(midMin, min(midIdeal, width - right - min(leftIdeal, 120) - 2 * gap))
            left = max(0, width - mid - right - 2 * gap)
            midX = bounds.minX + left + gap + mid / 2
        }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: left, height: bounds.height))
        subviews[1].place(at: CGPoint(x: midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: mid, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: right, height: bounds.height))
    }
}

/// Solid content card. Its owner supplies rows or sections; cards do not nest.
struct DeckCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    init(padding: CGFloat = DeckTokens.Metrics.cardPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding.isFinite ? max(0, padding) : DeckTokens.Metrics.cardPadding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckTokens.card,
                        in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius)
                    .strokeBorder(DeckTokens.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// One quiet empty state, sized inside the existing page column.
struct DeckEmpty: View {
    let title: String
    var message: String? = nil
    var symbol: String = "tray"
    var symbolColor: Color = .secondary
    var actionLabel: String? = nil
    var primary = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DeckTokens.Spacing.s12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title).font(DeckTokens.Typography.section)
            if let message, !message.isEmpty {
                Text(message)
                    .font(DeckTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            if let actionLabel, let action {
                if primary {
                    Button(actionLabel, action: action).buttonStyle(.borderedProminent)
                } else {
                    Button(actionLabel, action: action).buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.bottom, DeckTokens.Metrics.pageBottom)
    }
}

struct DeckError: View {
    var title = "Couldn't load this page"
    let message: String
    var retry: (() -> Void)? = nil
    /// SAFE BY DEFAULT: Try Again is the person's. True only for a read-only reload: it is then
    /// also pressed once when the app's lines come back (DeckReconnect), never on a timer.
    var autoRetry = false
    private let retryID: String

    init(title: String = "Couldn't load this page", message: String, retry: (() -> Void)? = nil,
         autoRetry: Bool = false, file: String = #fileID, line: Int = #line) {
        self.title = title; self.message = message; self.retry = retry; self.autoRetry = autoRetry
        retryID = "\(file):\(line)"
    }

    var body: some View {
        let state = DeckEmpty(title: title, message: message, symbol: "exclamationmark.triangle",
                              symbolColor: DeckTokens.warn, actionLabel: retry == nil ? nil : "Try Again",
                              action: retry)
        if autoRetry, let retry { state.deckRetriesItself(id: retryID, retry) } else { state }
    }
}
