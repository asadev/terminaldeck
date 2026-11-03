using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Remote;

// The phone features a Mac serves, on Windows (windows-phone-features, 1 Nov 2026).
public sealed class PhoneHostFeaturesTests
{
  private sealed class TrustStore : IDeviceTrustPersistence
  { private IReadOnlyList<StoredDevice> devices = []; public IReadOnlyList<StoredDevice> Load() => devices; public void Save(IReadOnlyList<StoredDevice> next) => devices = next; }
  private sealed class NoSessions : IPhoneSessionView { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => []; }
  private sealed class Store<T>(T value) : IStateStore<T> { public T? Load() => value; public void Save(T next) => value = next; }
  // A keeper watch that stays open with nothing new to say, as a quiet terminal's does.
  private sealed class QuietStream : Stream
  {
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => 0; public override long Position { get => 0; set { } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) { await Task.Delay(Timeout.Infinite, ct); return 0; }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
  }

  private sealed class Host : IPhoneHostSessions
  {
    public List<SessionRecord> Terminal = [];
    public List<ChatRecord> Chat = [];
    public HashSet<string> Shared = [];
    public List<string> Written = [];
    public List<string> Closed = [];
    public event Action? Changed;
    public void Raise() => Changed?.Invoke();
    public bool Broken;
    public IChatSessions? Engine;
    public string ChatFolder = "C:\\Work\\Sample";
    public Func<ApprovedDevice, IReadOnlyList<string>, CancellationToken, ValueTask<ChatAttachmentData[]>>? LoadAttachments;
    public bool SupportsAttachments => LoadAttachments is not null;
    public ValueTask<ChatAttachmentData[]> AttachmentsAsync(ApprovedDevice d, IReadOnlyList<string> p, CancellationToken ct) => LoadAttachments!(d, p, ct);
    public IReadOnlyList<SessionRecord> Terminals() => Broken ? throw new NullReferenceException("synthetic") : Terminal;
    public IReadOnlyList<ChatRecord> Chats() => Chat;
    public bool Visible(ApprovedDevice device, SessionRecord terminal) => device.Access == PhoneAccess.Full || Shared.Contains(terminal.Definition.Id);
    public bool Visible(ApprovedDevice device, ChatRecord chat) => device.Access == PhoneAccess.Full || Shared.Contains(chat.Definition.Id);
    public IReadOnlyList<string> Folders(ApprovedDevice device) => [ChatFolder];
    public bool MayStartIn(ApprovedDevice device, string folder) => folder == ChatFolder;
    public ValueTask<SessionRecord> StartTerminalAsync(string provider, string folder, string? accountId, CancellationToken ct)
    {
      var row = Session(Guid.NewGuid().ToString(), provider, SessionState.Running); Terminal.Add(row); return ValueTask.FromResult(row);
    }
    public ValueTask<ChatRecord> StartChatAsync(string provider, string folder, string? accountId, ChatOptions options, AiPermissionMode? mode, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask CloseAsync(string id, CancellationToken ct) { Closed.Add(id); return ValueTask.CompletedTask; }
    public ValueTask RenameAsync(string id, string title, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<KeeperRemoteAttachment> AttachAsync(string id, CancellationToken ct) =>
      ValueTask.FromResult(new KeeperRemoteAttachment(new QuietStream(), new SessionSnapshot(7, Terminal.Single(s => s.Definition.Id == id), "PS C:\\Work\\Sample> ")));
    public ValueTask WriteAsync(string id, string data, CancellationToken ct) { Written.Add(id + ":" + data); return ValueTask.CompletedTask; }
    public ValueTask ResizeAsync(string id, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public IChatSessions? ChatEngine => Engine;
    public IReadOnlyList<AccountProfile> Accounts() => [];
    public AccountProfile? PreferredAccount(string provider, string folder) => null;
    public AiPermissionMode NewChatPermission(string provider) => AiPermissionMode.Ask;
  }

  private sealed class Activity : ISystemActivityReader
  {
    public JsonObject Sample(bool top) => new()
    {
      ["at"] = 1, ["cpu"] = new JsonObject { ["total"] = 12.5, ["cores"] = new JsonArray(10.0, 15.0), ["count"] = 2 },
      ["memory"] = new JsonObject { ["used"] = 4L << 30, ["total"] = 16L << 30, ["pressure"] = "normal", ["swapUsed"] = 0, ["swapTotal"] = 0 },
      ["load"] = null, ["disk"] = new JsonObject { ["free"] = 1, ["total"] = 2 }, ["net"] = new JsonObject { ["in"] = null, ["out"] = null }, ["busy"] = false
    };
  }

  private sealed class Screen : IScreenHost
  {
    public List<ScreenInput> Posted = [];
    public IReadOnlyList<ScreenDisplay> Displays() => [new("mac:1", "DESKTOP-TEST", 1920, 1080, true)];
    public ScreenPicture? Capture(string displayId, int maxSide, int quality, bool drawCursor, ulong? unlessHash, out string? problem)
    { problem = null; return unlessHash == 1 ? new([], 1920, 1080, 1) : new([1, 2, 3], 1920, 1080, 1); }
    public ScreenStill? Still(string displayId, out string? problem) { problem = null; return new(new byte[16 * 9 * 4], 16, 9); }
    public byte[] EncodePng(ScreenStill still) => [0x89];
    public byte[] EncodeJpeg(ScreenStill still, int maxSide, int quality, out int width, out int height) { width = still.Width; height = still.Height; return [0xFF, 0xD8]; }
    public string? Post(string displayId, ScreenInput input) { lock (Posted) Posted.Add(input); return null; }
    public ScreenPointer? Pointer(string displayId, int knownShape) => new(0.5, 0.5, true, null);
    public bool? TextFocus() => false;
    public string? Block;
    public string? Blocked() => Block;
  }

  private sealed class Fixture : IDisposable
  {
    public DeviceTrust Trust { get; } = new(new TrustStore());
    public byte[] Key { get; } = Enumerable.Repeat((byte)7, 32).ToArray();
    public PairingReceipt Pair { get; }
    public Host Host { get; } = new();
    public Screen Screen { get; } = new();
    public PhoneHostFeatures App { get; }
    public List<JsonElement> Pushed { get; } = [];
    public Fixture(PhoneAccess access)
    {
      Pair = Trust.Redeem(Trust.Pairing.Create().Code, "Synthetic iPhone", "ios", Key); Trust.Approve(Pair.DeviceId, access);
      // §11.7: H.264 on a direct link (the fixture's phone has one).
      var screens = new PhoneScreens(Screen, () => true, "off", () => [], (_, _, _, _, _) => ValueTask.FromResult("Sent.")) { Video = new FakeScreenVideo(), HasLink = _ => true };
      App = new(new PhoneLink(Trust, "DESKTOP-TEST", "0.20.2.8", new NoSessions()), Trust, Host, new Activity(), screens);
      App.SetPublisher((_, bytes, _) => { lock (Pushed) Pushed.Add(Parse(bytes)); return ValueTask.CompletedTask; });
    }
    public async Task<(JsonElement[] Frames, bool Close)> Send(object value)
    {
      var reply = await App.ReceiveAsync("phone", Key, JsonSerializer.SerializeToUtf8Bytes(value), default);
      return (reply.Messages.Select(Parse).ToArray(), reply.Close);
    }
    public Task<(JsonElement[] Frames, bool Close)> Hello() =>
      Send(new { t = "hello", protocol = 1, token = Pair.Credential, device = new { name = "Synthetic iPhone", platform = "ios" }, capabilities = new[] { "device.access" } });
    public void Dispose() => App.Dispose();
  }

  private static JsonElement Parse(byte[] bytes) { using var doc = JsonDocument.Parse(bytes); return doc.RootElement.Clone(); }
  private static SessionRecord Session(string id, string provider, SessionState state, string cwd = "C:\\Work\\Sample") =>
    new(new(id, provider, cwd, provider == "shell" ? "PowerShell" : "Claude Code"), Guid.NewGuid().ToString("N"), state, CreatedAt: 1_000);
  private static ChatRecord Chat(string id, bool busy, params ChatEvent[] events) =>
    new(1, new(id, "claude", "C:\\Work\\Sample", "Plan the release", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()), "key", events, [], Busy: busy);

  [Fact]
  public async Task UploadedAttachmentOnlyMessageUsesActualChatOwnerAndRetryDoesNotDuplicateMedia()
  {
    await using var chat = new TerminalDeck.Core.Tests.Chats.ChatFixture(); await chat.InitializeAsync();
    using var f = new Fixture(PhoneAccess.Work);
    f.Host.Engine = chat.Chats; f.Host.ChatFolder = chat.Root.DirectoryPath; f.Host.Chat.Add(chat.Chat); f.Host.Shared.Add(chat.Chat.Definition.Id);
    var ledger = new PhoneUploadedFiles(); var path = Path.Combine(chat.Root.DirectoryPath, "proof.pdf");
    var bytes = "%PDF-1.7\nsynthetic"u8.ToArray(); await File.WriteAllBytesAsync(path, bytes);
    ledger.Remember(new(f.Pair.DeviceId, "Phone", "ios", PhoneAccess.Work), path, bytes.Length, Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)));
    var allowed = true;
    f.Host.LoadAttachments = (d, p, ct) => ledger.ReadAsync(d, p, (_, _) => allowed, ct);
    await f.Hello(); var id = Guid.NewGuid().ToString();
    var message = new { t = "chats.say", id = chat.Chat.Definition.Id, text = "", clientMessageId = id, files = new[] { path } };
    Assert.Empty((await f.Send(message)).Frames);
    var sent = Assert.Single(chat.Chats.Get(chat.Chat.Definition.Id).Messages); var media = Assert.Single(sent.Media);
    Assert.Equal("application/pdf", media.MimeType); Assert.Equal(bytes, chat.Chats.ReadImage(chat.Chat.Definition.Id, media));
    Assert.Empty((await f.Send(message)).Frames); Assert.Single(chat.Chats.Get(chat.Chat.Definition.Id).Messages);
    allowed = false;
    Assert.Equal("error", Assert.Single((await f.Send(message)).Frames).GetProperty("t").GetString());
    Assert.Single(chat.Chats.Get(chat.Chat.Definition.Id).Messages);
    allowed = true;
    f.Host.LoadAttachments = async (d, p, ct) =>
    {
      var files = await ledger.ReadAsync(d, p, (_, _) => true, ct);
      f.Host.Shared.Clear(); // The grant disappears while file IO is in flight.
      return files;
    };
    Assert.Equal("error", Assert.Single((await f.Send(new { t = "chats.say", id = chat.Chat.Definition.Id, text = "", clientMessageId = Guid.NewGuid().ToString(), files = new[] { path } })).Frames).GetProperty("t").GetString());
    Assert.Single(chat.Chats.Get(chat.Chat.Definition.Id).Messages);
  }

