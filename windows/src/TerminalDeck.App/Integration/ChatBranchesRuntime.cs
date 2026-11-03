using System.Text.Json;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private ChatBranchService? chatBranches;
  private ChatBranchService ChatBranches => chatBranches ??= new(Root, new JsonStateStore<ChatWorktreeState>(Root, "chat-worktrees"), () => Chats,
    new WindowsChatFork(Root, TerminalDeck.Platform.Windows.WindowsProviderLaunchPlanner.BundledToolsDirectory).ForkCodexAsync,
    () => Sessions.Where(s => s.State != SessionState.Exited).Select(s => s.Definition.Cwd).Concat(Chats.List().Where(c => !c.Ended).Select(c => c.Definition.Cwd)).ToArray());
  private void InitializeChatBranches()
  {
    ChatBranchActions.Invoke = (parent, action, arguments, ct) => ChatBranchAsync(parent, action, arguments, ct);
    Door.Register("sessions.chat_fork", async (context, arguments, ct) =>
    {
      var id = arguments.GetProperty("sessionId").GetString()!; context.Require("sessions", id);
      var parent = Chats.Get(id); context.Require("folders", parent.Definition.Cwd);
      var action = arguments.GetProperty("do").GetString()!;
      if (action is "fork" or "worktree-chat" or "worktree-remove")
      {
        if (context.Grant.DeviceId is not null || !context.Grant.Attended) throw new McpRefusal("Forking a local chat or changing its worktree needs the person on this PC.");
        context.Require("accounts", parent.Definition.AccountId);
      }
      await context.EnsureCurrentAsync(ct);
      var result = await ChatBranchAsync(id, action, arguments, ct, context);
      if (result.TryGetProperty("session", out var chat) && chat.TryGetProperty("id", out var started)) context.NoteSessionStarted(started.GetString()!);
      return result;
    });
  }
  private async Task<JsonElement> ChatBranchAsync(string id, string action, JsonElement arguments, CancellationToken ct, McpCallContext? context = null)
  {
    var parent = await Chats.ReadAsync(id, ct);
    string? Text(string name) => arguments.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    switch (action)
    {
      case "location": return JsonSerializer.SerializeToElement(new { machine = Environment.MachineName, executionLocation = "this-pc", provider = parent.Definition.Provider, folder = parent.Definition.Cwd, accountId = parent.Definition.AccountId, conversationId = parent.ConversationId, worktrees = ChatBranches.Worktrees(id), canFork = parent.Definition.Provider is "claude" or "codex", canForkIntoWorktree = parent.Definition.Provider == "codex", sameAccountRequired = true }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
      case "worktree-status": return JsonSerializer.SerializeToElement(await ChatBranches.StatusAsync(id, Text("session") ?? id, ct));
      case "worktree-remove":
        if (context is not null) await context.EnsureCurrentAsync(ct);
        await ChatBranches.RemoveAsync(id, Text("session") ?? id, ct, context is null ? null : context.EnsureCurrentAsync); return JsonSerializer.SerializeToElement(new { removed = true, branchKept = true });
      case "fork": case "worktree-chat":
        var account = await Accounts.RequireSignedInAsync(parent.Definition.AccountId, ct);
        if (account.HomeId != parent.Definition.AccountHome) throw new InvalidOperationException("This chat's login home changed. Reconnect or switch its account before forking; no other account was substituted.");
        if (context is not null) await context.EnsureCurrentAsync(ct);
        var result = await ChatBranches.CreateAsync(id, action == "fork", action == "worktree-chat" || arguments.TryGetProperty("worktree", out var own) && own.ValueKind == JsonValueKind.True, Text("throughTurn"), Text("title"), ct, context is null ? null : context.EnsureCurrentAsync);
        var project = Projects.Resolve(null, parent.Definition.Cwd); Projects.BindSession(result.Chat.Definition.Id, project); await RefreshSessionsAsync();
        return JsonSerializer.SerializeToElement(new { session = ChatMcpTools.View(result.Chat), action, parentSessionId = id, conversationId = result.Chat.ConversationId, parentConversationId = parent.ConversationId, forked = result.Forked, confirmed = result.Confirmed, folder = result.Chat.Definition.Cwd, worktree = result.Worktree, branchSafe = result.Worktree, executionLocation = "this-pc", warning = result.Warning });
      default: throw new ArgumentException("Choose fork, worktree-chat, worktree-status, worktree-remove or location.");
    }
  }
}
