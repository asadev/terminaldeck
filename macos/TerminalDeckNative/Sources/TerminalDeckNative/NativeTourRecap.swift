import Observation
import SwiftUI
import TerminalDeckNativeCore

/// "What it found" — copilot/driving/TourRecap.tsx, drawn in Swift, for Hoot's
/// screen (lane R) and Settings → Hoot (lane E2) to embed: the last few finished
/// tours from `deck-control:tours`, each a card with its answer grouped by
/// session, and "Take me there" to box a stop again.
struct NativeTourRecap: View {
    var limit = 5
    @State private var model = TourRecapModel()

    var body: some View {
        Group {
            if model.records.isEmpty {
                // Draws nothing until there is something, as on the page — but exists,
                // so it appears and starts reading.
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What it found").font(.system(size: 15, weight: .semibold))
                    Text("Written by the app, outside Hoot’s folder — every quote is the text it checked before it put a box around it.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(model.records, id: \.id) { record in
                        AnswerCard(model: model, record: record)
                    }
                }
            }
        }
        .onAppear { model.start(limit: limit) }
        .onDisappear { model.stop() }
        .onChange(of: DriveHost.shared.copilotFront) { _, front in if front { model.load() } }
    }
}

@MainActor
@Observable
final class TourRecapModel {
    private(set) var records: [TourRecord] = []
    var open: String?
    private(set) var pointed: String?
    @ObservationIgnored private var limit = 5
    @ObservationIgnored private var opened: String?
    @ObservationIgnored private var subscription: EngineSubscription?

    func start(limit: Int) {
        self.limit = limit
        load()
        if subscription == nil {
            // A finished scan announces itself as a `tour.play` action row.
            subscription = EngineBridge.shared.on("deck-control:action") { [weak self] args in
                if DriveTour.isScanRow(args.first) { self?.load() }
            }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        if pointed != nil { DriveHost.shared.point(nil) }
    }

    func load() {
        let limit = self.limit
        Task {
            guard let raw = try? await EngineBridge.shared.invoke(DriveTour.toursChannel, [limit]) else { return }
            let found = DriveTour.records(raw)
            records = found
            let newest = found.first?.id
            if newest == opened { return }
            opened = newest
            open = newest
            pointed = nil
        }
    }

    func takeMeThere(_ stop: TourStopRecord, key: String) {
        if pointed == key {
            pointed = nil
            DriveHost.shared.point(nil)
            return
        }
        AppModel.shared.select(stop.sessionId)
        if stop.kind == "anchor" && stop.at == "git-file" { DeckPage.navigate("git") }
        if let target = DriveTour.focus(stop) { DriveHost.shared.point(target) }
        pointed = key
    }
}

private struct AnswerCard: View {
    let model: TourRecapModel
    let record: TourRecord

    var body: some View {
        let open = model.open == record.id
        let stopped = DriveTour.stoppedSentence(record)
        let dropped = DriveTour.droppedSentence(record.dropped)
        let grouped = Scan.groupBySession(record.stops, background: record.background)
        VStack(alignment: .leading, spacing: 8) {
            Button { model.open = open ? nil : record.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.question).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                    Text("\(when(record.startedAt)) · \(Scan.answerSummary(grouped))\(record.background ? " Found without driving." : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? .isSelected : [])

            if open {
                Text(record.headline).font(.callout)
                if !stopped.isEmpty || !dropped.isEmpty {
                    Text([stopped, dropped].filter { !$0.isEmpty }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.sessionId) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(session.lines.enumerated()), id: \.offset) { position, line in
                            let stop = DriveTour.nthStop(record, sessionId: session.sessionId, position: position)
                            let key = "\(record.id):\(session.sessionId):\(position)"
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(DriveTour.reasonLabel(line.why)).font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                                    if !line.shown { Text("Not reached").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Text(line.note).font(.callout)
                                if !line.quote.isEmpty {
                                    Text(line.quote).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .padding(6).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                                }
                                if let why = stop?.degradedWhy { Text(why).font(.caption).foregroundStyle(.orange) }
                                if let stop {
                                    Button(model.pointed == key ? "Take the box off" : "Take me there") { model.takeMeThere(stop, key: key) }
                                        .buttonStyle(.link)
                                }
                            }
                            .opacity(line.shown ? 1 : 0.7)
                        }
                    }
                }
                if !record.dropped.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not shown").font(.caption.weight(.semibold))
                        ForEach(Array(record.dropped.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(entry.title).font(.callout)
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    /// `new Date(at).toLocaleString()`.
    private func when(_ at: Double) -> String {
        guard at.isFinite, at > 0 else { return "" }
        return Date(timeIntervalSince1970: at / 1000).formatted(date: .numeric, time: .standard)
    }
}
