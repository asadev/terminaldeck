using System.Collections.Concurrent;

namespace TerminalDeck.Platform.Windows.Accounts;

// Listen only while the person's own login terminal is open. File contents and
// browser URLs never pass through this observer; the provider confirms status.
internal sealed class WindowsSignInWatch : IDisposable
{
  private readonly ConcurrentDictionary<string, FileSystemWatcher> watchers = [];
  public IDisposable Begin(string account, string home, Func<Task<bool>> completed)
  {
    Directory.CreateDirectory(home);
    var watcher = new FileSystemWatcher(home) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size };
    if (watchers.TryRemove(account, out var previous)) previous.Dispose();
    watchers[account] = watcher;
    var pending = 0; var revision = 0; var checkedRevision = 0;
    async void Changed(object sender, FileSystemEventArgs args)
    {
      if (Path.GetFileName(args.FullPath) is not ("auth.json" or ".credentials.json" or "oauth_creds.json" or "google_accounts.json" or "settings.json")) return;
      Interlocked.Increment(ref revision);
      if (Interlocked.Exchange(ref pending, 1) != 0) return;
      try
      {
        do
        {
          checkedRevision = Volatile.Read(ref revision);
          await Task.Delay(250);
          if (!watchers.TryGetValue(account, out var active) || active != watcher) return;
          if (await completed()) { if (Remove(account, watcher)) watcher.Dispose(); return; }
        } while (checkedRevision != Volatile.Read(ref revision));
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
      finally
      {
        Interlocked.Exchange(ref pending, 0);
        // A final credential write may arrive while status is being checked.
        // Keep that signal, including the race just before releasing pending.
        if (checkedRevision != Volatile.Read(ref revision) && watchers.TryGetValue(account, out var active) && active == watcher) Changed(sender, args);
      }
    }
    watcher.Changed += Changed; watcher.Created += Changed; watcher.Renamed += Changed;
    watcher.EnableRaisingEvents = true;
    _ = ExpireAsync(account, watcher);
    return new WatchLease(() => { if (Remove(account, watcher)) watcher.Dispose(); });
  }
  private async Task ExpireAsync(string account, FileSystemWatcher watcher)
  {
    await Task.Delay(TimeSpan.FromMinutes(15));
    if (Remove(account, watcher)) watcher.Dispose();
  }
  private bool Remove(string account, FileSystemWatcher watcher) =>
    ((ICollection<KeyValuePair<string, FileSystemWatcher>>)watchers).Remove(new(account, watcher));
  private sealed class WatchLease(Action end) : IDisposable
  {
    private int disposed;
    public void Dispose() { if (Interlocked.Exchange(ref disposed, 1) == 0) end(); }
  }
  public void Dispose()
  {
    foreach (var (id, watcher) in watchers.ToArray()) if (watchers.TryRemove(id, out _)) watcher.Dispose();
  }
}