  [Fact]
  public async Task FullControlSeesEverySessionAndChatWithTheirRealStateAndTheMacsCapabilities()
  {
    using var f = new Fixture(PhoneAccess.Full);
    f.Host.Terminal.Add(Session("11111111-1111-1111-1111-111111111111", "shell", SessionState.Running));
    f.Host.Terminal.Add(Session("22222222-2222-2222-2222-222222222222", "claude", SessionState.Exited));
    var waiting = Chat("33333333-3333-3333-3333-333333333333", false, new ChatEvent(1, "user", "u1", "Deploy?"), new ChatEvent(2, "approval", "req-1", "Run deploy.ps1"));
    f.Host.Chat.Add(waiting);
    f.Host.Chat.Add(Chat("44444444-4444-4444-4444-444444444444", true, new ChatEvent(1, "user", "u1", "Hi")));
    var (frames, close) = await f.Hello();
    Assert.False(close);
    var welcome = frames.Single(m => m.GetProperty("t").GetString() == "welcome");
    var caps = welcome.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()).ToArray();
    foreach (var cap in new[] { "create", "close", "rename", "chats", "activity", "sims" }) Assert.Contains(cap, caps);
    var rows = welcome.GetProperty("sessions").EnumerateArray().ToDictionary(r => r.GetProperty("id").GetString()!, r => r);
    Assert.Equal(4, rows.Count);
    Assert.Equal("idle", rows["11111111-1111-1111-1111-111111111111"].GetProperty("status").GetString());
    Assert.Equal("exited", rows["22222222-2222-2222-2222-222222222222"].GetProperty("status").GetString());
    Assert.Equal("waiting", rows["33333333-3333-3333-3333-333333333333"].GetProperty("status").GetString());
    Assert.True(rows["33333333-3333-3333-3333-333333333333"].GetProperty("chat").GetBoolean());
    Assert.Equal("working", rows["44444444-4444-4444-4444-444444444444"].GetProperty("status").GetString());
    Assert.Contains("C:\\Work\\Sample", welcome.GetProperty("folders").EnumerateArray().Select(x => x.GetString()));
    Assert.Equal("0.20.2.8", welcome.GetProperty("appVersion").GetString());
  }

