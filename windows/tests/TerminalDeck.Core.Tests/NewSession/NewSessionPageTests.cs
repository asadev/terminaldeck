using System.Text.Json;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.NewSession;

// The New session page's rules (Mac NativeLanding, 14 Nov): what the page presets, when a session
// is made, and the send rule. No window is needed for any of them.
public sealed class NewSessionPageTests
{
  private sealed class Store<T> : IStateStore<T> { public T? Value; public T? Load() => Value; public void Save(T state) => Value = state; }

  private static NewSessionWorld World(string[]? projects = null, NewSessionAgent[]? agents = null, Dictionary<string, string[]>? accounts = null, string defaultProvider = "claude") =>
    new(projects ?? ["imatch", "site"], agents ?? [new("decker", "Decker", "imatch", "claude", Lead: true), new("hand", "Hand", "imatch", "codex"), new("free", "Free", ProjectIdentity.IndependentId, "gemini")],
      ["claude", "codex", "gemini", "shell"],
      provider => (accounts ?? new() { ["claude"] = ["c1", "c2"], ["codex"] = ["x1"], ["gemini"] = [] }).GetValueOrDefault(provider) ?? [],
      provider => provider == "claude" ? "c2" : null, defaultProvider);

  [Fact]
  public void A_first_launch_presets_no_project_the_default_AI_its_default_account_and_Chat()
  {
    var start = NewSessionPresets.Resolve(null, World());
    Assert.Equal(new NewSessionStart(ProjectIdentity.IndependentId, null, "claude", "c2", null, null, "chat"), start);
  }

  [Fact]
  public void The_last_start_presets_every_choice()
  {
    var last = new NewSessionStart("imatch", "hand", "codex", "x1", "gpt-5.5", "high", "terminal");
    Assert.Equal(last, NewSessionPresets.Resolve(last, World()));
  }

  [Fact]
  public void What_no_longer_exists_falls_back_quietly()
  {
    var last = new NewSessionStart("deleted", "gone", "claude", "removed-account", "opus", "max", "chat");
    var start = NewSessionPresets.Resolve(last, World());
    Assert.Equal(ProjectIdentity.IndependentId, start.ProjectId);
    Assert.Null(start.AgentId);
    Assert.Equal("c2", start.AccountId);
    Assert.Equal("opus", start.Model);
  }

  [Fact]
  public void New_session_pressed_in_a_project_starts_there()
  {
    var last = new NewSessionStart("imatch", "decker", "claude", "c1", null, null, "chat");
    var start = NewSessionPresets.Resolve(last, World(), "site");
    Assert.Equal("site", start.ProjectId);
    Assert.Null(start.AgentId);
  }

  [Fact]
  public void An_agent_brings_its_AI_and_No_agent_keeps_the_AI()
  {
    var world = World();
    var start = NewSessionPresets.Resolve(new("imatch", null, "claude", "c1", "opus", "high", "chat"), world);
    var withHand = NewSessionPresets.WithAgent(start, "hand", world);
    Assert.Equal("codex", withHand.Provider); Assert.Equal("hand", withHand.AgentId); Assert.Equal("x1", withHand.AccountId);
    Assert.Null(withHand.Model);
    var none = NewSessionPresets.WithAgent(withHand, null, world);
    Assert.Equal("codex", none.Provider); Assert.Null(none.AgentId);
  }

  [Fact]
  public void The_lead_is_listed_first_and_independent_agents_are_offered_everywhere()
  {
    var names = NewSessionPresets.AgentsFor("imatch", World()).Select(a => a.Name).ToArray();
    Assert.Equal(new[] { "Decker", "Free", "Hand" }, names);
    Assert.Equal(new[] { "Free" }, NewSessionPresets.AgentsFor("site", World()).Select(a => a.Name).ToArray());
  }

  [Fact]
  public void Picking_another_AIs_account_picks_that_AI_and_Shell_opens_in_Terminal()
  {
    var world = World();
    var start = NewSessionPresets.Resolve(null, world);
    var codex = NewSessionPresets.WithProvider(start, "codex", world, "x1");
    Assert.Equal("codex", codex.Provider); Assert.Equal("x1", codex.AccountId); Assert.Equal("chat", codex.Mode);
    var shell = NewSessionPresets.WithProvider(codex, "shell", world);
    Assert.Equal("shell", shell.Provider); Assert.Null(shell.AccountId); Assert.Equal("terminal", shell.Mode);
    Assert.Equal("terminal", NewSessionPresets.WithMode(shell, "chat").Mode);
  }

  [Fact]
  public void Changing_project_lets_go_of_an_agent_from_another_project()
  {
    var world = World();
    var start = NewSessionPresets.WithAgent(NewSessionPresets.Resolve(new("imatch", null, "claude", "c1", null, null, "chat"), world), "decker", world);
    Assert.Null(NewSessionPresets.WithProject(start, "site", world).AgentId);
    var free = NewSessionPresets.WithAgent(start, "free", world);
    Assert.Equal("free", NewSessionPresets.WithProject(free, "site", world).AgentId);
  }

