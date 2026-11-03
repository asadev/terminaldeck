using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Sessions;

// 2 Nov, Umer's PC: the self-update restarted the app 5 s after a Claude terminal sent
// its next request (the busy check knew only chats), and every terminal Claude came
// back in a fresh conversation (no conversation id was ever saved for terminals).
public sealed class UpdateReadinessTests
{
  private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
  private static readonly Dictionary<string, ProviderHookEvent> NoHooks = [];
  private static readonly TimeSpan Away = TimeSpan.FromMinutes(11);
  private static SessionActivity Terminal(long? outputAge = null, long? run = null, long? inputAge = null, bool? busy = null) =>
    new("s1", "claude", "Claude Code (iPresent)", outputAge, run, inputAge, busy);

  [Fact]
  public void AnAiStreamingInATerminalHoldsTheRestart()
  {
    // Claude repaints ~10x a second through a whole turn, tools included.
    Assert.Equal("Claude Code (iPresent) is working", UpdateReadiness.WaitReason([Terminal(outputAge: 800, run: 12_000)], NoHooks, false, Away, Now));
    // Claude's own status file says busy (thinking, a request in flight).
    Assert.NotNull(UpdateReadiness.WaitReason([Terminal(outputAge: 50_000, run: 0, busy: true)], NoHooks, false, Away, Now));
  }

  [Fact]
  public void AQuietOrMerelyRedrawnTerminalDoesNotHoldIt()
  {
    Assert.Null(UpdateReadiness.WaitReason([Terminal(outputAge: 45_000, run: 30_000, busy: false)], NoHooks, false, Away, Now));
    // One redraw (the window came to the front) is not a turn.
    Assert.Null(UpdateReadiness.WaitReason([Terminal(outputAge: 300, run: 0)], NoHooks, false, Away, Now));
    Assert.Null(UpdateReadiness.WaitReason([Terminal()], NoHooks, false, Away, Now));
  }

  [Fact]
  public void SomeoneAtThePcOrTypingIntoASessionKeepsTheButton()
  {
    Assert.Equal("someone is using this PC", UpdateReadiness.WaitReason([], NoHooks, false, TimeSpan.FromMinutes(3), Now));
    // Typing from a phone reaches the keeper, not this PC's keyboard.
    Assert.Equal("someone is typing in Claude Code (iPresent)", UpdateReadiness.WaitReason([Terminal(inputAge: 120_000)], NoHooks, false, Away, Now));
    Assert.Null(UpdateReadiness.WaitReason([Terminal(inputAge: 11 * 60_000)], NoHooks, false, Away, Now));
    Assert.Equal("a chat is answering", UpdateReadiness.WaitReason([], NoHooks, true, Away, Now));
    Assert.Null(UpdateReadiness.WaitReason([], NoHooks, false, null, Now));
  }

  [Fact]
  public void AWorkingHookCountsOnlyWhileTheScreenStillMoves()
  {
    var hooks = new Dictionary<string, ProviderHookEvent> { ["s1"] = new("codex", "PreToolUse", "s1", null, null, Now.AddMinutes(-3)) };
    Assert.NotNull(UpdateReadiness.WaitReason([Terminal(outputAge: 60_000, run: 0)], hooks, false, Away, Now));
    // Esc ends a turn with no hook at all: a frozen screen means it is over.
    Assert.Null(UpdateReadiness.WaitReason([Terminal(outputAge: 5 * 60_000, run: 0)], hooks, false, Away, Now));
    hooks["s1"] = hooks["s1"] with { Event = "Stop" };
    Assert.Null(UpdateReadiness.WaitReason([Terminal(outputAge: 60_000, run: 0)], hooks, false, Away, Now));
  }
}

