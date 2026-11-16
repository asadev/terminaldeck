using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Tests.Cloud;

/// The contract's service for sessions and chats, kept small (the Mac's CloudChatsTests.FakeService): one machine, its
/// list, each stream's bytes, tail parts and pieces.
internal sealed class CloudChatsFakeService
{
  public sealed class Held { public int Gen = 1; public List<byte> Bytes = []; public int Pieced; public List<int> Pieces = []; public List<int> Tail = []; }
  private readonly object gate = new();
  public readonly List<(string Method, string Path, JsonObject Body)> Calls = [];
  public JsonArray List = [];
  public readonly List<JsonArray> Lists = [];
  public readonly Dictionary<string, Held> Streams = [];
  public readonly Dictionary<string, byte[]?> Snaps = [];
  public readonly Dictionary<string, string> Binned = [];
  public bool RoutesMissing, LoseNextTick;
  public string[] Paths() { lock (gate) return Calls.Select(c => c.Method + " " + c.Path).ToArray(); }
  public Held? HeldOf(string session, string stream) { lock (gate) return Streams.GetValueOrDefault(session + "|" + stream); }
  public byte[] BytesOf(string session, string stream) => HeldOf(session, stream)?.Bytes.ToArray() ?? [];
  public CloudChatsSend Send => (method, path, body) => Task.FromResult(Answer(method, path, body));
  private static CloudChatsAnswer Json(int status, object value) => new(status, JsonSerializer.SerializeToUtf8Bytes(value));
  private static CloudChatsAnswer Refuse(int status, string code) => Json(status, new { error = new { code, message = code } });
  private static byte[]? Raw(JsonObject part)
  {
    if (part["gz"]?.GetValue<string>() is not { } gz || CloudChats.Gunzip(Convert.FromBase64String(gz)) is not { } bytes) return null;
    return bytes.Length == part["rawLen"]!.GetValue<int>() && CloudChats.Hex(bytes) == part["sha256"]!.GetValue<string>() ? bytes : null;
  }

