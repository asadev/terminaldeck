using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task StartAgainHereAsync(SessionDraft draft)
  {
    var previous = Runtime.Sessions.FirstOrDefault(row => row.Definition.Id == draft.Id) ?? throw new InvalidOperationException("This session is no longer available.");
    if (previous.State != SessionState.Exited) throw new InvalidOperationException("This session has not ended.");
    var definition = previous.Definition with { Id = Guid.NewGuid().ToString(), ConversationId = null, InitialPrompt = null };
    if (definition.AccountId is { } accountId)
    {
      var account = await Runtime.Accounts.RequireSignedInAsync(accountId);
      definition = definition with { AccountHome = account.HomeId };
    }
    // A new run gets its own identity. The ended row and its replay stay intact.
    var started = (await Runtime.Keeper.CreateAsync(definition)).Session ?? throw new IOException("The program did not start.");
    Runtime.Projects.BindSession(started.Definition.Id, Runtime.Projects.Resolve(draft.ProjectId, draft.Folder));
    await Runtime.RefreshSessionsAsync(); SyncSessions(); SelectSessionWindow(Model.Sessions.Single(row => row.Id == started.Definition.Id));
  }
}
