using System.Collections.Immutable;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Receiver;

public sealed class ReceiverTests
{
  [Fact] public void InboxRestoresAndRulesOnlyPropose()
  {
    var f = new Fixture(); f.Store.SaveRule(new("rule", "Failures", "source", "failed", new(RouteKind.Session, "session")));
    var item = f.Store.Receive(new("source", "Build failed", "Outside message"));
    Assert.Equal(InboxStatus.Held, item.Status); Assert.Empty(f.Delivery.Keys);
    var restored = new ReceiverStore(f.State, f.Delivery, f.Clock);
    Assert.Equal(item, restored.Item(item.Id));
  }
  [Fact] public void ReviewPreselectsSavedProposalOnlyWhileItIsAValidDestination()
  {
    var f = new Fixture(); var proposed = new ReceiverTarget(RouteKind.Chat, "chat");
    f.Store.SaveRule(new("rule", "Chat rule", "source", "", proposed));
    var item = f.Store.Receive(new("source", "Incoming", "Review this")); var targets = f.Store.Destinations(item.ProjectId);
    Assert.Equal(proposed, item.Target);
    Assert.Equal(1, ReceiverReview.DestinationIndex(targets, item.Target));
    Assert.Equal(0, ReceiverReview.DestinationIndex(targets, new(RouteKind.Chat, "removed")));
    Assert.Equal(0, ReceiverReview.DestinationIndex(targets, null));
    Assert.Equal(-1, ReceiverReview.DestinationIndex([], proposed));
    Assert.Empty(f.Delivery.Keys);
  }
  [Fact] public void DuplicateRequestIsOneItemAcrossRestart()
  {
    var f = new Fixture(); var a = f.Store.Receive(new("source", "First", "one", ExternalId: "request"));
    var restored = new ReceiverStore(f.State, f.Delivery, f.Clock);
    var b = restored.Receive(new("source", "Second", "two", ExternalId: "request"));
    Assert.Equal(a.Id, b.Id); Assert.Single(restored.Items());
  }
  [Fact] public void DryRunSpendsNothingAndQuietHoursCrossMidnight()
  {
    var f = new Fixture(); f.Clock.Now = new(2026, 10, 29, 23, 0, 0, TimeSpan.Zero);
    var rule = new ReceiverRule("rule", "Quiet", "source", "", new(RouteKind.Session, "session"), QuietStartHour: 22, QuietEndHour: 8);
    var decision = f.Store.Test(new("source", "Sample", "text"), rule);
    Assert.Contains("Quiet hours", decision.Reason); Assert.Empty(f.Store.Items()); Assert.Empty(f.Store.Rules()); Assert.Empty(f.Delivery.Keys);
  }
  [Fact] public async Task FailedSendRetainsDeliveryKeyForRetry()
  {
    var f = new Fixture(); var item = f.Store.Receive(new("source", "Message", "text")); f.Delivery.Fail = true;
    var failed = await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session"));
    Assert.Equal(InboxStatus.Failed, failed.Status); f.Delivery.Fail = false;
    var done = await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session"));
    Assert.Equal(InboxStatus.Delivered, done.Status); Assert.Equal(f.Delivery.Keys[0], f.Delivery.Keys[1]);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session")));
  }
  [Fact] public async Task ConcurrentSendAndDismissCannotDoubleDeliver()
  {
    var f = new Fixture(); f.Delivery.Pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
    var item = f.Store.Receive(new("source", "Message", "text")); var send = f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session")).AsTask();
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session")));
    Assert.Throws<ArgumentException>(() => f.Store.Dismiss(item.Id));
    f.Delivery.Pending.SetResult(); await send; Assert.Single(f.Delivery.Keys);
  }
  [Fact] public async Task CannotRouteAcrossProjects()
  {
    var f = new Fixture(); var item = f.Store.Receive(new("source", "Message", "text"));
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "other")));
    Assert.Empty(f.Delivery.Keys); Assert.Equal(InboxStatus.Unrouted, f.Store.Item(item.Id).Status);
  }
  [Fact] public void PausedSourceAndUnsafeLinksAreRefused()
  {
    var f = new Fixture(); Assert.Throws<ArgumentException>(() => f.Store.Receive(new("source", "Link", "", "javascript:alert(1)")));
    Assert.Throws<ArgumentException>(() => f.Store.Receive(new("source", "Link", "", "https://name:password@example.test/")));
    f.Store.SaveSource(f.Store.Sources()[0] with { Enabled = false });
    Assert.Throws<ArgumentException>(() => f.Store.Receive(new("source", "Message", "text")));
  }
  [Fact] public void PersistenceFailureDoesNotChangeMemory()
  {
    var f = new Fixture(); f.State.Fail = true;
    Assert.Throws<IOException>(() => f.Store.Receive(new("source", "Message", "text"))); Assert.Empty(f.Store.Items());
  }
  [Fact] public void ArrivalLimitDoesNotLoseExistingItems()
  {
    var f = new Fixture();
    for (var i = 0; i < 60; i++) f.Store.Receive(new("source", "Message " + i, "text"));
    Assert.Throws<IOException>(() => f.Store.Receive(new("source", "Over limit", "text"))); Assert.Equal(60, f.Store.Items().Count);
  }
  [Fact] public async Task HourlyRuleLimitIsPreviewedWithoutAutomaticDelivery()
  {
    var f = new Fixture(); f.Store.SaveRule(new("rule", "One", "source", "", new(RouteKind.Session, "session"), PerHour: 1));
    var item = f.Store.Receive(new("source", "Message", "text")); await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session"));
    Assert.Contains("hourly limit", f.Store.Test(new("source", "Next", "text")).Reason); Assert.Single(f.Delivery.Keys);
  }
  [Fact] public void RuleOrderAndSourceHistoryStayIntact()
  {
    var f = new Fixture();
    f.Store.SaveRule(new("a", "A", "source", "", new(RouteKind.Session, "session"))); f.Store.SaveRule(new("b", "B", "source", "", new(RouteKind.Chat, "chat")));
    f.Store.MoveRule("b", 0); Assert.Equal("b", f.Store.Test(new("source", "Message", "text")).RuleId);
    f.Store.Receive(new("source", "Message", "text")); Assert.Throws<ArgumentException>(() => f.Store.RemoveSource("source"));
  }
  [Fact] public void SearchAndStatusFiltersMatchCounts()
  {
    var f = new Fixture(); var a = f.Store.Receive(new("source", "One", "Needle")); f.Store.Receive(new("source", "Two", "text")); f.Store.Dismiss(a.Id);
    Assert.Single(f.Store.Items(query: "needle")); Assert.Single(f.Store.Items(status: InboxStatus.Ignored)); Assert.Single(f.Store.Items(status: InboxStatus.Unrouted));
  }
  [Fact] public void PhoneLookAccessCannotWriteAndWorkOnlyProposes()
  {
    var f = new Fixture(); var phone = new ReceiverPhoneIntake(f.Store, (_, id) => id == "session", (_, _) => "source");
    var bytes = Encoding.UTF8.GetBytes("{\"t\":\"session.send\",\"id\":\"session\",\"rid\":\"request\",\"data\":\"Hello\"}");
    Assert.Throws<ProtocolException>(() => phone.SendToSession(new("phone", "Phone", "ios", PhoneAccess.Look), bytes));
    _ = phone.SendToSession(new("phone", "Phone", "ios", PhoneAccess.Work), bytes);
    Assert.Equal(InboxStatus.Held, Assert.Single(f.Store.Items()).Status); Assert.Empty(f.Delivery.Keys);
  }
  [Fact] public void PhoneGrantCannotBeReplacedByVisibleDestination()
  {
    var f = new Fixture(); var phone = new ReceiverPhoneIntake(f.Store, (_, _) => false, (_, _) => "source");
    Assert.Throws<ProtocolException>(() => phone.Report(new("phone", "Phone", "android", PhoneAccess.Full), "session", "Report", "body", "r")); Assert.Empty(f.Store.Items());
  }
  [Fact] public async Task PhoneAcknowledgementUsesExistingWireAndOnlyConfirmsDelivery()
  {
    var f = new Fixture(); var phone = new ReceiverPhoneIntake(f.Store, (_, _) => true, (_, _) => "source");
    var device = new ApprovedDevice("phone", "Phone", "android", PhoneAccess.Work);
    var bytes = Encoding.UTF8.GetBytes("{\"t\":\"session.send\",\"id\":\"session\",\"rid\":\"request\",\"data\":\"Hello\"}");
    using var held = System.Text.Json.JsonDocument.Parse(phone.SendToSession(device, bytes));
    Assert.Equal("session.sent", held.RootElement.GetProperty("t").GetString()); Assert.False(held.RootElement.GetProperty("ok").GetBoolean());
    Assert.Equal("session", held.RootElement.GetProperty("id").GetString());
    var item = Assert.Single(f.Store.Items()); await f.Store.RouteAsync(item.Id, new(RouteKind.Session, "session"));
    using var sent = System.Text.Json.JsonDocument.Parse(phone.SendToSession(device, bytes)); Assert.True(sent.RootElement.GetProperty("ok").GetBoolean()); Assert.Single(f.Store.Items());
  }
  [Fact] public void ToolNamesAndTiersMatchMacAndMutationsAreNeverReads()
  {
    var specs = ReceiverContracts.Specs;
    Assert.Equal(specs.Count, specs.Select(s => s.Wire).Distinct().Count());
    Assert.Equal(McpTier.Act, specs.Single(s => s.Id == "receiver.route").Tier);
    Assert.Equal(McpTier.Alter, specs.Single(s => s.Id == "receiver.source_change").Tier);
    Assert.Equal(McpTier.Alter, specs.Single(s => s.Id == "artifacts.remove").Tier);
    Assert.Equal(McpTier.Read, specs.Single(s => s.Id == "artifacts.list").Tier);
    foreach (var spec in specs) Assert.Equal(spec.Id.Replace('.', '_'), spec.Wire);
  }
  [Fact] public void ToolSchemasDescribeTheWindowsRecordsAndRefuseHiddenSourceFields()
  {
    var change = ReceiverContracts.Specs.Single(s => s.Id == "receiver.source_change");
    McpSchema.Validate(change.InputSchema, ReceiverJson.Value(new { action = "update", source = new ReceiverSource("source", "Browser", IntakeKind.Browser, "project") }));
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(change.InputSchema, ReceiverJson.Value(new { action = "update", source = new { id = "source", name = "Browser", kind = "browser", projectId = "project", unexpectedField = "refused" } })));
    var route = ReceiverContracts.Specs.Single(s => s.Id == "receiver.route");
    McpSchema.Validate(route.InputSchema, ReceiverJson.Value(new { id = "item", target = new ReceiverTarget(RouteKind.Hoot) }));
  }
}