public sealed class TerminalConversationTests
{
  private sealed class Files : IConversationFiles
  {
    public Dictionary<int, LiveConversation> Programs { get; } = [];
    public Dictionary<string, string> Discovered { get; } = [];
    public HashSet<string> Saved { get; } = [];
    public Dictionary<string, string> NewestFor { get; } = [];
    public string? Newest(SessionRecord session) => NewestFor.GetValueOrDefault(session.Definition.Id);
    public IReadOnlySet<string>? LastClaimed { get; private set; }
    public string FindConversation(SessionRecord session) => throw new IOException("Not used.");
    public void Validate(SessionDefinition source, SessionDefinition destination) { }
    public void Copy(SessionDefinition source, SessionDefinition destination) { }
    public LiveConversation? Live(SessionDefinition definition, int processId, long startedAtMs) => Programs.GetValueOrDefault(processId);
    public string? Discover(SessionRecord session, IReadOnlySet<string> claimed)
    {
      LastClaimed = claimed;
      return Discovered.TryGetValue(session.Definition.Id, out var id) && !claimed.Contains(id) ? id : null;
    }
    public bool CanResume(SessionDefinition definition) => definition.Provider != "claude" || definition.ConversationId is { } id && Saved.Contains(id);
  }
  private sealed class Processes : ISessionProcessKeeper
  {
    public Dictionary<string, ProcessObservation> Observations { get; } = [];
    public List<string> Calls { get; } = [];
    public int NextPid = 4100;
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord s, CancellationToken ct) => ValueTask.FromResult(Observations.GetValueOrDefault(s.Definition.Id, new(ProcessPresence.Dead)));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord s, bool resume, CancellationToken ct)
    {
      Calls.Add((resume ? "resume:" : "start:") + s.Definition.Id + ":" + s.Definition.ConversationId);
      var live = new ProcessObservation(ProcessPresence.Live, s.CreationKey, ProcessId: NextPid++, ProcessStartedAt: 1);
      Observations[s.Definition.Id] = live; return ValueTask.FromResult(live);
    }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask QuitAsync(string lease, CancellationToken ct) { Calls.Add("quit:" + lease); return ValueTask.CompletedTask; }
  }
  private static SessionDefinition Definition(string provider, string? conversation = null, string? brief = null) =>
    new(Guid.NewGuid().ToString(), provider, "C:\\Users\\admin\\iPresent", "Claude Code (iPresent)", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), conversation, InitialPrompt: brief);

  [Fact]
  public async Task ANewClaudeTerminalIsGivenItsOwnConversationAndARetryStillMatches()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes, new Files());
    var asked = Definition("claude");
    var row = await keeper.CreateAsync(asked);
    Assert.True(Guid.TryParse(row.Definition.ConversationId, out _)); Assert.True(row.DeclaredConversation); Assert.False(row.Resume);
    Assert.Equal("start:" + asked.Id + ":" + row.Definition.ConversationId, Assert.Single(processes.Calls));
    Assert.Equal(row.CreationKey, (await keeper.CreateAsync(asked)).CreationKey);
    Assert.Single(processes.Calls);
    // Codex, shells and sign-ins are not named here.
    Assert.Null((await keeper.CreateAsync(Definition("codex"))).Definition.ConversationId);
    Assert.Null((await keeper.CreateAsync(Definition("claude") with { Purpose = "sign-in" })).Definition.ConversationId);
  }

  [Fact]
  public async Task AnUpdateResumesTheConversationClaudeIsInNowEvenAfterClear()
  {
    var store = new MemoryState<SessionLedger>(); var processes = new Processes(); var files = new Files();
    var keeper = new SessionKeeper(store, processes, files);
    var row = await keeper.CreateAsync(Definition("claude"));
    var pid = processes.Observations[row.Definition.Id].ProcessId!.Value;
    var cleared = Guid.NewGuid().ToString(); files.Programs[pid] = new(cleared, false); files.Saved.Add(cleared);

    Assert.Equal(1, await keeper.PrepareUpdateAsync());
    var saved = keeper.Get(row.Definition.Id);
    Assert.Equal(cleared, saved.Definition.ConversationId); Assert.True(saved.Resume);
    Assert.Contains("This session continues its conversation.", saved.ReplayPrefix);

    processes.Calls.Clear(); processes.Observations.Clear();
    await new SessionKeeper(store, processes, files).RecoverAsync();
    Assert.Equal("resume:" + row.Definition.Id + ":" + cleared, Assert.Single(processes.Calls));
  }

  [Fact]
  public async Task AClaudeConversationWithNothingSavedStartsAgainUnderItsOwnNameWithItsBrief()
  {
    var store = new MemoryState<SessionLedger>(); var processes = new Processes(); var files = new Files();
    var keeper = new SessionKeeper(store, processes, files);
    var row = await keeper.CreateAsync(Definition("claude", brief: "Read the plan"));
    await keeper.PrepareUpdateAsync();
    var saved = keeper.Get(row.Definition.Id);
    Assert.False(saved.Resume); Assert.Equal(row.Definition.ConversationId, saved.Definition.ConversationId); Assert.Equal("Read the plan", saved.Definition.InitialPrompt);
    processes.Calls.Clear(); processes.Observations.Clear();
    await new SessionKeeper(store, processes, files).RecoverAsync();
    Assert.Equal("start:" + row.Definition.Id + ":" + row.Definition.ConversationId, Assert.Single(processes.Calls));
  }

  [Fact]
  public async Task ACodexTerminalResumesTheOneConversationItsTranscriptsShowAndNeverRepeatsItsBrief()
  {
    var processes = new Processes(); var files = new Files(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes, files);
    var other = await keeper.CreateAsync(Definition("codex", "11111111-1111-1111-1111-111111111111"));
    var found = await keeper.CreateAsync(Definition("codex", brief: "Fix the build"));
    var second = await keeper.CreateAsync(Definition("codex", brief: "Write the notes"));
    files.Discovered[found.Definition.Id] = "22222222-2222-2222-2222-222222222222";
    // The same transcript can never be taken by a second terminal.
    files.Discovered[second.Definition.Id] = "22222222-2222-2222-2222-222222222222";
    await keeper.PrepareUpdateAsync();
    Assert.Contains("11111111-1111-1111-1111-111111111111", files.LastClaimed!);
    Assert.Equal("22222222-2222-2222-2222-222222222222", keeper.Get(found.Definition.Id).Definition.ConversationId);
    Assert.True(keeper.Get(found.Definition.Id).Resume); Assert.Equal("Fix the build", keeper.Get(found.Definition.Id).Definition.InitialPrompt);
    Assert.Equal("11111111-1111-1111-1111-111111111111", keeper.Get(other.Definition.Id).Definition.ConversationId);
    Assert.Null(keeper.Get(second.Definition.Id).Definition.ConversationId); Assert.False(keeper.Get(second.Definition.Id).Resume);
    Assert.Null(keeper.Get(second.Definition.Id).Definition.InitialPrompt);
  }

  [Fact]
  public async Task AFreshRestartWithoutAConversationDropsItsBrief()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes, new Files());
    var row = await keeper.CreateAsync(Definition("codex", brief: "Write the notes"));
    await keeper.PrepareUpdateAsync();
    var saved = keeper.Get(row.Definition.Id);
    Assert.False(saved.Resume); Assert.Null(saved.Definition.ConversationId); Assert.Null(saved.Definition.InitialPrompt);
    Assert.Contains("This terminal restarted in", saved.ReplayPrefix);
  }

  [Fact]
  public async Task AfterARebootAnAiTerminalWithoutASavedIdResumesTheOneItsTranscriptsShow()
  {
    var store = new MemoryState<SessionLedger>(); var processes = new Processes(); var files = new Files();
    var row = await new SessionKeeper(store, processes, files).CreateAsync(Definition("codex"));
    processes.Observations.Clear(); processes.Calls.Clear();
    files.Discovered[row.Definition.Id] = "33333333-3333-3333-3333-333333333333";
    await new SessionKeeper(store, processes, files).RecoverAsync();
    Assert.Equal("resume:" + row.Definition.Id + ":33333333-3333-3333-3333-333333333333", Assert.Single(processes.Calls));
  }

  [Fact]
  public async Task TheUpdateFromAnOlderKeeperStillResumesTheFoldersNewestConversationWhenNoOtherTerminalHoldsIt()
  {
    // What 0.20.3.1's keeper saved: an AI terminal reset for the update, with no conversation.
    SessionRecord HandedOver(string cwd) => new(new(Guid.NewGuid().ToString(), "claude", cwd, "Claude Code", Guid.NewGuid().ToString("N"), "00000000000000000000000000000001"),
      Guid.NewGuid().ToString("N"), SessionState.Starting, CreatedAt: 1, ReplayPrefix: "[Terminal Deck was updated. This terminal restarted in " + cwd + ".]", Replay: "x");
    var alone = HandedOver("C:\\Users\\admin\\iPresent"); var pairA = HandedOver("C:\\site"); var pairB = HandedOver("C:\\site");
    var store = new MemoryState<SessionLedger> { Value = new(1, 1, [alone, pairA, pairB]) };
    var files = new Files(); var processes = new Processes(); var newest = Guid.NewGuid().ToString();
    files.NewestFor[alone.Definition.Id] = newest; files.Saved.Add(newest); files.NewestFor[pairA.Definition.Id] = Guid.NewGuid().ToString(); files.Saved.Add(files.NewestFor[pairA.Definition.Id]);
    await new SessionKeeper(store, processes, files).RecoverAsync();
    Assert.Contains("resume:" + alone.Definition.Id + ":" + newest, processes.Calls);
    // Two terminals of the same AI in one folder: never guess, start fresh as before.
    Assert.Contains("start:" + pairA.Definition.Id + ":", processes.Calls);
    Assert.Contains("start:" + pairB.Definition.Id + ":", processes.Calls);
  }

  [Fact]
  public async Task ActivityReportsOutputRunsRealTypingAndClaudesOwnBusyFlag()
  {
    long clock = 100_000; var processes = new Processes(); var files = new Files();
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), processes, files) { Clock = () => clock };
    var row = await keeper.CreateAsync(Definition("claude"));
    var pid = processes.Observations[row.Definition.Id].ProcessId!.Value; files.Programs[pid] = new(row.Definition.ConversationId, true);
    for (var i = 0; i < 30; i++) { await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, "."); clock += 100; }
    await keeper.WriteAsync(row.Definition.Id, keeper.Instance, "\u001b[I\u001b[O"u8.ToArray());
    var seen = Assert.Single(keeper.Activity());
    Assert.Equal(100, seen.OutputAgeMs); Assert.Equal(2900, seen.OutputRunMs); Assert.Null(seen.InputAgeMs); Assert.True(seen.ProviderBusy);

    clock += 10_000; await keeper.AppendWorkerOutputAsync(row.Definition.Id, row.LeaseIdentity!, "redraw");
    await keeper.WriteAsync(row.Definition.Id, keeper.Instance, "y"u8.ToArray()); clock += 50;
    seen = Assert.Single(keeper.Activity());
    Assert.Equal(0, seen.OutputRunMs); Assert.Equal(50, seen.InputAgeMs);
  }

  [Fact]
  public async Task AHookCanMoveATerminalToItsNewConversationThroughTheKeeper()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new Processes(), new Files());
    var secret = new string('s', 64); var endpoint = new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "fixture");
    var row = await keeper.CreateAsync(Definition("claude")); var moved = Guid.NewGuid().ToString();
    await endpoint.HandleAsync(new() { Secret = secret, Operation = "conversation", Instance = keeper.Instance, Id = row.Definition.Id, Conversation = moved });
    Assert.Equal(moved, keeper.Get(row.Definition.Id).Definition.ConversationId);
    await Assert.ThrowsAsync<ArgumentException>(async () => await endpoint.HandleAsync(new() { Secret = secret, Operation = "conversation", Instance = keeper.Instance, Id = row.Definition.Id, Conversation = "not-an-id" }));
    var shell = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "C:\\work", "PowerShell"));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.UpdateConversationAsync(shell.Definition.Id, moved));
    var activity = await endpoint.HandleAsync(new() { Secret = secret, Operation = "activity" });
    Assert.Equal(2, activity.Activity!.Count);
  }
}

