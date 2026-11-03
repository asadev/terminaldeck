using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Quality;

public sealed record DeploymentStep(string Id, string Name, string Tool, string State, string? Result = null, int? Passed = null, int? Failed = null);
public sealed record DeploymentRun(string Id, string ProjectId, string? SessionId, string Title, string Actor, DateTimeOffset UpdatedAt, DeploymentStep[] Steps);
public sealed record DeploymentLedger(int Version, DeploymentRun[] Runs);

// Only reported facts enter this ledger. It never starts a deployment or turns
// a successful build into an invented live/deployed state.
public sealed class Deployments(IStateStore<DeploymentLedger> store)
{
  private readonly object gate = new();
  private DeploymentLedger state = store.Load() ?? new(1, []);
  public event Action? Changed;
  public IReadOnlyList<DeploymentRun> Read(string? project = null, string? session = null)
  {
    lock (gate) return state.Runs.Where(r => (project is null || r.ProjectId == project) && (session is null || r.SessionId == session)).OrderByDescending(r => r.UpdatedAt).Select(r => r with { Steps = r.Steps.ToArray() }).ToArray();
  }
  public DeploymentRun Report(string project, string? session, string? id, string title, string actor, DeploymentStep[] steps)
  {
    if (string.IsNullOrWhiteSpace(project) || string.IsNullOrWhiteSpace(title) || title.Length > 160 || string.IsNullOrWhiteSpace(actor) || actor.Length > 160 || steps.Length is < 1 or > 100) throw new ArgumentException("Name the project, run, actor and 1–100 real steps.");
    if (steps.Select(s => s.Id).Distinct().Count() != steps.Length || steps.Any(s => string.IsNullOrWhiteSpace(s.Id) || s.Id.Length > 64 || string.IsNullOrWhiteSpace(s.Name) || s.Name.Length > 120 || s.Tool.Length > 120 || s.State is not ("waiting" or "running" or "done" or "failed" or "skipped") || s.Result?.Length > 2000 || s.Passed < 0 || s.Failed < 0)) throw new ArgumentException("Give each step its identity, real state and nonnegative counts.");
    DeploymentRun run;
    lock (gate)
    {
      if (id is not null && !state.Runs.Any(r => r.Id == id)) throw new ArgumentException("Choose a saved deployment run.");
      if (id is not null && state.Runs.Any(r => r.Id == id && (r.ProjectId != project || r.SessionId != session))) throw new ArgumentException("A deployment cannot move to another project or session.");
      run = new(id ?? Guid.NewGuid().ToString("N"), project, session, title, actor, DateTimeOffset.UtcNow, steps.ToArray());
      var next = new DeploymentLedger(1, state.Runs.Where(r => r.Id != run.Id).Prepend(run).Take(500).ToArray());
      store.Save(next); state = next;
    }
    Changed?.Invoke(); return run with { Steps = run.Steps.ToArray() };
  }
}