internal sealed class MemoryState<T> : IStateStore<T>
{
  public T? Value; public bool Fail;
  public T? Load() => Value;
  public void Save(T value) { if (Fail) throw new IOException("Test write failed."); Value = value; }
}
internal sealed class TestClock : TimeProvider
{
  public DateTimeOffset Now = new(2026, 10, 29, 12, 0, 0, TimeSpan.Zero);
  public override DateTimeOffset GetUtcNow() => Now;
  public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
}
internal sealed class Delivery : IReceiverDelivery
{
  public readonly List<string> Keys = []; public bool Fail; public TaskCompletionSource? Pending;
  public IReadOnlyList<ReceiverDestination> Destinations() => [new(new(RouteKind.Session, "session"), "Session", "project"), new(new(RouteKind.Chat, "chat"), "Chat", "project"), new(new(RouteKind.Session, "other"), "Other", "other-project")];
  public async ValueTask<DeliveryReceipt> DeliverAsync(ReceiverItem item, ReceiverTarget target, string deliveryId, CancellationToken ct)
  { Keys.Add(deliveryId); if (Pending is not null) await Pending.Task.WaitAsync(ct); if (Fail) throw new IOException("Test delivery failed."); return new("receipt", "Delivered."); }
}
internal sealed class Fixture
{
  public readonly MemoryState<ReceiverState> State = new(); public readonly Delivery Delivery = new(); public readonly TestClock Clock = new(); public readonly ReceiverStore Store;
  public Fixture() { Store = new(State, Delivery, Clock); Store.SaveSource(new("source", "Test source", IntakeKind.Browser, "project")); }
}

