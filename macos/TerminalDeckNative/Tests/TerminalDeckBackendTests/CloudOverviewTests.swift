import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Hand-over item 3: the ONE place on Settings → Cloud that says where this Mac stands. Pure state; fixtures only.
@Suite("Cloud page — the one place that says where this Mac stands with the Cloud")
struct CloudOverviewTests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let idA = "10000000-0000-4000-8000-00000000000a"
    static let idB = "10000000-0000-4000-8000-00000000000b"

    private func coverage(_ row: String, items: Int = 3, complete: Bool = true, reasons: [String] = [], exclusions: [String] = []) -> CloudCoverage {
        CloudCoverage(sourceId: "fixture-" + row, inventoryRow: row, complete: complete, items: items, bytes: 10, blockedReasons: reasons, exclusions: exclusions)
    }
    private func snapshot(coverage: [CloudCoverage] = [], queued: Int = 0, blocked: Int = 0, problem: String? = nil,
                          trust: [CloudDeviceTrustRow] = [], held: Int = 0, refused: Int = 0, notice: String? = nil,
                          baseline: CloudBaselineProgress? = nil, head: UInt64? = 7, fetched: UInt64? = 7,
                          phase: CloudAccountSnapshot.Phase = .signedIn) -> CloudAccountSnapshot {
        let cloudHead: CloudSequence? = head.map { CloudSequence($0) }
        let mine: CloudSequence? = fetched.map { CloudSequence($0) }
        return CloudAccountSnapshot(phase: phase, gate: Self.gate, displayName: "Fixture", coverage: coverage, waitingRecords: queued,
                                    blockedRecords: blocked, problem: problem, trust: trust, heldChanges: held, refusedPacks: refused,
                                    trustNotice: notice, baseline: baseline, cloudHead: cloudHead, fetched: mine)
    }
    private func memoryOn(_ snapshot: CloudAccountSnapshot, newMac: Bool = false) -> BackendCloudOverviewInput {
        BackendCloudOverviewInput(snapshot: snapshot, newMacPending: newMac, memory: memory(true))
    }
    private func device(_ id: String, _ name: String, waiting: Int, readable: Bool = true, removed: Bool = false) -> CloudDeviceTrustRow {
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")
        return CloudDeviceTrustRow(deviceId: id, name: name, standing: .new, code: readable ? "4F2A 91C3 B07E 55D1 8A2C" : nil, keyId: nil,
                                   signKey: readable ? key : nil, waiting: waiting, removed: removed)
    }
    private func passwords(_ standing: BackendCloudSecretsPage.Standing) -> BackendCloudSecretsPage {
        var page = BackendCloudSecretsPage()
        page.standing = standing
        return page
    }
    private func memory(_ included: Bool?) -> BackendCloudOverviewInput.Memory { BackendCloudOverviewInput.Memory(included: included) }
    private func feature(_ waiting: [BackendCloudOverview.Waiting] = [], notes: [String] = []) -> BackendCloudOverviewInput.Feature {
        BackendCloudOverviewInput.Feature(waiting: waiting, notes: notes)
    }
    private func build(_ input: BackendCloudOverviewInput) throws -> BackendCloudOverview {
        try #require(BackendCloudOverviewBuilder.build(input))
    }

    @Test func savedPasswordsGoingUpOrStillToFetchAreNeverUpToDate_B1() throws {
        // Memory not used on this Mac and no other row: only saved passwords travel. A queued upload or an
        // unfetched change of theirs still keeps the headline off "Up to date" and is said in a line.
        let up = try build(BackendCloudOverviewInput(snapshot: snapshot(queued: 2), memory: memory(false), passwords: passwords(.protected)))
        #expect(up.standing == .saving)
        #expect(up.lines.contains(BackendCloudOverviewWords.goingUp(2)))
        let down = try build(BackendCloudOverviewInput(snapshot: snapshot(head: 12, fetched: 7), memory: memory(false), passwords: passwords(.protected)))
        #expect(down.standing == .catchingUp)
        #expect(down.lines.contains(BackendCloudOverviewWords.behind(5)))
        let unknown = try build(BackendCloudOverviewInput(snapshot: snapshot(head: nil, fetched: nil), passwords: passwords(.protected)))
        #expect(unknown.standing != .upToDate)
    }

    @Test func aSavedPasswordThatFailedOrCouldNotBeCheckedIsNeverProtectedOrSettled_B2() throws {
        // A failed or unreadable check is "could not check" with Check again, never "ready".
        let unknown = try build(BackendCloudOverviewInput(snapshot: snapshot(), passwords: passwords(.unknown)))
        // Page-names 2: said calmly with Check again, never counted as needing the person.
        let unchecked = try #require(unknown.notices.first)
        #expect(unknown.waiting.isEmpty)
        #expect(unchecked.text == BackendCloudOverviewWords.passwordsNotChecked)
        #expect(unchecked.action == .checkAgain)
        #expect(unknown.rows.first?.settled == false)
        var unread = passwords(.protected)
        unread.couldNotCheck = true
        let partly = try build(BackendCloudOverviewInput(snapshot: snapshot(), passwords: unread))
        #expect(partly.standing != .needsYou && partly.standing != .upToDate)
        let partlyActions = partly.notices.map { $0.action }
        #expect(partlyActions == [.checkAgain])
        #expect(partly.rows.first?.settled == false)
        // A failed save is named as a gap: not "Protected", not settled.
        var failed = passwords(.protected)
        failed.gaps = [BackendCloudSecretsWords.notSavedToCloud("Server passwords and saved SSH keys", reason: "The service refused it")]
        let named = try build(BackendCloudOverviewInput(snapshot: snapshot(), passwords: failed))
        #expect(named.standing == .needsYou)
        #expect(named.rows.first?.state != BackendCloudSecretsWords.on)
        #expect(named.rows.first?.settled == false)
        #expect(failed.gaps.first == "Not saved to Cloud from this Mac: Server passwords and saved SSH keys. The service refused it. It is tried again at the next sync.")
    }

    @Test func anUnreadListIsCheckingAndAFailedReadIsSaidWithCheckAgain_B3() throws {
        let starting = try build(BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I11")]), projects: .notReadYet))
        #expect(starting.title == "Checking…")
        let row = try #require(starting.rows.first)
        #expect(row.state == "Checking…")
        #expect(!row.settled)
        let failed = try build(BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I09")]), bootFiles: .unreadable))
        // Page-names 2 (13 Nov): a list that could not be read is not a task: one calm notice with Check again,
        // never counted as needing the person, and the page is still never "Up to date".
        #expect(failed.waiting.isEmpty)
        let line = try #require(failed.notices.first)
        #expect(line.text == BackendCloudOverviewWords.notChecked(.bootFiles))
        #expect(line.action == .checkAgain)
        #expect(failed.rows.first?.settled == false)
        #expect(failed.standing != .upToDate)
        let passwordsRow = try build(BackendCloudOverviewInput(snapshot: snapshot(), passwordsChecking: true))
        let passwordStates = passwordsRow.rows.map { $0.state }
        #expect(passwordStates == ["Checking…"])
        #expect(passwordsRow.standing == .checking)
    }

    @Test func notNowSaysWhatIsNotSentAndThatNoneArrives_B4() throws {
        let notNow = try build(BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I01")]), memory: memory(false)))
        #expect(notNow.notUsedHere)
        #expect(notNow.lines.first == BackendCloudOverviewWords.notUsedHere)
        // Saved passwords are switched on separately, so the line names what is not sent and never says "nothing".
        #expect(BackendCloudOverviewWords.notUsedHere == "Cloud is not used on this Mac yet: its memory, projects, agents and boot files are not sent, and none arrive here.")
        #expect(notNow.standing != .upToDate)
        // No word on the page says only "not sent" for this choice.
        let words = notNow.lines + notNow.rows.flatMap { $0.notes } + notNow.rows.map { $0.state }
        let sentOnly = words.contains { $0.contains("not sent") && !$0.contains("received") && !$0.contains("arrive") }
        #expect(!sentOnly)
        // Answered "Use Cloud here": the memory row is there and the line is gone.
        let used = try build(memoryOn(snapshot(coverage: [coverage("I01")])))
        #expect(!used.notUsedHere)
        #expect(!used.lines.contains(BackendCloudOverviewWords.notUsedHere))
        #expect(BackendCloudOverviewWords.memoryAfterQuestion == "Starts once you have answered whether to use your Cloud on this Mac.")
    }

    @Test func whatThisVersionDoesNotSaveIsSaidOnThePageAndInTheTool_item8() throws {
        let overview = try build(memoryOn(snapshot(coverage: [coverage("I01")])))
        #expect(overview.notSavedInThisVersion == ["Boot files travel only from each project's chosen folder.",
                                                   "Your account-wide instruction files, skills and agents (the ones outside your projects) do not travel yet.",
                                                   "API keys do not travel yet."])
        let wire = overview.wireValue["notSavedInThisVersion"].elements ?? []
        #expect(wire.count == 3)
        #expect(BackendCloudOverviewWords.notSavedTitle == "Not saved in this version")
    }

    @Test func upToDateOnlyWhenEverythingIsSavedFetchedAndNothingWaits() throws {
        let level = snapshot(coverage: [coverage("I01", items: 200), coverage("I02", items: 14)])
        let overview = try build(memoryOn(level))
        #expect(overview.standing == .upToDate)
        #expect(overview.title == "Up to date")
        #expect(overview.waiting.isEmpty)
        #expect(overview.lines == ["Everything on this Mac is saved to your Cloud.", "This Mac has everything your Cloud holds."])
        #expect(overview.rows.count == 1)
        let row = try #require(overview.rows.first)
        #expect(row.kind == .memory)
        #expect(row.title == "Memory")
        #expect(row.state == "All saved")
        #expect(row.settled)
    }

    @Test func neverUpToDateWhileAnythingIsGoingUpToFetchOrWaiting() throws {
        let saved = [coverage("I01")]
        let going = CloudBaselineProgress(total: 50, sent: 20, filesWaiting: 0, waitingUntil: nil, reason: nil)
        let folder = BackendCloudOverview.Waiting(id: "project:p1", text: "Project “Site” needs a folder on this Mac.", action: .chooseFolder(projectId: "p1"))
        let file = BackendCloudOverview.Waiting(id: "file:f1", text: "A file from your Cloud can run a command and waits for you.", action: .acceptFile(id: "f1"))
        var cases: [(name: String, input: BackendCloudOverviewInput, standing: BackendCloudOverview.Standing)] = []
        func add(_ name: String, _ input: BackendCloudOverviewInput, _ standing: BackendCloudOverview.Standing) {
            cases.append((name: name, input: input, standing: standing))
        }
        add("one change still going up", memoryOn(snapshot(coverage: saved, queued: 1)), .saving)
        add("the first save still going up", memoryOn(snapshot(coverage: [coverage("I01", complete: false)], queued: 30, baseline: going)), .saving)
        add("sending held up", memoryOn(snapshot(coverage: saved, blocked: 1)), .saving)
        add("behind the Cloud", memoryOn(snapshot(coverage: saved, head: 9, fetched: 7)), .catchingUp)
        add("going up and behind", memoryOn(snapshot(coverage: saved, queued: 1, head: 9, fetched: 7)), .savingAndCatchingUp)
        add("not known yet", memoryOn(snapshot(coverage: saved, head: nil, fetched: nil)), .notReady)
        add("sources not joined yet", memoryOn(snapshot()), .notReady)
        add("a new device, nothing waiting from it yet", memoryOn(snapshot(coverage: saved, trust: [device(Self.idA, "MacBook Air", waiting: 0)])), .needsYou)
        add("changes of a device Cloud does not list", memoryOn(snapshot(coverage: saved, held: 3)), .needsYou)
        add("a change that could not be checked", memoryOn(snapshot(coverage: saved, refused: 1)), .needsYou)
        add("the trusted list cannot be read", memoryOn(snapshot(coverage: saved, notice: BackendCloudAccount.listUnreadable)), .needsYou)
        add("the new-Mac sheet not answered", memoryOn(snapshot(coverage: saved), newMac: true), .needsYou)
        add("memory short for a reason", memoryOn(snapshot(coverage: [coverage("I01", complete: false, reasons: ["A kept conflict to check."])])), .needsYou)
        add("Cloud not reachable", memoryOn(snapshot(coverage: saved, problem: "Could not reach Cloud. Your local work is kept; Cloud tries again.")), .unreachable)
        add("paused", memoryOn(snapshot(coverage: saved, phase: .paused)), .paused)
        add("memory choice not made", BackendCloudOverviewInput(snapshot: snapshot(), memory: memory(nil)), .notReady)
        add("saved passwords locked", BackendCloudOverviewInput(snapshot: snapshot(), passwords: passwords(.locked)), .needsYou)
        add("this Mac's own saved-password key is lost", BackendCloudOverviewInput(snapshot: snapshot(), passwords: passwords(.keyLost("The key that opens this Mac's own saved passwords is gone."))), .needsYou)
        add("saved passwords cannot be checked", BackendCloudOverviewInput(snapshot: snapshot(), passwords: passwords(.unknown)), .notReady)
        add("a project needs a folder", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I11")]), projects: feature([folder])), .needsYou)
        add("a file waits to be accepted", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I09")]), bootFiles: feature([file])), .needsYou)
        // Review B-M1: saved passwords travel like every other row, in both directions.
        add("a saved password still going up", BackendCloudOverviewInput(snapshot: snapshot(queued: 1), passwords: passwords(.protected)), .saving)
        add("a saved password still to fetch", BackendCloudOverviewInput(snapshot: snapshot(head: 9, fetched: 7), passwords: passwords(.protected)), .catchingUp)
        add("saved-password sending held up", BackendCloudOverviewInput(snapshot: snapshot(blocked: 1), passwords: passwords(.protected)), .saving)
        // Review B-M3: a lane's list not read yet, or unreadable, is unknown: never "Up to date". Page-names 2 (13 Nov):
        // an unreadable list or saved-password check is "Not ready yet" with a Check again notice, not "needs you".
        add("projects just started, nothing read yet", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I11")]), projects: .notReadYet), .checking)
        add("boot files just started, nothing read yet", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I09")]), bootFiles: .notReadYet), .checking)
        add("the projects list could not be read", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I11")]), projects: .unreadable), .notReady)
        add("the boot files list could not be read", BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I09")]), bootFiles: .unreadable), .notReady)
        add("saved passwords not read yet", BackendCloudOverviewInput(snapshot: snapshot(), passwordsChecking: true), .checking)
        #expect(cases.count == 29)
        for item in cases {
            let overview = try build(item.input)
            #expect(overview.standing == item.standing, "\(item.name)")
            #expect(overview.standing != .upToDate, "\(item.name)")
            #expect(overview.title != BackendCloudOverviewWords.upToDate, "\(item.name)")
        }
    }

    @Test func theFirstSaveSaysHowFarItIsAndWhenItContinues() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Dubai"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12)))
        let soon = Int64((noon.timeIntervalSince1970 + 5 * 60) * 1000)
        let going = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 0, waitingUntil: soon, reason: "Cloud asked this Mac to slow down for a moment.")
        let input = memoryOn(snapshot(coverage: [coverage("I01", items: 1_200, complete: false, reasons: ["Not everything is in Cloud yet."])], queued: 3_800, baseline: going))
        let overview = try #require(BackendCloudOverviewBuilder.build(input, now: noon, calendar: calendar))
        #expect(overview.standing == .saving)
        #expect(overview.title == "Saving to your Cloud")
        let row = try #require(overview.rows.first)
        #expect(row.state.hasPrefix("1,200 of 5,000 changes saved; continues by itself at ") && row.state.contains("12:05"))
        #expect(row.state.hasSuffix(". Cloud asked this Mac to slow down for a moment."))
        #expect(!row.settled)
        #expect(overview.lines.first == "This Mac's first save: " + row.state)
        // "Still going up" is not something that waits for the person.
        #expect(overview.waiting.isEmpty)
        // Without a first save: the number of changes still going up, and the row says how far it is.
        let later = try build(memoryOn(snapshot(coverage: [coverage("I01", items: 40, complete: false)], queued: 2)))
        #expect(later.lines.first == "2 changes on this Mac are still going up.")
        #expect(later.rows.first?.state == "Still going up")
    }

    @Test func itSaysWhetherThisMacIsLevelWithTheCloudOrCatchingUp() throws {
        let saved = [coverage("I01")]
        let behind = try build(memoryOn(snapshot(coverage: saved, head: 40, fetched: 28)))
        #expect(behind.standing == .catchingUp)
        #expect(behind.title == "Catching up with your Cloud")
        #expect(behind.lines.contains("This Mac is catching up with your Cloud: 12 changes still to fetch."))
        let level = try build(memoryOn(snapshot(coverage: saved, head: 40, fetched: 40)))
        #expect(level.standing == .upToDate)
        #expect(level.lines.contains("This Mac has everything your Cloud holds."))
        // Changes of a device not yet trusted are read past and said on their own: level, but never "Up to date".
        let waitingDevice = device(Self.idA, "MacBook Air", waiting: 14)
        let held = try build(memoryOn(snapshot(coverage: saved, trust: [waitingDevice], held: 14, head: 40, fetched: 40)))
        #expect(held.lines.contains(BackendCloudOverviewWords.levelExceptUntrusted))
        #expect(held.standing == .needsYou)
        let unknown = try build(memoryOn(snapshot(coverage: saved, head: nil, fetched: nil)))
        #expect(unknown.lines.contains("Not checked yet whether this Mac has everything your Cloud holds."))
        // The account's own answer.
        #expect(snapshot(head: 40, fetched: 28).catchingUp == true)
        #expect(snapshot(head: 40, fetched: 28).behindBy == 12)
        #expect(snapshot(head: 40, fetched: 40).catchingUp == false)
        #expect(snapshot(head: 40, fetched: 40).behindBy == 0)
        #expect(snapshot(head: nil, fetched: nil).catchingUp == nil)
        #expect(snapshot(head: nil, fetched: nil).behindBy == nil)
    }

    @Test func devicesThatWaitAreListedWithTheirTrustButtons() throws {
        let saved = [coverage("I01")]
        let waitingDevice = device(Self.idA, "MacBook Air", waiting: 14)
        let quietDevice = device(Self.idB, "Mac Studio", waiting: 0)
        let overview = try build(memoryOn(snapshot(coverage: saved, trust: [waitingDevice, quietDevice], held: 14)))
        #expect(overview.title == "2 things need you on this Mac")
        let texts = overview.waiting.map { $0.text }
        #expect(texts == ["“MacBook Air” is a new device. 14 changes from it wait until you trust it.",
                          "“Mac Studio” is a new device. Its changes will wait until you trust it."])
        let actions = overview.waiting.map { $0.action }
        #expect(actions == [.trust(deviceId: Self.idA), .trust(deviceId: Self.idB)])
        // A device that cannot be trusted right now is named without a button.
        let unreadable = device(Self.idA, "iMac", waiting: 1, readable: false)
        let blocked = try build(memoryOn(snapshot(coverage: saved, trust: [unreadable], held: 1)))
        let blockedItem = try #require(blocked.waiting.first)
        #expect(blockedItem.action == .none)
        #expect(blockedItem.text == "“iMac” is a new device that cannot be trusted right now. Look at it under Devices.")
        // A device Cloud reports as removed, with nothing waiting from it, is not something for the person.
        let gone = device(Self.idA, "Old iMac", waiting: 0, removed: true)
        let quiet = try build(memoryOn(snapshot(coverage: saved, trust: [gone])))
        #expect(quiet.waiting.isEmpty)
        #expect(quiet.standing == .upToDate)
        // After a sign-in on a new Mac the first thing listed is the choice of devices, with its button.
        let fresh = try build(BackendCloudOverviewInput(snapshot: snapshot(trust: [waitingDevice], held: 14), newMacPending: true,
                                                        memory: memory(nil)))
        let first = try #require(fresh.waiting.first)
        #expect(first.action == .chooseDevices)
        #expect(first.text == BackendCloudOverviewWords.chooseDevices)
        let memoryRow = try #require(fresh.rows.first)
        #expect(memoryRow.state == "Not started yet")
        #expect(memoryRow.notes == ["Starts once you have chosen which devices this Mac trusts."])
    }

    @Test func aRowThatIsNotSwitchedOnIsAbsent() throws {
        let quiet = snapshot(coverage: [coverage("I01")])
        // Nothing switched on and nothing waiting: the place itself is absent.
        let nothing = BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: quiet))
        #expect(nothing == nil)
        // Only saved passwords: one row. They travel through the sync core, so both directions are said (B-M1).
        let onlyPasswords = try build(BackendCloudOverviewInput(snapshot: quiet, passwords: passwords(.protected)))
        let onlyKinds = onlyPasswords.rows.map { $0.kind }
        #expect(onlyKinds == [.passwords])
        #expect(onlyPasswords.standing == .upToDate)
        #expect(onlyPasswords.lines == [BackendCloudOverviewWords.allSaved, BackendCloudOverviewWords.level])
        // All four, in one order.
        let everything = snapshot(coverage: [coverage("I01"), coverage("I11"), coverage("I10"), coverage("I09")])
        let full = try build(BackendCloudOverviewInput(snapshot: everything, memory: memory(true), projects: feature(), bootFiles: feature(),
                                                       passwords: passwords(.protected)))
        let titles = full.rows.map { $0.title }
        #expect(titles == ["Memory", "Projects and agents", "Boot files", "Saved passwords"])
        let states = full.rows.map { $0.state }
        #expect(states == ["All saved", "All saved", "All saved", BackendCloudSecretsWords.on])
        #expect(full.standing == .upToDate)
        // Review B-M4: "Not now" on this Mac: no memory row, one line that says both directions, never "Up to date".
        let excluded = try build(BackendCloudOverviewInput(snapshot: snapshot(), memory: memory(false)))
        #expect(excluded.rows.isEmpty)
        #expect(excluded.notUsedHere)
        #expect(excluded.standing == .notUsed)
        #expect(excluded.title == "Not used on this Mac")
        #expect(excluded.lines == ["Cloud is not used on this Mac yet: its memory, projects, agents and boot files are not sent, and none arrive here."])
        // Nothing switched on, but a device waits: only what waits is shown.
        let onlyWaiting = try build(BackendCloudOverviewInput(snapshot: snapshot(trust: [device(Self.idA, "MacBook Air", waiting: 0)])))
        #expect(onlyWaiting.rows.isEmpty)
        #expect(onlyWaiting.standing == .needsYou)
    }

    @Test func whatWaitsOnThisMacForThePersonIsListedInPlainWords() throws {
        let folder = BackendCloudOverview.Waiting(id: "project:p1", text: "Project “Site” needs a folder on this Mac.", action: .chooseFolder(projectId: "p1"))
        let permission = BackendCloudOverview.Waiting(id: "permission:a1", text: "A change to what the agent “Builder” may do is held on this Mac.")
        let file = BackendCloudOverview.Waiting(id: "file:f1", text: "A file from your Cloud can run a command and waits for you: .claude/commands/deploy.md",
                                                action: .acceptFile(id: "f1"))
        let input = BackendCloudOverviewInput(snapshot: snapshot(coverage: [coverage("I01"), coverage("I11"), coverage("I09")]),
                                              memory: memory(true), projects: feature([folder, permission], notes: ["1 other version is kept."]),
                                              bootFiles: feature([file]), passwords: passwords(.locked))
        let overview = try build(input)
        #expect(overview.standing == .needsYou)
        #expect(overview.title == "4 things need you on this Mac")
        let texts = overview.waiting.map { $0.text }
        #expect(texts == [folder.text, permission.text, file.text, "Saved passwords are locked on this Mac. Unlock them under Saved passwords."])
        let actions = overview.waiting.map { $0.action }
        #expect(actions == [.chooseFolder(projectId: "p1"), .none, .acceptFile(id: "f1"), .none])
        // A row with something waiting is not settled, whatever its count says; its notes are shown under it.
        let projects = try #require(overview.rows.first(where: { $0.kind == .projects }))
        #expect(!projects.settled)
        #expect(projects.notes.contains("1 other version is kept."))
        let secrets = try #require(overview.rows.first(where: { $0.kind == .passwords }))
        #expect(secrets.state == "Locked on this Mac")
        #expect(!secrets.settled)
        // Another device asking for the saved passwords leads to this Mac's own sheet.
        var asking = passwords(.protected)
        asking.approvals = [.init(id: "approval-1", expiresAt: 9_999)]
        let asked = try build(BackendCloudOverviewInput(snapshot: snapshot(), passwords: asking))
        let request = try #require(asked.waiting.first)
        #expect(request.action == .reviewApproval(id: "approval-1"))
        #expect(asked.standing == .needsYou)
    }

    @Test func memoryThatWaitsForAProjectIsSaidAndNeverCalledSaving() throws {
        let line = DeckMemoryCloudLeanProjects.waitingLine(2)
        let short = coverage("I01", items: 9, complete: false, reasons: ["Memory still has unfinished imports or kept conflicts to check.", line])
        let overview = try build(memoryOn(snapshot(coverage: [short, coverage("I02")])))
        #expect(overview.standing == .needsYou)
        let texts = overview.waiting.map { $0.text }
        #expect(texts == ["Memory still has unfinished imports or kept conflicts to check.", "2 items of memory are waiting for a project on this Mac."])
        let row = try #require(overview.rows.first)
        #expect(row.state == "Not complete")
        #expect(overview.lines.contains(BackendCloudOverviewWords.notAllSaved))
        #expect(!overview.lines.contains(BackendCloudOverviewWords.allSaved))
    }

    @Test func pausedAndUnreachableAreSaidWithEverythingElseStillListed() throws {
        let saved = [coverage("I01")]
        let waitingDevice = device(Self.idA, "MacBook Air", waiting: 2)
        let paused = try build(memoryOn(snapshot(coverage: saved, trust: [waitingDevice], held: 2, phase: .paused)))
        #expect(paused.standing == .paused)
        #expect(paused.title == "Paused")
        #expect(paused.lines.first == BackendCloudOverviewWords.pausedLine)
        #expect(paused.waiting.count == 1)
        let problem = "Could not reach Cloud. Your local work is kept; Cloud tries again."
        let offline = try build(memoryOn(snapshot(coverage: saved, problem: problem)))
        #expect(offline.standing == .unreachable)
        #expect(offline.title == "Can't reach Cloud right now")
        #expect(offline.lines.first == problem)
    }

    @Test func theSummaryForAgentsIsTheSameStateAndCarriesNoAction() throws {
        let waitingDevice = device(Self.idA, "MacBook Air", waiting: 14)
        let overview = try build(memoryOn(snapshot(coverage: [coverage("I01")], trust: [waitingDevice], held: 14)))
        let wire = overview.wireValue
        #expect(wire["standing"].string == "needsYou")
        #expect(wire["title"].string == "1 thing needs you on this Mac")
        let waiting = wire["waitingForYou"].elements ?? []
        #expect(waiting.count == 1)
        #expect(waiting.first?.string == "“MacBook Air” is a new device. 14 changes from it wait until you trust it.")
        let rows = wire["rows"].elements ?? []
        #expect(rows.first?["kind"].string == "memory")
        // State only: no device id, no key and nothing that names a press.
        let text = wire.compact
        #expect(!text.contains(Self.idA))
        #expect(!text.contains("trust("))
    }

    // MARK: the account

    @Test func theAccountSaysWhetherThisMacIsLevelWithTheCloudAndSyncNowFetchesThenSends() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let level = await f.account.state()
        #expect(level.catchingUp == false)
        await f.transport.setHead(CloudSequence(40))
        await f.outbox.setFetched(CloudSequence(28))
        try await f.account.refresh()
        let behind = await f.account.state()
        #expect(behind.catchingUp == true)
        #expect(behind.behindBy == 12)
        #expect(behind.wireValue["catchingUp"].bool == true)
        // Not reaching Cloud keeps what was last known, with the problem said.
        await f.transport.setOffline(true)
        await #expect(throws: (any Error).self) { try await f.account.refresh() }
        let offline = await f.account.state()
        #expect(offline.problem != nil)
        #expect(offline.behindBy == 12)
        await f.transport.setOffline(false)
        // "Sync now": one fetch, then one send. A fetch that cannot run this moment is not an error.
        await f.outbox.setFetched(CloudSequence(40))
        let sentBefore = await f.outbox.flushes
        try await f.account.sync(action: "now")
        #expect(await f.outbox.pulls == 1)
        #expect(await f.outbox.flushes == sentBefore + 1)
        let after = await f.account.state()
        #expect(after.catchingUp == false)
        #expect(after.problem == nil)
        // Pausing carries the same facts under the paused phase.
        try await f.account.sync(action: "pause")
        let paused = await f.account.state()
        #expect(paused.phase == .paused)
        #expect(paused.catchingUp == false)
        #expect(paused.coverage == after.coverage)
    }

    @Test func theStatusToolCarriesTheSameSummaryThePageShows() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let waitingDevice = device(Self.idA, "MacBook Air", waiting: 14)
        let summary = try build(memoryOn(snapshot(coverage: [coverage("I01")], trust: [waitingDevice], held: 14))).wireValue
        let server = BackendNativeMCPServer()
        let entries = try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), overview: { summary }, signin: { _ in })
        try await server.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: entries)
        let endpoint = try await server.start()
        let token = String(repeating: "f", count: 64)
        let granted = Set(BackendCloudAccountTools.ids + BackendCloudAccountTools.ids.map { $0.replacingOccurrences(of: ".", with: "_") })
        do {
            let registration = try await server.register(token: token, grant: .init(attended: true, allowedTools: granted, allowedTiers: [.read]))
            try await server.bind(registration, sessionID: "fixture-overview", machineID: "fixture-machine")
            let status = try await rpc(endpoint.url, token: token, method: "tools/call",
                                       params: .object([.init("name", .string("cloud_status")), .init("arguments", .object([]))]))
            let text = status.compact
            #expect(status["result"]["isError"].bool != true)
            #expect(text.contains("1 thing needs you on this Mac"))
            #expect(text.contains("overview"))
            #expect(text.contains("catchingUp"))
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
    private func rpc(_ url: URL, token: String, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        guard url.host == "127.0.0.1" || url.host == "localhost" else { throw CloudFailure.unsafeConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string(method)), .init("params", params)]).encodedJSON()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try NativeRPCValue.parseJSON(data)
    }
}
