/**
 * Alerts: the switches, and the sentence that says what they can and cannot do.
 *
 * ## The honest limit is the point of this screen — and it is a line now
 *
 * Two switches would fit in a menu. What does not fit in a menu, and what a
 * person deciding whether to rely on this deserves before they do, is that a
 * suspended phone is not reachable: this product has no push service, so an
 * alert can only be raised while the app is running.
 *
 * That used to be five paragraphs. *"Remove this full shit. I don't want any
 * kind of long descriptions anywhere. Just if somewhere it's very required,
 * give the i icon."* It is one line and an ⓘ now, and the split between them is
 * the only judgement on this screen worth writing down.
 *
 * **The limit stays visible.** Not saying it costs somebody a two-hour wait for
 * a buzz that was never coming, and that is the sort of thing an app is
 * uninstalled over — and somebody who does not know there is a limit will never
 * tap a dot to go looking for one. What went *behind* the dot is the mechanism:
 * the half-minute iOS allows after the phone goes down, and the catch-up on the
 * next connection. Mechanism is only interesting once you know there is
 * something to explain, and by then a tap is cheap.
 *
 * ## Why the permission button is not a switch
 *
 * The system prompt can be asked exactly once. Before it, this screen offers a
 * button that asks; after a refusal there is nothing this app can do at all, so
 * it says so and offers the Settings app, which is the only place it can be
 * undone. Drawing a switch for something the app cannot change would be a
 * control that lies.
 */

import SwiftUI
import UIKit

struct AlertsView: View {
    let model: DeckModel
    let dismiss: () -> Void

    /// Mirrors of the stored settings. `AlertSettings` is a `UserDefaults`
    /// façade rather than an observable object, so the switches hold their own
    /// state and write through — which is also what makes them respond
    /// instantly rather than after a store round trip.
    @State private var needsYou = AlertSettings.needsYou
    @State private var finished = AlertSettings.finished
    @State private var asking = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        permissionBlock
                        switches
                        limits
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("alerts.done")
                }
            }
        }
        .tint(Theme.accent)
        .task { await model.refreshAlertPermission() }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionBlock: some View {
        switch model.alertPermission {
        case .none:
            // Still asking iOS. A blank moment rather than a claim that turns
            // out to be wrong a frame later.
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)

        case .notAsked:
            // No line under this one at all: the button directly beneath says
            // "Turn on alerts", which is the same sentence with a finger on it.
            Block(title: "Get told when a machine needs you",
                  about: "alerts",
                  info: "A session that stops and waits for an answer can put a notification on "
                      + "this phone, so you do not have to keep opening the app to check.")
            Button {
                asking = true
                Task {
                    await model.requestAlertPermission()
                    asking = false
                }
            } label: {
                Text(asking ? "Asking…" : "Turn on alerts")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .disabled(asking)
            .padding(.top, 20)
            .accessibilityIdentifier("alerts.turnOn")

        case .denied:
            // One line and no dot. "Nothing here can turn them back on — that
            // switch lives over there" was the second sentence, and the button
            // under it is labelled Open Settings, which says it better.
            Block(title: "Alerts are off",
                  detail: "Turned off for \(Brand.name) in the Settings app.")
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 20)
            .accessibilityIdentifier("alerts.openSettings")

        case .allowed, .other:
            Block(title: "Alerts are on",
                  detail: "Choose what is worth interrupting you for.")
        }
    }

    // MARK: - The two switches

    @ViewBuilder
    private var switches: some View {
        if model.alertPermission == .allowed || model.alertPermission == .other {
            VStack(spacing: 0) {
                SwitchRow(title: "A session needs you",
                          detail: "It has stopped and is waiting for an answer. Makes a sound.",
                          isOn: $needsYou)
                    .accessibilityIdentifier("alerts.needsYou")
                    .onChange(of: needsYou) { _, value in AlertSettings.needsYou = value }

                Divider()
                    .overlay(Theme.hairline)
                    .padding(.leading, 16)

                SwitchRow(title: "A session finishes",
                          detail: "The agent finished its turn, or the session ended. Silent.",
                          isOn: $finished)
                    .accessibilityIdentifier("alerts.finished")
                    .onChange(of: finished) { _, value in AlertSettings.finished = value }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 24)
        }
    }

    // MARK: - What it cannot do

    /// The limit, and the mechanism behind it. See the header for why one of
    /// those two is on the screen and the other is not.
    private var limits: some View {
        HStack(spacing: 4) {
            Text("A phone that has been asleep cannot be woken.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                // Kept on the text rather than on the row, so the ⓘ beside it
                // keeps an identifier of its own.
                .accessibilityIdentifier("alerts.limits")

            InfoDot(about: "what alerts can reach",
                    text: "Alerts are raised by this app while it is running — open, or for "
                        + "about half a minute after you put the phone down. \(Brand.name) has "
                        + "no notification server, so nothing on a machine can reach a sleeping "
                        + "phone.\n\nAnything that happened while it was asleep is picked up the "
                        + "next time the app connects, and the session list says what changed.")

            Spacer(minLength: 0)
        }
        .padding(.top, 30)
    }
}

/**
 * A title, at most one line under it, and the ⓘ that holds whatever used to be
 * a paragraph there.
 *
 * The spacing the design brief asks for is unchanged — title brighter,
 * description dimmer, room between them. What changed is that `detail` is now
 * optional and is one line when it is there at all. Each of the three states
 * this screen has opened with a heading and two lines of prose explaining
 * itself, directly above a button that said the same thing in three words.
 */
private struct Block: View {
    let title: String
    /// One line, or none. Never a paragraph — that is what `info` is for.
    var detail: String? = nil
    var about: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let about, let info {
                    InfoDot(about: about, text: info)
                }
                Spacer(minLength: 0)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
