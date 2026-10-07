import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Backend CRM inline files, comments and wire contracts")
struct BackendCrmTextAndContractsTests {
    @Test func inlineSyntaxIsExactAndRepeatedPlacementsAreKept() {
        let source = "See [[file:a]] [[file:draft:k]] [[file:a]] [[file:draft:]] [[file:x:y]]"
        #expect(BackendCrmInlineFiles.fileTokenIds(source) == ["a", "draft:k", "a"])
        #expect(BackendCrmInlineFiles.countFileTokens(source) == 3)
        #expect(BackendCrmInlineFiles.splitInlineFiles("").isEmpty)
        #expect(BackendCrmInlineFiles.isDraftFileId("draft:missing"))
    }
    @Test func tokensDoNotConsumeTheVisibleTitleLimitAndNeverSplit() {
        let source = String(repeating: "a", count: 300) + "[[file:x]]"
        #expect(BackendCrmInlineFiles.visibleLength(source) == 300)
        #expect(BackendCrmInlineFiles.visibleLength("😀[[file:x]]") == 2)
        #expect(BackendCrmInlineFiles.truncateVisible("abcd [[file:x]] more", max: 2) == "ab[[file:x]]")
        #expect(BackendCrmInlineFiles.visibleTitleMax == 300 && BackendCrmInlineFiles.rawTitleMax == 4000)
    }
    @Test func draftRewriteCanReplaceRemoveOrLeaveAPlacement() {
        let map: [String: String?] = ["draft:k": "live", "x": nil]
        #expect(BackendCrmInlineFiles.rewriteFileTokens("See [[file:draft:k]]  [[file:x]] [[file:y]]", map: map) == "See [[file:live]] [[file:y]]")
        #expect(BackendCrmInlineFiles.rewriteFileTokens("  unchanged  ", map: [:]) == "  unchanged  ")
        #expect(BackendCrmInlineFiles.stripFileTokens("see  [[file:x]] here\n\n\n next") == "see here\n\nnext")
    }
    @Test func aPastedTokenCannotBecomeSomebodyElsesFile() {
        #expect(BackendCrmInlineFiles.plainTextForField("a\r\nb[[file:other]]\u{FFFC}\u{200B}") == "a\nb")
        #expect(BackendCrmInlineFiles.fromFlat("A\u{FFFC}B\u{FFFC}", ids: ["one"]) == "A[[file:one]]B")
    }
    @Test func flatSpliceRemovesOnlyTheSelectedPlacements() {
        let edited = BackendCrmInlineFiles.spliceStorage("A[[file:first]]B[[file:second]]C", start: 1, end: 3, insert: "X")
        #expect(edited.text == "AX[[file:second]]C" && edited.caret == 2)
        let placed = BackendCrmInlineFiles.insertFileAt("A[[file:first]]B[[file:second]]C", at: 3, id: "new")
        #expect(placed.text == "A[[file:first]]B [[file:new]] [[file:second]]C" && placed.caret == 6)
        #expect(BackendCrmInlineFiles.visibleInFlatRange("A[[file:a]]😀B", start: 0, end: 5) == 4)
    }
    @Test func editorCaretOffsetsCountUTF16Units() {
        let inserted = BackendCrmInlineFiles.insertAt("😀x", index: 2, snippet: "hi", spaced: false)
        #expect(inserted.text == "😀hix" && inserted.caret == 4)
        #expect(BackendCrmInlineFiles.toFlat("[[file:a]]😀").utf16.count == 3)
    }
    @Test func headingCountsCodePointsAndKeepsTokensWhole() {
        let split = BackendCrmTaskPage.splitTaskText("Call [[file:a]]. Then ship it")
        #expect(split.heading == "Call [[file:a]]." && split.body == "Then ship it" && !split.cut)
        #expect(BackendCrmTaskPage.splitTaskText(String(repeating: "e\u{0301}", count: 41)).cut)
        #expect(BackendCrmTaskPage.splitTaskText("First\nSecond").body == "Second")
    }
    @Test func uploadCapAndRefusalsMatchTheHTTPContract() {
        #expect(BackendCrmTaskRules.checkUpload(name: "report.pdf", size: Double(25 * 1024 * 1024)) == .allowed)
        #expect(BackendCrmTaskRules.checkUpload(name: "report.pdf", size: Double(25 * 1024 * 1024 + 1)) == .refused(error: "“report.pdf” is too big — the limit is 25 MB.", status: 413))
        #expect(BackendCrmTaskRules.checkUpload(name: "report.pdf", size: .nan) == .refused(error: "The file is empty.", status: 400))
        #expect(BackendCrmTaskRules.checkUpload(name: "hidden", size: 1) == .refused(error: "“hidden” has no file extension, so its type cannot be checked.", status: 400))
        #expect(BackendCrmTaskRules.checkUpload(name: "script.exe", size: 1).wire["status"] == .number(400))
        #expect(BackendCrmTaskRules.checkUpload(name: "a.pdf", size: 0.5) == .allowed)
    }
    @Test func localAttachmentAddressEncodesBothIDsAndMalformedEscapesThrow() throws {
        let href = BackendCrmAttachmentRules.taskAttachmentHref(taskID: "local:a/b", attachmentID: "a ?", download: true)
        #expect(href == "task-file:local%3Aa%2Fb/a%20%3F?download=1")
        let result = try BackendCrmAttachmentRules.parseTaskAttachmentHref(href)
        #expect(result?.taskId == "local:a/b" && result?.attachmentId == "a ?")
        #expect(try BackendCrmAttachmentRules.parseTaskAttachmentHref("https://example.com") == nil)
        #expect(throws: NativeRPCError.self) { try BackendCrmAttachmentRules.parseTaskAttachmentHref("task-file:a/%ZZ") }
        #expect(!BackendCrmAttachmentRules.servesInline("image/svg+xml"))
        #expect(BackendCrmAttachmentRules.servesInline("application/pdf"))
        #expect(BackendCrmAttachmentRules.inlineKind(nil, fileName: "camera.HEIC") == "image")
    }
    @Test func legacyPageOptionsNeverStartTheNextTaskDone() {
        let rule = BackendCrmTaskPage.normalizeRecurrenceRule(.object(["forever": .bool(false), "until": .string("2026-12-31"), "updateStatusTo": .string("Done")]))
        #expect(rule["until"] == .string("2026-12-31") && rule["updateStatusTo"] == .null && rule["createNew"] == .bool(true))
        #expect(BackendCrmTaskPage.normalizeRecurrenceRule(.object(["until": .string("2026-12-31")]))["until"] == .null)
        #expect(BackendCrmTaskPage.normalizeLabels([.string("  A  B  "), .number(4), .string("a b"), .string("Other")]) == ["A B", "Other"])
        #expect(BackendCrmTaskPage.notAvailableSentence(code: "42703") == "This isn't available yet.")
        #expect(BackendCrmTaskPage.notAvailableSentence(code: "network") == "This could not be read just now.")
    }
    @Test func aPassedCommentScheduleStillWaitsUntilServerDelivery() {
        let now = BackendCrmTime.parseInstant("2026-10-06T10:00:00Z")!
        let waiting = CommentMeta(scheduledFor: "2026-10-06T09:00:00Z", deliveredAt: .some(nil))
        #expect(BackendCrmComments.isPending(waiting, now: now))
        #expect(!BackendCrmComments.visibleTo(authorUserID: "a", meta: waiting, viewerID: "b", now: now))
        #expect(BackendCrmComments.visibleTo(authorUserID: "a", meta: waiting, viewerID: "a", now: now))
        let legacy = CommentMeta(scheduledFor: "2026-10-06T09:00:00Z")
        #expect(!BackendCrmComments.isPending(legacy, now: now))
        let withdrawn = CommentMeta(scheduledFor: "2026-10-07T09:00:00Z", withdrawn: ("2026-10-06", "Left the task"), deliveredAt: .some(nil))
        #expect(!BackendCrmComments.isPending(withdrawn, now: now))
    }
    @Test func missingParentsReturnRepliesToTheTopLevelWithoutLosingOrder() {
        let comments = ["one", "reply", "orphan", "two"]
        let threaded = BackendCrmComments.threadComments(comments, id: { $0 }, meta: ["reply": CommentMeta(parentId: "one"), "orphan": CommentMeta(parentId: "gone")])
        #expect(threaded.top == ["one", "orphan", "two"] && threaded.replies["one"] == ["reply"])
        #expect(BackendCrmComments.isReactionEmoji("✅") && !BackendCrmComments.isReactionEmoji("🦄"))
    }
    @Test func commentCodecKeepsAbsentAndExplicitNullDeliveryDistinct() throws {
        let absent = BackendCrmWire.commentMeta(CommentMeta())
        let pending = BackendCrmWire.commentMeta(CommentMeta(deliveredAt: .some(nil)))
        #expect(!absent.has("deliveredAt") && pending.has("deliveredAt") && pending["deliveredAt"] == .null)
        let roundTrip = try NativeRPCValue.parseJSON(pending.encodedJSON())
        #expect(roundTrip.has("deliveredAt") && roundTrip["deliveredAt"] == .null)
    }
    @Test func optionalWireMetadataKeepsAbsentFalseAndNullDistinct() throws {
        let more = try #require(CrmDecode.more([String: Any]()))
        let absent = BackendCrmWire.more(more, optionalMetadata: .object([]))
        let explicit = BackendCrmWire.more(more, optionalMetadata: .object([.init("canColorTags", .bool(false))]))
        #expect(!absent.has("canColorTags") && !absent.has("canRemoveFollowers"))
        #expect(explicit.has("canColorTags") && explicit["canColorTags"] == .bool(false) && !explicit.has("canRemoveFollowers"))
        let file = try #require(CrmDecode.attachment(["id": "a", "fileName": "a.png"]))
        #expect(!BackendCrmWire.attachment(file, optionalMetadata: .object([])).has("previewUrl"))
        #expect(BackendCrmWire.attachment(file, optionalMetadata: .object([.init("previewUrl", .null)]))["previewUrl"] == .null)
    }
    @Test func localPeopleAndProfileHealingUseTheSharedPaletteAndPhotoFallback() {
        let people = BackendCrmPeople.localPeople([("builder", "Builder")])
        #expect(people.map(\.id) == ["me", "hoot", "builder"] && people[0].initials == "ME")
        let profile = BackendCrmPeople.ProfileLite(id: "profile", name: "Asad Khan", email: "asad@example.com", initials: "?", avatarBackground: "bg-blue-500", avatarURL: "https://example.com/photo.jpg")
        let assignee = BackendCrmPeople.toAssignee(profile)
        #expect(assignee.initials == "AK" && assignee.avatarUrl == profile.avatarURL)
        #expect(assignee.color == BackendCrmPeople.avatarPalette[BackendCrmPeople.hashStringToIndex("asad@example.com", 10)])
    }
    @Test func inheritedAssigneeDoesNotOverrideAnExplicitItemID() {
        let people = TaskPeople(primary: BackendCrmPeople.localPerson("me", "You"))
        #expect(BackendCrmCollaboration.effectiveAssignee(nil, people: people) == "me")
        #expect(BackendCrmCollaboration.effectiveAssignee("outside", people: people) == "outside")
    }
    @Test func contractCatalogueAndCreatePayloadKeepWireNames() {
        #expect(BackendCrmDetailContract.channel == "tasks:local-detail")
        #expect(Set(BackendCrmDetailContract.functions).count == BackendCrmDetailContract.functions.count)
        #expect(BackendCrmDetailContract.isLocalDetailFn("fetchRoutine"))
        #expect(BackendCrmDetailContract.isLocalDetailFn("chooseTaskProject"))
        #expect(!BackendCrmDetailContract.isLocalDetailFn("runJavaScript"))
        #expect(BackendCrmActivity.readLimit == 500 && BackendCrmActivity.kinds.count == 27)
        let payload = BackendCrmTasksData.NewTaskInput(title: "Plan", group: "To-Do", board: "", dueDate: "")
        #expect(payload.wire["priority"] == .null && payload.wire["assigneeUserId"] == .null)
        #expect(!payload.wire.has("routine") && !payload.wire.has("description"))
        #expect(BackendCrmMore.labelTone("grey")?.dot == "var(--text-muted)")
    }
    @Test func aTimeEntryBelongsToTheDayItStoppedAndDurationRulesStayUnchanged() throws {
        let raw: [String: Any] = ["id": "e", "startedAt": "2026-10-05T23:00:00Z", "endedAt": "2026-10-06T01:00:00Z", "seconds": 7200]
        let entry = try #require(CrmDecode.timeEntry(raw))
        #expect(BackendCrmTaskPage.timeEntryDay(entry, zone: TimeZone(secondsFromGMT: 0)!) == "2026-10-06")
        #expect(BackendCrmTaskRules.parseDuration("1:99") == 9540)
        #expect(BackendCrmTaskRules.parseDuration("2h30") == 9000)
        #expect(BackendCrmTaskRules.parseDuration("25h") == nil)
        #expect(BackendCrmTaskRules.formatDuration(5400) == "1h 30m")
    }
}
