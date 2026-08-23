/**
 * *"Use Face ID next time?"* — offered once, at the moment it makes sense, and
 * never again if the answer is no.
 *
 * ## The requirement, and the word that shapes it
 *
 * > *"Also give the face or fingerprint login there if somebody wants to have
 * > that, also for the next time."*
 *
 * **"if somebody wants."** So this is an offer with two answers and no default
 * dressed as one. Somebody who taps *Not now* keeps typing their password and is
 * not asked again on this login; the switch on the server's own page is where
 * they would go if they change their mind, and the same switch is how it comes
 * back off. Nothing here nags, and nothing here is on until it is pressed.
 *
 * ## Why the offer lands here rather than in a settings screen
 *
 * **"there"** — the credential has just been proved to work, the person is
 * holding the phone, and the very next thing they will do with this server is
 * come back to it. That is the moment. A switch buried three screens away is a
 * feature that ships and nobody finds; `ServerDetailView` carries one anyway,
 * for turning it off and for the person who said no the first time.
 *
 * ## The name on screen is the name that phone actually has
 *
 * Never "Face ID" on a device with a fingerprint reader. `BiometryAvailability`
 * asks `LAContext` what this hardware is and the label follows it, including on
 * a phone that has neither — where the offer is simply not made, because an
 * offer nobody can accept is a control drawn hopefully.
 */

import SwiftUI

/**
 * The offer, as a card. Renders nothing at all when there is nothing to offer:
 * no sensor, nothing enrolled, or the lock is already on.
 */
struct BiometricOfferCard: View {
    let model: DeckModel
    let serverId: String
    /// Set when the person has declined on this screen. Held by the caller so
    /// the card does not come back when the view redraws under it.
    @Binding var declined: Bool

    @State private var working = false
    @State private var refusal: String?

    private var connector: ServerConnector { model.serverConnector }
    private var server: StoredServer? { connector.server(serverId) }

    var body: some View {
        // Asked fresh rather than cached: biometry can be enrolled or removed
        // while this app is in the background.
        let availability = connector.biometry.look()
        if let server, server.isBiometricLocked {
            /*
             * It is on — said, once, rather than the card simply vanishing.
             *
             * The card disappearing on success is technically the right state
             * and reads as the button having done nothing. This is the whole of
             * the confirmation, and it names the sensor the phone actually has.
             */
            Label("\(availability.name) is on for this server. It will ask next time.",
                  systemImage: "checkmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("biometry.on")
        } else if let server, !server.isBiometricLocked, !declined, availability.isReady {
            card(availability)
        } else if let refusal {
            // A refusal that arrived *after* the card was shown stays visible
            // even though the card's condition has changed — otherwise pressing
            // the button and being told nothing is what happens.
            Text(refusal)
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("biometry.refusal")
        }
    }

    private func card(_ availability: BiometryAvailability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: availability.kind == .touchID ? "touchid" : "faceid")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                Text("Use \(availability.name) next time?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("biometry.offer")
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small).tint(Theme.accent) }
            }

            Text("Your sign-in stays in this iPhone's Keychain either way. Turning this on puts "
                 + "\(availability.name) in front of it, so opening this server asks for your face "
                 + "rather than your password. This iPhone's passcode always works too.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("biometry.refusal")
            }

            HStack(spacing: 10) {
                Button {
                    working = true
                    refusal = nil
                    Task {
                        refusal = await connector.setBiometricLock(true, for: serverId)
                        working = false
                    }
                } label: {
                    Text("Turn on \(availability.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .disabled(working)
                .accessibilityIdentifier("biometry.turnOn")

                Button("Not now") { declined = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("biometry.notNow")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/**
 * The same setting as a switch, on a server's own page — for turning it off, and
 * for whoever said *Not now* the first time.
 *
 * A switch rather than a button because it has two states and both are real. It
 * is disabled with a stated reason when this phone cannot do it, never hidden:
 * somebody looking for a feature they were told about must find out *why* it is
 * not here, not fail to find it.
 */
struct BiometricLockRow: View {
    let model: DeckModel
    let serverId: String

    @State private var working = false
    @State private var refusal: String?

    private var connector: ServerConnector { model.serverConnector }

    var body: some View {
        let availability = connector.biometry.look()
        let on = connector.server(serverId)?.isBiometricLocked == true
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: availability.kind == .touchID ? "touchid" : "faceid")
                    .font(.system(size: 14))
                    .foregroundStyle(availability.isReady || on ? Theme.accent : Theme.faint)
                    .frame(width: 18)
                Text(on ? "\(availability.name) is on for this server"
                        : "Unlock with \(availability.name)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.biometryLabel")
                Spacer(minLength: 8)
                if working {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else {
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { wanted in
                            working = true
                            refusal = nil
                            Task {
                                refusal = await connector.setBiometricLock(wanted, for: serverId)
                                working = false
                            }
                        }))
                        .labelsHidden()
                        // Off *and* impossible is disabled with the reason under
                        // it; already on stays switchable, because a person
                        // whose sensor stopped working still has to be able to
                        // take the lock off.
                        .disabled(!availability.isReady && !on)
                        .accessibilityIdentifier("server.biometryToggle")
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.biometryRefusal")
            } else if !availability.isReady, !on, let why = availability.refusal {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.biometryRefusal")
            }
        }
    }
}
