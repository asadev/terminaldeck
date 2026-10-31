import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One open task's popup: everything the reference CRM's task page reads and
/// writes (src/renderer/crm-task/task-detail-panel.tsx), each call one
/// `tasks:local-detail` call — its function's name and arguments — answered by the
/// engine with the CRM's own result shape. Changes show at once and are put back,
/// with the refusal said, when the engine refuses them.
@MainActor
@Observable
final class TaskDetailModel {
    enum Section: String, CaseIterable { case subtasks, checklist, dependencies, attachments }
    enum Load: Equatable { case loading, error(String), ready }

    let taskId: String
    var row: TaskRow
    var team: [CrmPerson]
    let me: String
    /// Set when the task lives in a connected task system: every call goes to that system
    /// (through `connected-tasks:detail`), as the connected person, with its people.
    let connected: Connected?
    struct Connected: Equatable {
        var connection: String
        var me: String
        var createdBy: String?
        var team: [CrmPerson]
        /// The task's own address in that system (#315: ⋯ › Copy link).
        var link: String? = nil
    }

    /// The most recent refused write, in the engine's own words.
    var error: String?

    // What the popup changed, shown at once; the next state from the engine replaces it.
    var overrides: [String: String?] = [:]
    var overridesAt: Double = 0

    // The bundle: people, subtasks, checklists, dependencies, attachments.
    var bundleState: Load = .loading
    var people: TaskPeople?
    var subtasks: [SubtaskRow]?
    var checklists: [Checklist]?
    var dependencies: [TaskDependency]?
    var attachments: [TaskAttachment]?
    /// Which optional sections are on screen: whatever has rows, plus whatever an action row revealed.
    var shown: Set<Section> = []
    var justAdded: Section?
    /// A dependency kind asked for from a menu, and a key that remounts the section to open its adder.
    var depKind: DependencyKind?
    var depKey = 0

    // Extras: type, tags, time, recurrence options, subtask priority/due.
    var extras: TaskPageExtras?
    var extrasError: String?

    // The routine.
    var routine: RoutineView?
    var routineError: String?
    var routineBusy = false

    // Part 2: reminders, archive, times, tag colours, time-entry tags.
    var more: TaskMore?
    var moreError: String?
    var versions: [DescriptionVersion]?
    var historyOpen = false

    // Linked records (a connected system's task only): what is linked, which kinds can be searched.
    struct Related: Equatable { var links: [TagHit]; var areas: [String]; var supported: Bool }
    var related: Related?

    // Comments and activity.
    var comments: [TaskComment]?
    var commentDeliveries: [String: FIXESCommentDelivery] = [:]
    /// #109: receipts of the other agents (or Hoot) @asked in a comment.
    var commentMentionDeliveries: [String: [FIXESCommentDelivery]] = [:]
    /// Recipients that have a comment and have not answered, with their session.
    var commentWritingCandidates: [FIXESWritingCandidate] = []
    /// Last pushed `session:status` of those sessions.
    var liveSessionStatus: [String: String] = [:]
    /// Tests inject these; the app reads Hoot's chat and the session's live status.
    @ObservationIgnored var hootBusyOverride: (@MainActor () -> Bool)?
    @ObservationIgnored var sessionStatusOverride: (@MainActor (String) -> String?)?
    @ObservationIgnored var sessionStatusSubscription: EngineSubscription?
    var commentCapabilities: [String: Bool] = [:]
    var commentPaneSelection: FIXESTaskThreadPane = .comments
    var commentThreadUIReady = false
    var commentWritingProof: FIXESTaskWritingProof?
    var commentDeliveryPending: Set<String> = []
    @ObservationIgnored var commentAgentProfiles: [AgentProfile] = []
    var commentsError: String?
    var commentExtras: CommentExtras?
    var activity: [TaskActivityRow]?
    var activityError: String?
    var activityTotal: Int?

