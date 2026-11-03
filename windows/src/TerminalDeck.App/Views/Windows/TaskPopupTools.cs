using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private object? TaskPopupSnapshot(McpCallContext context)
  {
    if (tasksPage?.Model.Selected is not { } task || !context.Has("tasks", task.Id) || !context.Has("projects", task.ProjectId) || task.Folder.Length > 0 && !context.Has("folders", task.Folder)) return null;
    var model = tasksPage.Model;
    return new { taskId = task.Id, expanded = tasksPage.PopupExpanded, threadOpen = model.TaskThreadOpen,
      threadPane = model.ThreadPane, hideEmptyFields = model.HideEmptyFields, search = model.ThreadSearch, activityCategory = model.ActivityCategory };
  }
  private void ApplyTaskPopup(McpCallContext context, JsonElement args)
  {
    if (tasksPage is null) throw new McpRefusal("Tasks are not connected yet.");
    var id = args.TryGetProperty("taskId", out var selected) ? selected.ValueKind == JsonValueKind.Null ? null : selected.GetString() : tasksPage.Model.SelectedId;
    if (id is not null)
    {
      var task = Runtime.Tasks.Get(id, includeTrash: true); context.Require("tasks", id); context.Require("projects", task.ProjectId);
      if (task.Folder.Length > 0) context.Require("folders", task.Folder);
    }
    var model = tasksPage.Model;
    Model.Page = ViewModels.ShellPage.Tasks;
    if (args.TryGetProperty("taskId", out _)) model.Select(id);
    if (args.TryGetProperty("expanded", out var expanded)) tasksPage.SetPopupExpanded(expanded.GetBoolean());
    if (args.TryGetProperty("threadOpen", out var thread)) model.TaskThreadOpen = thread.GetBoolean();
    if (args.TryGetProperty("threadPane", out var pane)) model.ThreadPane = pane.GetString()!;
    if (args.TryGetProperty("hideEmptyFields", out var hide)) model.HideEmptyFields = hide.GetBoolean();
    if (args.TryGetProperty("search", out var query)) { model.ThreadSearch = query.GetString()!; model.ThreadSearchOpen = true; }
    if (args.TryGetProperty("activityCategory", out var category)) model.ActivityCategory = category.GetString()!;
    model.PresentationChanged();
  }
}
