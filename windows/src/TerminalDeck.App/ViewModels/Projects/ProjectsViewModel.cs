using System.ComponentModel;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.App.ViewModels.Projects;

public abstract class ProjectAgentViewModel : INotifyPropertyChanged
{
  private int busy;
  public bool IsBusy => Volatile.Read(ref busy) != 0;
  public string Message { get; private set; } = "";
  public bool IsError { get; private set; }
  public event Action? Changed;
  public event PropertyChangedEventHandler? PropertyChanged;
  public void Notice(string message, bool error = false) { Message = message; IsError = error; Refresh(); }
  public void Refresh() { PropertyChanged?.Invoke(this, new(null)); Changed?.Invoke(); }
  public async Task<bool> RunAsync(Func<Task> action, string success = "Saved.")
  {
    if (Interlocked.Exchange(ref busy, 1) != 0) return false;
    Message = "Saving…"; IsError = false; Refresh();
    try { await action(); Message = success; return true; }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or TerminalDeck.Core.Platform.ProviderUnavailableException) { Message = ex.Message; IsError = true; return false; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Message = "That change could not be saved. Check the folder is available, then try again."; IsError = true; return false; }
    finally { Volatile.Write(ref busy, 0); Refresh(); }
  }
  public Task<bool> RunAsync(Action action, string success = "Saved.") => RunAsync(async () => { await Task.Yield(); action(); }, success);
}

public sealed class ProjectsViewModel : ProjectAgentViewModel, IDisposable
{
  public IProjects Projects { get; }
  public IAgents Agents { get; }
  public AccountService? Accounts { get; }
  private readonly Func<IReadOnlyList<ProjectSession>> sessions;
  private string? selectedId;
  public string? SelectedId { get => selectedId; set { selectedId = value; Refresh(); } }
  public Project? Selected => SelectedId is { } id ? Projects.List().FirstOrDefault(p => p.Id == id) : null;
  public ProjectsViewModel(IProjects projects, IAgents agents, Func<IReadOnlyList<ProjectSession>> sessions, AccountService? accounts = null, bool autoLogos = true)
  {
    Projects = projects; Agents = agents; Accounts = accounts; this.sessions = sessions;
    projects.Changed += Refresh; agents.Changed += Refresh;
    if (autoLogos) { projects.Changed += QueueLogos; QueueLogos(); }
  }
  // Mac: every project shows its own picture. A project with none gets the first usable
  // logo, favicon or app icon found in its folders, once per folder set, off the UI thread.
  private readonly HashSet<string> scanned = new(StringComparer.Ordinal);
  private int scanning;
  public Task? LogoScan { get; private set; }
  private void QueueLogos()
  {
    if (disposed) return;
    string[] due;
    lock (scanned) due = Projects.List().Where(ProjectLogoAuto.Wanted).Select(p => p.Id + "|" + string.Join("|", p.Folders)).Where(k => !scanned.Contains(k)).ToArray();
    if (due.Length == 0 || Interlocked.Exchange(ref scanning, 1) != 0) return;
    LogoScan = Task.Run(() =>
    {
      try
      {
        foreach (var key in due)
        {
          if (disposed) return;
          lock (scanned) scanned.Add(key);
          try { ProjectLogoAuto.Fill(Projects, key[..key.IndexOf('|')]); }
          catch (Exception ex) when (ex is not OutOfMemoryException) { }
        }
      }
      finally { Volatile.Write(ref scanning, 0); }
      QueueLogos();
    });
  }
  private volatile bool disposed;
  public IReadOnlyList<Project> OpenProjects(string query = "") => Projects.List().Where(p => p.IsOpen && (p.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || p.Folders.Any(f => f.Contains(query, StringComparison.OrdinalIgnoreCase)))).ToArray();
  public IReadOnlyList<ProjectSessionGroup> Groups => Projects.GroupSessions(sessions());
  public IReadOnlyList<ProjectSession> SessionsFor(string id) => Groups.FirstOrDefault(g => g.ProjectId == id)?.Sessions.ToArray() ?? [];
  public IReadOnlyList<SavedAgent> AgentsFor(string id) => Agents.List().Where(a => a.ProjectId == id && a.Status != SavedAgentStatus.Archived).ToArray();
  public AgentActivity Activity(SavedAgent agent) => AgentActivity.For(agent, Agents.Runs(), sessions());
  public bool Leads(SavedAgent agent, Project project) => project.Lead == "agent:" + agent.Id;
  public ProjectSetupScore SetupFor(string id) => Projects.Setup(id, Agents.SetupAgents(), Agents.Seats().FirstOrDefault(s => s.SeatKey == "lead:" + id)?.Card ?? "");
  public void Dispose() { disposed = true; Projects.Changed -= Refresh; Projects.Changed -= QueueLogos; Agents.Changed -= Refresh; }
  public Task<bool> SaveValuesAsync(string id, IReadOnlyDictionary<string, JsonElement> values) => RunAsync(() => Projects.PatchSettings(id, values));
}
