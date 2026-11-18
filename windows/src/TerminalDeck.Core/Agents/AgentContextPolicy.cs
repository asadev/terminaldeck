using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Agents;

public static class AgentContextPolicy
{
  public static string Signature(AgentLaunchPlan plan, string? ownerScope) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new
  {
    plan.AgentId, plan.ProjectId, plan.Folder, plan.Provider, plan.AccountId, plan.Permission, plan.Instructions, plan.InstructionsFile,
    plan.Model, plan.Effort, addonsOff = plan.Efficiency?.AddonsOff == true, ownerScope
  })));

  public static string? Parked(AgentLaunchPlan plan, TasksState tasks, IReadOnlyList<SessionRecord> terminals, IReadOnlyList<ChatRecord> chats)
  {
    if (plan.Efficiency?.ReuseContext != true || plan.ContextSignature is null || plan.AgentId is null) return null;
    foreach (var run in tasks.Runs.Where(r => r.Parked && r.ConversationId is not null && r.State == TaskRunState.Ended && r.AgentId == plan.AgentId
      && r.AccountId == plan.AccountId && r.ContextSignature == plan.ContextSignature && r.Efficiency?.ReuseContext == true)
      .OrderByDescending(r => r.CompletedAt))
    {
      if (tasks.Tasks.FirstOrDefault(t => t.Id == run.TaskId)?.ProjectId != plan.ProjectId || !Path.GetFullPath(run.ExecutionFolder ?? run.Folder).Equals(Path.GetFullPath(plan.Folder), StringComparison.OrdinalIgnoreCase)) continue;
      if (terminals.Any(s => s.State != SessionState.Exited && s.Definition.ConversationId == run.ConversationId)
        || chats.Any(c => !c.Ended && c.ConversationId == run.ConversationId)) continue;
      if (run.Mode == "chat")
      {
        var source = chats.FirstOrDefault(c => c.Definition.Id == run.SessionId);
        if (source is not { Ended: true, Busy: false } || source.AccountRevision != 0 || source.ConversationId != run.ConversationId
          || source.Definition.Provider != plan.Provider || source.Definition.AccountId != plan.AccountId) continue;
      }
      else
      {
        var source = terminals.FirstOrDefault(s => s.Definition.Id == run.SessionId);
        if (source is not { State: SessionState.Exited } || source.AccountRevision != 0 || source.Definition.ConversationId != run.ConversationId
          || source.Definition.Provider != plan.Provider || source.Definition.AccountId != plan.AccountId) continue;
      }
      return run.ConversationId;
    }
    return null;
  }
}
