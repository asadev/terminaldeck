/**
 * Room at the bottom of a scrolling screen for the tab bar that floats over it —
 * measured, once, rather than guessed at in six files.
 *
 * ## The defect
 *
 * Asad, on his own phone, 0.10.1: the About row on Settings read *"Terminal Deck
 * 0.10.1"* with the words **behind** the tab-bar pill. Every scrolling screen
 * under the bar loses its last rows the same way, and it is invisible in review
 * because the content is there, laid out correctly, with sixty points of chrome
 * on top of it.
 *
 * Each of those screens ended in `.padding(.bottom, 28)` — a literal, copied
 * into six files. Twenty-eight points is breathing room; it is not the bar. On
 * an iPhone 17 Pro the bar's own frame is **eighty-three points** tall (about
 * forty-nine of floating pill over the thirty-four of home indicator), so a
 * screen that gets no inset from the system and only reserves twenty-eight is
 * fifty-five points short — which is an entire row, and the row it eats is the
 * last one.
 *
 * ## Why this is measured and not a number
 *
 * Because the answer is not the same on every release, and both wrong answers
 * are bad. Measured here on iOS 27, the `TabView` **does** hand its floating
 * bar's height to a nested `ScrollView`: the content stops exactly at the bar's
 * top edge, and a screen that reserved the band a second time would sit above a
 * hundred and sixty points of nothing. On the release his phone is running it
 * plainly does not, or the words would not have been behind the pill.
 *
 * So this reserves **the difference**: the bar's real band, minus whatever the
 * scroll view has already been inset by. Nothing on a release that hands it
 * over, the whole band on one that does not, and no constant that goes stale
 * when Apple changes the bar again.
 *
 * ## Why it is content and not a `safeAreaInset`
 *
 * A `.safeAreaInset(edge: .bottom)` would *become* part of the scroll view's
 * adjusted inset — the very number this measures — so the spacer would read its
 * own contribution and oscillate. Sitting at the end of the content it adds to
 * `contentSize`, which `adjustedContentInset` does not depend on, so the
 * measurement is a fixed point on the first pass.
 */

import SwiftUI
import UIKit

/// The arithmetic, alone, so it can be pinned by a test rather than only by a
/// screenshot. See `DeckChromeTests`.
enum TabBarClearanceMath {

    /**
     * How much more the content needs at its bottom.
     *
     * `band` is what the bar covers at the bottom of the window; `alreadyInset`
     * is what the scroll view has been given. Never negative — a screen that has
     * been over-inset is not fixed by removing content — and never anything at
     * all when the two already agree.
     *
     * A band of zero means no bar was found, which is the state of every screen
     * that hides it and of a phone mid-transition; the honest answer there is to
     * add nothing rather than to reserve room for a bar that is not drawn.
     */
    static func spacer(band: CGFloat, alreadyInset: CGFloat) -> CGFloat {
        guard band.isFinite, alreadyInset.isFinite, band > 0 else { return 0 }
        return max(0, band - max(0, alreadyInset))
    }
}

/// The spacer. Put it last inside a scrolling screen that keeps the tab bar.
struct TabBarClearance: View {
    @State private var needed: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: needed)
            // Zero-height, so the probe measures the scroll view it is inside
            // without being a spacer itself; the `Color` above is what actually
            // takes the room.
            .overlay(alignment: .bottom) {
                ClearanceProbe(needed: $needed).frame(height: 0)
            }
            .accessibilityHidden(true)
    }
}

/// The one thing in this app that reads UIKit for a layout number, because the
/// two facts it needs — how tall the bar actually is, and what this scroll view
/// was actually inset by — are UIKit's and SwiftUI does not publish either.
private struct ClearanceProbe: UIViewRepresentable {
    @Binding var needed: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.report = record
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.report = record
        view.remeasure()
    }

    /**
     * Write the measurement back, next runloop turn and only when it moved.
     *
     * Two guards, and both are load-bearing. **Half a point of hysteresis**, so
     * a layout pass that produces the answer already on screen does not write
     * state and schedule another one — this is measured *from* `layoutSubviews`,
     * so a write per pass would be a write per pass forever. And **`async`**,
     * because the measurement happens inside UIKit's layout, which is inside
     * SwiftUI's update: changing `@State` there is the "modifying state during
     * view update" trap, and the cost of avoiding it is that the spacer settles
     * one frame after the bar does.
     */
    private func record(_ measured: CGFloat) {
        guard abs(measured - needed) > 0.5 else { return }
        DispatchQueue.main.async {
            if abs(measured - needed) > 0.5 { needed = measured }
        }
    }

    final class ProbeView: UIView {
        var report: ((CGFloat) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            remeasure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            remeasure()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            remeasure()
        }

        func remeasure() {
            report?(TabBarClearanceMath.spacer(band: band(), alreadyInset: alreadyInset()))
        }

        /// What the bar covers at the bottom of this window, from the bar that is
        /// actually drawn. Zero when there is none — see the note on `spacer`.
        private func band() -> CGFloat {
            guard let window else { return 0 }
            guard let bar = Self.tabBar(in: window) else { return 0 }
            let frame = bar.convert(bar.bounds, to: window)
            guard frame.height > 0 else { return 0 }
            return max(0, window.bounds.maxY - frame.minY)
        }

        /// What the enclosing scroll view has already been given at its bottom.
        /// `adjustedContentInset` rather than `contentInset`, because the safe
        /// area is exactly the part being asked about.
        private func alreadyInset() -> CGFloat {
            var view: UIView? = superview
            while let current = view {
                if let scroll = current as? UIScrollView { return scroll.adjustedContentInset.bottom }
                view = current.superview
            }
            return 0
        }

        /// The first `UITabBar` in the window. A depth-first walk, because the
        /// bar's position in a SwiftUI hierarchy is not something to rely on —
        /// what is relied on is that it is a `UITabBar`, which is what makes it
        /// findable by XCUITest's `tabBars` query as well.
        private static func tabBar(in root: UIView) -> UITabBar? {
            if let bar = root as? UITabBar { return bar.isHidden ? nil : bar }
            for child in root.subviews {
                if let found = tabBar(in: child) { return found }
            }
            return nil
        }
    }
}