  [Fact]
  public void The_send_rule_reads_the_box_at_the_press()
  {
    Assert.False(NewSessionSend.Allowed("", 0, false));
    Assert.False(NewSessionSend.Allowed("  \n ", 0, false));
    Assert.True(NewSessionSend.Allowed("hello", 0, false));
    Assert.True(NewSessionSend.Allowed("", 1, false));
    Assert.False(NewSessionSend.Allowed("hello", 0, true));
  }

  [Fact]
  public async Task Showing_the_page_and_changing_choices_make_nothing_and_one_send_makes_one_session()
  {
    var made = new List<(NewSessionStart, string)>();
    var gate = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
    var flow = new NewSessionFlow((start, text, _) => { made.Add((start, text)); return gate.Task; });
    var world = World();
    var choices = NewSessionPresets.WithProvider(NewSessionPresets.Resolve(null, world), "codex", world);
    choices = NewSessionPresets.WithMode(NewSessionPresets.WithProject(choices, "site", world), "terminal");
    Assert.Empty(made);
    Assert.Equal(NewSessionOutcome.NotSent, (await flow.SendAsync("", 0, choices, Task.CompletedTask, TimeSpan.FromSeconds(1))).Outcome);
    Assert.Empty(made);
    var first = flow.SendAsync("fix the login", 0, choices, Task.CompletedTask, TimeSpan.FromSeconds(1));
    // A second Return while the session is being made makes no second session.
    Assert.Equal(NewSessionOutcome.NotSent, (await flow.SendAsync("fix the login", 0, choices, Task.CompletedTask, TimeSpan.FromSeconds(1))).Outcome);
    gate.SetResult("session-1");
    var result = await first;
    Assert.Equal(new NewSessionResult(NewSessionOutcome.Started, "session-1"), result);
    var only = Assert.Single(made);
    Assert.Equal(choices, only.Item1); Assert.Equal("fix the login", only.Item2);
  }

  [Fact]
  public async Task A_send_before_the_app_is_ready_is_held_then_kept_and_a_failure_keeps_the_text()
  {
    var calls = 0;
    var flow = new NewSessionFlow((_, _, _) => { calls++; throw new InvalidOperationException("Not signed in. Your message and choices are kept here."); });
    var start = NewSessionPresets.Resolve(null, World());
    var notReady = await flow.SendAsync("hello", 0, start, new TaskCompletionSource().Task, TimeSpan.FromMilliseconds(20));
    Assert.Equal(new NewSessionResult(NewSessionOutcome.NotReady, Message: NewSessionFlow.NotReadyMessage), notReady);
    Assert.Equal(0, calls);
    var failed = await flow.SendAsync("hello", 0, start, Task.CompletedTask, TimeSpan.FromSeconds(1));
    Assert.Equal(NewSessionOutcome.Failed, failed.Outcome);
    Assert.Equal("Not signed in. Your message and choices are kept here.", failed.Message);
    Assert.False(flow.Starting);
  }

  [Fact]
  public void Only_the_sent_text_leaves_the_box()
  {
    Assert.Equal("", NewSessionSend.AfterSend("fix it", "fix it"));
    Assert.Equal("and the tests", NewSessionSend.AfterSend("fix it\nand the tests", "fix it"));
    Assert.Equal("fix it now", NewSessionSend.AfterSend("fix it now", "fix it later"));
  }

  [Fact]
  public void No_project_runs_in_its_own_folder_never_the_home_folder()
  {
    var home = Path.Combine(Path.GetTempPath(), "home");
    var folder = NewSessionSend.IndependentFolder(home);
    Assert.NotEqual(home, folder);
    Assert.Equal(Path.Combine(home, Brand.Name, "Independent"), folder);
  }

  [Fact]
  public void The_last_start_and_the_unsent_text_stay_on_this_PC()
  {
    var last = new Store<NewSessionStart>(); var draft = new Store<NewSessionDraft>();
    var memory = new NewSessionMemory(last, draft);
    Assert.Null(memory.Last()); Assert.Equal("", memory.Draft());
    var start = new NewSessionStart("imatch", "decker", "claude", "c1", "opus", "high", "chat");
    memory.Remember(start); memory.KeepDraft("half a thought");
    Assert.Equal(start, memory.Last()); Assert.Equal("half a thought", memory.Draft());
  }

  [Fact]
  public void When_Terminal_Deck_opens_defaults_to_New_session_and_offers_two_choices_on_Windows()
  {
    var store = new Store<GeneralPreferences>();
    var settings = new GeneralSettings(store);
    Assert.True(OpensOn.ShowsNewSession(settings.Read().WhenOpens));
    Assert.Equal(new[] { "New session", "Where I left off" }, OpensOn.OnWindows.Select(OpensOn.Label).ToArray());
    settings.Patch(JsonDocument.Parse("""{"whenOpens":"where-i-left-off"}""").RootElement);
    Assert.False(OpensOn.ShowsNewSession(settings.Read().WhenOpens));
    Assert.Throws<ArgumentException>(() => settings.Patch(JsonDocument.Parse("""{"whenOpens":"somewhere"}""").RootElement));
    Assert.Equal(OpensOn.WhereILeftOff, OpensOn.Normal(OpensOn.Overview));
  }
}
