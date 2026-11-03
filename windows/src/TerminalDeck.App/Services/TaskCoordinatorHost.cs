using System.Collections.Concurrent;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Services;

// Startup owns the file watcher, independently of which page is open. Each
// subscriber refreshes from the ledger; an event carries no cached task data.
public sealed class TaskCoordinatorHost : IDisposable
{
  private static readonly ConcurrentDictionary<string, TaskCoordinatorHost> hosts = new();
  private readonly FileSystemWatcher changes;
  private readonly string key;
  private event Action? Changed;
  private TaskCoordinatorHost(AppDataRoot root)
  {
    key = root.NamespaceId;
    var directory = Path.Combine(root.DirectoryPath, "state"); Directory.CreateDirectory(directory);
    changes = new(directory, "hoot-tasks.json") { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
    changes.Changed += (_, _) => Changed?.Invoke(); changes.Created += (_, _) => Changed?.Invoke();
    changes.Renamed += (_, _) => Changed?.Invoke(); changes.Error += (_, _) => Changed?.Invoke();
    changes.EnableRaisingEvents = true;
  }
  public static TaskCoordinatorHost Register(AppDataRoot root) => hosts.GetOrAdd(root.NamespaceId, _ => new(root));
  public static IDisposable Observe(AppDataRoot root, Action refresh)
  {
    var host = Register(root); host.Changed += refresh;
    // The first read also covers an atomic replacement before subscription.
    refresh(); return new Subscription(host, refresh);
  }
  private sealed class Subscription(TaskCoordinatorHost host, Action refresh) : IDisposable
  { public void Dispose() => host.Changed -= refresh; }
  public void Dispose() { hosts.TryRemove(key, out _); changes.Dispose(); }
}
