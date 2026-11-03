using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Hoot.Tests;

// Asad, 30 Oct: "when we land in the application, Hoot should always be already
// set up ... we send a message and it just responds." The fake CLI here is the
// fixture's chat process keeper: it records each send and replays the answer.
public sealed class HootReadyTests
{
  private sealed class Ready : IAsyncDisposable
  {
    public readonly string Root = Path.Combine(Path.GetTempPath(), "td-hoot-ready-" + Guid.NewGuid().ToString("N"));
    public readonly Processes Process = new();
    public readonly AccountService Accounts; public readonly ChatSessions Chats; public readonly HootService Hoot;
    public readonly IStateStore<HootState> Store;
    public readonly List<string> ToolsPrepared = [];
    public Ready(AccountProfile[] accounts, HootState? saved = null, Func<string, AiPermissionMode>? permission = null)
    {
      Directory.CreateDirectory(Root); var root = AppDataRoot.Explicit(Root);
      Accounts = new(new State<AccountState>(new(1, accounts, [], [])), [new TestAccountProvider()]);
      Chats = new(new ChatHistory(root), Process, Accounts); Store = HootStorage.At(root);
      if (saved is not null) Store.Save(saved);
      Hoot = new(Store, Chats, Accounts, new Handoff(), prepareTools: (id, _) => { ToolsPrepared.Add(id); return ValueTask.CompletedTask; },
        ready: HootReady.For(root, permission));
    }
    public async Task<string> Say(string text)
    { var id = Guid.NewGuid().ToString(); await Hoot.SayAsync(id, text); return id; }
    public void Answer(string id, string text)
    {
      var chat = Hoot.Read().Turns.Single(t => t.Id == id).ChatId!;
      Process.Emit(chat, id, "message", text); Process.Emit(chat, id, "complete");
    }
    public async ValueTask DisposeAsync()
    { await Hoot.DisposeAsync(); await Chats.DisposeAsync(); Directory.Delete(Root, true); }
  }
  private static AccountProfile Account(string provider, bool signedIn, string name = "Default")
  { var id = Guid.NewGuid().ToString("N"); return new(id, provider, name, signedIn ? "fixture@example.invalid" : null, AccountAuthentication.Subscription, signedIn, id); }

  [Fact] public async Task FirstLaunchSetsHootUpAndTheFirstMessageIsAnswered()
  {
    var claude = Account("claude", true);
    await using var r = new Ready([Account("codex", true), claude]);
    Assert.Null(r.Hoot.Read().Settings);
    await r.Hoot.StartAsync();
    var settings = r.Hoot.Read().Settings!;
    Assert.Equal("claude", settings.Provider); Assert.Equal(claude.Id, settings.AccountId);
    Assert.Equal(Path.Combine(r.Root, "hoot"), settings.Folder); Assert.True(Directory.Exists(settings.Folder));
    Assert.StartsWith("# Memory index", File.ReadAllText(Path.Combine(settings.Folder, "memory", "MEMORY.md")));
    Assert.Equal(TerminalDeck.Core.Accounts.ModelCatalog.Top("claude")!.Id, settings.Options.Model); Assert.Equal("xhigh", settings.Options.Effort); // app-wide Opus 5.5 · Extra high
    Assert.Equal(AiPermissionMode.Auto, settings.PermissionMode);
    Assert.Equal(settings, r.Store.Load()!.Settings);

    var id = await r.Say("What needs me?");
    var sent = Assert.Single(r.Process.Sent);
    Assert.Equal(claude.Id, sent.Chat.Definition.AccountId); Assert.Equal(settings.Folder, sent.Chat.Definition.Cwd);
    Assert.Equal(AiPermissionMode.Auto, sent.Chat.Definition.PermissionMode);
    Assert.StartsWith("What needs me?", sent.Message.Text);
    Assert.Equal([sent.Chat.Definition.Id], r.ToolsPrepared); // the Deck tools are attached before the turn
    r.Answer(id, "Nothing needs you right now.");
    await Fixture.Wait(r.Hoot, s => !s.Busy);
    Assert.Contains(r.Hoot.Read().Lines, l => l.Kind == "assistant" && l.Text == "Nothing needs you right now.");
    Assert.Null(r.Hoot.Read().Problem);
  }

