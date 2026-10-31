import SwiftUI
import TerminalDeckNativeCore

/// Facts are measured server facts, never invented defaults. Unknown facts stay empty.
struct NativeMACHINESMetricStrip: View {
    let state: ServerRoomState?
    let now: Double
    var onHealth: () -> Void = {}
    private var facts: ServerFacts? { state?.view?.facts }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { metrics }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) { metrics }
        }
    }
    @ViewBuilder private var metrics: some View {
        tile("Status", value: state?.link == .ready ? "Running" : state?.link == .failed ? "Not answering" : "Checking…",
            detail: state?.view.map { "Checked \(ServerWords.asOf($0.measuredAt, now: now))" } ?? "", progress: nil)
        amount("Storage", key: "disk")
        amount("Memory", key: "memory")
        let load = facts?["load"]?.value?.number
        let cpus = facts?["cpus"]?.value?.number
        tile("Load", value: ServerWords.workload(facts),
            detail: load.flatMap { load in cpus.map { load.formatted(.number.precision(.fractionLength(1))) + " / \(Int($0)) cores" } } ?? "",
            progress: ServerWords.loadShare(facts))
        tile("Up", value: ServerWords.onFor(facts), detail: "", progress: nil)
    }
    private func amount(_ title: String, key: String) -> some View {
        let amount = facts?[key]?.value
        let used = amount?["usedKb"].number
        let total = amount?["totalKb"].number
        return tile(title, value: ServerWords.percent(key, facts),
            detail: used.flatMap { used in total.map { NativeMACHINESServersDashboard.gigabytes(used: used, total: $0) } } ?? "",
            progress: ServerWords.share(key, facts))
    }
    private func tile(_ label: String, value: String, detail: String, progress: Double?) -> some View {
        Button(action: onHealth) {
            VStack(alignment: .leading, spacing: 7) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text(detail.isEmpty ? " " : detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let progress {
                    GeometryReader { geometry in
                        Capsule().fill(Color.secondary.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(label == "Storage" && progress >= 0.7 ? Color.orange : Color.secondary)
                                    .frame(width: geometry.size.width * progress)
                            }
                    }.frame(height: 5)
                } else { Color.clear.frame(height: 5) }
            }
            .padding(16).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            .background(MACHINESTokens.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MACHINESTokens.hairline, lineWidth: 1))
        }.buttonStyle(MACHINESRowStyle()).help("Open server health")
    }
}

struct NativeMACHINESCodingRows: View {
    let facts: ServerFacts?
    var checking = false
    var onRefresh: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding AIs").font(.system(size: 15, weight: .semibold))
            MACHINESCard {
                if checking {
                    skeleton
                } else {
                    switch facts?["agents"] {
                    case .yes(let raw):
                        if let rows = CodingAIAgentOnServer.parseList(raw) {
                            if rows.isEmpty { Label("No Coding AIs found", systemImage: "terminal").foregroundStyle(.secondary) }
                            else { agentRows(rows) }
                        } else { unavailable("The Coding AI reply could not be read.") }
                    case .no:
                        Label("No Coding AIs found", systemImage: "terminal").foregroundStyle(.secondary)
                    case .cannot(let reason): unavailable(reason)
                    case nil: unavailable("No Coding AI checks were returned.")
                    }
                }
            }
        }
    }
    private var skeleton: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 150, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 220, height: 10)
                    }
                    Spacer()
                }
            }
        }.accessibilityLabel("Checking Coding AIs")
    }
    private func unavailable(_ reason: String) -> some View {
        HStack(spacing: 12) {
            NativeMACHINESInlineNotice(text: "Coding AIs couldn’t be checked").help(reason)
            Spacer()
            if let onRefresh { DeckRetryButton("Try again", autoRetry: true, action: onRefresh) } // autoRetry: re-reads this server's state
        }
    }
    private func agentRows(_ rows: [CodingAIAgentOnServer]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                HStack(spacing: 12) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CodingAICatalog.label(row.id)).fontWeight(.semibold)
                        Text(row.version.isEmpty ? "Version not measured" : row.version)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.account ?? (row.signedIn == .yes ? "Signed in" : row.signedIn == .no ? "Not signed in" : "Sign-in not checked"))
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
        }
    }
}

struct NativeMACHINESHealth: View {
    let state: ServerRoomState?
    let now: Double
    let onRefresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Health").font(.system(size: 15, weight: .semibold)); Spacer(); Button("Check now", action: onRefresh) }
            MACHINESCard {
                let cards = state?.view?.cards ?? []
                let stopped = cards.filter { $0.running == false }
                let unknown = cards.filter { $0.running == nil }
                if state == nil || state?.link == .connecting {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 240, height: 14)
                        }
                    }.accessibilityLabel("Checking server health")
                } else if state?.link == .failed {
                    NativeMACHINESInlineNotice(text: "Server health couldn’t be checked").help(state?.problem ?? "")
                } else if cards.isEmpty {
                    Label("No app status measurements returned", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                } else {
                    if stopped.isEmpty && unknown.isEmpty {
                        Label("Everything checked is running", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(stopped) { card in
                        HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text("\(card.name) is stopped"); Spacer() }.padding(.vertical, 6)
                    }
                    ForEach(unknown) { card in
                        HStack { Image(systemName: "questionmark.circle").foregroundStyle(.secondary); Text("\(card.name) hasn’t been checked"); Spacer() }.padding(.vertical, 6)
                    }
                }
                ForEach(state?.view?.cannot ?? [], id: \.what) { fact in
                    HStack { Text(fact.what); Spacer(); Text(fact.why).foregroundStyle(.secondary).lineLimit(1).help(fact.why) }.padding(.vertical, 6)
                }
            }
        }
    }
}

struct NativeMACHINESHealthDuties: View {
    let server: CodingAIServer
    let writesDisabled: Bool
    @State private var holder = NativeAppsSRV2ServerHolder()
    var body: some View {
        MACHINESCard {
            VStack(alignment: .leading, spacing: 12) {
                NativeAppsSRV2ServerSectionList(model: holder.model(serverID: server.id, serverName: server.name),
                    writesDisabled: writesDisabled, sections: [.cleanup, .history])
            }
        }
    }
}

/// Warnings keep neutral words and surfaces; only the small symbol is orange.
struct NativeMACHINESInlineNotice: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(text)
        }
    }
}
