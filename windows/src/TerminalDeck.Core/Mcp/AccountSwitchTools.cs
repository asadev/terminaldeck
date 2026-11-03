using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Mcp;

public sealed record DeferredAccountSwitch(string SessionId, string Destination, string CallerId, DateTimeOffset ExpiresAt);
public interface IDeferredSwitchAuthorizer
{
  ValueTask<bool> StillAllowedAsync(DeferredAccountSwitch change, CancellationToken cancellationToken);
}
public sealed record DeferredSwitchState(DeferredAccountSwitch[] Switches);

// The keeper calls OnIdleAsync after an actual process-state event. No polling.
public sealed class AccountSwitchTools
{
  private readonly AccountSwitchCoordinator switches;
  private readonly IConversationAccountRuntime runtime;
  private readonly SessionKeeper keeper;
  private readonly IStateStore<DeferredSwitchState> store;
  private readonly AccountService accounts;
  private readonly IDeferredSwitchAuthorizer authorization;
  private readonly SemaphoreSlim gate = new(1);
  private DeferredSwitchState state;
  public AccountSwitchTools(AccountSwitchCoordinator switches, IConversationAccountRuntime runtime, SessionKeeper keeper, AccountService accounts, IStateStore<DeferredSwitchState> store, IDeferredSwitchAuthorizer authorization)
  {
    this.switches = switches; this.runtime = runtime; this.keeper = keeper; this.accounts = accounts; this.store = store; this.authorization = authorization;
    state = store.Load() ?? new([]);
  }
  public void Register(McpDoor door) => door.Register("sessions.account", async (c, a, ct) =>
  {
    var action = DeckCoreTools.Required(a, "action");
    if (action == "armed")
    {
      await gate.WaitAsync(ct);
      try { return JsonSerializer.SerializeToElement(state.Switches.Where(s => c.Has("sessions", s.SessionId) && c.Has("accounts", s.Destination))); }
      finally { gate.Release(); }
    }
    var id = DeckCoreTools.Required(a, "sessionId"); c.Require("sessions", id);
    if (action == "show")
    {
      var binding = await runtime.ReadAsync(id, ct); c.Require("accounts", binding.AccountId);
      return JsonSerializer.SerializeToElement(new { sessionId = id, accountId = binding.AccountId, conversationId = binding.ConversationId });
    }
    if (action == "cancel")
    {
      await gate.WaitAsync(ct);
      try { await c.EnsureCurrentAsync(ct); Save(new(state.Switches.Where(s => s.SessionId != id).ToArray())); }
      finally { gate.Release(); }
      return JsonSerializer.SerializeToElement(new { cancelled = true });
    }
    var destination = accounts.Get(DeckCoreTools.Required(a, "account")); c.Require("accounts", destination.Id);
    var plan = await switches.PlanAsync(id, destination.Id, ct);
    await c.EnsureCurrentAsync(ct);
    if (action == "plan") return JsonSerializer.SerializeToElement(new { sessionId = id, accountId = destination.Id, conversationId = plan.Before.ConversationId, keepsConversation = true });
    if (action == "switch")
    {
      var done = await switches.SwitchAsync(id, destination.Id, ct);
      return JsonSerializer.SerializeToElement(new { switched = true, conversationId = done.After.ConversationId });
    }
    await gate.WaitAsync(ct);
    try { await c.EnsureCurrentAsync(ct); Save(new(state.Switches.Where(s => s.SessionId != id).Append(new(id, destination.Id, c.Grant.CallerId, c.Grant.ExpiresAt)).ToArray())); }
    finally { gate.Release(); }
    return JsonSerializer.SerializeToElement(new { scheduled = true });
  });
  public async ValueTask<bool> OnIdleAsync(string sessionId, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      var pending = state.Switches.FirstOrDefault(s => s.SessionId == sessionId);
      if (pending is null || !await keeper.IsIdleAsync(sessionId, cancellationToken)) return false;
      if (pending.ExpiresAt <= DateTimeOffset.UtcNow || !await authorization.StillAllowedAsync(pending, cancellationToken))
      { Save(new(state.Switches.Where(s => s.SessionId != sessionId).ToArray())); return false; }
      await switches.SwitchAsync(sessionId, pending.Destination, cancellationToken);
      Save(new(state.Switches.Where(s => s.SessionId != sessionId).ToArray())); return true;
    }
    finally { gate.Release(); }
  }
  private void Save(DeferredSwitchState next) { store.Save(next); state = next; }
}
