import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("Server classifier uses measured facts and conservative commands")
struct BackendServersClassifyTests {
    private func facts(_ raw: String = "") -> BackendServersFacts { BackendServersProbe.parse("init=systemd\nroot=yes\ncontainers=docker\nweb=nginx\n" + raw + "\n#end ok", serverId: "s1", measuredAt: 1000) }
    @Test func sitesHaveOnlyMeasuredAddressesAndNoInventedState() {
        let f = facts("#sites ok\nexample.com\n*.example.com\n#listeners ok\n*\t443\tnginx\t1\tnginx.service")
        let cards = BackendServersClassify.classify(f)
        #expect(cards.count == 2); #expect(cards.first { $0.name == "example.com" }?.url == "https://example.com")
        #expect(cards.first { $0.name == "*.example.com" }?.url == nil); #expect(cards.allSatisfy { $0.running == nil && $0.managedBy == nil })
        #expect(BackendServersClassify.siteURL("example.com", listeners: []) == nil)
        #expect(BackendServersClassify.siteURL("example.com", listeners: [.init(address: "*", port: 80)]) == "http://example.com")
    }
    @Test func dormantPackageUnitsNeverGainStartControls() {
        let f = facts("#services ok\nmine.service\tinactive\tdead\tMy app\nrescue.service\tinactive\tdead\trescue\nssh.service\tactive\trunning\tSSH\nbroken.service\tfailed\tfailed\tBroken\npostgresql.service\tinactive\tdead\tDatabase\n#adminunits ok\nmine.service\n#listeners ok\n*\t5432\tpostgres\t1\tpostgresql.service")
        let cards = BackendServersClassify.classify(f)
        #expect(!cards.contains { $0.id == "service:rescue.service" })
        #expect(cards.first { $0.id == "service:mine.service" }?.kind == .app)
        #expect(cards.first { $0.id == "service:postgresql.service" }?.kind == .database)
        #expect(cards.filter { $0.kind == .other }.count == 2)
        let other = cards.first { $0.id == "service:ssh.service" }!
        #expect(BackendServersActions.availableActions(other, facts: f.actionFacts, canDownload: true, composeAvailable: true).offered == [.logs])
    }
    @Test func unknownInitStillDrawsCardsAndNeverGuessesCommands() {
        var f = facts("#services ok\nmine.service\tactive\trunning\tMine\n#adminunits ok\nmine.service")
        f.`init` = .yes(.sysvinit, measuredAt: 1, how: "asked init")
        #expect(BackendServersClassify.classify(f).first?.managedBy == nil)
        #expect(BackendServersClassify.classify(BackendServersProbe.parse("", serverId: "s", measuredAt: 1)).isEmpty)
    }
    @Test func composeAndRepositorySurveyRejectShellMaterial() {
        let survey = BackendServersClassify.parseSurvey("##compose-available\nyes\n##compose\nweb-1\tproject\tweb\t/opt/project\nmanual\t\t\t\nevil\tproj$(reboot)\tsvc\t/tmp\nok\tproj\tsvc\t/tmp/x; reboot\n##repos\nmine.service\t/opt/repo\n")
        #expect(survey.composeAvailable); #expect(survey.compose.count == 1); #expect(survey.repos["mine.service"] == "/opt/repo")
        #expect(!BackendServersClassify.parseSurvey("##compose-available\nno\n").composeAvailable)
        let f = facts("#services ok\nmine.service\tactive\trunning\tMine\nssh.service\tactive\trunning\tSSH\n#adminunits ok\nmine.service")
        let script = BackendServersClassify.waybackScript(f)
        #expect(script.contains(#"{{.Label "com.docker.compose.project"}}"#)); #expect(!script.contains("index .Labels"))
        #expect(script.contains("'mine.service'")); #expect(!script.contains("'ssh.service'"))
        var cannot = f; cannot.containerRuntime = .cannot(measuredAt: 1, why: "Not permitted.")
        #expect(!BackendServersClassify.waybackScript(cannot).contains("docker"))
    }
    @Test func wholeWordEnginesSafetyNamesAndLimits() {
        #expect(BackendServersClassify.engineOf("postgres:16-alpine") == .postgres); #expect(BackendServersClassify.engineOf("mariadb:11") == .mariadb)
        #expect(BackendServersClassify.engineOf("ghcr.io/acme/redis-cache:1") == .redis); #expect(BackendServersClassify.engineOf("nomongolia:1") == nil)
        for name in ["a b", "$(reboot)", "a\nb", "app\n", String(repeating: "a", count: 257)] { #expect(!BackendServersClassify.isSafeName(name)) }
        for path in ["opt/relative", "/opt/`reboot`", "/tmp/$(reboot)", "/tmp/a;b", "/tmp/app\n", String(repeating: "/", count: 4097)] { #expect(!BackendServersClassify.isSafePath(path)) }
        #expect(BackendServersClassify.isSafeName("td-scratch.service")); #expect(BackendServersClassify.isSafePath("/opt/td-scratch"))
    }
    @Test func composeNamesOrderAndPageHonesty() {
        let f = facts("#sites ok\nexample.com\n#containers ok\nweb-1\talpine:3\trunning\tUp\t\ndb\tredis:7\trunning\tUp\t\n#services ok\nssh.service\tactive\trunning\tSSH")
        let survey = BackendServersClassify.parseSurvey("##compose\nweb-1\tproject\twebsite\t/opt/project\n")
        let cards = BackendServersClassify.classify(f, survey: survey)
        #expect(cards.map(\.kind) == [.site, .app, .database, .other]); #expect(cards[1].name == "website")
        #expect(Set(BackendServersClassify.howOf(f)).count == BackendServersClassify.howOf(f).count)
        var unknown = f; unknown.containers = .cannot(measuredAt: 1, why: "No permission.")
        #expect(BackendServersClassify.cannotOf(unknown).contains { $0.what == "anything running in a container" && $0.why == "No permission." })
    }
}