  [Fact]
  public async Task AnUnknownMessageIsAnsweredLikeTheMacAndTheConnectionStaysOpen()
  {
    using var f = new Fixture(PhoneAccess.Full);
    await f.Hello();
    var (frames, close) = await f.Send(new { t = "future.thing", rid = "r1" });
    Assert.False(close);
    var error = Assert.Single(frames);
    Assert.Equal("bad-message", error.GetProperty("code").GetString());
    Assert.Equal("unknown message type: future.thing", error.GetProperty("message").GetString());
    var (pong, stillOpen) = await f.Send(new { t = "ping" });
    Assert.False(stillOpen); Assert.Equal("pong", Assert.Single(pong).GetProperty("t").GetString());
    var (panel, panelClose) = await f.Send(new { t = "panel.read", panel = "goals", path = "C:\\Work" });
    Assert.False(panelClose); Assert.Equal("unavailable", Assert.Single(panel).GetProperty("code").GetString());
  }

  [Fact]
  public async Task AnUnexpectedFailureIsAnsweredAndNeverStopsTheRelay()
  {
    using var f = new Fixture(PhoneAccess.Full);
    f.Host.Broken = true;
    var (welcome, closed) = await f.Hello();
    Assert.False(closed); Assert.Contains(welcome, m => m.GetProperty("t").GetString() == "welcome");
    var (frames, close) = await f.Send(new { t = "list" });
    Assert.False(close); Assert.Equal("unavailable", Assert.Single(frames).GetProperty("code").GetString());
    var (silent, _) = await f.Send(new { t = "sims.input", id = "mac:1", @do = "wheel", dy = 0.1 });
    Assert.Empty(silent);
  }

