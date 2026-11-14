using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Views;

// The New session page (Mac: NativeLanding). Opening it, changing a choice or leaving it makes
// nothing; the session is made only by his send (StartFromPageAsync). The full form
// (NewSessionPicker) stays: "All choices…" on the page, and every caller that used it before.
public sealed partial class ShellWindow
{
  private NewSessionPage? newSessionPage;
  private readonly Dictionary<string, string> pendingChatDrafts = [];

  internal void OpenNewSessionPage(string? projectId = null)
  {
    var page = NewSessionView();
    Model.Page = ShellPage.NewSession;
    page.Arrive(projectId);
  }

  // "When Terminal Deck opens" (Settings > General). Proof and test runs keep their own start.
  private void OpenOnLaunch()
  {
    if (Environment.GetEnvironmentVariables().Keys.OfType<string>().Any(key => key.StartsWith("TD_", StringComparison.Ordinal) && key.Contains("PROOF", StringComparison.Ordinal))) return;
    if (OpensOn.ShowsNewSession(Runtime.General.Read().WhenOpens)) OpenNewSessionPage();
  }

  private NewSessionPage NewSessionView() => newSessionPage ??= new NewSessionPage(new(
    NewSessionWorldNow,
    id => id == ProjectIdentity.IndependentId ? "No project" : Runtime.Projects.List().FirstOrDefault(p => p.Id == id)?.Name ?? "No project",
    id => Runtime.Agents.List().FirstOrDefault(a => a.Id == id)?.Name ?? "Agent",
    provider => Runtime.Accounts.List(provider),
    (provider, account) => Runtime.Accounts.InstantModels(provider, account).Models,
    async (account, ct) => (await Runtime.Accounts.ModelsAsync(account, cancellationToken: ct)).Models,
    PageModelAndEffort,
    PagePermission,
    provider => provider == "shell" ? NewSessionPicker.Services?.ShellLabel?.Invoke() ?? "PowerShell" : TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider),
    StartFromPageAsync,
    PageStarted,
    projectId => _ = ShowFullNewSessionFormAsync(projectId),
    OpenCodingAis,
    () => WindowHandle,
    () => Ready), new NewSessionMemory(dataRoot), null);

  private NewSessionWorld NewSessionWorldNow()
  {
    var projects = Runtime.Projects.List().Where(p => p.IsOpen && p.Id != ProjectIdentity.IndependentId).OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    var leads = projects.ToDictionary(p => p.Id, p => p.Lead);
    var agents = Runtime.Agents.List().Where(a => a.Status == TerminalDeck.Core.Agents.SavedAgentStatus.Active)
      .Select(a => new NewSessionAgent(a.Id, a.Name, a.ProjectId, a.Provider, leads.GetValueOrDefault(a.ProjectId) == "agent:" + a.Id)).ToArray();
    return new(projects.Select(p => p.Id).ToArray(), agents, ["claude", "codex", "gemini", "shell"],
      provider => Runtime.Accounts.List(provider).Select(a => a.Id).ToArray(), provider => Runtime.Accounts.Default(provider)?.Id, Runtime.General.Read().DefaultProvider);
  }

  // What will start, so what the line under the box shows is what starts: an agent's own model and
  // effort win (shown, not changeable here); otherwise his pick, else "New sessions start with".
  private (string Model, string? Effort, bool OwnedByAgent) PageModelAndEffort(NewSessionStart start)
  {
    if (!NewSessionPresets.CanChat(start.Provider)) return ("", null, false);
    var launch = TerminalDeck.Core.Settings.LaunchDefaults.For(start.Provider, Runtime.General.Read());
    var agent = start.AgentId is { } id ? Runtime.Agents.List().FirstOrDefault(a => a.Id == id) : null;
    if (agent is not null && (agent.Model.Length > 0 || agent.Effort is not ("" or "auto")))
      return (agent.Model.Length > 0 ? agent.Model : launch.Model, agent.Effort is "" or "auto" ? launch.Effort : agent.Effort, true);
    return (start.Model ?? launch.Model, start.Effort ?? launch.Effort, false);
  }

  // "Before it changes files": the mode this start really uses (the agent's or project's own, else
  // Settings > General's mode for new chats). Shown, not chosen, on the page; sent by name.
  private AiPermissionMode? PagePermission(NewSessionStart start)
  {
    if (!NewSessionPresets.CanChat(start.Provider)) return null;
    var agent = start.AgentId is { } id ? Runtime.Agents.List().FirstOrDefault(a => a.Id == id) : null;
    var project = Runtime.Projects.List().FirstOrDefault(p => p.Id == start.ProjectId);
    var projectDefault = project is not null && project.Preferences.Text("defaultPermission") is "ask" or "plan" or "auto" ? project.Preferences.Text("defaultPermission") : null;
    var mode = TerminalDeck.Core.Agents.AgentOptions.ToMode(agent?.Settings.PermissionMode ?? projectDefault) ?? Runtime.General.NewChatPermission(start.Provider);
    return ChatPermissionModes.Supported(start.Provider).Contains(mode) ? mode : ChatPermissionModes.DefaultFor(start.Provider);
  }

  private async Task<string> StartFromPageAsync(NewSessionStart start, string text, IReadOnlyList<NewSessionFile> files, CancellationToken ct)
  {
    // No project, or a project whose folder is gone: "Terminal Deck\Independent" in the home folder.
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var project = Runtime.Projects.List().FirstOrDefault(p => p.Id == start.ProjectId && p.IsOpen && p.HomeFolder is { } own && Directory.Exists(own));
    var folder = project?.HomeFolder ?? NewSessionSend.IndependentFolder(home);
    var projectId = project?.Id ?? ProjectIdentity.IndependentId;
    Directory.CreateDirectory(folder);
    if (start.Provider == "shell")
    {
      var row = await Runtime.StartShellForProjectAsync(folder, projectId);
      if (text.Trim().Length > 0) await Runtime.SendAsync(row.Definition.Id, text.TrimEnd() + "\r");
      return row.Definition.Id;
    }
    var terminal = start.Mode == "terminal";
    // A terminal (or an agent) starts signed in, as the full form does; a plain chat shows its own Sign in.
    if ((terminal || start.AgentId is not null) && start.AccountId is { } accountId)
    {
      var current = await Runtime.Accounts.RefreshAsync(accountId, ct);
      if (!current.SignedIn)
      {
        await Runtime.Accounts.SignInAsync(current.Id, folder, ct);
        current = await Runtime.Accounts.RefreshAsync(current.Id, ct);
        if (!current.SignedIn) throw new InvalidOperationException("Not signed in. Your message and choices are kept here.");
      }
    }
    var shown = PageModelAndEffort(start);
    // Terminal: the first message is the AI's own starting prompt; photo paths go after the words.
    var first = terminal && files.Count > 0 ? (text.TrimEnd() + " " + string.Join(" ", files.Select(f => "\"" + f.Path + "\""))).Trim() : text;
    if (terminal && first.Length > 4000) throw new ArgumentException("A Terminal start takes up to 4,000 characters. Shorten the message or switch to Chat.");
    var run = await Runtime.Agents.StartAsync(new(start.AgentId, projectId, folder, start.Provider, start.AccountId, start.Mode, terminal ? first : "",
      Model: shown.Model, Effort: start.Provider == "gemini" ? "auto" : shown.Effort, Permission: PagePermission(start)), ct);
    if (!terminal)
    {
      // If the first message cannot be handed over, it waits in that chat's own box.
      try
      {
        var media = new List<ChatMedia>();
        foreach (var file in files) media.Add(await Runtime.Chats.AddImageAsync(run.SessionId, file.Image.Name, file.Image.MimeType, file.Image.Bytes, file.Image.Width, file.Image.Height, ct));
        await Runtime.Chats.SendAsync(run.SessionId, Guid.NewGuid().ToString(), text, media.Count > 0 ? media.ToArray() : null, ct);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { pendingChatDrafts[run.SessionId] = text; }
    }
    return run.SessionId;
  }

  // Shown if he is still on the page; if he went elsewhere meanwhile it only appears in the side panel.
  private async void PageStarted(string id)
  {
    if (Model.Page == ShellPage.NewSession) { OpenSession(id); return; }
    try { await Runtime.RefreshSessionsAsync(); SyncSessions(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "The new session started. Find it in the side panel."; }
  }

  // The full New session form, as before.
  private async Task ShowFullNewSessionFormAsync(string? projectId)
  {
    try
    {
      await NewSessionPicker.ShowAsync(Root.XamlRoot, Runtime.Agents, Runtime.Projects, Runtime.Accounts, this, projectId,
        terminalStart: async (folder, project) => { var row = await Runtime.StartShellForProjectAsync(folder, project); OpenSession(row.Definition.Id); });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException ? ex.Message : "The new session picker could not open."; }
  }
}