  private CloudChatsAnswer Answer(string method, string path, byte[] body)
  {
    lock (gate)
    {
      var o = body.Length == 0 ? new JsonObject() : JsonNode.Parse(body)!.AsObject();
      Calls.Add((method, path, o));
      if (RoutesMissing) return Refuse(404, "not_found");
      if (method == "GET" && path.StartsWith("/chats/head", StringComparison.Ordinal))
      {
        var sessions = new Dictionary<string, Dictionary<string, object>>();
        foreach (var (key, held) in Streams)
        {
          var parts = key.Split('|', 2);
          if (!sessions.TryGetValue(parts[0], out var streams)) sessions[parts[0]] = streams = [];
          streams[parts[1]] = new { gen = held.Gen, length = held.Bytes.Count, pieced = held.Pieced, pieces = held.Pieces.Count, tailParts = held.Tail };
        }
        return Json(200, new { sessions = sessions.Select(s => new { session = s.Key, @ref = s.Key, binned = false, closed = false, streams = s.Value }) });
      }
      if (path == "/chats/tick")
      {
        if (LoseNextTick) { LoseNextTick = false; throw new HttpRequestException("lost"); }
        if (o["sessions"] is JsonArray rows) { List = (JsonArray)rows.DeepClone(); Lists.Add((JsonArray)rows.DeepClone()); }
        var answers = new List<object>();
        foreach (var part in (o["parts"] as JsonArray ?? []).OfType<JsonObject>())
        {
          string session = part["session"]!.GetValue<string>(), stream = part["stream"]!.GetValue<string>();
          int gen = part["gen"]!.GetValue<int>(), from = part["from"]!.GetValue<int>();
          var key = session + "|" + stream;
          var held = Streams.GetValueOrDefault(key) ?? new Held { Gen = gen };
          if (gen > held.Gen)
          {
            if (from != 0) { answers.Add(new { session, stream, ok = false, gen = held.Gen, have = held.Bytes.Count, code = "chat_offset" }); continue; }
            held = new Held { Gen = gen };
          }
          if (gen != held.Gen) { answers.Add(new { session, stream, ok = false, gen = held.Gen, have = held.Bytes.Count, code = "old_gen" }); continue; }
          if (from != held.Bytes.Count) { answers.Add(new { session, stream, ok = false, gen = held.Gen, have = held.Bytes.Count, code = "chat_offset" }); continue; }
          if (Raw(part) is not { } bytes) { answers.Add(new { session, stream, ok = false, gen = held.Gen, have = held.Bytes.Count, code = "bad_bytes" }); continue; }
          if (stream == "read") Assert.Equal((byte)'\n', bytes[^1]); // whole lines only
          held.Bytes.AddRange(bytes); held.Tail.Add(bytes.Length);
          Streams[key] = held;
          answers.Add(new { session, stream, ok = true, gen = held.Gen, have = held.Bytes.Count });
        }
        return Json(200, new { tickId = o["tickId"]?.GetValue<string>() ?? "", parts = answers });
      }
      if (path == "/chats/piece")
      {
        string session = o["session"]!.GetValue<string>(), stream = o["stream"]!.GetValue<string>();
        var key = session + "|" + stream;
        var held = Streams.GetValueOrDefault(key) ?? new Held { Gen = o["gen"]!.GetValue<int>() };
        int index = o["index"]!.GetValue<int>(), rawFrom = o["rawFrom"]!.GetValue<int>(), rawLen = o["rawLen"]!.GetValue<int>();
        if (index != held.Pieces.Count || rawFrom != held.Pieced || Raw(o) is not { } bytes)
          return Json(409, new { ok = false, code = "piece_boundary", gen = held.Gen, have = held.Bytes.Count, pieced = held.Pieced, pieces = held.Pieces.Count });
        if (held.Tail.Count == 0)
        {
          if (rawFrom != held.Bytes.Count) return Refuse(409, "chat_offset");
          held.Bytes.AddRange(bytes);
        }
        else
        {
          // Must end where one of the tail parts ends; the covered parts are dropped.
          int sum = 0, covered = 0;
          foreach (var part in held.Tail) { sum += part; covered++; if (sum >= rawLen) break; }
          if (sum != rawLen || !held.Bytes.Skip(rawFrom).Take(rawLen).SequenceEqual(bytes)) return Refuse(409, "piece_mismatch");
          held.Tail.RemoveRange(0, covered);
        }
        held.Pieced += rawLen; held.Pieces.Add(rawLen);
        Streams[key] = held;
        return Json(200, new { ok = true, gen = held.Gen, index, pieced = held.Pieced, have = held.Bytes.Count });
      }
      if (path == "/chats/bin")
      {
        var reference = o["ref"]?.GetValue<string>() ?? o["session"]?.GetValue<string>() ?? "";
        var action = o["action"]?.GetValue<string>() ?? "";
        if (action != "bin" && !Binned.ContainsKey(reference)) return Refuse(404, "not_binned");
        if (action == "restore") Binned.Remove(reference); else Binned[reference] = action;
        return Json(200, new { @ref = reference, binnedAt = 1, removeAt = 2 });
      }
      if (path == "/chats/snap")
      {
        Snaps[o["session"]!.GetValue<string>()] = Raw(o);
        return Json(200, new { ok = true });
      }
      return Refuse(404, "not_found");
    }
  }
}

