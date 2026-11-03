namespace TerminalDeck.Core.Projects;

// Name writes are ordered and conditional on the last observed saved name. A
// folder/account update does not conflict with a name edit or get overwritten.
public sealed class ProjectNameEditor(Func<string, string, string> save, string initial) : IDisposable
{
  private readonly object gate = new();
  private readonly SemaphoreSlim writer = new(1);
  private CancellationTokenSource? pending;
  private bool disposed;
  public string Draft { get; private set; } = initial;
  public string Saved { get; private set; } = initial;
  private string observed = initial;
  public bool Conflict { get; private set; }
  public bool Saving { get; private set; }
  public string Error { get; private set; } = "";
  public bool Dirty => Draft != Saved;
  public event Action? Changed;
  public void Edit(string text)
  {
    CancellationTokenSource? delay = null;
    lock (gate)
    {
      if (disposed) return;
      Draft = text; Error = ""; pending?.Cancel();
      if (!Conflict) pending = delay = new();
    }
    Changed?.Invoke(); if (delay is not null) _ = LaterAsync(delay);
  }
  private async Task LaterAsync(CancellationTokenSource delay)
  {
    try { await Task.Delay(300, delay.Token); if (!delay.IsCancellationRequested) await FlushAsync(); }
    catch (OperationCanceledException) { }
    finally { lock (gate) { if (ReferenceEquals(pending, delay)) pending = null; delay.Dispose(); } }
  }
  public void Observe(string name)
  {
    lock (gate)
    {
      observed = name; if (Saving || disposed) return;
      if (!Dirty) { Saved = Draft = name; Conflict = false; Error = ""; }
      else if (Saved != name) { pending?.Cancel(); Conflict = true; Error = "The project name changed elsewhere. Choose Keep mine or Use saved."; }
    }
    Changed?.Invoke();
  }
  public void UseSaved()
  {
    lock (gate) { pending?.Cancel(); Saved = Draft = observed; Conflict = false; Error = ""; }
    Changed?.Invoke();
  }
  public void KeepMine()
  {
    string draft; lock (gate) { Saved = observed; Conflict = false; draft = Draft; }
    Edit(draft);
  }
  public async Task<bool> FlushAsync()
  {
    lock (gate) pending?.Cancel();
    await writer.WaitAsync();
    string draft; string expected;
    try
    {
      lock (gate)
      {
        if (disposed || Conflict) return false;
        draft = Draft; expected = Saved; if (draft == expected) return true;
        Saving = true; Error = "";
      }
      Changed?.Invoke();
      try
      {
        var name = save(draft, expected);
        lock (gate) { Saved = observed = name; if (Draft == draft) Draft = name; Error = ""; }
      }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      {
        lock (gate) { Error = ex is ArgumentException or InvalidOperationException ? ex.Message : "The project name could not be saved. Check the folder is available, then try again."; if (ex is InvalidOperationException) Conflict = true; }
        return false;
      }
      return !Dirty;
    }
    finally { lock (gate) Saving = false; writer.Release(); Changed?.Invoke(); }
  }
  public void Dispose() { lock (gate) { disposed = true; pending?.Cancel(); Changed = null; } }
}
