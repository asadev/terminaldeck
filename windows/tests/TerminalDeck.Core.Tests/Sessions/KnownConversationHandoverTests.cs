using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class KnownConversationHandoverTests
{
  [Fact]
  public async Task Repaired_home_resumes_the_exact_known_conversation_and_persists_before_process_start()
  {
    var definition = Definition();
    var row = HandedOver(definition);
    var store = new MemoryState<SessionLedger> { Value = new(1, 0, [row]) };
    var files = new Files(true);
    var processes = new Processes((started, resume) =>
    {
      Assert.True(resume); Assert.True(Assert.Single(store.Value!.Sessions).Resume);
      Assert.Equal(definition, started.Definition);
    });
    var keeper = new SessionKeeper(store, processes, files);
    await keeper.RecoverAsync();
    Assert.True(keeper.Get(definition.Id).Resume);
    Assert.Equal(definition, keeper.Get(definition.Id).Definition);
    Assert.Equal(0, files.Discoveries); Assert.Single(processes.Starts);
  }

  [Theory]
  [InlineData(false, true, null, "claude")]
  [InlineData(true, false, null, "claude")]
  [InlineData(true, true, "sign-in", "claude")]
  [InlineData(true, true, null, "codex")]
  public async Task Missing_transcript_non_handover_signin_and_other_provider_keep_their_prior_start_behavior(bool saved, bool handover, string? purpose, string provider)
  {
    var definition = Definition() with { Provider = provider, Purpose = purpose };
    var row = HandedOver(definition) with { ReplayPrefix = handover ? "[Terminal Deck was updated. Restarting.]" : "ordinary recovery" };
    var store = new MemoryState<SessionLedger> { Value = new(1, 0, [row]) };
    var processes = new Processes((started, resume) => { Assert.False(resume); Assert.Equal(definition, started.Definition); });
    var keeper = new SessionKeeper(store, processes, new Files(saved));
    await keeper.RecoverAsync();
    Assert.False(keeper.Get(definition.Id).Resume); Assert.Single(processes.Starts);
  }

  [Fact]
  public async Task Unknown_transcript_availability_does_not_enable_the_new_resume_path()
  {
    var definition = Definition();
    var row = HandedOver(definition);
    var store = new MemoryState<SessionLedger> { Value = new(1, 0, [row]) };
    var processes = new Processes((_, resume) => Assert.False(resume));
    await new SessionKeeper(store, processes).RecoverAsync();
    Assert.Single(processes.Starts);
  }

  private static SessionDefinition Definition() => new(Guid.NewGuid().ToString(), "claude", @"C:\work", "Keeper recovery", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString(), InitialPrompt: "ORIGINAL_BRIEF_MUST_NOT_REPEAT");
  private static SessionRecord HandedOver(SessionDefinition definition) => new(definition, Guid.NewGuid().ToString("N"), SessionState.Starting,
    Resume: false, HasStarted: false, ReplayPrefix: "[Terminal Deck was updated. This terminal restarted.]");

  private sealed class Files(bool saved) : IConversationFiles
  {
    public int Discoveries { get; private set; }
    public bool CanResume(SessionDefinition definition) => saved;
    public string FindConversation(SessionRecord session) => throw new InvalidOperationException("The exact conversation is already known.");
    public void Validate(SessionDefinition source, SessionDefinition destination) => throw new InvalidOperationException("No account move is allowed.");
    public void Copy(SessionDefinition source, SessionDefinition destination) => throw new InvalidOperationException("No account move is allowed.");
    public string? Discover(SessionRecord session, IReadOnlySet<string> claimed) { Discoveries++; throw new InvalidOperationException("A known conversation must not be replaced."); }
  }
  private sealed class Processes(Action<SessionRecord, bool> starting) : ISessionProcessKeeper
  {
    public List<SessionRecord> Starts { get; } = [];
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Dead));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct)
    {
      starting(row, resume); Starts.Add(row); return ValueTask.FromResult(new ProcessObservation(ProcessPresence.Live, "fixture-lease"));
    }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new InvalidOperationException("Recovery must not type the original prompt.");
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask QuitAsync(string lease, CancellationToken ct) => throw new InvalidOperationException("No live process should be stopped.");
  }
}
