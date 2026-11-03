namespace TerminalDeck.Core.Hoot;

public sealed partial class HootRoutines
{
  public ValueTask StopAsync(string id, CancellationToken ct = default)
  {
    ct.ThrowIfCancellationRequested();
    lock (gate)
    {
      if (!state.Routines.Any(r => r.Id == id)) throw new ArgumentException("Choose a saved routine.");
      if (active.TryGetValue(id, out var current)) current.Cancel();
      Update(id, r => r with { Runs = r.Runs.Select(run => run.State == "queued" ? run with { State = "stopped", Problem = "Stopped by the person." } : run).ToArray() });
      Schedule();
    }
    return ValueTask.CompletedTask;
  }
  public void KeepUnconfirmed(string id)
  {
    lock (gate)
    {
      if (!state.Routines.Any(r => r.Id == id)) throw new ArgumentException("Choose a saved routine.");
      Update(id, r => r with { RecoveryHold = false, Problem = "Earlier unconfirmed work was kept without resending.", NextAt = r.Enabled ? NextDue(r, clock.GetUtcNow()) : null,
        Runs = r.Runs.Select(run => run.State == "queued" ? run with { State = "stopped", Problem = "Kept without resending after recovery." } : run).ToArray() });
      Schedule();
    }
  }
}
