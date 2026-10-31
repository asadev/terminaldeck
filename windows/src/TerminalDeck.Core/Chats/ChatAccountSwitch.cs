using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Chats;

public sealed partial class ChatSessions
{
  private AccountSwitchCoordinator? accountSwitches;
  private AccountSwitchCoordinator Switches => accountSwitches ??= history is ChatHistory saved
    ? new(accounts, new AccountRuntime(this, saved.AccountConversations, accounts, processes), saved.AccountSwitchJournal)
    : throw new InvalidOperationException("This chat cannot save an account switch yet.");

  public async ValueTask<bool> CanSwitchAccountAsync(string id, string accountId, CancellationToken cancellationToken = default)
  {
    var account = await accounts.RequireSignedInAsync(accountId, cancellationToken);
    await gate.WaitAsync(cancellationToken);
    try
    {
      var chat = Get(id); RequireIdle(chat);
      if (account.Provider != chat.Definition.Provider) throw new ArgumentException("Choose an account for this coding AI.");
      if (chat.ConversationId is null || account.Id == chat.Definition.AccountId && account.HomeId == chat.Definition.AccountHome) return true;
      _ = await Switches.PlanAsync(id, account.Id, cancellationToken);
      return true;
    }
    finally { gate.Release(); }
  }

  // The chat gate surrounds every transaction, including recovery. Old worker
  // events cannot advance the conversation while its transcript is transferred.
  private async ValueTask RecoverAccountSwitchesAsync(CancellationToken ct)
  {
    if (history is ChatHistory) await Switches.RecoverAsync(ct);
  }

  private sealed class AccountRuntime(ChatSessions owner, IConversationFiles files, AccountService accounts, IChatProcessKeeper processes) : IConversationAccountRuntime
  {
    private static ConversationBinding Binding(ChatRecord chat) => new(chat.Definition.Id, chat.Definition.Id,
      chat.ConversationId ?? throw new InvalidOperationException("Wait for this chat to save its conversation before switching."),
      chat.Definition.Provider, chat.Definition.AccountId, chat.Definition.AccountHome, chat.AccountRevision);
    private static SessionDefinition Definition(ChatRecord chat, ConversationBinding binding) => Session(chat).Definition with
    { AccountId = binding.AccountId, AccountHome = binding.HomeId, ConversationId = binding.ProviderConversationId };

    public ValueTask<ConversationBinding> ReadAsync(string id, CancellationToken ct)
    {
      ct.ThrowIfCancellationRequested(); var chat = owner.Get(id); RequireIdle(chat);
      return ValueTask.FromResult(Binding(chat));
    }
    public async ValueTask<AccountSwitchPlan> PrepareAsync(string id, ConversationBinding before, AccountProfile destination, CancellationToken ct)
    {
      var chat = owner.Get(before.SessionId); RequireIdle(chat);
      if (Binding(chat) != before) throw new InvalidOperationException("This chat changed. Prepare the switch again.");
      if (before.Provider != destination.Provider) throw new ArgumentException("Choose an account for this coding AI.");
      if ((await processes.ObserveAsync(Session(chat), ct)).Presence == ProcessPresence.Unknown)
        throw new IOException("Reconnect before changing this chat.");
      if (chat.Definition.Options.Model.Length > 0 && !(await accounts.ModelsAsync(destination.Id, cancellationToken: ct)).Models.Any(m => m.Id == chat.Definition.Options.Model))
        throw new InvalidOperationException("Choose Automatic or a model offered by both accounts before switching.");
      var after = before with { AccountId = destination.Id, HomeId = destination.HomeId, Revision = before.Revision + 1 };
      files.Validate(Definition(chat, before), Definition(chat, after));
      return new(id, before, after, before.ProviderConversationId);
    }
    public async ValueTask ApplyAsync(AccountSwitchPlan plan, CancellationToken ct)
    {
      var chat = owner.Get(plan.Before.SessionId); RequireIdle(chat);
      if (chat.LastAccountSwitch == plan.TransactionId && Binding(chat) == plan.After) return;
      if (Binding(chat) != plan.Before) throw new InvalidOperationException("This chat changed before its account switch finished.");
      await RetireAsync(chat, ct);
      files.Copy(Definition(chat, plan.Before), Definition(chat, plan.After));
      owner.Save(chat with
      {
        Definition = chat.Definition with { AccountId = plan.After.AccountId, AccountHome = plan.After.HomeId },
        AccountRevision = plan.After.Revision, LastAccountSwitch = plan.TransactionId,
        CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0, Problem = null
      });
    }
    public async ValueTask RollbackAsync(AccountSwitchPlan plan, CancellationToken ct)
    {
      var chat = owner.Get(plan.Before.SessionId);
      if (Binding(chat) != plan.Before && !(Binding(chat) == plan.After && chat.LastAccountSwitch == plan.TransactionId))
        throw new InvalidOperationException("This chat changed before its original account could be restored.");
      await RetireAsync(chat, ct);
      owner.Save(chat with
      {
        Definition = chat.Definition with { AccountId = plan.Before.AccountId, AccountHome = plan.Before.HomeId },
        AccountRevision = plan.Before.Revision, LastAccountSwitch = null,
        CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0
      });
    }
    private async ValueTask RetireAsync(ChatRecord chat, CancellationToken ct)
    {
      await owner.RetireWorkerAsync(chat, ct);
      if ((await processes.ObserveAsync(Session(chat), ct)).Presence != ProcessPresence.Dead)
        throw new IOException("The previous chat worker has not stopped. Its account was kept.");
    }
  }
}
