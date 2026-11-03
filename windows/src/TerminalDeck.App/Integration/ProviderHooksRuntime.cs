using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

public sealed record HookAccountStatus(string AccountId, string Name, string Provider, ProviderHookStatus Status);
public sealed partial class AppRuntime
{
  private ProviderHooksHost? providerHookHost;
  public ConcurrentDictionary<string, ProviderHookEvent> HookSessionEvents { get; } = new();
  private ProviderHooksHost HookHost
  {
    get
    {
      if (providerHookHost is null)
      {
        providerHookHost = new(Root);
        providerHookHost.Received += observation =>
        {
          // A working-directory match alone is ambiguous and never transfers
          // status to some other session using the same project.
          var terminals = Sessions.Where(s => s.Definition.Provider == observation.Provider &&
            (s.Definition.Id == observation.SessionId || observation.ConversationId is not null && s.Definition.ConversationId == observation.ConversationId)).ToArray();
          var chats = Chats.List().Where(c => c.Definition.Provider == observation.Provider &&
            (c.Definition.Id == observation.SessionId || observation.ConversationId is not null && c.ConversationId == observation.ConversationId)).ToArray();
          var ids = terminals.Select(s => s.Definition.Id).Concat(chats.Select(c => c.Definition.Id)).Distinct().ToArray();
          if (ids.Length != 1) return;
          HookSessionEvents[ids[0]] = observation; Changed?.Invoke();
          // The AI says this terminal is in another conversation now (/clear, /resume):
          // the keeper saves it, so a restart resumes that one.
          if (terminals.Length == 1 && terminals[0].Definition.Id == observation.SessionId && terminals[0].Definition.Purpose is null &&
              observation.ConversationId is { } conversation && Guid.TryParse(conversation, out _) && conversation != terminals[0].Definition.ConversationId)
            _ = FollowTerminalConversationAsync(terminals[0].Definition.Id, conversation);
          if (phoneRoutines is not null)
          {
            var routineFolder = terminals.FirstOrDefault()?.Definition.Cwd ?? chats.FirstOrDefault()?.Definition.Cwd;
            if (routineFolder is not null)
            {
              Routines.ObserveSession(ids[0], routineFolder, observation.Event is "UserPromptSubmit" or "BeforeAgent" or "PreToolUse" or "PostToolUse" or "BeforeTool" or "AfterTool", observation.Event == "SessionEnd");
              if (observation.Event is "Stop" or "AfterAgent") _ = TriggerRoutineEventAsync("session-finished", routineFolder);
              else if (observation.Event == "StopFailure") _ = TriggerRoutineEventAsync("session-failed", routineFolder);
              else if (observation.Event is "Notification" or "PermissionRequest") _ = TriggerRoutineEventAsync("alert", routineFolder, "warning");
            }
          }
          if (Notifications is not null)
          {
            var waiting = observation.Event is "Notification" or "PermissionRequest";
            var busy = observation.Event is "UserPromptSubmit" or "PreToolUse" or "PostToolUse" or "BeforeAgent" or "BeforeTool" or "AfterTool";
            _ = ObserveDesktopNoticeAsync(new(ids[0], terminals.FirstOrDefault()?.Definition.Title ?? chats.FirstOrDefault()?.Definition.Title ?? "Session", busy, waiting));
          }
          if (observation.Event is "Notification" or "PermissionRequest") _ = SendPhoneNoticeAsync(new("needs-you", ids[0], observation.Provider, "Session", observation.Folder ?? ""));
          else if (observation.Event is "Stop" or "AfterAgent") _ = SendPhoneNoticeAsync(new("finished", ids[0], observation.Provider, "Session", observation.Folder ?? ""));
        };
      }
      return providerHookHost;
    }
  }
  private async Task FollowTerminalConversationAsync(string id, string conversation)
  {
    try { using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10)); await Keeper.UpdateConversationAsync(id, conversation, deadline.Token); }
    catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException or InvalidOperationException or ArgumentException) { }
  }
  private ProviderHooks HookOwner(string accountId)
  {
    var account = Accounts.Get(accountId);
    var home = new WindowsProviderLaunchPlanner(Root, WindowsProviderLaunchPlanner.BundledToolsDirectory).AccountHome(account.Provider, account.HomeId);
    return HookHost.ForHomes(new Dictionary<string, string> { [account.Provider] = home });
  }
  public HookAccountStatus[] ProviderHookStatuses() => Accounts.List().Where(a => a.Provider is "claude" or "codex" or "gemini").Select(a =>
  {
    try { return new HookAccountStatus(a.Id, a.Name, a.Provider, HookOwner(a.Id).Status(a.Provider)); }
    catch (Exception e) when (e is IOException or InvalidOperationException or ArgumentException or UnauthorizedAccessException)
    { return new(a.Id, a.Name, a.Provider, new(a.Provider, "", false, "error", [], ProviderHooks.Events[a.Provider], 0, null, "This account's settings are unavailable in this app copy.")); }
  }).ToArray();
  public ProviderHookStatus ChangeProviderHooks(string accountId, bool install)
  {
    var account = Accounts.Get(accountId); var owner = HookOwner(accountId);
    var result = install ? owner.Install(account.Provider) : owner.Remove(account.Provider); Changed?.Invoke(); return result;
  }
  private void InitializeProviderHooks()
  {
    _ = HookHost;
    Door.Register("hooks.status", (context, args, ct) => { context.Require("settings", "hooks"); return ValueTask.FromResult(JsonSerializer.SerializeToElement(ProviderHookStatuses().Where(s => context.Has("accounts", s.AccountId)))); });
    Door.Register("hooks.change", async (context, args, ct) =>
    {
      context.Require("settings", "hooks"); var account = args.GetProperty("accountId").GetString()!; context.Require("accounts", account);
      await context.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(ChangeProviderHooks(account, args.GetProperty("install").GetBoolean()));
    });
  }
  private PhonePanelOwner PhoneHooksPanel() => new("hooks", true, (device, request, ct) =>
    ValueTask.FromResult(Panel("Session updates", new JsonArray(ProviderHookStatuses().Select(row => (JsonNode)new JsonObject { ["id"] = row.AccountId, ["title"] = row.Name + " · " + row.Provider,
      ["value"] = row.Status.State, ["detail"] = row.Status.Message, ["actions"] = row.Status.State == "error" ? new JsonArray() : new JsonArray(PanelAction("install", "Install or repair"), PanelAction("remove", "Remove app hooks")) }).ToArray()))),
    async (device, request, ct) => { await RequirePhoneCurrentAsync(device, ct); ChangeProviderHooks(PanelText(request, "id")!, PanelText(request, "action") == "install"); });
}
