using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.ProjectsAgents.Tests;

internal sealed class Fixture : IDisposable
{
  public string Directory { get; } = Path.Combine(Path.GetTempPath(), "td-projects-agents-" + Guid.NewGuid().ToString("N"));
  public AppDataRoot Root { get; }
  public ProjectService Projects { get; }
  public AgentService Agents { get; }
  public AccountService Accounts { get; }
  public CaptureGateway Gateway { get; } = new();
  public ExampleProvider[] Providers { get; }
  public PictureStore Pictures { get; } = new();
  public string Home { get; }
  public Fixture()
  {
    System.IO.Directory.CreateDirectory(Directory); Root = AppDataRoot.Explicit(Path.Combine(Directory, "data"));
    Home = Path.Combine(Directory, "work"); System.IO.Directory.CreateDirectory(Home);
    Projects = new(new JsonStateStore<ProjectState>(Root, "projects"), new LocalProjectFolders(Root), Pictures);
    Providers = [new("claude"), new("codex"), new("gemini")];
    Accounts = new(new JsonStateStore<AccountState>(Root, "accounts"), Providers);
    Agents = new(new JsonStateStore<AgentState>(Root, "agents"), Projects, new AgentInstructions(Root), Accounts, Gateway);
  }
  public static async Task<Fixture> ReadyAsync()
  {
    var f = new Fixture();
    foreach (var provider in f.Providers)
    {
      var a = await f.Accounts.CreateAsync(provider.Provider, provider.Provider + " example");
      await f.Accounts.RefreshAsync(a.Id); await f.Accounts.SetDefaultAsync(provider.Provider, a.Id);
    }
    f.Projects.Save(new("sample", "Sample project", [f.Home])); return f;
  }
  public SavedAgent Agent(string id = "reviewer", string? role = null) => Agents.Save(new(id, id, "codex", "Reviews changes", "example-model", "high", "sample", role ?? id, Skills: ["review"]));
  public AgentService ReloadAgents() => new(new JsonStateStore<AgentState>(Root, "agents"), Projects, new AgentInstructions(Root), Accounts, Gateway);
  public ProjectService ReloadProjects() => new(new JsonStateStore<ProjectState>(Root, "projects"), new LocalProjectFolders(Root), Pictures);
  public void Dispose() => System.IO.Directory.Delete(Directory, true);
}
internal sealed class CaptureGateway : IAgentSessionGateway
{
  public List<AgentLaunchPlan> Plans { get; } = [];
  public bool LoseReply { get; set; }
  public ValueTask<AgentSessionStarted> StartAsync(AgentLaunchPlan plan, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested(); Plans.Add(plan);
    if (LoseReply) throw new IOException("SYNTHETIC_PRIVATE_VALUE");
    return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode));
  }
}
internal sealed class ExampleProvider(string provider) : IAccountProvider
{
  public string Provider => provider;
  public bool SignedIn { get; set; } = true;
  public Func<CancellationToken, Task>? WaitForStatus { get; set; }
  public async ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken cancellationToken)
  {
    if (WaitForStatus is not null) await WaitForStatus(cancellationToken);
    return new(SignedIn, SignedIn ? account.Id + "@example.invalid" : null);
  }
  public ValueTask SignInAsync(AccountProfile a, string folder, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask SignOutAsync(AccountProfile a, CancellationToken ct) => ValueTask.CompletedTask;
  public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile a, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
}
internal sealed class PictureStore : IProjectPictures
{
  public List<string> Removed { get; } = [];
  public string Adopt(string projectId, string source) => source == "bad" ? throw new ArgumentException("Choose a picture.") : projectId + "-picture.png";
  public string? PathFor(string name) => name.Length == 0 ? null : "/scratch/" + name;
  public void Discard(string name) => Removed.Add(name);
}
internal sealed class MemoryStore<T>(T? initial = default) : IStateStore<T>
{
  public T? State { get; private set; } = initial;
  public bool Fail { get; set; }
  public T? Load() => State;
  public void Save(T value) { if (Fail) throw new IOException("Save unavailable."); State = value; }
}
