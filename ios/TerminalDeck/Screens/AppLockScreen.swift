/**
 * The two screens the app lock has: the switch that turns it on, and the door it
 * puts in front of the app.
 *
 * > *"On the main page of settings just give it there, as optional for the
 * > overall application. If somebody wants to keep it they can."*
 *
 * So: **one** switch, on the main Settings page, off until somebody moves it.
 * There is no offer after a login, no card that appears when the app thinks you
 * might like this, and nothing anywhere else in the app that mentions it. The
 * feature is exactly as loud as an optional setting should be.
 *
 * Self-contained, in the way `ServerSettingsSection` is and for the same reason:
 * `SettingsGroup` and `SectionCaption` are private to `DeckTabs.swift`, and a
 * section that reached for them would have to live in that file. This one draws
 * its own card so it can be dropped into `DeckSettingsView` as a single line.
 *
 * ## The paragraph under the switch, and why this one is allowed
 *
 * Asad on the desktop's settings page: *"we don't need this much of big
 * descriptions under each."* He is right, and the rule holds everywhere else on
 * that screen. This row keeps two sentences because the thing they say is the
 * thing he asked to be true — *when* it will ask — and a rule about when an app
 * challenges you is one you should be able to read rather than discover by being
 * challenged.
 */

import SwiftUI

/**
 * The switch, its caption, and whatever sentence the last attempt produced.
 *
 * The row is never hidden on a phone that cannot do this. It is disabled with
 * the reason directly underneath — somebody looking for a feature they were told
 * about has to find out *why* it is not available, not fail to find it at all.
 */
struct AppLockSection: View {
    let lock: AppLock

    var body: some View {
        // Asked fresh on every draw, never cached: a passcode can be removed and
        // a face enrolled while this app is in the background, and a cached
        // answer is how a screen offers Face ID to somebody who turned it off.
        let availability = lock.look()
        let on = lock.enabled

        VStack(alignment: .leading, spacing: 0) {
            Text("LOCK")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.top, 24)
                .padding(.bottom, 8)

            HStack(spacing: 12) {
                Image(systemName: availability.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(availability.canLock || on ? Theme.secondary : Theme.faint)
                    .frame(width: 18)
                Text(availability.title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.appLockLabel")
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { wanted in Task { await lock.setEnabled(wanted) } }))
                    .labelsHidden()
                    // Off *and* impossible is disabled with the reason under it.
                    // Already on stays switchable whatever the phone can do now,
                    // because somebody whose sensor stopped working still has to
                    // be able to take the lock off.
                    .disabled(lock.working || (!availability.canLock && !on))
                    .accessibilityIdentifier("settings.appLock")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let trouble = lock.trouble {
                caption(trouble, tone: Theme.warning, id: "settings.appLockTrouble")
            }
            if let notice = lock.notice {
                caption(notice, tone: Theme.warning, id: "settings.appLockNotice")
            }
            if let refusal = availability.refusal, !on {
                caption(refusal, tone: Theme.faint, id: "settings.appLockRefusal")
            } else if let caveat = availability.caveat {
                caption(caveat, tone: Theme.faint, id: "settings.appLockCaveat")
            }

            caption(AppLockText.rule(availability), tone: Theme.faint, id: "settings.appLockRule")
        }
        // A sentence from an attempt made ten minutes ago is not news. It goes
        // when the screen does.
        .onDisappear { lock.clearTrouble() }
    }

    private func caption(_ text: String, tone: Color, id: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .accessibilityIdentifier(id)
    }
}

/// The sentences both screens say, written once so they cannot drift apart.
enum AppLockText {

    /// When it asks — the requirement, in the person's own terms, naming the
    /// thing their phone will actually put in front of them.
    static func rule(_ availability: AppLockAvailability) -> String {
        "\(Brand.name) asks for \(availability.noun) when it starts, and again if you have been "
            + "away for more than \(AppLock.graceWords). Coming back from the app switcher, a share "
            + "sheet or another app for a moment does not ask."
    }
}

/**
 * The door. One button, one sentence, and never a dead end behind it.
 *
 * Presented in a window of its own — see `AppLockShield` — so it is above the
 * sheets as well as the app. Nothing on it can be dismissed past: the only ways
 * off this screen are a successful authentication, and the **Continue** button
 * that appears in the single state where nothing could ever authenticate.
 */
struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        let availability = lock.look()
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Image(systemName: availability.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 20)
                    .accessibilityIdentifier("applock.symbol")

                Text("\(Brand.name) is locked")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("applock.title")

                Text(lock.stranded
                     ? "There is nothing left on this iPhone to unlock it with."
                     : "Unlock with \(availability.noun) to open it.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                if let trouble = lock.trouble {
                    Text(trouble)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("applock.trouble")
                }

                if lock.stranded {
                    // The one state where pressing Unlock again could never
                    // help. Deleting the app is the alternative, so this is the
                    // door: it opens, and Settings says what happened.
                    button("Continue", id: "applock.continue") {
                        lock.continueWithoutLock()
                    }
                } else {
                    button(lock.working ? "Asking…" : "Unlock", id: "applock.unlock") {
                        Task { await lock.unlock() }
                    }
                    .disabled(lock.working)
                }

                Spacer(minLength: 0)

                Text(AppLockText.rule(availability))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
                    .accessibilityIdentifier("applock.rule")
            }
        }
        .accessibilityIdentifier("applock.screen")
        /*
         * The prompt raises itself, and `promptToken` is what says when.
         *
         * `.task(id:)` runs once when this screen appears — the cold start — and
         * again each time the token moves, which `AppLock` does only when the
         * app comes back from the **background** to a locked screen. It
         * deliberately does not move when the app merely goes inactive, which is
         * what the system's own Face ID sheet does to this app: a token bumped
         * there would re-raise the prompt the instant somebody cancelled it, for
         * ever.
         */
        .task(id: lock.promptToken) {
            await lock.unlock()
        }
    }

    private func button(_ title: String,
                        id: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(minWidth: 180)
                .padding(.vertical, 13)
                .padding(.horizontal, 22)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 26)
        .accessibilityIdentifier(id)
    }
}