public sealed class ReceiverHttpTests
{
  private static readonly string Token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
  private static async Task<HttpResponseMessage> Post(HttpClient client, object value)
  {
    using var content = new ByteArrayContent(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(value));
    content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
    return await client.PostAsync("/receive", content);
  }
  private static HttpClient Client(ReceiverHttpIntake endpoint, bool authorized = true)
  {
    var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{endpoint.Port}"), Timeout = TimeSpan.FromSeconds(10) };
    if (authorized) client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Token); return client;
  }
  [Fact] public async Task AuthorizedExtensionOnlyStoresInInbox()
  {
    var f = new Fixture(); await using var endpoint = new ReceiverHttpIntake(f.Store, "source", Token); using var client = Client(endpoint);
    client.DefaultRequestHeaders.Add("Origin", "chrome-extension://example");
    var response = await Post(client, new { title = "Link", text = "context", url = "https://example.test/" });
    Assert.Equal(HttpStatusCode.Accepted, response.StatusCode); Assert.Equal(InboxStatus.Unrouted, Assert.Single(f.Store.Items()).Status); Assert.Empty(f.Delivery.Keys);
  }
  [Fact] public async Task MissingTokenIsRefused()
  {
    var f = new Fixture(); await using var endpoint = new ReceiverHttpIntake(f.Store, "source", Token); using var client = Client(endpoint, false);
    Assert.Equal(HttpStatusCode.Unauthorized, (await Post(client, new { title = "A" })).StatusCode); Assert.Empty(f.Store.Items());
  }
  [Fact] public async Task WebPageAndHostRebindingAreRefused()
  {
    var f = new Fixture(); await using var endpoint = new ReceiverHttpIntake(f.Store, "source", Token); using var client = Client(endpoint);
    client.DefaultRequestHeaders.Add("Origin", "https://example.test"); Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsJsonAsync("/receive", new { title = "A" })).StatusCode);
    client.DefaultRequestHeaders.Remove("Origin"); client.DefaultRequestHeaders.Host = "evil.test";
    Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsJsonAsync("/receive", new { title = "A" })).StatusCode); Assert.Empty(f.Store.Items());
  }
  [Fact] public async Task PathsAndPreflightCannotEnter()
  {
    var f = new Fixture(); await using var endpoint = new ReceiverHttpIntake(f.Store, "source", Token); using var client = Client(endpoint);
    Assert.Equal(HttpStatusCode.BadRequest, (await Post(client, new { title = "A", path = "C:/private" })).StatusCode);
    using var preflight = new HttpRequestMessage(HttpMethod.Options, "/receive"); Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(preflight)).StatusCode); Assert.Empty(f.Store.Items());
  }
  [Fact] public async Task OversizedBodyIsRefusedBeforeParsing()
  {
    var f = new Fixture(); await using var endpoint = new ReceiverHttpIntake(f.Store, "source", Token); using var client = Client(endpoint);
    using var body = new StringContent(new string('a', 65537), Encoding.UTF8, "application/json");
    Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await client.PostAsync("/receive", body)).StatusCode); Assert.Empty(f.Store.Items());
  }
}

