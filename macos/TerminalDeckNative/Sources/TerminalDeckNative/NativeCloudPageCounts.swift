import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Page-names lane (owner, 13 Nov): the ONE source of every number Settings → Cloud and the Your Cloud window show,
/// read from what is really on this Mac: its own memory (notes, diary entries, topics, settings, and what has arrived
/// but is not added yet), its own project and agent lists, and its instruction files. Both views read `counts`, so the
/// same thing has the same number in both. Read only: nothing is written, sent or asked of the network.
@MainActor @Observable
final class NativeCloudPageCounts {
    static let shared = NativeCloudPageCounts()
    /// nil until the first read; the pages then say "All saved" with no number.
    private(set) var counts: BackendCloudPageCounts?
    /// Note titles by their place in the memory folder, so a note is named by its title, never its file name.
    @ObservationIgnored private(set) var titles: [String: String] = [:]
    /// Lane L4: what each note is, by its place in the memory folder (one item per note on both pages).
    @ObservationIgnored private(set) var noteFacts: [String: BackendCloudNoteFacts] = [:]
    /// Lane L4: the dated earlier copies this Mac keeps (read with the titles).
    @ObservationIgnored private(set) var keptCopies: Set<String> = []
    /// CLOUD-FILES-2: places this Mac deleted by Clean up / Empty Bin, and their former places.
    @ObservationIgnored private(set) var deletedHere: Set<String> = []
    /// One rule phase 2: the memory store's ONE Bin, its kept texts by place, their count, and the missing-notes line.
    @ObservationIgnored private(set) var memoryBin: [DeckMemoryBinItem] = []
    @ObservationIgnored private(set) var memoryKept: [String: [DeckMemoryKeptVersion]] = [:]
    @ObservationIgnored private(set) var memoryKeptCount: Int?
    @ObservationIgnored private(set) var memoryMissingLine: String?
    @ObservationIgnored private(set) var memoryAnswer: DeckMemoryAnswer?
    /// Lane L3 slice 1: what waits for his answer about the Cloud folder.
    @ObservationIgnored private(set) var folderAnswer: CloudFolderAnswer?
    /// Review 14 Nov (point 4): the Cloud folder's Bin, its "newer one is in use" lines, and its page lines.
    @ObservationIgnored private(set) var folderBin: [CloudFolderKept] = []
    @ObservationIgnored private(set) var folderReplaced: [CloudVersionReplacedLine] = []
    @ObservationIgnored private(set) var folderLines: [String] = []
    /// Lane L3 slice 2: the artifacts' question, their Bin on this Mac and their page lines.
    @ObservationIgnored private(set) var artifactsAnswer: CloudFolderAnswer?
    @ObservationIgnored private(set) var artifactsBin: [CloudFolderKept] = []
    @ObservationIgnored private(set) var artifactsLines: [String] = []
    @ObservationIgnored private var titlesReadAt: Date?
    @ObservationIgnored private var reading = false

    /// Pictures and checks: fixed numbers that no refresh replaces (nil ends it). Nothing of this Mac is read meanwhile.
    @ObservationIgnored private var fixed = false
    func fixture(_ counts: BackendCloudPageCounts?) { self.counts = counts; fixed = counts != nil }
    func refresh(snapshot: CloudAccountSnapshot, includeBin: Bool = true) async {
        guard !reading, !fixed else { return }
        reading = true
        defer { reading = false }
        var made = BackendCloudPageCounts()
        // Titles change rarely: read at most every 30 seconds; the counts every time.
        let withTitles = titlesReadAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
        if DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore,
           let read = try? await store.cloudPageRead(withTitles: withTitles, includeBin: includeBin) {
            made.here = read.here
            made.arriving = read.arriving
            made.missing = read.missing
            noteFacts = read.noteFacts
            deletedHere = read.deletedHere
            memoryBin = read.memoryBin
            memoryKept = read.memoryKept
            memoryKeptCount = read.memoryKeptCount
            if withTitles { titles = read.titles; keptCopies = read.keptCopies; titlesReadAt = Date() }
        }
        // Page-names 2 (MacBook: "1 project and 1 agent" while his account holds 4 projects and 78 agents): the projects
        // and agents of his account, from the record store that carries them: here, and still arriving. The project
        // list on screen started as the one built-in project and the Agents list only fills once that page is read,
        // so neither is counted from any more.
        if let records = NativeCloudRecords.shared.records, let account = await NativeCloudRecords.accountCounts(records) {
            if records.projects != nil {
                made.here[.projects] = account.projectsHere
                if account.projectsArriving > 0 { made.arriving[.projects] = account.projectsArriving }
            }
            if records.agents != nil {
                made.here[.agents] = account.agentsHere
                if account.agentsArriving > 0 { made.arriving[.agents] = account.agentsArriving }
            }
        }
        if let files = BackendCloudPageCounts.instructionFilesHere(snapshot) { made.here[.instructionFiles] = files }
        // Lane L3: this Mac's own tasks and his settings that travel, counted from the two owners (plain numbers).
        if let kinds = NativeCloudBrainRegistration.kinds {
            let counts = await kinds.counts()
            if let tasks = counts.tasks { made.here[.tasks] = tasks }
            if let settings = counts.settings { made.here[.appSettings] = settings }
        }
        // Lane L3 slice 1: the files in his Cloud folder that travel, and their size, from the folder's owner.
        if let folder = NativeCloudFolder.current {
            folderAnswer = try? await folder.waitingAnswer()
            folderBin = includeBin ? ((try? await folder.bin()) ?? []) : []
            var names: [String: String] = [:]
            for device in snapshot.devices { names[device.deviceId.lowercased()] = BackendCloudContentsWords.plain(device.shownName) }
            folderReplaced = (try? await folder.replacedLines(names: names)) ?? []
            folderLines = (try? await folder.pageLines()) ?? []
            if folderAnswer?.folderMissing == true {
                folderLines.removeAll { $0.hasPrefix("Your Cloud folder is not on this Mac") }
                folderLines.insert("Your Cloud folder is not on this Mac", at: 0)
            }
        } else {
            folderAnswer = nil; folderBin = []; folderReplaced = []; folderLines = []
        }
        if let folder = NativeCloudFolder.current, let counted = try? await folder.counts() {
            made.here[.cloudFolder] = counted.files
            made.cloudFolderBytes = counted.bytes
        }
        // Lane L3 slice 2: artifacts that travel, their size, question, Bin and lines, from their owner.
        if let artifacts = NativeCloudArtifacts.shared.owner {
            artifactsAnswer = try? await artifacts.owner.waitingAnswer()
            let projects = Dictionary(NativePROJLabels.shared.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            artifactsBin = includeBin ? ((try? await artifacts.bin(projects: projects)) ?? []) : []
            artifactsLines = (try? await artifacts.pageLines()) ?? []
            if let counted = try? await artifacts.counts() {
                made.here[.artifacts] = counted.artifacts
                made.artifactsBytes = counted.bytes
            }
        } else {
            artifactsAnswer = nil; artifactsBin = []; artifactsLines = []
        }
        made.waitingForFolder = BackendCloudPageCounts.instructionFilesWaitingForFolder(snapshot)
        // Status-line lane: space used per kind, from the same snapshot, with the account's room left.
        made.space = BackendCloudSpace.make(snapshot, bytesLeft: NativeCloudAccount.shared.storageLeft)
        if counts != made { counts = made }
    }
}
