import Observation
import SwiftUI

/// One read when Machines is visible, plus a person's explicit retry. There is
/// no file-system socket discovery here; the existing Docker owner owns it.
@MainActor
@Observable
final class NativeServerControlLocalDiscovery {
    enum State: Equatable {
        case checking
        case available
        case absent
        case unavailable
    }

    private(set) var state: State = .checking
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func start() {
        read?.cancel()
        generation += 1
        let mine = generation
        state = .checking
        read = Task { [weak self] in
            do {
                // DKU owns the contract projection, DKE the socket discovery.
                let found = try await NativeDockerClient.hasLocalSocket()
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                self.state = found ? .available : .absent
            } catch {
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                // Do not display transport bodies, socket paths or credentials.
                self.state = .unavailable
            }
        }
    }

    func stop() {
        generation += 1
        read?.cancel()
        read = nil
    }
}

/// Add to the existing Machines list. `open` selects a local case on the same
/// NativeServersRoute; it must not create a second sidebar page for servers.
struct NativeServerControlLocalEntry: View {
    let open: () -> Void
    @State private var discovery = NativeServerControlLocalDiscovery()

    var body: some View {
        Group {
            switch discovery.state {
            case .checking:
                NativePageNote("Checking local access…", busy: true)
                    .frame(height: 44)
            case .available:
                Button(action: open) {
                    // NativeServerRow's compact grey row; the current server
                    // continues to be selected by the existing Machines route.
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This Mac")
                                .foregroundStyle(.secondary)
                            Text("Advanced controls")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This Mac, Advanced controls")
            case .absent:
                EmptyView()
            case .unavailable:
                HStack(spacing: 8) {
                    NativePageNote("Local access could not be checked.")
                    Button("Try again") { discovery.start() }
                }
                .frame(height: 44)
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }
}

/// The local branch of the existing Machines route. It uses the same control
/// host as a remote server and offers only Advanced; no new sidebar destination.
struct NativeServerControlLocalSurface: View {
    @Binding var route: NativeServersRoute
    var advanced: NativeServerControlHost.Child?
    @State private var controller = NativeServerControlController(target: "local", name: "This Mac")

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Button("Back to machines") { route = .list }
                        Text("This Mac").font(.title3.weight(.semibold))
                        Spacer()
                    }
                    NativeServerControlHost(controller: controller, advanced: advanced)
                        .frame(height: max(600, viewport.size.height - 48), alignment: .topLeading)
                }
                .padding(24)
                .frame(maxWidth: MachinesPage.measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
