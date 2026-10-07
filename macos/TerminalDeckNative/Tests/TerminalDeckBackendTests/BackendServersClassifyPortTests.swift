import Testing
@testable import TerminalDeckBackend

@Suite("Server classification exact remaining cases")
struct BackendServersClassifyPortTests {
    private func facts() -> BackendServersFacts {
        var f = BackendServersProbe.parse("init=systemd\nroot=yes\ncontainers=docker\nweb=caddy\n#services ok\n#containers ok\n#listeners ok\n#sites ok\n#end ok", serverId: "s1", measuredAt: 1)
        f.services = .yes([], measuredAt: 1, how: "asked what it is set up to keep running"); f.containers = .yes([], measuredAt: 1, how: "asked"); f.listeners = .yes([], measuredAt: 1, how: "asked"); f.siteNames = .yes([], measuredAt: 1, how: "asked"); return f
    }
    @Test func measuredSiteHasExactNounAddressDetailAndUnknownState() {
        var f = facts(); f.siteNames = .yes(["178-105-239-176.sslip.io"], measuredAt: 1, how: "read web settings"); f.listeners = .yes([.init(address: "*", port: 443, program: "caddy", pid: 761, unit: "caddy.service")], measuredAt: 1, how: "asked")
        let cards = BackendServersClassify.classify(f); #expect(cards.count == 1); #expect(cards.first?.kind == .site && cards.first?.url == "https://178-105-239-176.sslip.io" && cards.first?.detail == "Served by caddy" && cards.first?.running == nil)
    }
    @Test func noWebListenerMeansNoSiteAddress() { var f = facts(); f.siteNames = .yes(["example.test"], measuredAt: 1, how: "read web settings"); #expect(BackendServersClassify.classify(f).first?.url == nil) }
    @Test func administratorServicesAreAppsAndRunningPackageServicesRemain() {
        var f = facts(); f.services = .yes([.init(name: "terminaldeck-demo-broker.service", state: .running, description: "Terminal Deck demo broker", addedHere: true), .init(name: "caddy.service", state: .running, description: "Caddy"), .init(name: "systemd-journald.service", state: .running, description: "Journal Service")], measuredAt: 1, how: "asked")
        let cards = BackendServersClassify.classify(f); #expect(cards.count == 3); #expect(cards.first { $0.id == "service:terminaldeck-demo-broker.service" }?.kind == .app); for name in ["caddy", "systemd-journald"] { #expect(cards.first { $0.id == "service:\(name).service" }?.kind == .other) }
    }
    @Test func dormantSystemUnitsDisappearAndOnlyFailedRemainderCountsStopped() {
        var f = facts(); f.services = .yes([.init(name: "terminaldeck-demo-broker.service", state: .running, addedHere: true), .init(name: "caddy.service", state: .running), .init(name: "rescue.service", state: .stopped), .init(name: "emergency.service", state: .stopped), .init(name: "modprobe@drm.service", state: .stopped), .init(name: "cloud-init-hotplugd.service", state: .failed)], measuredAt: 1, how: "asked")
        let cards = BackendServersClassify.classify(f); #expect(cards.map(\.id).sorted() == ["service:caddy.service", "service:cloud-init-hotplugd.service", "service:terminaldeck-demo-broker.service"]); #expect(cards.filter { $0.running == false }.map(\.name) == ["cloud-init-hotplugd"])
    }
    @Test func noCardMeansNoRescueOrEmergencyStart() { var f = facts(); f.services = .yes(["rescue.service", "emergency.service", "initrd-switch-root.service"].map { .init(name: $0, state: .stopped) }, measuredAt: 1, how: "asked"); #expect(BackendServersClassify.classify(f) == []) }
    @Test func packageDatabaseIsPromotedByMeasuredListener() {
        var f = facts(); f.services = .yes([.init(name: "postgresql.service", state: .running, description: "PostgreSQL RDBMS")], measuredAt: 1, how: "asked"); f.listeners = .yes([.init(address: "127.0.0.1", port: 5432, program: "postgres", pid: 900, unit: "postgresql.service")], measuredAt: 1, how: "asked")
        let cards = BackendServersClassify.classify(f); #expect(cards.first?.kind == .database && cards.first?.engine == .postgres)
    }
    @Test func composeCardCarriesExactManagerAndImageDescription() {
        var f = facts(); f.containers = .yes([.init(name: "tdscratch-web-1", image: "alpine:3", state: .running, status: "Up 2 minutes")], measuredAt: 1, how: "asked")
        var survey = BackendServersWayBackSurvey(); let ref = BackendServersComposeRef(project: "tdscratch", service: "web", workingDir: "/opt/td-scratch-compose"); survey.compose["tdscratch-web-1"] = ref
        let card = BackendServersClassify.classify(f, survey: survey).first; #expect(card?.name == "web" && card?.detail == "Running in a container from alpine:3"); #expect(card?.managedBy == .container(runtime: .docker, name: "tdscratch-web-1", compose: ref))
    }
    @Test func cannotRuntimeStillHasComposeSection() { var f = facts(); f.containerRuntime = .cannot(measuredAt: 1, why: "not allowed to ask"); let script = BackendServersClassify.waybackScript(f); #expect(!script.contains("docker")); #expect(script.contains("##compose")) }
    @Test func surveyExactShapeDropsManualAndUnsafeRows() {
        let survey = BackendServersClassify.parseSurvey("##compose-available\nyes\n##compose\ntdscratch-web-1\ttdscratch\tweb\t/opt/td-scratch-compose\nhand-started\t\t\t\n##repos\ntd-scratch.service\t/opt/td-scratch")
        #expect(survey.composeAvailable); #expect(survey.compose["tdscratch-web-1"] == .init(project: "tdscratch", service: "web", workingDir: "/opt/td-scratch-compose")); #expect(survey.compose["hand-started"] == nil); #expect(survey.repos["td-scratch.service"] == "/opt/td-scratch")
        #expect(!BackendServersClassify.parseSurvey("##compose-available\nno\n##compose\n##repos\n").composeAvailable); #expect(!BackendServersClassify.parseSurvey("").composeAvailable)
        #expect(BackendServersClassify.parseSurvey("##compose\nevil\tproj$(rm -rf /)\tsvc\t/tmp\nok\tproj\tsvc\t/tmp/x; reboot").compose.isEmpty)
    }
    @Test func plainImageIsNotEngineAndHowIsOnlyAnsweredQuestions() {
        #expect(BackendServersClassify.engineOf("postgres:16-alpine") == .postgres); #expect(BackendServersClassify.engineOf("mariadb:11") == .mariadb)
        #expect(BackendServersClassify.engineOf("ghcr.io/acme/redis-cache:1") == .redis); #expect(BackendServersClassify.engineOf("nomongolia:1") == nil)
        #expect(BackendServersClassify.engineOf("my-app:latest") == nil)
        let f = facts(), how = BackendServersClassify.howOf(f); #expect(how.contains("asked what it is set up to keep running")); #expect(Set(how).count == how.count)
    }
    @Test func cannotIsExactServerReasonOnly() {
        var f = facts(); f.containers = .cannot(measuredAt: 1, why: "this sign-in is not allowed to ask this server about its containers")
        #expect(BackendServersClassify.cannotOf(f) == [.init(what: "anything running in a container", why: "this sign-in is not allowed to ask this server about its containers")])
    }
    @Test func hostnamePatternAndEmptyHostAreNeverAddresses() {
        let listeners: [BackendServersListenerFact] = [.init(address: "*", port: 443)]
        #expect(BackendServersClassify.siteURL("*.example.com", listeners: listeners) == nil); #expect(BackendServersClassify.siteURL("", listeners: listeners) == nil); #expect(BackendServersClassify.siteURL("example.com", listeners: listeners) == "https://example.com")
    }
    @Test func onlyAdministratorServicesAreSurveyed() {
        var f = facts(); f.services = .yes([.init(name: "mine.service", state: .running, addedHere: true), .init(name: "systemd-udevd.service", state: .running, addedHere: false)], measuredAt: 1, how: "asked")
        let script = BackendServersClassify.waybackScript(f); #expect(script.contains("'mine.service'")); #expect(!script.contains("systemd-udevd"))
    }
}