    // Files on their way.
    struct PendingUpload: Identifiable { let id = UUID(); let fileName: String; let sizeBytes: Int }
    var pending: [PendingUpload] = []
    var linking = false

    // The page's own state.
    var activityOpen = true
    var hideEmpty = false
    var full = false

    // The task's own workspace.
    struct WorkspaceShown: Equatable { var folder, branch, repo, state: String; var reason: String? }
    struct WorkspaceView: Equatable { var workspace: WorkspaceShown?; var refusal: String? }
    var workspace: WorkspaceView?
    var workspaceBusy = false
    var workspaceNote: (ok: Bool, text: String)?

    @ObservationIgnored var seen: [String: String] = [:]
    @ObservationIgnored var activityTimer: Task<Void, Never>?
    @ObservationIgnored var renameTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var renameOrigins: [String: String] = [:]
    @ObservationIgnored var routineSaving = false
    @ObservationIgnored let threadTransport: NativeFIXESTaskThreadTransport?
    @ObservationIgnored var threadSubscription: NativeFIXESTaskThreadCancel?
    @ObservationIgnored var threadRefresh: Task<Void, Never>?
    @ObservationIgnored var threadGeneration: UInt64 = 0
    @ObservationIgnored var threadEpoch: UInt64 = 0
    @ObservationIgnored var commentsSequence: UInt64 = 0
    @ObservationIgnored var extrasSequence: UInt64 = 0
    @ObservationIgnored var activitySequence: UInt64 = 0

    init(row: TaskRow, agents: [AgentProfile], connected: Connected? = nil,
         threadTransport: NativeFIXESTaskThreadTransport? = nil, loadOnOpen: Bool = true) {
        self.threadTransport = threadTransport
        self.commentAgentProfiles = agents
        taskId = row.id
        self.row = row
        self.connected = connected
        me = connected?.me ?? CrmPeople.me
        team = connected?.team ?? CrmPeople.local(agents.map { ($0.id, $0.name) })
        overridesAt = row.updatedAt
        let task = CrmTask(row, team: team)
        // Seeded with the line already known: "You created this task · when".
        if let created = task.createdAt {
            activity = [TaskActivityRow(id: "local-created-\(row.id)", taskId: row.id, kind: "created", payload: [:],
                                        actor: team.first { $0.id == task.createdBy }, actorUserId: task.createdBy, createdAt: created)]
        }
        seen = fingerprint(task)
        if loadOnOpen { Task { [weak self] in await self?.loadAll() } }
    }

    func startThreadUpdates() {
        guard threadSubscription == nil else { return }
        threadEpoch &+= 1; let epoch = threadEpoch
        threadSubscription = (threadTransport ?? .live).observe { [weak self] in
            guard let self, self.threadEpoch == epoch, self.threadSubscription != nil else { return }
            self.refreshThread()
        }
        // "<name> is writing…": the recipient's session status is pushed; nothing polls.
        if threadTransport == nil, sessionStatusSubscription == nil {
            sessionStatusSubscription = EngineBridge.shared.on("session:status") { [weak self] args in
                guard let self, let event = IntentHoot.statusEvent(args),
                      self.commentWritingCandidates.contains(where: { $0.sessionID == event.id }) else { return }
                self.liveSessionStatus[event.id] = event.status
            }
        }
    }
    func stopThreadUpdates() {
        threadEpoch &+= 1
        commentWritingProof = nil
        sessionStatusSubscription?.cancel(); sessionStatusSubscription = nil
        threadSubscription?.cancel(); threadSubscription = nil
        threadRefresh?.cancel(); threadRefresh = nil; threadGeneration &+= 1
    }
    func refreshThread() {
        threadRefresh?.cancel(); threadGeneration &+= 1
        threadRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.loadComments()
            guard !Task.isCancelled else { return }
            await self.loadCommentExtras()
            await self.loadActivity()
        }
    }

}
