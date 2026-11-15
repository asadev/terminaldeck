using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The secrets class in the real engine (the Mac's CloudSecretsSyncEngineTests, CloudSecretsKnownCanonicalTests and the
// engine half of SecretsDeleteRuleTests): saved values travel sealed twice, on their own position, never stall memory,
// an older key generation's pack is closed (never parked), "already sent" is per generation and per queue, and the
// delete rule's sealed Bin: removals everywhere, kept away after, back only by Put back, unreadable removals closed.
public sealed class CloudSecretsSyncEngineTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-secrets-engine-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(root, true); } catch (Exception) { } }

  internal sealed class Store(string source = "servers", string domain = CloudSecretsDomains.Server) : ICloudSecretsStore
  {
    public readonly Dictionary<string, string> Values = new(StringComparer.Ordinal);
    public string SourceId => source; public string InventoryRow => "I14"; public string Domain => domain;
    public bool Locked { get; set; }
    public CloudSecretRecord Record(string id, string value) => new(SourceId, id, Domain, CloudJson.Obj(("password", CloudJson.From(value))));
    private static string Value(CloudSecretRecord r) => ((CloudJson.Object)r.Payload)["password"]!.AsString!;
    public Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync() => Locked ? throw new CloudFailure("secrets_locked")
      : Task.FromResult<IReadOnlyList<CloudSecretRecord>>(Values.OrderBy(v => v.Key).Select(v => Record(v.Key, v.Value)).ToArray());
    public Task ValidateAsync(CloudSecretRecord record) => Task.CompletedTask;
    public Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
    {
      if (!Values.TryGetValue(record.RecordId, out var old)) { Values[record.RecordId] = Value(record); return Task.FromResult(CloudApplyStatus.Applied); }
      return Task.FromResult(old == Value(record) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth);
    }
    public Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome) => Task.FromResult(true);
    public Task<bool> RemoveAsync(CloudSecretRecord record) =>
      Task.FromResult(Values.TryGetValue(record.RecordId, out var v) && v == Value(record) && Values.Remove(record.RecordId));
  }

  private sealed class Peer
  {
    public required CloudSecretsTestDevice Secrets; public required CloudSyncEngine Engine; public required Store Store;
    public required CloudTestAdapter Memory; public required CloudSecretsDeleteOwner Owner; public required CloudSecretsLogicalAdapter Adapter;
    public async Task Round() { await Engine.CaptureAsync(default); await Engine.FlushAsync(default); await Engine.PullAsync(default); }
  }
  private Peer Make(CloudFakeService feed, CloudSecretsFakeService service, CloudSecretsTestDevice secrets, CloudTestTrust trust)
  {
    var device = new CloudTestDevice(secrets.Id, feed);
    trust.Trusted[secrets.Id] = device.Jwk;
    var store = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), CloudFakeService.Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), CloudFakeService.Subject, device, feed, store, () => feed.Now,
      new CloudSyncBackoff(store, () => feed.Now, _ => 0));
    var folder = Path.Combine(root, secrets.Id);
    var values = new Store();
    var owner = new CloudSecretsDeleteOwner(values, folder, () => true, r => r.RecordId, values.RemoveAsync, serviceClock: () => feed.Now, now: () => feed.Now);
    var content = new CloudSecretsContent(CloudFakeService.Subject, secrets.Id, secrets.Handover);
    CloudSyncEngine? engine = null;
    var adapter = new CloudSecretsLogicalAdapter(owner, content, secrets.Id, new CloudSecretsKnownStore(Path.Combine(folder, "known")), store.OutboxId,
      op => engine!.StillQueued(op));
    var memory = new CloudTestAdapter(secrets.Id);
    engine = new CloudSyncEngine(CloudFakeService.Subject, secrets.Id, client, store, trust, device.Sign, [memory], null, () => feed.Now,
      new CloudSecretsClass(content, [adapter], new CloudMemorySlot()));
    return new Peer { Secrets = secrets, Engine = engine, Store = values, Memory = memory, Owner = owner, Adapter = adapter };
  }
  private async Task<(CloudFakeService Feed, CloudSecretsFakeService Service, Peer A, Peer B)> Two()
  {
    var feed = new CloudFakeService();
    var service = new CloudSecretsFakeService { Now = feed.Now };
    var sa = new CloudSecretsTestDevice(service, "Studio PC"); var sb = new CloudSecretsTestDevice(service, "Mac mini", "macos");
    sa.Trust(sb); sb.Trust(sa);
    await sa.Handover.SetupSilentlyAsync();
    await sb.Handover.RequestApprovalAsync(); await sa.Handover.AnswerAllAsync(); Assert.True(await sb.Handover.ReceiveApprovalAsync());
    var trust = new CloudTestTrust();
    return (feed, service, Make(feed, service, sa, trust), Make(feed, service, sb, trust));
  }

  [Fact]
  public async Task A_saved_value_travels_sealed_in_a_saved_passwords_pack_and_memory_is_untouched()
  {
    var (feed, _, a, b) = await Two();
    a.Store.Values["srv-1"] = "hunter2-fixture";
    await a.Round(); await b.Round();
    Assert.Equal("hunter2-fixture", b.Store.Values["srv-1"]);
    var page = await new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), CloudFakeService.Subject,
      new CloudTestDevice(Guid.NewGuid().ToString("D"), feed), feed, new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), CloudFakeService.Subject)).ChangesAsync(0, 128, default);
    var entry = Assert.Single(page.Segments);
    Assert.Equal("secrets", entry.StorageClass); Assert.Equal("secret", entry.Descriptor!.Purpose);
    Assert.Empty(b.Memory.Applied);
    // Nothing changed: nothing is sent again (the mark was written once the Cloud took it).
    await a.Round();
    Assert.Equal(1, feed.Segments);
  }

  [Fact]
  public async Task While_saved_passwords_are_locked_here_nothing_of_them_is_sent_and_memory_goes_on()
  {
    var (feed, _, a, _) = await Two();
    a.Secrets.Slots.Items.Remove("key");
    a.Store.Values["srv-1"] = "x";
    a.Memory.Add("note");
    await a.Round();
    Assert.Equal(1, feed.Segments);
    Assert.DoesNotContain(a.Engine.State().Phase, new[] { CloudSyncPhase.Sending });
    // The key arrives again: what waited goes now.
    a.Secrets.Handover.ForgetAfterRemoteSignOut();
    Assert.Equal(CloudSecretsProtection.Locked, a.Secrets.Handover.Protection());
  }

  [Fact]
  public async Task A_pack_of_an_older_key_generation_is_closed_not_parked_and_every_value_goes_again_under_the_new_key()
  {
    var (feed, service, a, b) = await Two();
    var lost = new CloudSecretsTestDevice(service, "Old");
    service.Due = new(service.Now, lost.Id, "Old", []);
    a.Store.Values["srv-1"] = "one";
    await a.Round();
    Assert.Equal(CloudSecretsKeyChange.Rotated, await a.Secrets.Handover.KeyChangeAsync());
    Assert.Equal(CloudSecretsKeyChange.TookCopy, await b.Secrets.Handover.KeyChangeAsync());
    await b.Round();
    Assert.False(b.Store.Values.ContainsKey("srv-1"));
    Assert.Contains(b.Engine.SecretsFeed!.Ledger.Refused, r => r.Reason == CloudSyncEngine.Superseded);
    await a.Round(); await b.Round();
    Assert.Equal("one", b.Store.Values["srv-1"]);
  }

  [Fact]
  public async Task A_removal_everywhere_travels_the_value_is_kept_away_after_and_comes_back_only_by_put_back()
  {
    var (feed, _, a, b) = await Two();
    a.Store.Values["srv-1"] = "leaked";
    await a.Round(); await b.Round(); await a.Round();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, a.Secrets.Id, "Studio PC", null, null, feed.Now, Guid.NewGuid().ToString("D"));
    await a.Owner.DeleteItemsAsync([new("srv-1", "saved-passwords", "srv-1", "servers")], CloudDeleteScope.Everywhere, actor);
    Assert.False(a.Store.Values.ContainsKey("srv-1"));
    await a.Round(); await b.Round();
    Assert.False(b.Store.Values.ContainsKey("srv-1"));
    Assert.Single(await b.Owner.BinGroupsAsync());
    // The same value showing up again (a restore of an old folder) is kept away; it never travels back.
    b.Store.Values["srv-1"] = "leaked";
    await b.Round(); await a.Round();
    Assert.False(a.Store.Values.ContainsKey("srv-1"));
    var group = Assert.Single(await a.Owner.BinGroupsAsync());
    Assert.Single(await a.Owner.PutBackGroupAsync(group.Id));
    Assert.Equal("leaked", a.Store.Values["srv-1"]);
  }

  [Fact]
  public async Task A_removal_whose_value_changed_here_is_not_applied_and_a_put_relabelled_as_a_removal_is_never_authority()
  {
    var (feed, _, a, b) = await Two();
    a.Store.Values["srv-1"] = "v1";
    await a.Round(); await b.Round();
    b.Store.Values["srv-1"] = "v2-his-own";
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, a.Secrets.Id, "Studio PC", "s", null, feed.Now, Guid.NewGuid().ToString("D"));
    await a.Owner.DeleteItemsAsync([new("srv-1", "saved-passwords", "srv-1", "servers")], CloudDeleteScope.Everywhere, actor);
    await a.Round(); await b.Round();
    Assert.Equal("v2-his-own", b.Store.Values["srv-1"]);
    // A put sealed under the key but sent as an "archive": closed as not applied, nothing removed.
    var forged = a.Store.Record("srv-2", "x");
    b.Store.Values["srv-2"] = "x";
    var content = new CloudSecretsContent(CloudFakeService.Subject, a.Secrets.Id, a.Secrets.Handover);
    var env = content.Seal(forged.Canonical(), Guid.NewGuid().ToString("D"), "secret", a.Secrets.Local.Read()!.Epoch, "identity");
    var op = new CloudOperation(1, Guid.NewGuid().ToString("D"), a.Secrets.Id, CloudSecretsDomains.Server, "srv-2", "x", [], "archive", null, null, new("servers", "srv-2"),
      feed.Now, env.ToJson(), CloudOperation.PayloadHashOf(env.ToJson()));
    op = op with { Revision = op.OpId };
    await b.Adapter.ApplyAsync(op, new(a.Secrets.Id, 9, null, false), default);
    Assert.Equal("x", b.Store.Values["srv-2"]);
    Assert.Contains(CloudSecretsLogicalAdapter.NotAppliedWords, b.Adapter.Notices().Keys);
  }

  [Fact]
  public async Task Marks_kept_on_disk_are_keyed_and_name_no_value_id_or_source()
  {
    var (feed, _, a, _) = await Two();
    a.Store.Values["srv-1"] = "very-secret-value";
    await a.Round();
    var marks = Directory.GetFiles(Path.Combine(root, a.Secrets.Id, "known"));
    Assert.NotEmpty(marks);
    foreach (var file in marks)
    {
      var text = File.ReadAllText(file);
      Assert.DoesNotContain("very-secret-value", text); Assert.DoesNotContain("srv-1", text); Assert.DoesNotContain("servers", text);
    }
  }
}
