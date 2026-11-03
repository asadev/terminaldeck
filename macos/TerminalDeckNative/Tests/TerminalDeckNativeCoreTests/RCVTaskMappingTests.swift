import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// CRM-FIELDS: every CRM task field lands in a Terminal Deck task, an unread value is flagged with
/// "Map it", and anyone's own field (name + path) works for any source.
struct RCVTaskMappingTests {
    @Test func crmPresetCoversEveryFieldInTheTable() throws {
        let fields = RCVTaskMapping.fields(payload: Data(RCVPresets.crmTasksSample.utf8))
        #expect(fields.status == "To-Do" && fields.priority == "High")
        #expect(fields.startDate == "2026-10-12" && fields.dueDate == "2026-10-14" && fields.dueTime == "16:00")
        #expect(fields.labels == ["landlord", "follow-up"] && fields.board == "Follow-ups" && fields.taskType == "task" && fields.estimateMinutes == 30)
        let labels = Set(fields.custom.map(\.label))
        for label in ["CRM task ID", "URL", "Assigned to", "Requested by", "People", "Followers", "Related", "Subtasks", "Checklists",
                      "Attachments", "Budget", "Comments", "Created at"] {
            #expect(labels.contains(label), "missing \(label)")
        }
        #expect(fields.custom.first { $0.label == "URL" }?.kind == "website")
        #expect(fields.custom.first { $0.label == "Budget" }?.value == "AED 2,500,000", "a CRM custom field keeps its own label and shown value")
        #expect(fields.custom.first { $0.label == "Attachments" }?.value.contains("valuation.pdf (https://app.iloop.ae/f/a1)") == true, "attachments arrive as links")
        // The preset reads everything the sample carries: nothing is left unread.
        let preview = RCVFieldPreview.build(mapping: RCVPresets.crmTasksMapping, body: Data(RCVPresets.crmTasksSample.utf8), basis: "sample")
        #expect(preview.unmapped.isEmpty, "unread: \(preview.unmapped.map(\.path))")
        #expect(preview.rows.first { $0.id == "fields.dueDate" }?.destination == "Task · Due date")
    }

    @Test func anArrivingValueNothingReadsIsFlaggedAndMapItReadsIt() throws {
        let body = Data(#"{"title":"Fix it","task":{"region_code":"DXB"},"severity":"info"}"#.utf8)
        let mapping = RCVPresets.generic.mapping
        let before = RCVFieldPreview.build(mapping: mapping, body: body, basis: "sample")
        let flagged = try #require(before.unmapped.first { $0.path == "task.region_code" })
        #expect(flagged.suggestion.name == "regionCode" && flagged.suggestion.value == "{{task.region_code}}" && flagged.destination == "Custom field · “Region code”")
        let mapped = try #require(RCVFieldPreview.mapping(mapping, adding: flagged.suggestion))
        let after = RCVFieldPreview.build(mapping: mapped, body: body, basis: "sample")
        #expect(!after.unmapped.contains { $0.path == "task.region_code" })
        #expect(after.rows.first { $0.id == "fields.regionCode" }?.value == "DXB")
    }

    @Test func aCustomFieldPathWorksForAnySource() throws {
        var mapping = RCVPresets.server.mapping
        mapping.fields = [.init("dueDate", "{{deadline.when}}"), .init("Region", "{{meta_info.region}}"), .init("priority", "{{urgency}}")]
        let source = RCVSource(id: "s", name: "Ops", preset: "server", auth: .init(scheme: .token), mapping: mapping)
        let event = try #require(RCVEngine.normalize(body: Data(#"{"title":"Disk","deadline":{"when":"2026-11-02T10:00:00Z"},"meta_info":{"region":"EU"},"urgency":"urgent"}"#.utf8),
                                                    headers: [:], meta: [:], source: source, receivedAt: 0).first)
        let fields = RCVTaskMapping.fields(from: event.fields, order: mapping.fields.map(\.name))
        #expect(fields.dueDate == "2026-11-02" && fields.priority == "Critical")
        #expect(fields.custom == [.init(name: "Region", label: "Region", kind: "text", value: "EU")])
        #expect(RCVTaskMapping.destination("due_date") == .taskField(key: "dueDate", label: "Due date"))
    }

    @Test func checkConnectionSaysPlainlyWhenNothingHasArrived() {
        let source = RCVSource(id: "terminaldeck.tasks", name: "Tasks", preset: "terminaldeck", origin: .terminalDeck, auth: .init(scheme: .none), mapping: RCVPresets.crmTasksMapping)
        let relay = RCVSource(id: "r", name: "CRM", preset: "crm", auth: .init(scheme: .token), mapping: RCVPresets.crmTasksMapping)
        #expect(RCVConnectionCheck.make(source: source, active: true, relayConnected: true, events: [], snapshot: nil, when: { _ in "" }).verdict == .nothingYet)
        let check = RCVConnectionCheck.make(source: relay, active: true, relayConnected: true, events: [], snapshot: nil, when: { _ in "" })
        #expect(check.headline.contains("other side hasn’t sent anything") && check.headline.contains("nothing is wrong in Terminal Deck"))
    }
}
