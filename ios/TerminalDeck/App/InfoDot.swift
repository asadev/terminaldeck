/**
 * The ⓘ, and the only place an explanation is allowed to live.
 *
 * His instruction, twice in one recording and the one most often broken while
 * fixing something else:
 *
 *   > *"here you have a very long description… Remove this full shit. I don't
 *   > want any kind of long descriptions anywhere. Just if somewhere it's very
 *   > required, give the i icon like other ones, information icon in the
 *   > settings, same way."*
 *
 *   > *"don't put any single statement in anywhere… We want simplicity. Let the
 *   > smart people use it. Smart people knows how it works."*
 *
 * So a screen carries controls and figures, and anything that would have been a
 * paragraph under one of them goes behind this. Nothing is lost — it is
 * reachable by tap and by VoiceOver — and nothing is on screen that a person who
 * already knows how the thing works has to read past.
 *
 * ## The dot has to be pressable, and 44 does not fit
 *
 * It was the glyph and nothing else: a thirteen-point target for what is now
 * the only route to every sentence this pass took off the screens. Apple's
 * figure is 44 and it cannot be had here — two of these sit beside a section
 * caption whose whole band is thirteen points, and a 44-point dot inside one
 * would shove the caption away from the rows it names.
 *
 * 24 is the number because it is nearly free and it is three times the area a
 * thumb had before. In a row it is exactly free: every row that carries one of
 * these already holds something taller — a stepper, a colour well, a switch. On
 * a section caption it costs eleven points of band, and that is a price rather
 * than a fault: those captions had a thirteen-point dot in a thirteen-point
 * line and now have air around both, which is what the surfaces either side of
 * them have.
 *
 * A popover rather than a disclosure, which is the same decision the desktop's
 * Settings window made and for the same reason: a disclosure pushes everything
 * below it down the page, so reading the second explanation moves the third
 * somewhere else. `.presentationCompactAdaptation(.popover)` is what keeps it a
 * popover on a phone instead of becoming a sheet.
 */

import SwiftUI

struct InfoDot: View {
    /// What the ⓘ is about, for VoiceOver. Never drawn.
    let about: String
    let text: String

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.faint)
                // The target, not the glyph. See the header for why 24 and not
                // 44, and why 24 costs nothing.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(about)")
        .accessibilityHint(text)
        .accessibilityIdentifier("info.\(about.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: 300)
                .presentationCompactAdaptation(.popover)
        }
    }
}
