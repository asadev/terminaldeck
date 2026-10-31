namespace TerminalDeck.App.Views
{
  public sealed partial class ShellWindow
  {
    public Task RemoveFromSidebarAsync(string projectId) => RemoveSidebarProjectAsync(Runtime.Projects.Get(projectId));
    public async Task AssignTaskAsync(string projectId, string agentId)
    {
      Model.Page = TerminalDeck.App.ViewModels.ShellPage.Tasks;
      if (tasksPage is null) throw new InvalidOperationException("Tasks are still loading. Try again shortly.");
      await tasksPage.NewForAgentAsync(projectId, agentId);
    }
    private async void OpenCodingAis()
    {
      try { ShowSettingsPanel(); await settingsPanel!.SelectAsync("coding-ais"); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "Coding AIs could not open. Try again from Settings."; }
    }
  }
}