/// Sessions and chats in the Cloud, the PC's uploader (the Mac's CloudChatsTests, case for case): only what was added goes
/// up; nothing while idle; a crash resumes from what the service holds; a big history goes up in 4 MiB pieces, readable
/// copy first; a service without the routes is silent.
public sealed class CloudChatsTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-cloud-chats-" + Guid.NewGuid().ToString("N"));
  public CloudChatsTests() => Directory.CreateDirectory(root);
  public void Dispose() { try { Directory.Delete(root, true); } catch (IOException) { } }
  private sealed class Clock { public long Value = 1_700_000_000_000; public Func<long> Now => () => Value; }

  private static string User(int n) => $$"""{"type":"user","message":{"role":"user","content":"question {{n}}"},"uuid":"u-{{n}}","timestamp":"2026-11-15T01:00:00.000Z","sessionId":"c1","cwd":"/tmp/p"}""" + "\n";
  private static string Assistant(int n) => $$"""{"type":"assistant","message":{"id":"m-{{n}}","model":"claude-opus","content":[{"type":"text","text":"answer {{n}}"}]},"uuid":"a-{{n}}","timestamp":"2026-11-15T01:00:01.000Z","sessionId":"c1"}""" + "\n";
  /// A tool result about 1 KB long: history bytes with nothing readable in them.
  private static string ToolTraffic(int n) => $$"""{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-{{n}}","content":"{{new string('x', 960)}}"}]},"uuid":"t-{{n}}"}""" + "\n";
  private static CloudChats.Listed Listed(string file, string id = "tab-1") => new(
    new CloudChats.Row(id, "CRM", 1_700_000_000_000, new("crm", "CRM"), "/tmp/p", "claude", Kind: "terminal", Status: "idle", StartedAt: 1_699_000_000_000, ConversationId: "c1"),
    new CloudChats.Source(file, Readable: CloudChatsReadable.Format.Claude, Provider: "claude"));
  private string History(string text) { var file = Path.Combine(root, "c1.jsonl"); File.WriteAllText(file, text); return file; }
  private string State => Path.Combine(root, "state");

  [Fact] public async Task OnlyWhatWasAddedIsSentAndTheListOnce()
  {
    var service = new CloudChatsFakeService(); var history = History(User(1) + Assistant(1));
    var uploader = new CloudChatsUploader(service.Send, State);
    Assert.Equal(CloudChatsUploader.Outcome.Sent(2, true), await uploader.RoundAsync([Listed(history)]));
    Assert.Single(service.List);
    Assert.Equal("tab-1", service.List[0]!["sessionId"]!.GetValue<string>()); Assert.Equal("idle", service.List[0]!["status"]!.GetValue<string>());
    var before = File.ReadAllBytes(history);
    Assert.Equal(before, service.BytesOf("tab-1", "raw"));
    File.AppendAllText(history, User(2));
    service.Calls.Clear();
    Assert.Equal(CloudChatsUploader.Outcome.Sent(2, false), await uploader.RoundAsync([Listed(history)]));
    var tick = service.Calls.First(c => c.Path == "/chats/tick");
    var raw = tick.Body["parts"]!.AsArray().OfType<JsonObject>().First(p => p["stream"]!.GetValue<string>() == "raw");
    Assert.Equal(before.Length, raw["from"]!.GetValue<int>());
    Assert.Equal(Encoding.UTF8.GetByteCount(User(2)), raw["rawLen"]!.GetValue<int>());
    Assert.Null(tick.Body["sessions"]);
    Assert.Equal(File.ReadAllBytes(history), service.BytesOf("tab-1", "raw"));
    // The readable copy: three messages, numbered on.
    var lines = CloudChatsReadableTests.Events(service.BytesOf("tab-1", "read"));
    Assert.Equal(3, lines.Length);
    Assert.Equal(3, lines[2].GetProperty("sequence").GetInt64()); Assert.Equal("user", lines[2].GetProperty("kind").GetString());
    Assert.Equal("question 2", lines[2].GetProperty("value").GetProperty("text").GetString());
  }

  [Fact] public async Task NothingIsSentWhileNothingGrew()
  {
    var service = new CloudChatsFakeService(); var history = History(User(1));
    var uploader = new CloudChatsUploader(service.Send, State);
    await uploader.RoundAsync([Listed(history)]);
    var count = service.Calls.Count;
    Assert.Equal(CloudChatsUploader.Outcome.Idle, await uploader.RoundAsync([Listed(history)]));
    Assert.Equal(CloudChatsUploader.Outcome.Idle, await uploader.RoundAsync([Listed(history)]));
    Assert.Equal(count, service.Calls.Count);
  }

  [Fact] public async Task ACrashAfterTheServiceTookATickResumesFromWhatItHoldsALostAnswerSendsTheSameTickAgain()
  {
    var service = new CloudChatsFakeService(); var history = History(User(1));
    var first = new CloudChatsUploader(service.Send, State);
    await first.RoundAsync([Listed(history)]);
    var saved = File.ReadAllBytes(Path.Combine(State, "state.json"));
    File.AppendAllText(history, Assistant(1));
    await first.RoundAsync([Listed(history)]);
    // The PC stopped before it kept the second answer: its record still says the first length.
    File.WriteAllBytes(Path.Combine(State, "state.json"), saved);
    File.AppendAllText(history, User(2));
    service.Calls.Clear();
    var second = new CloudChatsUploader(service.Send, State);
    await second.RoundAsync([Listed(history)]);
    var rawParts = service.Calls.Where(c => c.Path == "/chats/tick").SelectMany(c => c.Body["parts"]!.AsArray().OfType<JsonObject>())
      .Where(p => p["stream"]!.GetValue<string>() == "raw").Select(p => p["from"]!.GetValue<int>()).ToArray();
    Assert.Equal([Encoding.UTF8.GetByteCount(User(1) + Assistant(1))], rawParts);
    Assert.Equal(File.ReadAllBytes(history), service.BytesOf("tab-1", "raw"));
    Assert.Equal(1, service.HeldOf("tab-1", "raw")!.Gen);

    // A tick whose answer is lost goes again with the same id and bytes.
    File.AppendAllText(history, Assistant(2));
    service.LoseNextTick = true;
    Assert.Equal(CloudChatsUploader.Outcome.Later, await second.RoundAsync([Listed(history)]));
    var lostId = service.Calls[^1].Body["tickId"]!.GetValue<string>();
    await second.RoundAsync([Listed(history)]);
    Assert.Equal(lostId, service.Calls.Last(c => c.Path == "/chats/tick").Body["tickId"]!.GetValue<string>());
    Assert.Equal(File.ReadAllBytes(history), service.BytesOf("tab-1", "raw"));
  }

  [Fact] public async Task ABigHistoryGoesUpIn4MiBPiecesReadableCopyFirstNeverAsOneTick()
  {
    var service = new CloudChatsFakeService();
    var text = new StringBuilder(User(1) + Assistant(1));
    for (var n = 0; n < 9_800; n++) text.Append(ToolTraffic(n));
    text.Append(User(2) + Assistant(2));
    var history = History(text.ToString());
    Assert.True(new FileInfo(history).Length > 9 * 1_048_576);
    var uploader = new CloudChatsUploader(service.Send, State);
    // The live tick carries the list only: the history is far too big for it.
    Assert.Equal(CloudChatsUploader.Outcome.Sent(0, true), await uploader.RoundAsync([Listed(history)]));
    var steps = 0;
    while (await uploader.CatchUpStepAsync([Listed(history)])) { steps++; Assert.True(steps < 20); }
    var pieces = service.Calls.Where(c => c.Path == "/chats/piece").ToArray();
    Assert.Equal("read", pieces[0].Body["stream"]!.GetValue<string>());
    Assert.Equal([4 * 1_048_576, 4 * 1_048_576], pieces.Where(p => p.Body["stream"]!.GetValue<string>() == "raw").Select(p => p.Body["rawLen"]!.GetValue<int>()));
    // The rest (under 4 MiB) comes with the next tick.
    await uploader.RoundAsync([Listed(history)]);
    Assert.Equal(File.ReadAllBytes(history), service.BytesOf("tab-1", "raw"));
    Assert.Equal(4, CloudChatsReadableTests.Events(service.BytesOf("tab-1", "read")).Length);
    // No call was ever bigger than the contract's 8 MiB.
    Assert.All(service.Calls, c => Assert.True(Encoding.UTF8.GetByteCount(c.Body.ToJsonString()) <= 8 * 1_048_576));
  }

  [Fact] public async Task AServiceWithoutTheRoutesIsSilentNothingMoreIsSentUntilTheNextLaunch()
  {
    var service = new CloudChatsFakeService { RoutesMissing = true }; var history = History(User(1));
    var uploader = new CloudChatsUploader(service.Send, State);
    Assert.Equal(CloudChatsUploader.Outcome.Missing, await uploader.RoundAsync([Listed(history)]));
    Assert.Equal(CloudChatsUploader.Outcome.Missing, await uploader.RoundAsync([Listed(history)]));
    Assert.False(await uploader.CatchUpStepAsync([Listed(history)]));
    Assert.Equal(["GET /chats/head"], service.Paths());
    Assert.False(uploader.StatusWire()["live"]!.GetValue<bool>());
  }

  [Fact] public async Task AnAppChatsSavedFileGoesUpOnceItHasBeenQuiet2MinutesWithoutItsRuntimeFields()
  {
    var service = new CloudChatsFakeService(); var clock = new Clock();
    var id = Guid.NewGuid().ToString();
    var chat = Path.Combine(root, "chat.json");
    File.WriteAllBytes(chat, JsonSerializer.SerializeToUtf8Bytes(CloudChatsReadableTests.Chat(id)));
    var item = new CloudChats.Listed(new CloudChats.Row("tab-chat", "Chat", 1, Kind: "chat"),
      new CloudChats.Source(Readable: CloudChatsReadable.Format.AppChat, Snap: chat, Provider: "claude"));
    var uploader = new CloudChatsUploader(service.Send, State, clock.Now);
    await uploader.RoundAsync([item]);
    Assert.False(service.Snaps.ContainsKey("tab-chat"));
    clock.Value += CloudChats.SnapQuietMs;
    await uploader.RoundAsync([item]);
    var sent = Encoding.UTF8.GetString(service.Snaps["tab-chat"]!);
    Assert.Contains(id, sent);
    Assert.DoesNotContain("Busy", sent, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("ActiveClientId", sent, StringComparison.OrdinalIgnoreCase);
  }

  [Fact] public void TheListRowTheSidePanelsNameTheContractsKeysOnlyStatusInItsWords()
  {
    var row = new CloudChats.Row("tab-1", "CRM", 5, Ai: "codex", Kind: "agent", Status: CloudChats.Status("input"));
    var keys = JsonNode.Parse(JsonSerializer.SerializeToUtf8Bytes(row, CloudChats.Wire))!.AsObject().Select(p => p.Key).ToArray();
    Assert.Subset(new HashSet<string> { "sessionId", "name", "lastUsedAt", "project", "cwd", "ai", "login", "kind", "status", "startedAt", "conversationId", "codeAt", "v" }, keys.ToHashSet());
    Assert.Equal("needsYou", JsonNode.Parse(JsonSerializer.SerializeToUtf8Bytes(row, CloudChats.Wire))!["status"]!.GetValue<string>());
    Assert.Equal("running", CloudChats.Status("working")); Assert.Equal("ended", CloudChats.Status("exited")); Assert.Equal("idle", CloudChats.Status("waiting"));
    // The PC's own session id is its Cloud id (it survives a restart), so the live row's `tab` is that same id.
    var session = new CloudChatsSession("6f9619ff-8b86-d011-b42d-00cf4fc964ff", "claude", @"C:\work\crm", "Claude", "exited", 5, 4, "c1");
    var made = CloudChats.RowFor(session, "Invoices", [new TerminalDeck.Core.Projects.Project("crm", "CRM", [@"C:\work\crm"])]);
    Assert.Equal(session.Id, made.SessionId); Assert.Equal("Invoices", made.Name); Assert.Equal("ended", made.Status); Assert.Equal("crm", made.Project!.CloudRef);
  }

  [Fact] public void TheLiveListsHeaderNamesThisPcByTheCloudsMachineWhileSignedIn()
  {
    var reference = CloudChats.MachineRef("sub-1", "m-1");
    Assert.Equal(32, reference.Length); Assert.True(reference.All(Uri.IsHexDigit));
    Assert.NotEqual(reference, CloudChats.MachineRef("sub-2", "m-1"));
    CloudChatsMachine.Shared.Set(null);
    Assert.Null(CloudChatsMachine.Shared.Current);
    CloudChatsMachine.Shared.Set(reference);
    try { Assert.Equal(reference, CloudChatsMachine.Shared.Current); } finally { CloudChatsMachine.Shared.Set(null); }
  }

  [Fact] public async Task AnOldHistoryInTerminalDecksOwnLoginFolderBecomesAnEarlierChatOfItsProjectAHelperAgentsDoesNot()
  {
    var service = new CloudChatsFakeService(); var clock = new Clock();
    var home = Path.Combine(root, "accounts", "work", "claude");
    var folder = Path.Combine(home, "projects", "-Users-sam-Code-crm");
    Directory.CreateDirectory(Path.Combine(folder, "0b1c", "subagents"));
    var history = Path.Combine(folder, "0b1c.jsonl");
    var lines = """{"type":"user","message":{"role":"user","content":"Fix the invoice totals before Friday please"},"uuid":"u1","timestamp":"2026-10-02T09:00:00.000Z","sessionId":"0b1c","cwd":"/Users/sam/Code/crm"}""" + "\n"
      + """{"type":"assistant","message":{"id":"m1","model":"claude-opus","content":[{"type":"text","text":"Done."}]},"uuid":"a1","timestamp":"2026-10-02T09:05:00.000Z","sessionId":"0b1c","cwd":"/Users/sam/Code/crm"}""" + "\n";
    File.WriteAllText(history, lines);
    // Helper agents' histories: one level deeper (today's Claude) and an `agent-` file of side chains (older Claude).
    File.WriteAllText(Path.Combine(folder, "0b1c", "subagents", "agent-a1.jsonl"), lines);
    File.WriteAllText(Path.Combine(folder, "agent-old.jsonl"), lines.Replace("\"type\":\"user\",", "\"type\":\"user\",\"isSidechain\":true,"));
    var projects = Path.Combine(home, "projects");
    Assert.True(CloudChatsArchive.IsClaudeHistory(history, projects));
    Assert.False(CloudChatsArchive.IsClaudeHistory(Path.Combine(folder, "0b1c", "subagents", "agent-a1.jsonl"), projects));
    Assert.False(CloudChatsArchive.IsClaudeHistory(Path.Combine(folder, "agent-old.jsonl"), projects));

    var found = CloudChatsArchive.Scan([home], null, new HashSet<string>());
    Assert.Equal([Path.GetFullPath(history)], found.Select(f => Path.GetFullPath(f.Path)));
    var one = found[0];
    Assert.Equal("Fix the invoice totals before Friday please", one.Name);
    Assert.Equal("/Users/sam/Code/crm", one.Cwd);
    Assert.Equal(1_790_931_900_000, one.LastUsedAt); // the history's own last turn, 2 Oct 09:05 UTC
    // A name the app still keeps for that conversation wins over the first words.
    Assert.Equal("Invoices", CloudChatsArchive.Scan([home], null, new HashSet<string>(), new Dictionary<string, string> { ["0b1c"] = "Invoices" })[0].Name);

    var uploader = new CloudChatsUploader(service.Send, State, clock.Now);
    await uploader.AddArchiveAsync(found, "pc-1", [new TerminalDeck.Core.Projects.Project("crm", "CRM", ["/Users/sam/Code/crm"])]);
    // Introduced once with its project, name and dates, then taken off the list: a closed session's chat.
    await uploader.RoundAsync([]);
    var introduced = service.Lists[^1][0]!.AsObject();
    Assert.Equal("crm", introduced["project"]!["cloudRef"]!.GetValue<string>());
    Assert.Equal("ended", introduced["status"]!.GetValue<string>()); Assert.Equal(one.Name, introduced["name"]!.GetValue<string>());
    var id = introduced["sessionId"]!.GetValue<string>();
    clock.Value += CloudChats.ListEveryMs;
    await uploader.RoundAsync([]);
    Assert.Empty(service.Lists[^1]);
    // Then copied in the background: readable copy first, then the history to the byte.
    while (await uploader.CatchUpStepAsync([])) { }
    Assert.Equal(["read", "raw"], service.Calls.Where(c => c.Path == "/chats/piece").Select(c => c.Body["stream"]!.GetValue<string>()));
    Assert.Equal(File.ReadAllBytes(history), service.BytesOf(id, "raw"));
    Assert.Equal(CloudChatsUploader.Stage.Done, uploader.Saved.Archive[id].Stage);
    // Found again later: already known, nothing new.
    Assert.Empty(CloudChatsArchive.Scan([home], null, await uploader.ArchiveSkipAsync()));
  }

  [Fact] public async Task ADeletedChatGoesToTheBinEverywhereOnlyStopsBeingCopiedAndComesBackWithPutBackAll()
  {
    var service = new CloudChatsFakeService(); var history = History(User(1));
    var uploader = new CloudChatsUploader(service.Send, State);
    await uploader.RoundAsync([Listed(history)]);
    var owner = new CloudChatsDeleteOwner((reference, session, action) => uploader.BinAsync(session, reference, action), Path.Combine(root, "bin.json"));
    // The page's row: one row, one delete item.
    var row = new CloudSessionsRead.Row("ref-1", Name: "CRM", LastUsedAt: 5, Project: new("crm", "CRM"), Ai: "claude", MachineName: "Mac mini", MachineOn: true, Mine: true);
    var entry = Assert.Single(CloudChatsContents.Items([row]));
    Assert.Equal("CRM", entry.Place);
    Assert.Equal(new CloudChatsDeleteOwner.Item("ref-1", "chat", "CRM", null), entry.DeleteItem);
    var target = new CloudChatsDeleteOwner.Item("ref-1", CloudChatsDeleteOwner.Kind, "CRM", "tab-1");

    var group = await owner.DeleteItemsAsync([target], "person", "Office PC", null, null, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "g1");
    Assert.Equal([target], group.Items);
    Assert.Equal("bin", service.Binned["ref-1"]);
    Assert.Equal(["g1"], (await owner.BinGroupsAsync()).Select(g => g.Id));
    // Binned: this PC copies nothing more of it, even when it grows.
    File.AppendAllText(history, Assistant(1));
    service.Calls.Clear();
    await uploader.RoundAsync([Listed(history)]);
    Assert.DoesNotContain(service.Calls, c => c.Body["parts"] is JsonArray { Count: > 0 });
    // Put back all.
    Assert.Equal([target], await owner.PutBackGroupAsync("g1"));
    Assert.False(service.Binned.ContainsKey("ref-1"));
    Assert.Empty(await owner.BinGroupsAsync());
    Assert.False(uploader.Saved.Sessions["tab-1"].Binned);
  }

  [Fact] public void TheLocatorFindsAClaudeHistoryByItsFolderAndItsToolResults()
  {
    var home = Path.Combine(root, "accounts", "a", "claude");
    var cwd = @"C:\work\crm";
    Assert.Equal("C--work-crm", CloudChatsLocator.ClaudeFolder(cwd));
    var folder = Path.Combine(home, "projects", "C--work-crm");
    Directory.CreateDirectory(Path.Combine(folder, "c1", "tool-results"));
    File.WriteAllText(Path.Combine(folder, "c1.jsonl"), User(1));
    File.WriteAllText(Path.Combine(folder, "c1", "tool-results", "t1.txt"), "out");
    var locator = new CloudChatsLocator([home], [], [], Path.Combine(root, "chats"), Path.Combine(root, "state", "hoot.json"));
    var source = locator.SourceFor(new CloudChatsSession("6f9619ff-8b86-d011-b42d-00cf4fc964ff", "claude", cwd, "Claude", "idle", 1, 1, "c1"));
    Assert.Equal(Path.Combine(folder, "c1.jsonl"), source.Raw);
    Assert.Equal([Path.Combine(folder, "c1", "tool-results", "t1.txt")], source.ToolFiles);
    // A plain terminal has nothing to read.
    Assert.Equal(CloudChats.Source.None, locator.SourceFor(new CloudChatsSession("6f9619ff-8b86-d011-b42d-00cf4fc964fe", "shell", cwd, "Shell", "idle", 1, 1)));
  }
}