  [Fact]
  public async Task LookOnlySeesOnlySharedSessionsAndCannotType()
  {
    using var f = new Fixture(PhoneAccess.Look);
    f.Host.Terminal.Add(Session("11111111-1111-1111-1111-111111111111", "shell", SessionState.Running));
    f.Host.Terminal.Add(Session("22222222-2222-2222-2222-222222222222", "shell", SessionState.Running));
    f.Host.Shared.Add("11111111-1111-1111-1111-111111111111");
    await f.Hello();
    var (list, _) = await f.Send(new { t = "list" });
    Assert.Equal("11111111-1111-1111-1111-111111111111", Assert.Single(Assert.Single(list).GetProperty("sessions").EnumerateArray().ToArray()).GetProperty("id").GetString());
    var (refused, close) = await f.Send(new { t = "input", id = "11111111-1111-1111-1111-111111111111", data = "dir\r" });
    Assert.False(close); Assert.Equal("unauthorized", Assert.Single(refused).GetProperty("code").GetString());
    Assert.Empty(f.Host.Written);
  }

  [Fact]
  public async Task APhoneOpensATerminalSeesItsScreenAndTypes()
  {
    using var f = new Fixture(PhoneAccess.Work);
    const string id = "11111111-1111-1111-1111-111111111111";
    f.Host.Terminal.Add(Session(id, "shell", SessionState.Running)); f.Host.Shared.Add(id);
    await f.Hello();
    var (frames, _) = await f.Send(new { t = "attach", id, cols = 80, rows = 24 });
    Assert.Equal(["attached", "output", "status"], frames.Select(m => m.GetProperty("t").GetString()));
    Assert.True(frames[1].GetProperty("replay").GetBoolean());
    Assert.Equal("PS C:\\Work\\Sample> ", frames[1].GetProperty("data").GetString());
    Assert.Equal("idle", frames[2].GetProperty("status").GetString());
    var (typed, close) = await f.Send(new { t = "input", id, data = "dir\r" });
    Assert.False(close); Assert.Empty(typed);
    Assert.Equal(id + ":dir\r", Assert.Single(f.Host.Written));
    var (created, _) = await f.Send(new { t = "create", cwd = "C:\\Work\\Sample", provider = "shell" });
    Assert.Equal("created", Assert.Single(created).GetProperty("t").GetString());
    var (outside, _) = await f.Send(new { t = "create", cwd = "C:\\Windows", provider = "shell" });
    Assert.Equal("unauthorized", Assert.Single(outside).GetProperty("code").GetString());
    var (closed, _) = await f.Send(new { t = "close", id });
    Assert.Equal("closed", Assert.Single(closed).GetProperty("t").GetString()); Assert.Equal(id, Assert.Single(f.Host.Closed));
  }

