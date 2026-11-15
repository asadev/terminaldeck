using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Cloud;

// Keys travel (port of the Mac's CloudKeysTravelTests, 15 Nov 2026, with review fixes 1-4): API keys, MCP servers and
// server keys ride the saved-passwords engine from device A to device B, are usable there, are one item when both hold
// the same, are both kept when they differ, follow the delete rule, and never show a value. Scratch stores only: made-up
// keys, a scratch `.claude.json`, a fake `claude` command, scratch server folders; no Credential Manager, no real settings.
public sealed class CloudKeysTravelTests : IDisposable
{
  private const string KeyA = "sk-made-up-key-aaaaaaaaaaaaaaaaaaaaaaaa", KeyB = "sk-made-up-key-bbbbbbbbbbbbbbbbbbbbbbbb", KeyC = "sk-made-up-key-cccccccccccccccccccccccc";
  private const string IdOne = "api-key-111111111111111111111111", IdTwo = "api-key-222222222222222222222222";
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-keys-travel-" + Guid.NewGuid().ToString("N"));
  private long clock = 1_800_000_000_000;
  private long Now() => clock += 1000;
  public void Dispose() { try { Directory.Delete(root, true); } catch (Exception) { } }
  private string State(string device) => Path.Combine(root, "state-" + device);
  private static readonly CloudSecretsStoreKeys Keys = new(1, RandomNumberGenerator.GetBytes(32), RandomNumberGenerator.GetBytes(32));
  private static CloudSecretsDeleteOwner Wrap(CloudSecretsDeleteOwner owner) { owner.UseKeys(Keys); return owner; }
  private CloudDeleteActor Actor(CloudDeleteBy by = CloudDeleteBy.Ai) => new(by, "a", "PC A", by == CloudDeleteBy.Ai ? "Night work" : null, null, Now(), Guid.NewGuid().ToString("D"));
  private CloudSecretsVanished ByAi() => new((_, _, _) => Task.FromResult(CloudDeleteWitnessAnswer.Ai("Night work", "Worker", DateTimeOffset.UtcNow, Guid.NewGuid().ToString("D"))), () => "a", () => "PC A");
  private static CloudSecretsVanished ByHand() => new((_, _, _) => Task.FromResult(CloudDeleteWitnessAnswer.NotAi), () => "a", () => "PC A");

  // ---------------------------------------------------------------- API keys

  private sealed class KeysApiOwner : ICloudKeysApiOwner
  {
    public readonly Dictionary<string, (CloudKeysApiAccount Account, string Key)> Accounts = new(StringComparer.Ordinal);
    public void Add(string id, string name, string key) =>
      Accounts[id] = (new(id, name, "claude", "anthropic", "https://api.anthropic.com", null, null), key);
    public Task<IReadOnlyList<CloudKeysApiAccount>> CloudAccountsAsync() => Task.FromResult<IReadOnlyList<CloudKeysApiAccount>>(Accounts.Values.Select(a => a.Account).ToArray());
    public Task<string?> CloudKeyAsync(string accountId) => Task.FromResult(Accounts.TryGetValue(accountId, out var a) ? a.Key : null);
    public Task CloudCreateAsync(string accountId, string name, CloudKeysApiValue value)
    {
      if (Accounts.ContainsKey(accountId)) throw new CloudFailure("version_changed");
      Accounts[accountId] = (new(accountId, name, value.Provider, value.Kind, value.BaseUrl, value.Model, value.WorkspaceId), value.Key);
      return Task.CompletedTask;
    }
    public Task<bool> CloudRemoveAsync(string accountId, string expectingKey)
    {
      if (!Accounts.TryGetValue(accountId, out var a)) return Task.FromResult(true);
      return Task.FromResult(a.Key == expectingKey && Accounts.Remove(accountId));
    }
    public Task<bool> CloudReplaceKeyAsync(string accountId, string key, string expectingKey)
    {
      if (!Accounts.TryGetValue(accountId, out var a) || a.Key != expectingKey) return Task.FromResult(false);
      Accounts[accountId] = (a.Account, key); return Task.FromResult(true);
    }
  }
  private CloudKeysApiStore Api(KeysApiOwner owner, string device, CloudKeysRemovals? removals = null) =>
    new(owner, State(device), () => "PC " + device, removals: removals ?? new CloudKeysRemovals());
  private CloudSecretsDeleteOwner ApiOwner(KeysApiOwner owner, string device, CloudSecretsVanished? vanished = null, CloudKeysRemovals? removals = null) =>
    Wrap(Api(owner, device, removals).DeleteRuleOwner(State(device), () => true, serviceClock: () => clock, vanished: vanished, now: Now));

