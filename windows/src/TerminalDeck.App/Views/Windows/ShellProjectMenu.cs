using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Projects;
using Windows.Storage;
using Windows.System;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private MenuFlyout ProjectMenu(Project project)
  {
    var menu = new MenuFlyout();
    void Add(string label, Func<Task> action)
    {
      var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) =>
      { try { await action(); } catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = ex is ArgumentException or InvalidOperationException ? ex.Message : "The project action could not finish. Check the folder and try again."; } }; menu.Items.Add(item);
    }
    Add("New session here", () => { OpenNewSessionPage(project.Id); return Task.CompletedTask; });
    Add("Project settings…", () => { Projects.OpenProject(project.Id, "Settings"); Model.Page = ViewModels.ShellPage.Projects; return Task.CompletedTask; });
    Add("Show in Explorer", async () =>
    {
      if (project.HomeFolder is null) throw new InvalidOperationException("This project has no home folder.");
      var folder = await StorageFolder.GetFolderFromPathAsync(project.HomeFolder);
      if (!await Launcher.LaunchFolderAsync(folder)) throw new InvalidOperationException("Explorer could not open this project folder.");
    });
    Add("Choose logo…", () => Projects.ChooseLogoAsync(project.Id));
    menu.Items.Add(new MenuFlyoutSeparator()); Add("Remove from sidebar", () => RemoveSidebarProjectAsync(project));
    return menu;
  }
  private async Task RemoveSidebarProjectAsync(Project project)
  {
    var members = SidebarProjectSessions(project.Id);
    var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = "Remove “" + project.Name + "” from sidebar?",
      Content = "This closes this project’s sessions and removes its sidebar entry. Project files and saved conversation history stay on disk.", PrimaryButtonText = "Remove from sidebar", CloseButtonText = "Keep it", DefaultButton = ContentDialogButton.Close };
    if (await ShowShellDialogAsync(dialog) != ContentDialogResult.Primary) return;
    await CloseSidebarProjectAsync(project, members);
  }
  private TerminalDeck.Core.Projects.ProjectSession[] SidebarProjectSessions(string id) => Runtime.Projects.GroupSessions(Runtime.ProjectSessions())
    .Where(group => group.ProjectId == id).SelectMany(group => group.Sessions)
    .Where(s => Model.Sessions.Any(row => row.Id == s.Id)).ToArray();
  private async Task CloseSidebarProjectAsync(Project project, TerminalDeck.Core.Projects.ProjectSession[] members, Func<Task>? beforeEach = null)
  {
    // Do not hide the project until every process acknowledges the close.
    foreach (var member in members)
    {
      if (beforeEach is not null) await beforeEach();
      if (member.Mode == "chat") await Runtime.Chats.EndAsync(member.Id);
      else if (member.Status.ToLowerInvariant() is not ("exited" or "ended")) await Runtime.StopAsync(member.Id);
      foreach (var page in browser.Core.Read().Tabs.Where(page => page.SessionId == member.Id)) await browser.Core.AttachAsync(page.Id, null);
      sidebar.HideSession(member.Id, true);
      if (windowState.Tabs.Any(t => t.Id == member.Id)) windowState.Close(member.Id);
    }
    if (beforeEach is not null) await beforeEach();
    Runtime.Projects.SetOpen(project.Id, false); browser.ObserveShellPages(); SyncSessions();
  }
  private void RegisterProjectRemovalTool()
  {
    Runtime.Door.Compose("projects.remove", _ => async (context, args, ct) =>
    {
      var path = args.GetProperty("path").GetString()!; context.Require("folders", path);
      var project = Runtime.Projects.Get(Runtime.Projects.Resolve(null, path)); context.Require("projects", project.Id);
      if (project.Id == ProjectIdentity.IndependentId) throw new TerminalDeck.Core.Mcp.McpRefusal("Choose a named project from the sidebar.");
      var members = SidebarProjectSessions(project.Id);
      foreach (var member in members) context.Require("sessions", member.Id);
      await context.EnsureCurrentAsync(ct);
      await CloseSidebarProjectAsync(project, members, async () => await context.EnsureCurrentAsync(ct));
      return System.Text.Json.JsonSerializer.SerializeToElement(new { removed = true, closedSessions = members.Select(s => s.Id), filesKept = true });
    });
  }
}
