using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.Platform.Windows.Tasks;

public sealed partial class KeeperTaskCoordinator
{
  private IReadOnlyList<AgentRun> BudgetRuns() => new JsonStateStore<AgentState>(root, "agents").Load()?.Runs.ToArray() ?? [];
  private AccountProfile? BudgetAccount(string id) => new JsonStateStore<AccountState>(root, "accounts").Load()?.Accounts.FirstOrDefault(a => a.Id == id);
  private TaskBudgetObserver CreateBudgetObserver(TaskService tasks)
  {
    var ledger = new AgentBudgetLedger(new JsonStateStore<AgentUsageLedgerState>(root, "agent-usage"));
    var reader = new AgentUsageReader(BudgetRuns, sessions.List, id => chats.List().FirstOrDefault(c => c.Definition.Id == id), new ConversationFiles(root), BudgetAccount);
    return new(tasks, new(ledger, reader.ReadAsync), ledger, BudgetRuns);
  }
  private UsageService CreateBudgetWatch() => new(id =>
  {
    var session = sessions.List().FirstOrDefault(s => s.Definition.Id == id);
    if (session?.Definition.AccountId is not { } accountId) return null;
    var account = BudgetAccount(accountId);
    if (account is null) return null;
    string home;
    try { home = new ConversationFiles(root).UsageHome(session.Definition); }
    catch (Exception error) when (error is IOException or ArgumentException) { return null; }
    return new UsageSubject(id, session.Definition.Provider, session.Definition.Cwd,
      new UsageAccount(account.Provider, account.Id, account.Name, home, account.Authentication == AccountAuthentication.ApiKey), session.Definition.ConversationId);
  }, () => []);
  private async Task ObserveBudgetAsync(TaskBudgetObserver budget, string id, CancellationToken ct)
  {
    try { await budget.ObserveAsync(id, ct); }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception error) when (error is not OutOfMemoryException) { Failed?.Invoke("This task's budget reading is unavailable. Its recorded usage was kept."); }
  }
}
