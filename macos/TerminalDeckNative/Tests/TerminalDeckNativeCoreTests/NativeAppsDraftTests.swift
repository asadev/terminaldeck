import Testing
@testable import TerminalDeckNativeCore

@Suite("New app draft")
struct NativeAppsDraftTests {
    @Test func displayNameKeepsItsWordsWhileAddressNameIsStable() {
        var draft = NativeAppsDraft(name: "  My Favourite App!  ", repository: "owner/app")
        #expect(draft.suggestedAppID == "my-favourite-app")
        #expect(draft.resolvedAppID == "my-favourite-app")
        #expect(draft.normalized.name == "My Favourite App!")
        draft.appID = "stable-address"
        draft.name = "Another name"
        #expect(draft.resolvedAppID == "stable-address")
    }

    @Test func suggestedAddressNamesMatchTheContract() {
        let numbered = NativeAppsDraft(name: "42 My Apps")
        #expect(numbered.suggestedAppID == "app-42-my-apps")
        let long = NativeAppsDraft(name: String(repeating: "a", count: 90))
        #expect(long.suggestedAppID.count == 48)
        #expect(NativeAppsDraft(name: "🦉").suggestedAppID == "app")
    }

    @Test func explicitAddressNamesRejectInvalidContractIDs() {
        for id in ["1app", "MyApp", "app name", "app/name", String(repeating: "a", count: 49)] {
            let draft = NativeAppsDraft(name: "My app", appID: id, repository: "owner/app")
            #expect(draft.validationMessage != nil)
            #expect(draft.sourceInfo == nil)
        }
        #expect(NativeAppsDraft(name: "My app", appID: "a", repository: "owner/app").validationMessage == nil)
    }

    @Test func newAddressNamesMustEndWithALetterOrNumber() {
        for id in ["app-", "a-", String(repeating: "a", count: 47) + "-"] {
            let draft = NativeAppsDraft(name: "App", appID: id, repository: "owner/app")
            #expect(draft.validationMessage == "End the address name with a letter or number so its web address works.")
            #expect(draft.sourceInfo == nil)
        }
        for id in ["app-1", "a", String(repeating: "a", count: 48)] {
            #expect(NativeAppsDraft(name: "App", appID: id, repository: "owner/app").validationMessage == nil)
        }
        #expect(NativeAppsDraft(name: "App-", repository: "owner/app").suggestedAppID == "app")
        let clippedName = String(repeating: "a", count: 47) + " next"
        let clipped = NativeAppsDraft(name: clippedName, repository: "owner/app")
        #expect(clipped.suggestedAppID == String(repeating: "a", count: 47))
        #expect(clipped.validationMessage == nil)
    }

    @Test func httpsRepositoryAddressesReuseGitHubReferences() {
        let draft = NativeAppsDraft(name: "App", repository: " https://github.com/owner/repository.git/ ", branch: "release/next")
        #expect(draft.githubRepository == GitHubRepoRef(nameWithOwner: "owner/repository", url: "https://github.com/owner/repository"))
        #expect(draft.validationMessage == nil)
        #expect(draft.sourceInfo == .github(repository: GitHubRepoRef(nameWithOwner: "owner/repository", url: "https://github.com/owner/repository"), branch: "release/next", port: 3000))
        #expect(draft.normalizedRepository == "owner/repository")
    }

    @Test func repositoryAddressesNeverCarryCredentialsOrWebPageParameters() {
        for repository in ["http://github.com/owner/app", "https://token@github.com/owner/app",
                           "https://person:password@github.com/owner/app", "https://github.com/owner/app?token=secret",
                           "https://github.com/owner/app#main", "https://github.com/owner/app/tree/main",
                           "https://example.com/owner/app", "https://github.example.com/owner/app",
                           "https://github.com.example.com/owner/app",
                           "owner", "owner//app", "git@github.com:owner/app.git"] {
            let draft = NativeAppsDraft(name: "App", repository: repository)
            #expect(draft.githubRepository == nil)
            #expect(draft.sourceInfo == nil)
        }
    }

