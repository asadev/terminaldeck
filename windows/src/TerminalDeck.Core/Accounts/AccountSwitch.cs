using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

// ConversationId is the app's stable identity; a cross-provider handover can have
// a different ProviderConversationId but may never silently start an empty chat.
public sealed record ConversationBinding(string SessionId, string ConversationId, string ProviderConversationId,
  string Provider, string AccountId, string HomeId, long Revision);
public sealed record AccountSwitchPlan(string TransactionId, ConversationBinding Before, ConversationBinding After, string CarryoverReference);
public enum SwitchState { Pending, Committed, RolledBack }
public sealed record AccountSwitchEntry(AccountSwitchPlan Plan, SwitchState State);
public sealed record AccountSwitchJournal(int Version, AccountSwitchEntry[] Entries);

public interface IConversationAccountRuntime
{
  ValueTask<ConversationBinding> ReadAsync(string sessionId, CancellationToken cancellationToken);
  // Prepare only reads/validates carryover; Apply performs the approved transfer.
  ValueTask<AccountSwitchPlan> PrepareAsync(string transactionId, ConversationBinding before, AccountProfile destination, CancellationToken cancellationToken);
  // Apply and rollback are durable/idempotent by TransactionId and reject stale revisions.
  ValueTask ApplyAsync(AccountSwitchPlan plan, CancellationToken cancellationToken);
  ValueTask RollbackAsync(AccountSwitchPlan plan, CancellationToken cancellationToken);
}

public sealed class AccountSwitchCoordinator
{
  private readonly AccountService accounts;
  private readonly IConversationAccountRuntime runtime;
  private readonly IStateStore<AccountSwitchJournal> store;
  private readonly SemaphoreSlim gate = new(1);
  private AccountSwitchJournal journal;
  public AccountSwitchCoordinator(AccountService accounts, IConversationAccountRuntime runtime, IStateStore<AccountSwitchJournal> store)
  {
    this.accounts = accounts; this.runtime = runtime; this.store = store;
    journal = store.Load() ?? new(1, []);
    if (journal.Version != 1) throw new IOException("The saved account switches could not be read.");
  }

  public async ValueTask<AccountSwitchPlan> PlanAsync(string sessionId, string destination, CancellationToken cancellationToken = default)
  {
    var account = await accounts.RequireSignedInAsync(destination, cancellationToken);
    var before = await runtime.ReadAsync(sessionId, cancellationToken);
    var transactionId = Guid.NewGuid().ToString("N");
    var plan = await runtime.PrepareAsync(transactionId, before, account, cancellationToken);
    if (plan.TransactionId != transactionId || plan.Before != before || plan.After.SessionId != before.SessionId || plan.After.ConversationId != before.ConversationId ||
      plan.After.AccountId != account.Id || plan.After.HomeId != account.HomeId || plan.After.Provider != account.Provider ||
      plan.After.Revision != before.Revision + 1 || string.IsNullOrEmpty(plan.After.ProviderConversationId) || string.IsNullOrEmpty(plan.CarryoverReference))
      throw new InvalidOperationException("This switch could not keep the conversation. The original account was kept.");
    return plan;
  }

  public async ValueTask<AccountSwitchPlan> SwitchAsync(string sessionId, string destination, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      if (journal.Entries.Any(e => e.State == SwitchState.Pending && e.Plan.Before.SessionId == sessionId))
        throw new InvalidOperationException("This session has an unfinished account switch. Recover it first.");
      var plan = await PlanAsync(sessionId, destination, cancellationToken);
      Save(new(plan, SwitchState.Pending));
      await CompleteAsync(plan, cancellationToken);
      return plan;
    }
    finally { gate.Release(); }
  }
  public async ValueTask RecoverAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      foreach (var entry in journal.Entries.Where(e => e.State == SwitchState.Pending).ToArray())
        await CompleteAsync(entry.Plan, cancellationToken);
    }
    finally { gate.Release(); }
  }
  private async ValueTask CompleteAsync(AccountSwitchPlan plan, CancellationToken cancellationToken)
  {
    try
    {
      await accounts.RequireSignedInAsync(plan.After.AccountId, cancellationToken);
      await runtime.ApplyAsync(plan, cancellationToken);
      await accounts.RequireSignedInAsync(plan.After.AccountId, cancellationToken);
    }
    catch
    {
      // Recovery remains pending if rollback itself fails; never erase its evidence.
      await runtime.RollbackAsync(plan, CancellationToken.None);
      Save(new(plan, SwitchState.RolledBack));
      throw;
    }
    // A failed final save leaves a pending intent. Recovery repeats idempotently.
    Save(new(plan, SwitchState.Committed));
  }
  private void Save(AccountSwitchEntry entry)
  {
    var next = journal with { Entries = journal.Entries.Where(e => e.Plan.TransactionId != entry.Plan.TransactionId).Append(entry).ToArray() };
    store.Save(next); journal = next;
  }
}
