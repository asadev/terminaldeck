import Observation
import SwiftUI
import TerminalDeckNativeCore

@MainActor @Observable
final class NativeGHJobLogModel {
    let repo: String
    let jobID: Int
    var text = ""
    var loading = false
    var complete = false
    var error: String?
    var cursor = 0
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var opening: Task<Void, Never>?

    init(repo: String, jobID: Int) { self.repo = repo; self.jobID = jobID }

    func start() {
        stop()
        let id = UUID().uuidString
        streamID = id
        loading = true
        complete = false
        text = ""
        error = nil
        cursor = 0
        // Subscribe before opening: a short archived log can finish before the
        // open call replies. Stream identity rejects any late old-job event.
        subscription = EngineBridge.shared.on("github:logs:data") { [weak self] args in
            MainActor.assumeIsolated {
                self?.receive(CodingAIJSON(args.first), expectedID: id)
            }
        }
        opening = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = CodingAIJSON(try await EngineBridge.shared.invoke("github:logs:open", [["repo": repo, "jobId": jobID, "streamId": id]]))
                guard streamID == id, !Task.isCancelled else {
                    _ = try? await EngineBridge.shared.invoke("github:logs:close", [id])
                    return
                }
                if answer["ok"].bool == false || !answer["error"].isNull {
                    throw NativeGHFailure(message: answer["error"]["message"].text ?? answer["error"].text ?? "Could not open this job’s logs. Refresh and try again.")
                }
            } catch {
                guard streamID == id, !Task.isCancelled else { return }
                self.error = CodingAIErrorText.from(error, fallback: "Could not open this job’s logs. Refresh and try again.")
                loading = false
                subscription?.cancel()
                subscription = nil
            }
        }
    }

    func stop() {
        let previous = streamID
        streamID = nil
        opening?.cancel()
        opening = nil
        subscription?.cancel()
        subscription = nil
        loading = false
        if let previous { Task { _ = try? await EngineBridge.shared.invoke("github:logs:close", [previous]) } }
    }

    private func receive(_ event: CodingAIJSON, expectedID: String) {
        guard streamID == expectedID, event["streamId"].text == expectedID else { return }
        if let message = event["error"].text ?? event["error"]["message"].text {
            error = message
            loading = false
            complete = true
        } else {
            let nextCursor = event["cursor"].ghInt ?? cursor
            guard nextCursor >= cursor || event["reset"].isTrue else { return }
            if event["reset"].isTrue { text = ""; cursor = 0 }
            if nextCursor > cursor || text.isEmpty { text += event["text"].string ?? "" }
            cursor = nextCursor
            complete = event["complete"].isTrue
            loading = !complete
            if event["truncated"].isTrue { error = "This view reached its log limit. Use the secondary GitHub link to download the full log." }
        }
        if complete { subscription?.cancel(); subscription = nil }
    }
}

/// The server downloads one archived log and streams its chunks into this view.
/// GitHub's REST API does not provide an unfinished job's live terminal output.
struct NativeGHJobLogs: View {
    let repo: String
    let jobID: Int
    let jobURL: String?
    @State private var model: NativeGHJobLogModel
    @State private var lineLimit = 1000

    init(repo: String, jobID: Int, jobURL: String?) {
        self.repo = repo
        self.jobID = jobID
        self.jobURL = jobURL
        _model = State(initialValue: NativeGHJobLogModel(repo: repo, jobID: jobID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Job logs").font(.callout.weight(.semibold))
                if model.loading { ProgressView().controlSize(.small); Text("Receiving…").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Copy") { DeckProject.copy(model.text) }.disabled(model.text.isEmpty)
                Button("Refresh") { lineLimit = 1000; model.start() }.disabled(model.loading)
            }
            .controlSize(.small)
            Text("GitHub makes full job logs available after the job finishes. Refresh to read the latest available copy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { NativeGHErrorNote(message: error) { model.start() } }
            if model.text.isEmpty {
                if model.loading { NativeGHListSkeleton().frame(height: 190) }
                else if model.error == nil { NativePageNote("This job has no log text.").padding(16) }
            } else {
                let lines = model.text.components(separatedBy: "\n")
                GeometryReader { viewport in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.prefix(lineLimit).enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                                    Text(line.isEmpty ? " " : line).fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 12, design: .monospaced)).padding(.vertical, 1)
                            }
                            if lines.count > lineLimit {
                                Button("Show next \(min(1000, lines.count - lineLimit)) lines") { lineLimit += 1000 }.padding(12)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                        .padding(8)
                    }
                }
                .frame(height: 320)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                .clipShape(.rect(cornerRadius: 8))
            }
            if let jobURL { NativeGHSecondaryLink(url: jobURL) }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