  [Fact]
  public async Task ActivityAnswersAtOnceInTheMacsShape()
  {
    using var f = new Fixture(PhoneAccess.Look);
    await f.Hello();
    var (frames, _) = await f.Send(new { t = "activity.watch", top = false });
    var sample = Assert.Single(frames);
    Assert.Equal("activity.sample", sample.GetProperty("t").GetString());
    Assert.Equal(12.5, sample.GetProperty("cpu").GetProperty("total").GetDouble());
    Assert.Equal(16L << 30, sample.GetProperty("memory").GetProperty("total").GetInt64());
    await f.Send(new { t = "activity.unwatch" });
  }

  [Fact]
  public async Task ThisPcIsListedWatchNeedsWorkAndControlNeedsFull()
  {
    using (var look = new Fixture(PhoneAccess.Look))
    {
      await look.Hello();
      var (rows, _) = await look.Send(new { t = "sims.list", rid = "r1" });
      var row = Assert.Single(Assert.Single(rows).GetProperty("devices").EnumerateArray().ToArray());
      Assert.Equal("mac:1", row.GetProperty("id").GetString()); Assert.Equal("mac", row.GetProperty("platform").GetString());
      Assert.Equal("ready", row.GetProperty("state").GetString());
      Assert.Equal("Ready · 1920 × 1080", row.GetProperty("runtime").GetString());
      var (refused, close) = await look.Send(new { t = "sims.watch", id = "mac:1", maxWidth = 1280, fps = 15, video = new[] { "h264" } });
      Assert.False(close); Assert.Equal("unauthorized", Assert.Single(refused).GetProperty("code").GetString());
    }
    using var work = new Fixture(PhoneAccess.Work);
    await work.Hello();
    var (opening, _) = await work.Send(new { t = "sims.watch", id = "mac:1", maxWidth = 1280, fps = 15, cursor = true, video = new[] { "h264" } });
    Assert.Equal("opening", Assert.Single(opening).GetProperty("state").GetString());
    var (input, _) = await work.Send(new { t = "sims.input", rid = "i1", id = "mac:1", @do = "click", button = "left" });
    Assert.Equal("unauthorized", Assert.Single(input).GetProperty("code").GetString());
    Assert.Empty(work.Screen.Posted);
    await work.Send(new { t = "sims.unwatch", id = "mac:1" });
  }

  [Fact]
  public async Task ADisconnectedSessionIsSaidOnTheRowBeforeATap()
  {
    using var f = new Fixture(PhoneAccess.Full);
    f.Screen.Block = "Nobody is connected to this PC's screen.";
    await f.Hello();
    var (rows, _) = await f.Send(new { t = "sims.list", rid = "r1" });
    var row = Assert.Single(Assert.Single(rows).GetProperty("devices").EnumerateArray().ToArray());
    Assert.True(row.GetProperty("canWatch").GetBoolean());
    Assert.Equal("Not available", row.GetProperty("runtime").GetString());
    Assert.Equal("Nobody is connected to this PC's screen.", row.GetProperty("note").GetString());
  }

  [Fact]
  public async Task FullControlDrivesThePointerAndAScreenIsVideoOnTheLinkOnly()
  {
    using var f = new Fixture(PhoneAccess.Full);
    await f.Hello();
    // §11.7: no pictures any more; a watch without H.264 is refused with its rid.
    var (pictures, _) = await f.Send(new { t = "sims.watch", rid = "w0", id = "mac:1", maxWidth = 1280, fps = 15 });
    Assert.Equal("Screens need the direct link to your PC.", Assert.Single(pictures).GetProperty("message").GetString());
    await f.Send(new { t = "sims.watch", id = "mac:1", maxWidth = 1280, fps = 15, video = new[] { "h264" } });
    var (none, _) = await f.Send(new { t = "sims.input", id = "mac:1", @do = "pointer", dx = 0.01, dy = -0.02, n = 3 });
    Assert.Empty(none);
    for (var i = 0; i < 100 && f.Screen.Posted.Count == 0; i++) await Task.Delay(20);
    var move = Assert.IsType<ScreenInput.Pointer>(Assert.Single(f.Screen.Posted));
    Assert.Equal(0.01, move.Dx, 5); Assert.Equal(-0.02, move.Dy, 5);
    await f.Send(new { t = "sims.unwatch", id = "mac:1" });
    var (gone, _) = await f.Send(new { t = "sims.annotate", rid = "a1", id = "mac:1", shot = "missing", note = "", to = "hoot", marks = Array.Empty<object>() });
    Assert.Equal("unavailable", Assert.Single(gone).GetProperty("code").GetString());
  }

