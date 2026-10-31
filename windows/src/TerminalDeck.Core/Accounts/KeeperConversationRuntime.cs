using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Accounts;

// The coordinator journals intent; the keeper owns stopping and replacing the
// exact process. Closing the UI cannot interrupt the keeper's durable intent.
public sealed class KeeperConversationRuntime(Func<KeeperClient> keeper, IConversationFiles files) : IConversationAccountRuntime
{
  private async Task<SessionRecord> SessionAsync(string id, CancellationToken ct) =>
    (await keeper().ListAsync(ct)).Sessions?.SingleOrDefault(s => s.Definition.Id == id) ?? throw new ArgumentException("Choose an existing session.");
  private ConversationBinding Binding(SessionRecord row)
  {
    if (row.Definition.Provider == "shell" || row.Definition.Purpose is not null || row.Definition.AccountId is null) throw new InvalidOperationException("Choose an AI conversation to switch accounts.");
    var conversation = files.FindConversation(row);
    return new(row.Definition.Id, row.Definition.Id, conversation, row.Definition.Provider, row.Definition.AccountId, row.Definition.AccountHome ?? row.Definition.AccountId, row.AccountRevision);
  }
  public async ValueTask<ConversationBinding> ReadAsync(string sessionId, CancellationToken ct) => Binding(await SessionAsync(sessionId, ct));
  public async ValueTask<AccountSwitchPlan> PrepareAsync(string transactionId, ConversationBinding before, AccountProfile destination, CancellationToken ct)
  {
    var row = await SessionAsync(before.SessionId, ct);
    if (Binding(row) != before || row.PendingAccount is not null) throw new InvalidOperationException("The session changed. Prepare the switch again.");
    if (destination.Provider != before.Provider) throw new InvalidOperationException("Choose an account for the same AI to keep this exact conversation.");
    if (destination.Id == before.AccountId && destination.HomeId == before.HomeId) throw new InvalidOperationException("This conversation already uses that account.");
    var after = before with { AccountId = destination.Id, HomeId = destination.HomeId, Revision = before.Revision + 1 };
    files.Validate(row.Definition with { ConversationId = before.ProviderConversationId }, row.Definition with { AccountId = after.AccountId, AccountHome = after.HomeId, ConversationId = after.ProviderConversationId });
    return new(transactionId, before, after, before.ProviderConversationId);
  }
  public async ValueTask ApplyAsync(AccountSwitchPlan plan, CancellationToken ct)
  {
    var row = await SessionAsync(plan.Before.SessionId, ct);
    if (row.LastAccountSwitch == plan.TransactionId && row.AccountRevision == plan.After.Revision && row.State == SessionState.Running) return;
    if (row.AccountRevision != plan.Before.Revision) throw new InvalidOperationException("The session changed before its switch could finish.");
    var destination = row.Definition with { AccountId = plan.After.AccountId, AccountHome = plan.After.HomeId, ConversationId = plan.After.ProviderConversationId };
    var reply = await keeper().SwitchAccountAsync(destination, plan.Before.Revision, plan.TransactionId, ct);
    if (reply.Session?.State != SessionState.Running) throw new IOException("The replacement terminal is waiting to reconnect.");
  }
  public async ValueTask RollbackAsync(AccountSwitchPlan plan, CancellationToken ct)
  {
    var row = await SessionAsync(plan.Before.SessionId, ct);
    if (row.Definition.AccountId == plan.Before.AccountId && row.PendingAccount is null && row.LastAccountSwitch != plan.TransactionId) return;
    await keeper().RollbackAccountAsync(row.Definition with { AccountId = plan.Before.AccountId, AccountHome = plan.Before.HomeId, ConversationId = plan.Before.ProviderConversationId }, plan.TransactionId, ct);
  }
}
