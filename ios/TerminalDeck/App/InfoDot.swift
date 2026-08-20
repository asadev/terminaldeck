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
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
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