    @Test func branchesAndPortsAreCheckedBeforeCreate() {
        var draft = NativeAppsDraft(name: "App", repository: "owner/app", branch: "")
        #expect(draft.resolvedBranch == "main")
        #expect(draft.validationMessage == nil)
        for branch in ["-main", "release/../main", "feature name", "feature@{one}", ".hidden", "main.lock"] {
            draft.branch = branch
            #expect(draft.validationMessage != nil)
        }
        draft.branch = "main"
        for port in [0, -1, 65_536] {
            draft.port = port
            #expect(draft.validationMessage != nil)
        }
        draft.port = 443
        #expect(draft.validationMessage == nil)
    }

    @Test func displayNameLengthCountsCharactersLikeTheServer() {
        let unicodeName = String(repeating: "é", count: 120)
        #expect(NativeAppsDraft(name: unicodeName, repository: "owner/app").validationMessage == nil)
        #expect(NativeAppsDraft(name: String(repeating: "a", count: 121), repository: "owner/app").validationMessage != nil)
        #expect(NativeAppsDraft(name: "App\nname", repository: "owner/app").validationMessage != nil)
    }

    @Test func databaseNamesFollowTheDataEnginesUTF8Limit() {
        for name in [String(repeating: "a", count: 120), String(repeating: "é", count: 60), String(repeating: "🦉", count: 30)] {
            #expect(NativeAppsDraft(name: name, source: .database).validationMessage == nil)
        }
        for name in [String(repeating: "a", count: 121), String(repeating: "é", count: 61), String(repeating: "🦉", count: 31)] {
            let draft = NativeAppsDraft(name: name, source: .database)
            #expect(draft.validationMessage == "Use a shorter database name.")
            #expect(draft.sourceInfo == nil)
        }
    }

    @Test func templateNamesFollowTheDataEnginesUTF8Limit() {
        for name in [String(repeating: "a", count: 120), String(repeating: "é", count: 60), String(repeating: "🦉", count: 30)] {
            #expect(NativeAppsDraft(name: name, source: .template, templateID: "uptime-kuma").validationMessage == nil)
        }
        for name in [String(repeating: "a", count: 121), String(repeating: "é", count: 61), String(repeating: "🦉", count: 31)] {
            let draft = NativeAppsDraft(name: name, source: .template, templateID: "uptime-kuma")
            #expect(draft.validationMessage == "Use a shorter app name for this template.")
            #expect(draft.sourceInfo == nil)
        }
    }

    @Test func repositoryBoundsMatchTheServerSource() {
        let longestOwner = String(repeating: "a", count: 39)
        let longestRepository = String(repeating: "b", count: 100)
        #expect(NativeAppsDraft(name: "App", repository: longestOwner + "/" + longestRepository).validationMessage == nil)
        for repository in [String(repeating: "a", count: 40) + "/app", "owner/" + String(repeating: "b", count: 101),
                           "owner_name/app", "owner.name/app", "-owner/app", "owner/.", "owner/.."] {
            #expect(NativeAppsDraft(name: "App", repository: repository).validationMessage != nil)
        }
    }

    @Test func branchLengthCountsUTF8BytesLikeTheServer() {
        #expect(NativeAppsDraft(name: "App", repository: "owner/app", branch: String(repeating: "a", count: 255)).validationMessage == nil)
        #expect(NativeAppsDraft(name: "App", repository: "owner/app", branch: String(repeating: "a", count: 256)).validationMessage != nil)
        #expect(NativeAppsDraft(name: "App", repository: "owner/app", branch: String(repeating: "é", count: 128)).validationMessage != nil)
    }

    @Test func onlyTheActiveSourceReachesItsAdapter() {
        var draft = NativeAppsDraft(name: "Database", source: .database,
                                    repository: "invalid repository", branch: "invalid branch", port: 0)
        #expect(draft.validationMessage == nil)
        #expect(draft.sourceInfo == .database(engine: "postgres"))
        for engine in ["postgres", "mysql", "redis", "mongodb"] {
            draft.databaseEngine = engine
            #expect(draft.validationMessage == nil)
        }
        draft.databaseEngine = "other"
        #expect(draft.validationMessage != nil)
        draft.source = .template
        #expect(draft.validationMessage != nil)
        draft.templateID = "  licensed-template  "
        #expect(draft.sourceInfo == .template(id: "licensed-template"))
    }
}