public sealed class ClaudeProcessFileTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Real(Path.GetTempPath()), "td-busy-" + Guid.NewGuid().ToString("N")));
  private static string Real(string path) => OperatingSystem.IsMacOS() && path.StartsWith("/var/", StringComparison.Ordinal) ? "/private" + path : path;
  private readonly string cwd;
  private readonly SessionDefinition definition;
  private string Config => Path.Combine(root.DirectoryPath, "accounts", definition.AccountHome!, "claude");
  public ClaudeProcessFileTests()
  {
    Directory.CreateDirectory(root.DirectoryPath);
    cwd = Path.Combine(root.DirectoryPath, "work", "iPresent"); Directory.CreateDirectory(cwd);
    definition = new(Guid.NewGuid().ToString(), "claude", cwd, "Claude Code", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString());
  }
  public void Dispose() { try { Directory.Delete(root.DirectoryPath, true); } catch (IOException) { } }
  private void Program(int pid, string session, string status, long startedAt)
  {
    Directory.CreateDirectory(Path.Combine(Config, "sessions"));
    File.WriteAllText(Path.Combine(Config, "sessions", pid + ".json"), JsonSerializer.Serialize(new { pid, sessionId = session, cwd, startedAt, status, kind = "interactive" }));
  }
  private string Transcript(string id, string? folder = null)
  {
    var directory = Path.Combine(Config, "projects", ConversationFiles.ClaudeProjectFolder(folder ?? cwd)); Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, id + ".jsonl");
    File.WriteAllText(path, JsonSerializer.Serialize(new { type = "summary" }) + "\n" + JsonSerializer.Serialize(new { sessionId = id, cwd = folder ?? cwd, type = "user" }) + "\n");
    return path;
  }

  [Fact]
  public void ClaudeNamesProjectFoldersLikeClaudeCodeDoes()
  {
    Assert.Equal("C--Users-admin-iPresent", ConversationFiles.ClaudeProjectFolder("C:\\Users\\admin\\iPresent"));
    Assert.Equal("-Users-imatch-Deck-Dev", ConversationFiles.ClaudeProjectFolder("/Users/imatch/Deck Dev"));
  }

  [Fact]
  public void TheLiveProgramFileGivesTheCurrentConversationAndBusyFlagOnlyForThatExactProgram()
  {
    var files = new ConversationFiles(root); var now = Guid.NewGuid().ToString();
    Program(4242, now, "busy", 2_000_000);
    Assert.Equal(new LiveConversation(now, true), files.Live(definition, 4242, 2_000_000));
    // A file left behind by an earlier program with the same number is not this one.
    Assert.Null(files.Live(definition, 4242, 2_000_000 + 60_000));
    Program(4243, now, "idle", 2_000_000);
    Assert.False(files.Live(definition, 4243, 0)!.Busy);
    Assert.Null(files.Live(definition, 4244, 0));
    Assert.Null(files.Live(definition with { Provider = "codex" }, 4243, 0));
  }

  [Fact]
  public void ResumeNeedsTheClaudeTranscriptToExist()
  {
    var files = new ConversationFiles(root);
    Assert.False(files.CanResume(definition));
    Transcript(definition.ConversationId!);
    Assert.True(files.CanResume(definition));
    var elsewhere = definition with { ConversationId = Guid.NewGuid().ToString() }; Transcript(elsewhere.ConversationId!, Path.Combine(root.DirectoryPath, "other"));
    Assert.True(files.CanResume(elsewhere));
    Assert.True(files.CanResume(definition with { Provider = "codex" }));
  }

  [Fact]
  public void DiscoveryFindsTheOneConversationThisSessionMovedTo()
  {
    var files = new ConversationFiles(root);
    var session = new SessionRecord(definition, "key", SessionState.Running, CreatedAt: DateTimeOffset.UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds());
    var mine = Transcript(definition.ConversationId!); File.SetLastWriteTimeUtc(mine, DateTime.UtcNow.AddMinutes(-2));
    Assert.Null(files.Discover(session, new HashSet<string>()));
    var cleared = Guid.NewGuid().ToString(); Transcript(cleared);
    Assert.Equal(cleared, files.Discover(session, new HashSet<string>()));
    // Another open terminal's conversation is never taken.
    Assert.Null(files.Discover(session, new HashSet<string> { cleared }));
    // Two candidates: ambiguous, keep what is saved.
    Transcript(Guid.NewGuid().ToString());
    Assert.Null(files.Discover(session, new HashSet<string>()));
    // A session that never had an id takes the only one written since it started.
    var fresh = session with { Definition = definition with { ConversationId = null, Cwd = Path.Combine(root.DirectoryPath, "work", "solo") } };
    Directory.CreateDirectory(fresh.Definition.Cwd);
    var only = Guid.NewGuid().ToString(); Transcript(only, fresh.Definition.Cwd);
    Assert.Equal(only, files.Discover(fresh, new HashSet<string>()));
    // Newest picks the latest written conversation of that folder (used only when no other terminal holds it).
    var later = Transcript(Guid.NewGuid().ToString(), fresh.Definition.Cwd); File.SetLastWriteTimeUtc(later, DateTime.UtcNow.AddSeconds(30));
    Assert.Equal(Path.GetFileNameWithoutExtension(later), files.Newest(fresh));
    Assert.Null(files.Discover(fresh, new HashSet<string>()));
  }
}