  [Fact] public async Task WithNobodySignedInHootWaitsThenConnectsByItselfAfterSignIn()
  {
    var claude = Account("claude", false);
    await using var r = new Ready([claude]);
    await r.Hoot.StartAsync();
    Assert.Null(r.Hoot.Read().Settings);
    var refused = await Assert.ThrowsAsync<InvalidOperationException>(() => r.Say("Hello"));
    Assert.Equal(HootReady.SignInLine, refused.Message); Assert.Empty(r.Process.Sent);

    await r.Accounts.RefreshAsync(claude.Id); // the in-app sign-in sheet finishing
    await r.Hoot.EnsureReadyAsync();
    Assert.Equal(claude.Id, r.Hoot.Read().Settings!.AccountId);
    var id = await r.Say("Hello"); r.Answer(id, "Hi.");
    await Fixture.Wait(r.Hoot, s => !s.Busy);
    Assert.Contains(r.Hoot.Read().Lines, l => l.Kind == "assistant" && l.Text == "Hi.");
  }

  [Fact] public async Task SignInBeforeTheFirstMessageIsPickedUpOnSend()
  {
    var claude = Account("claude", false);
    await using var r = new Ready([claude]);
    await r.Hoot.StartAsync(); await r.Accounts.RefreshAsync(claude.Id);
    await r.Say("Hello"); // no explicit ready call: the send connects Hoot
    Assert.Equal(claude.Id, Assert.Single(r.Process.Sent).Chat.Definition.AccountId);
  }

  [Fact] public async Task CodexOnlyGetsBypassAndThePersonsDefaultWinsWhereSupported()
  {
    await using (var r = new Ready([Account("claude", false), Account("codex", true)]))
    {
      await r.Hoot.StartAsync(); var s = r.Hoot.Read().Settings!;
      Assert.Equal("codex", s.Provider); Assert.Equal(AiPermissionMode.Bypass, s.PermissionMode); Assert.Equal("max", s.Options.Effort); // app-wide GPT-6.1-Sol · Max
    }
    await using (var r = new Ready([Account("gemini", true)], permission: _ => AiPermissionMode.Auto))
    {
      await r.Hoot.StartAsync(); var s = r.Hoot.Read().Settings!;
      Assert.Equal("gemini", s.Provider); Assert.Equal(AiPermissionMode.Bypass, s.PermissionMode); Assert.Equal("", s.Options.Effort);
    }
    await using (var r = new Ready([Account("claude", true)], permission: _ => AiPermissionMode.AcceptEdits))
    { await r.Hoot.StartAsync(); Assert.Equal(AiPermissionMode.AcceptEdits, r.Hoot.Read().Settings!.PermissionMode); }
  }

  [Fact] public async Task SavedChoicesAndAnExistingMemoryIndexAreNeverReplaced()
  {
    var claude = Account("claude", true); var codex = Account("codex", true);
    var own = Path.Combine(Path.GetTempPath(), "td-hoot-own-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(own);
    try
    {
      var saved = HootState.Empty with { Settings = new("codex", codex.Id, own, new("gpt-x", "low"), PermissionMode: AiPermissionMode.Ask) };
      await using var r = new Ready([claude, codex], saved);
      await r.Hoot.StartAsync(); await r.Hoot.EnsureReadyAsync();
      Assert.Equal(saved.Settings, r.Hoot.Read().Settings);
      Assert.False(Directory.Exists(Path.Combine(r.Root, "hoot")));

      var home = HootReady.For(AppDataRoot.Explicit(r.Root));
      Directory.CreateDirectory(Path.Combine(home.Home, "memory"));
      File.WriteAllText(Path.Combine(home.Home, "memory", "MEMORY.md"), "mine");
      home.EnsureFolder();
      Assert.Equal("mine", File.ReadAllText(Path.Combine(home.Home, "memory", "MEMORY.md")));
    }
    finally { Directory.Delete(own, true); }
  }
}
