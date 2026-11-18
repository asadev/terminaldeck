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
public sealed partial class KeeperTaskCoordinator(AppDataRoot root, SessionKeeper sessions, IChatSessions chats, IHoot hoot)
{
  public event Action<string>? Failed;
  public async Task RunAsync(CancellationToken ct)
  {
    using var lease = new TaskCoordinatorLease(root);
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var tasks = new TaskService(TaskStore.At(root), projects, _ => null, recoverStarts: true);
    var budget = CreateBudgetObserver(tasks);
    var completion = CreateTaskCompletion(tasks);
    using var usage = CreateBudgetWatch();
    void UsageChanged(string id) => _ = ObserveUsageAndCompletionAsync(budget, completion, id, ct);
    usage.Changed += UsageChanged;
    var coordinator = new TaskCoordinator(tasks, new SavedSessions(sessions, chats, budget, usage, (id, token) => ObserveBudgetAsync(budget, id, token), (id, signal, token) => ObserveCompletionAsync(completion, id, signal, token)), hoot);
    void Failure(string message) => Failed?.Invoke(message);
    coordinator.Failed += Failure;
    var directory = Path.Combine(root.DirectoryPath, "state"); Directory.CreateDirectory(directory);
    using var changes = new FileSystemWatcher(directory) { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
    void Changed(object sender, FileSystemEventArgs args)
    {
      if (args.Name is "hoot-tasks.json" or "sessions.json") { coordinator.Refresh(); _ = FinishPendingTasksAsync(tasks, completion, ct); }
    }
    void Overflow(object sender, ErrorEventArgs args) => coordinator.Refresh();
    changes.Changed += Changed; changes.Created += Changed; changes.Renamed += Changed; changes.Error += Overflow;
    var chatDirectory = Path.Combine(root.DirectoryPath, "chats"); Directory.CreateDirectory(chatDirectory);
    using var chatChanges = new FileSystemWatcher(chatDirectory, "*.json") { IncludeSubdirectories = true,
      NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite };
    void ChatChanged(object sender, FileSystemEventArgs args) { coordinator.Refresh(); _ = FinishPendingTasksAsync(tasks, completion, ct); }
    chatChanges.Changed += ChatChanged; chatChanges.Created += ChatChanged; chatChanges.Renamed += ChatChanged; chatChanges.Error += Overflow;
    chatChanges.EnableRaisingEvents = true;
    changes.EnableRaisingEvents = true;
    try { await coordinator.RunAsync(ct); }
    finally { changes.EnableRaisingEvents = false; chatChanges.EnableRaisingEvents = false; coordinator.Failed -= Failure; usage.Changed -= UsageChanged; }
  }

  private sealed class SavedSessions(SessionKeeper sessions, IChatSessions chats, TaskBudgetObserver budget, TerminalDeck.Core.Usage.UsageService usage, Func<string, CancellationToken, Task> observe, Func<string, TaskSessionSignal, CancellationToken, Task> complete) : ITaskRunSessions
  {
    public async IAsyncEnumerable<TaskSessionSignal> WatchAsync(string id, [EnumeratorCancellation] CancellationToken ct)
    {
      var watchBudget = budget.Watches(id);
      using var usageWatch = watchBudget ? usage.Watch(id, includeApiTranscript: true) : null;
      if (chats.List().Any(c => c.Definition.Id == id))
      {
        await foreach (var chat in chats.WatchAsync(id, ct))
        {
          if (watchBudget) await observe(id, ct);
          var signal = W9TaskRunner.ChatSignal(chat);
          await complete(id, signal, ct);
          yield return signal;
          if (chat.Ended) yield break;
        }
      }
      else
      {
        await using var attachment = await sessions.AttachAsync(id, ct);
        if (watchBudget) await observe(id, ct);
        if (W9TaskRunner.TerminalSignal(attachment.Snapshot.Session) is { } initial) { await complete(id, initial, ct); yield return initial; }
        if (attachment.Snapshot.Session.State == SessionState.Exited) yield break;
        await foreach (var change in attachment.Events(ct))
        {
          if (!W9TaskRunner.TerminalStatusEvent(change.Kind)) continue;
          if (watchBudget) await observe(id, ct);
          if (W9TaskRunner.TerminalSignal(sessions.Get(id)) is { } signal)
          {
            await complete(id, signal, ct);
            yield return signal;
            if (signal == TaskSessionSignal.Ended) yield break;
          }
        }
      }
    }
  }
}