  [Fact]
  public async Task AStillIsKeptForAnnotateAndItsMarksAreDrawn()
  {
    using var f = new Fixture(PhoneAccess.Full);
    await f.Hello();
    var (shot, _) = await f.Send(new { t = "sims.shot", rid = "s1", id = "mac:1", inspect = true });
    Assert.Equal(["sims.shot", "sims.elements"], shot.Select(m => m.GetProperty("t").GetString()));
    var token = shot[0].GetProperty("shot").GetString();
    var (sent, _) = await f.Send(new { t = "sims.annotate", rid = "a1", id = "mac:1", shot = token, note = "This button", to = "hoot", marks = new[] { new { c = 0, p = new[] { 0.1, 0.1, 0.9, 0.9 } } } });
    Assert.True(Assert.Single(sent).GetProperty("ok").GetBoolean());
    var pixels = new byte[16 * 9 * 4];
    PhoneScreens.Draw(pixels, 16, 9, JsonSerializer.SerializeToElement(new { c = 0, p = new[] { 0.0, 0.5, 1.0, 0.5 } }));
    Assert.Equal(255, pixels[(4 * 16 + 8) * 4 + 2]);
  }

  [Fact]
  public void AChatIsSentAsTheHootEventStreamThePhonesRead()
  {
    var chat = Chat("33333333-3333-3333-3333-333333333333", false, new ChatEvent(1, "user", "u1", "Hello"), new ChatEvent(2, "textDelta", "a1", "Hi "), new ChatEvent(3, "textDelta", "a1", "there"));
    var page = Parse(PhoneSessionRows.ChatEvents(chat));
    Assert.Equal("chats.events", page.GetProperty("t").GetString());
    Assert.True(page.GetProperty("reset").GetBoolean());
    var events = page.GetProperty("events").EnumerateArray().ToArray();
    Assert.Equal(["user", "message", "completed"], events.Select(e => e.GetProperty("kind").GetString()));
    Assert.Equal("Hi there", events[1].GetProperty("value").GetProperty("text").GetString());
    Assert.All(events, e => { Assert.Equal("claude", e.GetProperty("provider").GetString()); Assert.Equal("", e.GetProperty("turnId").GetString()); Assert.Equal(1, e.GetProperty("version").GetInt32()); });
    var sequences = events.Select(e => e.GetProperty("sequence").GetInt64()).ToArray();
    Assert.Equal(sequences.Distinct().Count(), sequences.Length); Assert.All(sequences, s => Assert.True(s > 0));
    var next = Parse(PhoneSessionRows.ChatEvents(chat with { Events = [.. chat.Events, new ChatEvent(4, "user", "u2", "Again")], Busy = true }));
    var newest = next.GetProperty("events").EnumerateArray().Last();
    Assert.Equal("user", newest.GetProperty("kind").GetString());
    Assert.True(newest.GetProperty("sequence").GetInt64() > sequences.Max());
  }

  [Fact]
  public void FullControlGrantFollowsNewSessionsAndTickedProjectsShareTheirFolders()
  {
    var grants = new PhoneSessionGrants(new Store<SessionGrantState>(new([])));
    var device = new ApprovedDevice("phone", "Synthetic iPhone", "ios", PhoneAccess.Full);
    var anywhere = Session(Guid.NewGuid().ToString(), "claude", SessionState.Running, "D:\\Other") with { };
    Assert.False(grants.Allows(device, anywhere));
    grants.Set(new("phone", true, [], [], [], Everything: true));
    Assert.True(grants.Allows(device, anywhere));
    grants.Set(new("phone", true, [], ["C:\\Work\\Sample"], [], AnyAccount: true));
    var withAccount = new SessionRecord(new(Guid.NewGuid().ToString(), "claude", "C:\\Work\\Sample\\api", "Claude Code", AccountId: "acct"), "k", SessionState.Running);
    Assert.True(grants.Allows(device, withAccount));
    Assert.False(grants.Allows(device, anywhere));
    Assert.True(grants.MayStartIn(device, "C:\\Work\\Sample\\api"));
    Assert.False(grants.MayStartIn(device, "C:\\Windows"));
  }
}
