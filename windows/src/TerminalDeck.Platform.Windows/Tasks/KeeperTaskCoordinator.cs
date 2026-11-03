using System.Runtime.CompilerServices;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Keeper;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Platform.Windows.Tasks;

// Compose this beside the keeper's existing SessionKeeper, chats and Hoot.
// It only attaches to their saved identities and never launches a task/worker.
public sealed class KeeperTaskCoordinator(AppDataRoot root, SessionKeeper sessions, IChatSessions chats, IHoot hoot)
{
  public event Action<string>? Failed;
  public async Task RunAsync(CancellationToken ct)
  {
    using var lease = new TaskCoordinatorLease(root);
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var tasks = new TaskService(TaskStore.At(root), projects, _ => null, recoverStarts: true);
    var coordinator = new TaskCoordinator(tasks, new SavedSessions(sessions, chats), hoot);
    void Failure(string message) => Failed?.Invoke(message);
    coordinator.Failed += Failure;
    var directory = Path.Combine(root.DirectoryPath, "state"); Directory.CreateDirectory(directory);
    using var changes = new FileSystemWatcher(directory) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
    void Changed(object sender, FileSystemEventArgs args)
    {
      if (args.Name is "hoot-tasks.json" or "sessions.json") coordinator.Refresh();
    }
    void Overflow(object sender, ErrorEventArgs args) => coordinator.Refresh();
    changes.Changed += Changed; changes.Created += Changed; changes.Renamed += Changed; changes.Error += Overflow;
    var chatDirectory = Path.Combine(root.DirectoryPath, "chats"); Directory.CreateDirectory(chatDirectory);
    using var chatChanges = new FileSystemWatcher(chatDirectory, "*.json") { IncludeSubdirectories = true,
      NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
    void ChatChanged(object sender, FileSystemEventArgs args) => coordinator.Refresh();
    chatChanges.Changed += ChatChanged; chatChanges.Created += ChatChanged; chatChanges.Renamed += ChatChanged; chatChanges.Error += Overflow;
    chatChanges.EnableRaisingEvents = true;
    changes.EnableRaisingEvents = true;
    try { await coordinator.RunAsync(ct); }
    finally { changes.EnableRaisingEvents = false; chatChanges.EnableRaisingEvents = false; coordinator.Failed -= Failure; }
  }

  private sealed class SavedSessions(SessionKeeper sessions, IChatSessions chats) : ITaskRunSessions
  {
    public async IAsyncEnumerable<TaskSessionSignal> WatchAsync(string id, [EnumeratorCancellation] CancellationToken ct)
    {
      if (chats.List().Any(c => c.Definition.Id == id))
      {
        await foreach (var chat in chats.WatchAsync(id, ct))
        {
          yield return W9TaskRunner.ChatSignal(chat);
          if (chat.Ended) yield break;
        }
      }
      else
      {
        await using var attachment = await sessions.AttachAsync(id, ct);
        if (W9TaskRunner.TerminalSignal(attachment.Snapshot.Session) is { } initial) yield return initial;
        if (attachment.Snapshot.Session.State == SessionState.Exited) yield break;
        await foreach (var change in attachment.Events(ct))
        {
          if (!W9TaskRunner.TerminalStatusEvent(change.Kind)) continue;
          if (W9TaskRunner.TerminalSignal(sessions.Get(id)) is { } signal)
          {
            yield return signal;
            if (signal == TaskSessionSignal.Ended) yield break;
          }
        }
      }
    }
  }
}
