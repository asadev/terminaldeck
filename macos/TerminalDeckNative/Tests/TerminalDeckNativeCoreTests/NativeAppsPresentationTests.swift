import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Apps presentation safety")
struct NativeAppsPresentationTests {
    @Test func appAddressesOpenOnlyWebPagesWithoutCredentials() {
        #expect(NativeAppsRules.safeAddress("https://site.example/path?mode=preview")?.host == "site.example")
        #expect(NativeAppsRules.safeAddress("http://127.0.0.1:8080")?.port == 8080)
        #expect(NativeAppsRules.safeAddress("HTTPS://site.example")?.host == "site.example")
        #expect(NativeAppsRules.safeAddress("https://[::1]:8443") != nil)

        for value in [
            "javascript:alert(1)", "file:///tmp/app", "ftp://site.example", "mailto:person@example.com",
            "//site.example", "https:///path", "https://", "site.example", "",
            "https://person:secret@site.example", "https://person@site.example", "https://@site.example",
            "https://%70erson:secret@site.example", "https://site.example\n", " https://site.example",
        ] {
            #expect(NativeAppsRules.safeAddress(value) == nil, "Unexpected usable address: \(value)")
        }
        #expect(NativeAppsRules.safeAddress(nil) == nil)
    }

    @Test func addressEntryAcceptsOnlyDNSNames() {
        for value in ["app.example.com", "App.EXAMPLE.com", "my-app.203.0.113.10.sslip.io", "xn--caf-dma.example"] {
            #expect(NativeAppsRules.validHostname(value), "Unexpected rejected hostname: \(value)")
        }
        for value in [
            "", "https://app.example.com", "app.example.com/path", "app.example.com:443",
            " app.example.com", "app.example.com ", "app.\nexample.com", "app\texample.com",
            "*.example.com", "-app.example.com", "app-.example.com", "app._private.example.com",
            ".example.com", "app..example.com", "app.example.com.", "café.example", "app.example.com?query=1",
            "localhost", "127.0.0.1", "app.local", "app.localhost", "app.internal", "app.123",
        ] {
            #expect(!NativeAppsRules.validHostname(value), "Unexpected accepted hostname: \(value)")
        }
        #expect(NativeAppsRules.validHostname(String(repeating: "a", count: 63) + ".example.com"))
        #expect(!NativeAppsRules.validHostname(String(repeating: "a", count: 64) + ".example.com"))
        let maximum = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }.joined(separator: ".")
        #expect(maximum.utf8.count == 253)
        #expect(NativeAppsRules.validHostname(maximum))
        #expect(!NativeAppsRules.validHostname(maximum + "a"))
    }

    @Test func destructiveConfirmationMustMatchTheWholeNameExactly() {
        #expect(NativeAppsRules.matchesConfirmation(typed: "customer-data", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: "Customer-data", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: " customer-data", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: "customer-data ", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: "customer", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: "", name: "customer-data"))
        #expect(!NativeAppsRules.matchesConfirmation(typed: "", name: ""))
    }

    @Test func environmentNamesFollowPOSIXRules() {
        for value in ["PORT", "DATABASE_URL", "_", "_PRIVATE_2", "app2", "a"] {
            #expect(NativeAppsRules.validEnvironmentKey(value), "Unexpected rejected key: \(value)")
        }
        for value in ["", "2PORT", "MY-KEY", "MY.KEY", "MY KEY", " NAME", "NAME ", "NAME=VALUE", "NÁME", "秘密", "KEY\n"] {
            #expect(!NativeAppsRules.validEnvironmentKey(value), "Unexpected accepted key: \(value)")
        }
        #expect(NativeAppsRules.validEnvironmentKey(String(repeating: "A", count: 128)))
        #expect(!NativeAppsRules.validEnvironmentKey(String(repeating: "A", count: 129)))
    }

    @Test func unfamiliarServerStatusesStayExplicit() {
        #expect(NativeAppsRules.friendlyStatus("running") == "Running")
        #expect(NativeAppsRules.friendlyStatus("unhealthy") == "Needs attention")
        #expect(NativeAppsRules.friendlyStatus("deploying") == "Deploying")
        #expect(NativeAppsRules.friendlyStatus("stopped") == "Stopped")
        #expect(NativeAppsRules.friendlyStatus(" RUNNING\n") == "Running")
        #expect(NativeAppsRules.friendlyStatus("unknown") == "Unknown")
        #expect(NativeAppsRules.friendlyStatus("new-server-state") == "Unknown")
    }

    @Test func logStreamEndReasonsUseFixedCopyWithoutRawOutput() {
        #expect(NativeAppsRules.logEndMessage("closed") == "Live logs stopped.")
        #expect(NativeAppsRules.logEndMessage("eof") == "The app’s log stream ended. Open Logs again to reconnect.")
        #expect(NativeAppsRules.logEndMessage("error") == "Live logs stopped after a connection error. Try again.")
        #expect(NativeAppsRules.logEndMessage("overflow") == "Live logs stopped because too much output arrived. Open Logs again to continue.")
        let rawSecret = "stderr: PASSWORD=DO_NOT_DISPLAY_947"
        #expect(NativeAppsRules.logEndMessage(rawSecret) == "Live logs stopped. Try again.")
        #expect(!NativeAppsRules.logEndMessage(rawSecret).contains("DO_NOT_DISPLAY_947"))
    }

    @Test func databaseInitializationKeysAreProtectedWhileAppAndOperationalSettingsStayEditable() {
        let protected: [String: [String]] = [
            "postgres": ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"],
            "mysql": ["MYSQL_ROOT_PASSWORD", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DATABASE"],
            "redis": ["REDIS_PASSWORD"],
            "mongodb": ["MONGO_INITDB_ROOT_USERNAME", "MONGO_INITDB_ROOT_PASSWORD", "MONGO_INITDB_DATABASE"],
        ]
        for (kind, keys) in protected {
            for key in keys {
                #expect(NativeAppsRules.isDatabaseLoginKey(kind: kind, key: key))
                #expect(!NativeAppsRules.isDatabaseLoginKey(kind: "app", key: key))
            }
            for key in ["LOG_LEVEL", "PORT", "TZ", "DATABASE_URL"] {
                #expect(!NativeAppsRules.isDatabaseLoginKey(kind: kind, key: key))
            }
        }
        #expect(!NativeAppsRules.isDatabaseLoginKey(kind: "postgres", key: "MYSQL_PASSWORD"))
        #expect(!NativeAppsRules.isDatabaseLoginKey(kind: "redis", key: "redis_password"))
        #expect(!NativeAppsRules.isDatabaseLoginKey(kind: "unknown", key: "POSTGRES_PASSWORD"))
    }

    @Test func connectionHostsBelongToTheSelectedAppAndDeclaredNamespace() {
        #expect(NativeAppsRules.databaseHostMatches(host: "terminaldeck-customer-data", appID: "customer-data"))
        #expect(NativeAppsRules.databaseHostMatches(host: "terminaldeck-td-test-data", appID: "td-test-data"))
        #expect(NativeAppsRules.databaseHostMatches(host: "td-test-td-test-data", appID: "td-test-data"))
        for host in ["terminaldeck-other-data", "terminaldeck-other-customer-data", "terminaldeck-customer-data-extra",
                     "custom-customer-data", "td-test-customer-data", "terminaldeck-customer-data.local",
                     "terminaldeck-customer-data:5432", "terminaldeck-customer-data\n", "Terminaldeck-customer-data"] {
            #expect(!NativeAppsRules.databaseHostMatches(host: host, appID: "customer-data"))
        }
        #expect(!NativeAppsRules.databaseHostMatches(host: "td-test-data", appID: "td-test-data"))
        for appID in ["", "customer-data\n", "Customer-data", "../data", String(repeating: "a", count: 49)] {
            #expect(!NativeAppsRules.databaseHostMatches(host: "terminaldeck-" + appID, appID: appID))
        }
    }
}
