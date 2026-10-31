import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Reads

    func loadAll() async {
        async let bundle: () = loadBundle()
        async let extras: () = loadExtras()
        async let routine: () = loadRoutine()
        async let more: () = loadMore()
        async let comments: () = loadComments()
        async let commentExtras: () = loadCommentExtras()
        async let activity: () = loadActivity()
        async let workspace: () = loadWorkspace()
        async let related: () = loadRelated()
        _ = await (bundle, extras, routine, more, comments, commentExtras, activity, workspace, related)
    }

    func loadBundle() async {
        let previews = Dictionary(uniqueKeysWithValues: (attachments ?? []).compactMap { row in row.previewUrl.map { (row.id, $0) } })
        switch await call("fetchTaskDetailBundle", [taskId, Array(previews.keys)]) {
        case .failure(let problem):
            bundleState = .error(problem.message)
        case .success(let r):
            guard let b = CrmDecode.bundle(r["bundle"]) else {
                bundleState = .error("Could not load this task.")
                return
            }
            people = b.people
            subtasks = b.subtasks
            checklists = b.checklists
            dependencies = b.dependencies
            attachments = b.attachments.map { row in
                var row = row
                if row.previewUrl == nil { row.previewUrl = previews[row.id] }
                return row
            }
            if !b.subtasks.isEmpty { shown.insert(.subtasks) }
            if !b.checklists.isEmpty { shown.insert(.checklist) }
            if !b.dependencies.isEmpty { shown.insert(.dependencies) }
            if !b.attachments.isEmpty { shown.insert(.attachments) }
            bundleState = .ready
        }
    }

    func loadRelated() async {
        guard connected != nil, case .success(let r) = await call("fetchTaskLinks", [taskId]) else { return }
        let links = (r["links"] as? [Any] ?? []).compactMap { raw -> TagHit? in
            guard let h = raw as? [String: Any], let id = h["id"] as? String, let area = h["area"] as? String else { return nil }
            return TagHit(area: area, id: id, label: h["label"] as? String ?? id, secondary: nil, status: nil, href: h["href"] as? String ?? "")
        }
        related = Related(links: links, areas: r["areas"] as? [String] ?? [], supported: TasksJSON.isTrue(r["supported"]))
    }

    /// Links or unlinks records; shown at once, put back with the refusal when the system says no.
    func setRelated(_ links: [TagHit]) {
        guard let before = related else { return }
        related?.links = links
        Task {
            let wire: [[String: Any]] = links.map { ["area": $0.area, "id": $0.id, "label": $0.label, "href": $0.href] }
            if !(await write("setTaskLinks", [taskId, wire], label: "Related to")) { related = before }
            await loadRelated()
        }
    }

    func retryBundle() {
        bundleState = .loading
        Task { await loadBundle() }
    }

    func loadExtras() async {
        switch await call("fetchTaskPageExtras", [taskId]) {
        case .success(let r): extras = CrmDecode.extras(r["extras"])
        case .failure(let problem): extrasError = problem.message
        }
    }

    func loadRoutine() async {
        switch await call("fetchRoutine", [taskId]) {
        case .success(let r):
            routine = CrmDecode.routine(r["routine"])
            routineError = nil
        case .failure(let problem):
            routineError = problem.message
        }
    }

    func loadMore() async {
        let raw: Any
        do {
            guard EngineBridge.shared.isReady else { return }
            if let connected {
                raw = await ConnectedTasksStore.shared.popupCall(connected.connection, "fetchTaskMore", [.string(taskId)]).foundation ?? NSNull()
            } else {
                raw = try await EngineBridge.shared.invoke("tasks:local-detail", ["fetchTaskMore", [taskId]])
            }
        } catch {
            moreError = "Couldn't load follow, reminders and archive — try again."
            return
        }
        let r = TasksJSON.record(raw)
        if TasksJSON.isTrue(r?["ok"]), let m = CrmDecode.more(r?["more"]) {
            more = m
            moreError = nil
        } else if TasksJSON.isTrue(r?["notReady"]) {
            // Before its migration, what needs it is hidden, never shown disabled.
            moreError = nil
        } else {
            moreError = "Couldn't load follow, reminders and archive — try again."
        }
    }

    func loadComments() async {
        commentsSequence &+= 1; let sequence = commentsSequence
        let generation = threadGeneration
        let result = await call("listTaskComments", [taskId])
        guard !Task.isCancelled, generation == threadGeneration, sequence == commentsSequence else { return }
        switch result {
        case .success(let r):
            let rows = r["comments"] as? [Any] ?? []
            comments = rows.compactMap(CrmDecode.comment)
            commentThreadUIReady = TasksJSON.isTrue(r["deliveryAvailable"])
            let capabilities = r["capabilities"] as? [String: Any] ?? [:]
            commentCapabilities = capabilities.mapValues(TasksJSON.isTrue)
            let proof = (r["writing"] as? [String: Any]).flatMap(FIXESTaskWritingProof.init(json:))
            commentWritingProof = proof.flatMap {
                $0.taskID == taskId && ($0.agentID == row.assignee || $0.agentID == row.handedFrom) ? $0 : nil
            }
            commentDeliveries = Dictionary(rows.compactMap { raw -> (String, FIXESCommentDelivery)? in
                guard let value = raw as? [String: Any], let id = value["id"] as? String,
                      let receipt = value["delivery"] as? [String: Any], let decoded = FIXESCommentDelivery(json: receipt) else { return nil }
                return (id, decoded)
            }, uniquingKeysWith: { _, last in last })
            commentMentionDeliveries = Dictionary(rows.compactMap { raw -> (String, [FIXESCommentDelivery])? in
                guard let value = raw as? [String: Any], let id = value["id"] as? String,
                      let list = value["mentionDeliveries"] as? [Any] else { return nil }
                let decoded = list.compactMap { ($0 as? [String: Any]).flatMap(FIXESCommentDelivery.init(json:)) }
                return decoded.isEmpty ? nil : (id, decoded)
            }, uniquingKeysWith: { _, last in last })
            commentWritingCandidates = (r["writingCandidates"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(FIXESWritingCandidate.init(json:)) }
            commentsError = nil
        case .failure(let problem):
            comments = []
            commentWritingProof = nil
            commentsError = problem.message
        }
    }

    func loadCommentExtras() async {
        extrasSequence &+= 1; let sequence = extrasSequence
        let generation = threadGeneration
        if case .success(let r) = await call("fetchCommentExtras", [taskId]) {
            guard !Task.isCancelled, generation == threadGeneration, sequence == extrasSequence else { return }
            commentExtras = CrmDecode.commentExtras(r["extras"])
        }
    }

    func loadActivity() async {
        activitySequence &+= 1; let sequence = activitySequence
        let generation = threadGeneration
        let result = await call("listTaskActivity", [taskId])
        guard !Task.isCancelled, generation == threadGeneration, sequence == activitySequence else { return }
        switch result {
        case .success(let r):
            activity = (r["rows"] as? [Any] ?? []).compactMap(CrmDecode.activity)
            activityTotal = TasksJSON.number(r["total"]).map { Int($0) }
            activityError = nil
        case .failure(let problem):
            activity = []
            activityTotal = nil
            activityError = problem.message
        }
    }

    func refreshActivity() { Task { await loadActivity() } }

    /// A Fields "Button" changed the status or commented, or a Files field uploaded:
    /// everything it could have touched is read again.
    func refetchAll() {
        Task {
            await loadBundle()
            await loadActivity()
            // #317: the guarded read (an older answer never wins), with receipts and capabilities.
            await loadComments()
        }
    }

}
