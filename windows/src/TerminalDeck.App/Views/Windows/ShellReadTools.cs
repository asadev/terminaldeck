using System.Text.Json;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private void RegisterShellReadTools()
  {
    Runtime.Door.Register("shell.read", async (context, args, ct) =>
    {
      context.Require("settings", "workspace");
      var kind = args.GetProperty("kind").GetString();
      var query = args.TryGetProperty("query", out var q) ? q.GetString() ?? "" : "";
      object result;
      switch (kind)
      {
        case "commands": result = ShellCommands.Matching(query); break;
        case "sidebar": result = SidebarSnapshot(context); break;
        case "quick-files":
          var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder);
          folder = WorkspaceFiles.ResolveFolder(folder); context.Require("folders", folder);
          result = await Task.Run(() => WorkspaceFiles.Find(folder, query, ct), ct); break;
        case "session-search":
          result = await Task.Run(() => SearchTranscripts(query, id => context.Has("sessions", id) && (Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id) is not { } chat || context.Has("accounts", chat.Definition.AccountId)), ct).ToArray(), ct); break;
        case "inspector":
          var id = args.GetProperty("sessionId").GetString()!; context.Require("sessions", id);
          if (Runtime.Chats.List().FirstOrDefault(c => c.Definition.Id == id) is { } chat) context.Require("accounts", chat.Definition.AccountId);
          result = InspectorSnapshot(id); break;
        default: throw new McpRefusal("Choose a listed shell read.");
      }
      return JsonSerializer.SerializeToElement(result);
    });
  }
  private async Task ApplyShellCommandAsync(McpCallContext context, string command, CancellationToken ct)
  {
    context.Require("settings", "workspace"); await context.EnsureCurrentAsync(ct);
    var tab = FocusedTab();
    if (tab is not null && command is "split" or "one-pane" or "inspector" or "actual-size" or "zoom-in" or "zoom-out" or "rename-session")
      if (!WindowAllowed(context, tab)) throw new McpRefusal("This view is outside this caller’s permission.");
    if (command == "quick-open")
    {
      var folder = tab is null ? Model.Selected?.Folder : WindowFolder(tab);
      if (string.IsNullOrEmpty(folder)) folder = Projects.Model.SelectedId is { } project ? Runtime.Projects.Get(project).HomeFolder : null;
      if (folder is null) throw new McpRefusal("Choose a granted session or project folder first.");
      context.Require("folders", folder); context.Require("folders", WorkspaceFiles.ResolveFolder(folder));
    }
    if (command == "swarm")
      foreach (var row in Model.Sessions.Where(row => row.State is not ("ended" or "exited") && !sidebar.Read.HiddenSessions.Contains(row.Id))) context.Require("sessions", row.Id);
    if (command is "exit" or "stop-exit")
      foreach (var row in Runtime.ProjectSessions()) context.Require("sessions", row.Id);
    if (command is "exit" or "stop-exit")
      foreach (var member in windowState.Tabs) if (!WindowAllowed(context, member)) throw new McpRefusal("Every open view must be within this caller’s permission.");
    if (command == "return-windows" && tab is not null)
      foreach (var member in windowState.Tabs.Where(member => member.Owner == tab.Owner)) if (!WindowAllowed(context, member)) throw new McpRefusal("Every returned view must be within this caller’s permission.");
    await RunShellCommandAsync(command, caller: context);
  }
}