public sealed class ReceiverArtifactsTests : IDisposable
{
  private readonly string root = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-receiver-" + Guid.NewGuid().ToString("N"));
  public ReceiverArtifactsTests() => Directory.CreateDirectory(root);
  public void Dispose() => Directory.Delete(root, true);
  private ReceiverArtifacts Index(Func<string, CancellationToken, ValueTask>? open = null) => new(new MemoryState<ReceiverArtifactState>(), cwd => cwd == root ? "project" : null, open ?? ((_, _) => ValueTask.CompletedTask), (_, _, _) => ValueTask.CompletedTask);
  [Fact] public void OnlyRecordedOutputsAppearAndRemoveKeepsFile()
  {
    File.WriteAllText(Path.Combine(root, "made.html"), "output"); File.WriteAllText(Path.Combine(root, "source.cs"), "source");
    var index = Index(); Assert.Empty(index.List(root)); index.Record(root, "made.html", "session", DateTimeOffset.UtcNow);
    Assert.Single(index.List(root)); index.Remove(root, "made.html"); Assert.Empty(index.List(root)); Assert.True(File.Exists(Path.Combine(root, "made.html")));
  }
  [Fact] public void TraversalAndUnknownProjectsAreRefused()
  {
    Assert.Throws<ArgumentException>(() => ReceiverArtifacts.SafePath(root, "../private.txt")); Assert.Throws<ArgumentException>(() => ReceiverArtifacts.SafePath(root, "C:/private.txt"));
    Assert.Throws<ArgumentException>(() => Index().List(Path.GetDirectoryName(root)!));
  }
  [Fact] public void SymlinkLoopsAreRefusedWithoutScanning()
  {
    Directory.CreateSymbolicLink(Path.Combine(root, "loop"), root);
    Assert.Throws<IOException>(() => ReceiverArtifacts.SafePath(root, "loop/output.txt"));
  }
  [Fact] public async Task ExecutableCannotBeOpenedAndTextPreviewIsBounded()
  {
    var opened = false; var index = Index((_, _) => { opened = true; return ValueTask.CompletedTask; });
    File.WriteAllText(Path.Combine(root, "made.exe"), "executable"); index.Record(root, "made.exe", "session", DateTimeOffset.UtcNow);
    await Assert.ThrowsAsync<ArgumentException>(async () => await index.OpenAsync(root, "made.exe")); Assert.False(opened);
    File.WriteAllText(Path.Combine(root, "long.html"), new string('x', 70000)); index.Record(root, "long.html", "session", DateTimeOffset.UtcNow);
    var preview = index.Preview(root, "long.html"); Assert.True(preview.Truncated); Assert.Equal(65536, preview.Text!.Length);
    await index.OpenAsync(root, "long.html"); Assert.True(opened);
  }
  [Theory]
  [InlineData("output.js")]
  [InlineData("output.py")]
  [InlineData("output.html")]
  [InlineData("output.json")]
  public async Task PreviewableSourceAlwaysSelectsAFixedTextEditor(string name)
  {
    var index = Index(); File.WriteAllText(Path.Combine(root, name), "source text"); index.Record(root, name, "session", DateTimeOffset.UtcNow);
    if (ArtifactCatalogPolicy.Includes(name)) Assert.Equal("source text", index.Preview(root, name).Text);
    else { Assert.Empty(index.List(root)); Assert.Throws<ArgumentException>(() => index.Preview(root, name)); }
    Assert.Equal(ArtifactOpenHandler.TextEditor, ArtifactOpenPolicy.HandlerFor(name));
    if (ArtifactCatalogPolicy.Includes(name)) await index.OpenAsync(root, name);
    Assert.Equal(ArtifactOpenHandler.DefaultApplication, ArtifactOpenPolicy.HandlerFor("photo.png"));
    Assert.Equal(ArtifactOpenHandler.DefaultApplication, ArtifactOpenPolicy.HandlerFor("document.pdf"));
    Assert.Throws<ArgumentException>(() => ArtifactOpenPolicy.HandlerFor("script.ps1"));
    Assert.Throws<ArgumentException>(() => ArtifactOpenPolicy.HandlerFor("script.cmd"));
  }
  [Fact] public async Task ImportedFilesKeepBytesAndDistinctContentDoesNotDeduplicate()
  {
    var files = new ReceiverFiles(AppDataRoot.Explicit(root)); var f = new Fixture();
    var a = await files.ImportAsync(new MemoryStream([1, 2]), "photo.png", "image/png"); var b = await files.ImportAsync(new MemoryStream([3, 4]), "photo.png", "image/png");
    f.Store.Receive(new("source", "Photo", "", Files: [a])); f.Store.Receive(new("source", "Photo", "", Files: [b])); Assert.Equal(2, f.Store.Items().Count);
    using var read = files.Open(a); Assert.Equal(1, read.ReadByte());
    await Assert.ThrowsAsync<ArgumentException>(async () => await files.ImportAsync(new MemoryStream([1]), "../bad", "text/plain"));
  }
  [Fact] public void OlderArtifactCanBePreviewedByItsExactPath()
  {
    File.WriteAllText(Path.Combine(root, "old.html"), "Older output"); var at = DateTimeOffset.UtcNow;
    var rows = Enumerable.Range(0, 301).Select(i => new ReceiverArtifact(i.ToString(), "project", root, i == 0 ? "old.html" : $"later-{i}.html", "session", at.AddSeconds(i))).ToImmutableArray();
    var state = new MemoryState<ReceiverArtifactState> { Value = new(rows) };
    var index = new ReceiverArtifacts(state, _ => "project", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    Assert.Equal("Older output", index.Preview(root, "old.html").Text);
  }
}
