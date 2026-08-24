/**
 * One server on the machines list.
 *
 * The name leads because it is what somebody is looking for; the address under
 * it is monospaced and dimmed because it is data — the design brief's rule, and
 * here it is also the answer to *"I don't know where it belongs to"*. **The port
 * is printed whenever it is not 22**, and that is not a detail: Asad's own
 * machine listens on 2222, and a row that hid the number would give two servers
 * on one host the same line.
 *
 * The status line says the one thing that separates a server from a machine on
 * this screen: whether this phone is *connected* to the host on it, as opposed
 * to merely being able to log in and manage it. Both are true of a connected
 * server and they are not the same fact.
 */

import SwiftUI

struct ServerRow: View {
    let server: StoredServer
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                // Not the address twice. A server nobody has renamed is called
                // by its address, and printing `root@<the same address>` under
                // it is one fact taking two lines on a 390-point screen — seen
                // in a photograph of the real list. When they differ, the line
                // is the thing somebody would type.
                Text(server.name == server.where_
                     ? "as \(server.username)"
                     : "\(server.username)@\(server.where_)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isConnected
                     ? "Connected — its sessions are on the Sessions tab."
                     : "Signed in over SSH. Not connected as a machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(isConnected ? Theme.positive : Theme.faint)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