  [Fact]
  public async Task An_api_key_travels_and_its_account_works_on_the_other_device()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA);
    var record = Assert.Single(await Api(apiA, "A").CaptureAsync());
    var b = Api(apiB, "B");
    await b.ValidateAsync(record);
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(record));
    Assert.True(await b.VerifyAsync(record, CloudApplyStatus.Applied));
    var made = apiB.Accounts[IdOne];
    Assert.Equal(("Work Claude", KeyA, "anthropic"), (made.Account.Name, made.Key, made.Account.Kind));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(record));
  }

  [Fact]
  public async Task The_same_key_on_both_is_one_account_and_one_id_in_cloud()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA); apiB.Add(IdTwo, "Claude at home", KeyA);
    var b = Api(apiB, "B");
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(Assert.Single(await Api(apiA, "A").CaptureAsync())));
    Assert.Single(apiB.Accounts);
    Assert.Equal(new[] { IdOne }, (await b.CaptureAsync()).Select(r => r.RecordId));
  }

  [Fact]
  public async Task A_different_key_under_the_same_account_keeps_both_named_by_the_device()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA); apiB.Add(IdOne, "Work Claude", KeyB);
    var record = Assert.Single(await Api(apiA, "A").CaptureAsync());
    var b = Api(apiB, "B");
    Assert.Equal(CloudApplyStatus.KeptBoth, await b.MergeAsync(record));
    Assert.True(await b.VerifyAsync(record, CloudApplyStatus.KeptBoth));
    Assert.Equal(KeyB, apiB.Accounts[IdOne].Key);
    Assert.Equal(2, apiB.Accounts.Count);
    Assert.Contains(apiB.Accounts.Values, a => a.Account.Name == "Work Claude (PC A)" && a.Key == KeyA);
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(record));
    Assert.Equal(2, apiB.Accounts.Count);
  }

  [Fact]
  public async Task An_api_key_removed_by_an_ai_goes_everywhere_and_comes_back_with_put_back()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA);
    var a = ApiOwner(apiA, "A"); var b = ApiOwner(apiB, "B");
    var record = Assert.Single(await a.CaptureAsync());
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(record));
    _ = await b.CaptureAsync();
    var item = Assert.Single(await a.ItemsAsync());
    Assert.Equal("Work Claude", item.Name);
    await a.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, Actor());
    Assert.Empty(apiA.Accounts);
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeRemovalAsync(Assert.Single(await a.CaptureRemovalsAsync())));
    Assert.Empty(apiB.Accounts);
    var group = Assert.Single(await b.BinGroupsAsync());
    Assert.Equal(new[] { "Work Claude" }, group.Items.Select(i => i.Name));
    Assert.Single(await b.PutBackGroupAsync(group.Id));
    Assert.Equal(KeyA, apiB.Accounts[IdOne].Key);
  }

  [Fact]
  public async Task A_remove_in_the_app_goes_everywhere_and_the_cloud_record_never_brings_it_back()
  {
    var apiA = new KeysApiOwner(); apiA.Add(IdOne, "Work Claude", KeyA);
    var removals = new CloudKeysRemovals();
    var owner = ApiOwner(apiA, "A", removals: removals);
    var record = Assert.Single(await owner.CaptureAsync());
    removals.Set(CloudKeysRemovals.Through(new Dictionary<string, CloudSecretsDeleteOwner> { ["api"] = owner }, () => Actor(CloudDeleteBy.Person)));
    Assert.True(await removals.RemoveEverywhereAsync("api", IdOne));
    Assert.Empty(apiA.Accounts);
    Assert.Single(await owner.CaptureRemovalsAsync());
    Assert.Single(await owner.BinGroupsAsync());
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(record));
    Assert.Empty(apiA.Accounts);
    // Not one of its items: not handled (the app removes the old way).
    Assert.False(await removals.RemoveEverywhereAsync("api", IdTwo));
  }

  [Fact]
  public async Task A_key_changed_twice_on_one_device_ends_as_one_account_with_the_newest_key()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA);
    var a = ApiOwner(apiA, "A"); var b = ApiOwner(apiB, "B");
    Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(Assert.Single(await a.CaptureAsync())));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await a.MergeAsync(Assert.Single(await b.CaptureAsync())));
    foreach (var key in new[] { KeyB, KeyC })
    {
      apiA.Accounts[IdOne] = (apiA.Accounts[IdOne].Account, key);
      Assert.Equal(CloudApplyStatus.Applied, await b.MergeAsync(Assert.Single(await a.CaptureAsync())));
      _ = await b.CaptureAsync();
      Assert.Single(apiB.Accounts);
      Assert.Equal(key, apiB.Accounts[IdOne].Key);
    }
    Assert.Equal(Assert.Single(await a.CaptureAsync()).Canonical(), Assert.Single(await b.CaptureAsync()).Canonical());
  }

  [Fact]
  public async Task A_stale_id_leaves_cloud_so_a_new_device_gets_one_account_with_the_newest_key()
  {
    var apiA = new KeysApiOwner(); var apiB = new KeysApiOwner();
    apiA.Add(IdOne, "Work Claude", KeyA); apiB.Add(IdTwo, "Claude at home", KeyA);
    CloudSecretsVanished Identity(string device) => CloudSecretsVanished.IdentityOnly(() => device, () => "PC " + device);
    var a = ApiOwner(apiA, "A", Identity("a")); var b = ApiOwner(apiB, "B", Identity("b"));
    Assert.Equal(new[] { IdTwo }, (await b.CaptureAsync()).Select(r => r.RecordId));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.MergeAsync(Assert.Single(await a.CaptureAsync())));
    var retired = Assert.Single(await b.CaptureRemovalsAsync());
    Assert.Equal(IdTwo, retired.RecordId);
    Assert.Equal(new[] { IdOne }, (await b.CaptureAsync()).Select(r => r.RecordId));
    Assert.Single(apiB.Accounts);
    apiA.Accounts[IdOne] = (apiA.Accounts[IdOne].Account, KeyB);
    var apiC = new KeysApiOwner(); var c = ApiOwner(apiC, "C");
    Assert.Equal(CloudApplyStatus.Applied, await c.MergeAsync(Assert.Single(await a.CaptureAsync())));
    _ = await c.MergeRemovalAsync(retired);
    Assert.Equal(KeyB, Assert.Single(apiC.Accounts).Value.Key);
  }

  [Fact]
  public async Task A_macs_api_record_lands_in_this_pcs_api_accounts_and_the_app_remove_goes_through_the_delete_rule()
  {
    var data = AppDataRoot.Explicit(Path.Combine(root, "data"));
    var secrets = new TestSecretStore();
    var accounts = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("claude"), new FakeAccountProvider("codex")]);
    var service = new ApiAccountService(accounts, new AccountCredentials(secrets, data), data);
    var door = service.CloudDoor(_ => false);
    var store = new CloudKeysApiStore(door, State("W"), () => "PC W", removals: CloudKeysRemovals.Shared);
    var owner = Wrap(store.DeleteRuleOwner(State("W"), () => true, serviceClock: () => clock, now: Now));
    // As the Mac's JSONEncoder writes it (kind in the Mac's words, the default address filled in).
    var mac = new CloudSecretRecord("api", IdOne, CloudSecretsDomains.ApiKey, CloudJson.Parse(
      "{\"baseURL\":\"https://api.anthropic.com\",\"from\":\"Mac mini\",\"key\":\"" + KeyA + "\",\"kind\":\"anthropicToken\",\"name\":\"Work gateway\",\"provider\":\"claude\"}"));
    await owner.ValidateAsync(mac);
    Assert.Equal(CloudApplyStatus.Applied, await owner.MergeAsync(mac));
    Assert.True(await owner.VerifyAsync(mac, CloudApplyStatus.Applied));
    var row = Assert.Single(accounts.List());
    Assert.Equal(("111111111111111111111111" + "00000000", "Work gateway", AccountAuthentication.ApiKey, true), (row.Id, row.Name, row.Authentication, row.SignedIn));
    var connection = service.Read(row.Id)!;
    Assert.Equal((ApiKinds.AnthropicToken, (string?)null), (connection.Kind, connection.BaseUrl));
    // It goes back to Cloud as the very record that came (no echo with this PC's name inside).
    Assert.Equal(mac.Canonical(), Assert.Single(await owner.CaptureAsync()).Canonical());
    // A Remove in the app: everywhere, through the delete rule.
    CloudKeysRemovals.Shared.Set(CloudKeysRemovals.Through(new Dictionary<string, CloudSecretsDeleteOwner> { ["api"] = owner }, () => Actor(CloudDeleteBy.Person)));
    try { await service.RemoveAsync(row.Id, _ => false); }
    finally { CloudKeysRemovals.Shared.Set(null); }
    Assert.Empty(accounts.List());
    Assert.Single(await owner.CaptureRemovalsAsync());
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(mac));
    Assert.Empty(accounts.List());
    Assert.DoesNotContain(secrets.Values.Values, v => Encoding.UTF8.GetString(v) == KeyA);
  }

  [Fact]
  public async Task No_value_appears_in_names_or_errors()
  {
    var apiA = new KeysApiOwner(); apiA.Add(IdOne, "Work Claude", KeyA);
    var a = ApiOwner(apiA, "A");
    Assert.DoesNotContain(KeyA, string.Join(",", (await a.ItemsAsync()).Select(i => i.ToString())));
    var record = Assert.Single(await a.CaptureAsync());
    var broken = new CloudSecretRecord(record.SourceId, "not-an-api-id-" + KeyA, record.Domain, record.Payload);
    var error = await Assert.ThrowsAsync<CloudFailure>(() => Api(new KeysApiOwner(), "B").ValidateAsync(broken));
    Assert.DoesNotContain(KeyA, error.Message + error.Code);
    // An unknown member is refused (what is written back must be exactly what arrived).
    var extra = new CloudSecretRecord(record.SourceId, IdOne, record.Domain, new CloudJson.Object(((CloudJson.Object)record.Payload).Members.Append(new("note", CloudJson.From("x"))).ToArray()));
    await Assert.ThrowsAsync<CloudFailure>(() => Api(new KeysApiOwner(), "B").ValidateAsync(extra));
  }

  // ---------------------------------------------------------------- MCP servers (Claude Code's user list)

  /// Stands in for `claude mcp add-json/remove`: writes the scratch `.claude.json` as Claude Code would.
  private sealed class FakeClaude(string file) : ICodeProcessRunner
  {
    public readonly List<string> Commands = [];
    public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
    {
      Commands.Add(string.Join(" ", arguments.Take(5)));
      var rootNode = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file))!.AsObject() : new JsonObject();
      var list = rootNode["mcpServers"] as JsonObject ?? new JsonObject();
      rootNode["mcpServers"] = list;
      if (arguments is ["mcp", "add-json", "--scope", "user", "--", var name, var json])
      {
        if (list.ContainsKey(name)) return Task.FromResult(new CodeProcessResult(1, "", "exists"));
        list[name] = JsonNode.Parse(json);
      }
      else if (arguments is ["mcp", "remove", "--scope", "user", "--", var gone]) list.Remove(gone);
      else return Task.FromResult(new CodeProcessResult(1, "", "unknown"));
      File.WriteAllText(file, rootNode.ToJsonString());
      return Task.FromResult(new CodeProcessResult(0, "", ""));
    }
  }
  private sealed record McpDevice(CloudKeysMcpStore Store, ClaudeMcpUserList List, string File, FakeClaude Claude);
  private McpDevice Mcp(string device, Dictionary<string, string> servers)
  {
    var folder = Path.Combine(root, "home-" + device); Directory.CreateDirectory(folder);
    var file = Path.Combine(folder, ".claude.json");
    var list = new JsonObject();
    foreach (var (name, token) in servers) list[name] = new JsonObject { ["type"] = "stdio", ["command"] = "made-up-server", ["args"] = new JsonArray(), ["env"] = new JsonObject { ["TOKEN"] = token } };
    File.WriteAllText(file, new JsonObject { ["numStartups"] = 3, ["mcpServers"] = list }.ToJsonString());
    var claude = new FakeClaude(file);
    var user = new ClaudeMcpUserList(() => file, claude, folder);
    return new(new CloudKeysMcpStore(user, () => "PC " + device), user, file, claude);
  }
  private static string? Token(McpDevice d, string name) => ((d.List.Definitions()[name] as CloudJson.Object)?["env"] as CloudJson.Object)?["TOKEN"]?.AsString;
  private CloudSecretsDeleteOwner McpOwner(McpDevice d, string device, CloudSecretsVanished? vanished = null) =>
    Wrap(d.Store.DeleteRuleOwner(State(device), () => true, serviceClock: () => clock, vanished: vanished, now: Now));
  private static void RemoveOutside(McpDevice d, string name)
  {
    var node = JsonNode.Parse(File.ReadAllText(d.File))!.AsObject();
    (node["mcpServers"] as JsonObject)!.Remove(name);
    File.WriteAllText(d.File, node.ToJsonString());
  }

  [Fact]
  public async Task An_mcp_server_is_added_with_no_click_and_a_different_one_is_added_beside()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" }); var b = Mcp("B", []);
    var record = (await a.Store.CaptureAsync()).First(r => r.RecordId == "example");
    Assert.Equal(CloudApplyStatus.Applied, await b.Store.MergeAsync(record));
    Assert.Equal("MADE_UP_MCP_TOKEN", Token(b, "example"));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.Store.MergeAsync(record));
    var c = Mcp("C", new() { ["example"] = "MADE_UP_OTHER_TOKEN" });
    Assert.Equal(CloudApplyStatus.KeptBoth, await c.Store.MergeAsync(record));
    Assert.Equal("MADE_UP_OTHER_TOKEN", Token(c, "example"));
    Assert.Equal("MADE_UP_MCP_TOKEN", Token(c, "example-pc-a"));
    var copy = (await c.Store.CaptureAsync()).First(r => r.RecordId == "example-pc-a");
    Assert.Equal(CloudApplyStatus.KeptBoth, await a.Store.MergeAsync(copy));
    Assert.Null(a.List.Definitions()["example-pc-a"]);
    Assert.All(a.Claude.Commands.Concat(c.Claude.Commands), command => Assert.DoesNotContain("MADE_UP", command));
  }

  [Fact]
  public async Task An_mcp_server_removed_on_one_device_is_removed_on_the_other()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" }); var b = Mcp("B", []);
    var ownerA = McpOwner(a, "A"); var ownerB = McpOwner(b, "B");
    Assert.Equal(CloudApplyStatus.Applied, await ownerB.MergeAsync(Assert.Single(await ownerA.CaptureAsync())));
    _ = await ownerB.CaptureAsync();
    await ownerA.DeleteItemsAsync([Assert.Single(await ownerA.ItemsAsync())], CloudDeleteScope.Everywhere, Actor());
    Assert.Equal(CloudApplyStatus.Applied, await ownerB.MergeRemovalAsync(Assert.Single(await ownerA.CaptureRemovalsAsync())));
    Assert.Null(b.List.Definitions()["example"]);
  }

  [Fact]
  public async Task An_mcp_server_removed_outside_the_app_by_an_ai_goes_everywhere_and_stays_removed()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" });
    var owner = McpOwner(a, "A", ByAi());
    var record = Assert.Single(await owner.CaptureAsync());
    RemoveOutside(a, "example");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Single(await owner.CaptureRemovalsAsync());
    Assert.Equal("Night work", Assert.Single(await owner.BinGroupsAsync()).Session);
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(record));
    Assert.Null(a.List.Definitions()["example"]);
  }

  [Fact]
  public async Task An_mcp_server_removed_by_his_own_hand_stays_away_here_only_and_bring_back_restores_it()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" });
    var owner = McpOwner(a, "A", ByHand());
    var record = Assert.Single(await owner.CaptureAsync());
    RemoveOutside(a, "example");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Empty(await owner.CaptureRemovalsAsync());
    Assert.Equal(new[] { CloudLocalMark.NotOnThisPc }, (await owner.NotHereAsync()).Select(n => n.Mark));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(record));
    Assert.Null(a.List.Definitions()["example"]);
    Assert.Single(await owner.BringBackAsync([Assert.Single(await owner.NotHereAsync()).Item], CloudBringBackDestination.ThisPc));
    Assert.NotNull(a.List.Definitions()["example"]);
  }

  [Fact]
  public async Task A_missing_file_or_one_without_a_list_changes_nothing()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN", ["other"] = "MADE_UP_OTHER_TOKEN" });
    var owner = McpOwner(a, "A", ByAi());
    Assert.Equal(2, (await owner.CaptureAsync()).Count);
    var saved = File.ReadAllBytes(a.File);
    File.Delete(a.File);
    Assert.Empty(await owner.CaptureAsync());
    File.WriteAllText(a.File, "{}");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Empty(await owner.CaptureRemovalsAsync()); Assert.Empty(await owner.NotHereAsync()); Assert.Empty(await owner.BinGroupsAsync());
    File.WriteAllBytes(a.File, saved);
    Assert.Equal(2, (await owner.CaptureAsync()).Count);
  }

  [Fact]
  public async Task His_last_mcp_server_removed_by_his_hand_stays_away_here_and_sync_never_adds_it_back()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN", ["other"] = "MADE_UP_OTHER_TOKEN" });
    var owner = McpOwner(a, "A", ByHand());
    var records = await owner.CaptureAsync();
    RemoveOutside(a, "other");
    Assert.Equal(new[] { "example" }, (await owner.CaptureAsync()).Select(r => r.RecordId));
    RemoveOutside(a, "example");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Empty(await owner.CaptureRemovalsAsync());
    Assert.Equal(new[] { "example", "other" }, (await owner.NotHereAsync()).Select(n => n.Item.Id).Order());
    foreach (var record in records) Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(record));
    Assert.Empty(a.List.Definitions().Members);
  }

  [Fact]
  public async Task His_last_mcp_server_removed_by_an_ai_goes_everywhere_even_with_the_list_key_gone()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" });
    var owner = McpOwner(a, "A", ByAi());
    var record = Assert.Single(await owner.CaptureAsync());
    File.WriteAllText(a.File, "{\"numStartups\":3}");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Equal(new[] { "example" }, (await owner.CaptureRemovalsAsync()).Select(r => r.RecordId));
    Assert.Equal(new[] { "example" }, Assert.Single(await owner.BinGroupsAsync()).Items.Select(i => i.Name));
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await owner.MergeAsync(record));
  }

  [Fact]
  public async Task Two_mcp_servers_vanishing_at_once_with_an_empty_list_change_nothing()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN", ["other"] = "MADE_UP_OTHER_TOKEN" });
    var owner = McpOwner(a, "A", ByAi());
    Assert.Equal(2, (await owner.CaptureAsync()).Count);
    var saved = File.ReadAllBytes(a.File);
    File.WriteAllText(a.File, "{\"mcpServers\":{}}");
    Assert.Empty(await owner.CaptureAsync());
    Assert.Empty(await owner.CaptureRemovalsAsync()); Assert.Empty(await owner.NotHereAsync()); Assert.Empty(await owner.BinGroupsAsync());
    File.WriteAllBytes(a.File, saved);
    Assert.Equal(2, (await owner.CaptureAsync()).Count);
  }

  [Fact]
  public async Task A_missing_or_invalid_settings_file_changes_nothing_even_for_his_only_server()
  {
    var a = Mcp("A", new() { ["example"] = "MADE_UP_MCP_TOKEN" });
    var owner = McpOwner(a, "A", ByAi());
    Assert.Single(await owner.CaptureAsync());
    var saved = File.ReadAllBytes(a.File);
    File.Delete(a.File);
    Assert.Empty(await owner.CaptureAsync());
    foreach (var broken in new[] { "not json", "", "[]", "{\"mcpServers\": 5}" })
    {
      File.WriteAllText(a.File, broken);
      await Assert.ThrowsAnyAsync<Exception>(() => owner.CaptureAsync());
    }
    Assert.Empty(await owner.CaptureRemovalsAsync()); Assert.Empty(await owner.NotHereAsync()); Assert.Empty(await owner.BinGroupsAsync());
    File.WriteAllBytes(a.File, saved);
    Assert.Single(await owner.CaptureAsync());
  }

  [Fact]
  public void Only_an_ais_own_mcp_remove_command_names_the_server()
  {
    static string[] Covers(string command, bool powershell = false) =>
      CloudAiDeleteWitness.ShellCovers(command, "C:/made-up/project", "C:/made-up/home", 0, powershell).Covers.Select(c => c.Value).ToArray();
    var path = CloudMcpRemoveCommand.StandInPath("example");
    Assert.Equal(new[] { path }, Covers("claude mcp remove example"));
    Assert.Equal(new[] { path }, Covers("claude mcp remove --scope user -- example"));
    Assert.Equal(new[] { path }, Covers("claude.exe mcp remove example", powershell: true));
    Assert.Empty(Covers("claude mcp remove -s project example"));
    Assert.Empty(Covers("claude mcp remove $NAME"));
    Assert.Empty(Covers("claude mcp list"));
    Assert.Empty(Covers("claude mcp add-json example '{}'"));
  }

  // ---------------------------------------------------------------- server keys

  private const string KeyText = "-----BEGIN OPENSSH PRIVATE KEY-----\nMADE-UP-KEY-MATERIAL\n-----END OPENSSH PRIVATE KEY-----\n";
  private static readonly string HostKey = Convert.ToBase64String(Encoding.ASCII.GetBytes("made-up host key made-up host key made-up host key!"));
  private const string ServerId = "5f0e6a2c9b1d4c3e8f7a1b2c3d4e5f60";
  private sealed record SshDevice(CloudKeysSshStore Store, ServerStore Servers, string ServersFolder);
  private async Task<SshDevice> Ssh(string device, bool ownKey, bool withServer = true)
  {
    var data = Path.Combine(root, "ssh-" + device);
    var servers = new ServerStore(AppDataRoot.Explicit(data), new TestSecretStore());
    var serversFolder = Path.Combine(data, "servers");
    if (withServer)
    {
      await servers.CloudAddSshIfAbsentAsync(ServerId, new CloudSecretsServerDefinition("Work box", "work-box", 22, "deploy", null, true, null, null), "work-box");
      if (ownKey)
      {
        var place = Path.Combine(serversFolder, ServerId); Directory.CreateDirectory(place);
        File.WriteAllText(Path.Combine(place, "identity"), device == "A" ? KeyText : KeyText.Replace("MADE-UP", "OTHER-MADE-UP"));
        File.WriteAllText(Path.Combine(place, "known_hosts"), "work-box ssh-ed25519 " + HostKey + "\n");
      }
    }
    var folder = new CloudKeysSshFolder(Path.Combine(State(device), "ssh-travelled"));
    return new(new CloudKeysSshStore(servers, id => Path.Combine(serversFolder, id), folder, Path.Combine(State(device), "ssh-server-ids.json")), servers, serversFolder);
  }
  private static string[] Listing(string folder) => Directory.Exists(folder)
    ? Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Select(f => f + ":" + Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f)))).Order().ToArray() : [];

  [Fact]
  public async Task A_servers_key_and_settings_travel_and_the_other_pc_connects_with_the_apps_copy()
  {
    var a = await Ssh("A", ownKey: true); var b = await Ssh("B", ownKey: false, withServer: false);
    var record = Assert.Single(await a.Store.CaptureAsync());
    await b.Store.ValidateAsync(record);
    Assert.Equal(CloudApplyStatus.Applied, await b.Store.MergeAsync(record));
    Assert.True(await b.Store.VerifyAsync(record, CloudApplyStatus.Applied));
    Assert.Equal("work-box", Assert.Single(b.Servers.List()).SshAlias);
    var copy = b.Store.Folder.Travelled(ServerId)!;
    Assert.Equal(("work-box", "deploy", 22), (copy.Hostname, copy.User, copy.Port));
    Assert.StartsWith(b.Store.Folder.Root, Assert.Single(copy.IdentityFiles));
    Assert.Equal(KeyText, File.ReadAllText(copy.IdentityFiles[0]));
    Assert.Equal("work-box ssh-ed25519 " + HostKey + "\n", File.ReadAllText(copy.KnownHostsFile));
    Assert.Empty(Listing(b.ServersFolder));   // nothing was written as his own key
    Assert.Equal(CloudApplyStatus.AlreadyPresent, await b.Store.MergeAsync(record));
    Assert.Equal(record.Canonical(), Assert.Single(await b.Store.CaptureAsync()).Canonical());
  }

  [Fact]
  public async Task The_other_pcs_own_key_always_wins()
  {
    var a = await Ssh("A", ownKey: true); var b = await Ssh("B", ownKey: true);
    var before = Listing(b.ServersFolder);
    Assert.Equal(CloudApplyStatus.KeptBoth, await b.Store.MergeAsync(Assert.Single(await a.Store.CaptureAsync())));
    Assert.Null(b.Store.Folder.Travelled(ServerId));
    Assert.Equal(before, Listing(b.ServersFolder));
  }

  [Fact]
  public async Task Removing_a_server_key_removes_only_the_apps_copy_never_his_own()
  {
    var a = await Ssh("A", ownKey: true); var b = await Ssh("B", ownKey: false, withServer: false);
    var ownerA = Wrap(a.Store.DeleteRuleOwner(State("A"), () => true, serviceClock: () => clock, now: Now));
    var ownerB = Wrap(b.Store.DeleteRuleOwner(State("B"), () => true, serviceClock: () => clock, now: Now));
    var before = Listing(a.ServersFolder);
    Assert.Equal(CloudApplyStatus.Applied, await ownerB.MergeAsync(Assert.Single(await ownerA.CaptureAsync())));
    _ = await ownerB.CaptureAsync();
    var item = Assert.Single(await ownerA.ItemsAsync());
    Assert.Equal("Server key · Work box", item.Name);
    await ownerA.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, Actor());
    Assert.Equal(before, Listing(a.ServersFolder));
    Assert.Empty(await ownerA.CaptureAsync());
    Assert.Equal(CloudApplyStatus.Applied, await ownerB.MergeRemovalAsync(Assert.Single(await ownerA.CaptureRemovalsAsync())));
    Assert.Null(b.Store.Folder.Travelled(ServerId));
    Assert.Single(await ownerB.PutBackGroupAsync(Assert.Single(await ownerB.BinGroupsAsync()).Id));
    Assert.NotNull(b.Store.Folder.Travelled(ServerId));
  }

  [Fact]
  public async Task A_macs_server_key_record_lands_under_the_same_server_and_goes_back_byte_for_byte()
  {
    const string macId = "5F0E6A2C-9B1D-4C3E-8F7A-1B2C3D4E5F60";
    var b = await Ssh("B", ownKey: false, withServer: false);
    var key = Convert.ToBase64String(Encoding.UTF8.GetBytes(KeyText));
    var mac = new CloudSecretRecord("ssh", macId, CloudSecretsDomains.Ssh, CloudJson.Parse(
      "{\"alias\":\"work-box\",\"hostname\":\"192.0.2.10\",\"keys\":[{\"bytes\":\"" + key + "\",\"name\":\"id_ed25519\"}],\"knownHosts\":[{\"algorithm\":\"ssh-ed25519\",\"key\":\"" +
      Convert.ToBase64String(RandomNumberGenerator.GetBytes(51)) + "\"}],\"port\":2222,\"server\":{\"address\":\"work-box\",\"name\":\"Work box\",\"port\":22,\"username\":\"deploy\"},\"user\":\"deploy\"}"));
    Assert.Equal(CloudApplyStatus.Applied, await b.Store.MergeAsync(mac));
    Assert.Equal(ServerId, Assert.Single(b.Servers.List()).Id);
    Assert.Equal(("192.0.2.10", 2222), (b.Store.Folder.Travelled(ServerId)!.Hostname, b.Store.Folder.Travelled(ServerId)!.Port));
    var back = Assert.Single(await b.Store.CaptureAsync());
    Assert.Equal(macId, back.RecordId);
    Assert.Equal(mac.Canonical(), back.Canonical());
    // No key material in names or refusals.
    Assert.DoesNotContain("MADE-UP-KEY-MATERIAL", CloudKeysSshStore.Name(mac));
    var error = await Assert.ThrowsAsync<CloudFailure>(() => b.Store.ValidateAsync(new("ssh", "../" + KeyText, CloudSecretsDomains.Ssh, mac.Payload)));
    Assert.DoesNotContain("MADE-UP", error.Message + error.Code);
  }
}
